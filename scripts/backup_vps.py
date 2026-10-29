"""Back up CircuitLab's database and immutable evidence; rehearse restore in an isolated container.

Never stops production services, publishes a database port, or restores into the live database.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tarfile
import time
import uuid
from deploy_vps import (
    ROOT,
    DeploymentError,
    existing_project,
    read_environment,
    validate_config,
)

FILES = ("postgres.dump", "evidence.tar")
IMAGE = "postgres:17.4-bookworm"


def execute(args, **kwargs):
    result = subprocess.run(
        args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180, **kwargs
    )
    if result.returncode:
        raise DeploymentError(
            "Backup operation failed; private subprocess output was suppressed"
        )
    return result.stdout


def file_hash(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_manifest(directory):
    directory = Path(directory).resolve()
    manifest = json.loads((directory / "manifest.json").read_text())
    if manifest.get("format") != 1 or set(manifest.get("files", {})) != set(FILES):
        raise ValueError("Unsupported or incomplete backup manifest")
    for name in FILES:
        path = directory / name
        entry = manifest["files"][name]
        if (
            path.is_symlink()
            or not path.is_file()
            or path.stat().st_size != entry["bytes"]
            or file_hash(path) != entry["sha256"]
        ):
            raise ValueError("Backup checksum verification failed")
    return manifest


def evidence_inventory(path):
    """Read without extracting: reject links, traversal and unexpected public/private files."""
    inventory = {}
    with tarfile.open(path, "r:") as archive:
        for item in archive:
            name = item.name.removeprefix("./")
            if item.isdir() and name in {"", "."}:
                continue
            if (
                not item.isfile()
                or not re.fullmatch(r"[0-9a-f-]{36}", name)
                or name in inventory
            ):
                raise ValueError("Unexpected evidence archive entry")
            digest = hashlib.sha256()
            with archive.extractfile(item) as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            inventory[name] = digest.hexdigest()
    return inventory


def create_backup(env, compose):
    existing_project(env)
    base = ROOT / ".tools/backups"
    if base.is_symlink():
        raise ValueError("Backup directory cannot be a symlink")
    base.mkdir(parents=True, exist_ok=True, mode=0o700)
    base.chmod(0o700)
    stamp = (
        datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        + "-"
        + uuid.uuid4().hex[:8]
    )
    directory = base / ("snapshot-" + stamp)
    directory.mkdir(mode=0o700)
    for name, args in [
        (
            "postgres.dump",
            [
                "exec",
                "-T",
                "postgres",
                "pg_dump",
                "-U",
                env["POSTGRES_USER"],
                "-d",
                env["POSTGRES_DB"],
                "-Fc",
            ],
        ),
        (
            "evidence.tar",
            ["exec", "-T", "api", "tar", "-C", "/data/evidence", "-cf", "-", "."],
        ),
    ]:
        path = directory / name
        with path.open("xb") as output:
            path.chmod(0o600)
            result = subprocess.run(
                compose + args, stdout=output, stderr=subprocess.PIPE, timeout=180
            )
        if result.returncode or path.stat().st_size == 0:
            raise DeploymentError(
                "Backup is incomplete; no success manifest was written"
            )
    evidence_inventory(directory / "evidence.tar")
    manifest = {
        "format": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "project": env["CIRCUITLAB_PROJECT_NAME"],
        "files": {
            name: {
                "bytes": (directory / name).stat().st_size,
                "sha256": file_hash(directory / name),
            }
            for name in FILES
        },
    }
    manifest_path = directory / "manifest.json"
    with manifest_path.open("x", encoding="utf-8") as output:
        manifest_path.chmod(0o600)
        output.write(json.dumps(manifest, indent=2) + "\n")
    check_manifest(directory)
    return directory


def rehearse_restore(directory):
    """The throwaway PostgreSQL instance has no network or host ports; production is never a target."""
    directory = Path(directory).resolve()
    check_manifest(directory)
    inventory = evidence_inventory(directory / "evidence.tar")
    name = "circuitlab-restore-check-" + uuid.uuid4().hex[:12]
    child_env = {**os.environ, "POSTGRES_PASSWORD": secrets.token_urlsafe(32)}
    container_id = (
        execute(
            [
                "docker",
                "run",
                "-d",
                "--network",
                "none",
                "--memory",
                "512m",
                "--cpus",
                "0.5",
                "--pids-limit",
                "128",
                "--name",
                name,
                "--label",
                "io.circuitlab.restore-check=true",
                "--env",
                "POSTGRES_PASSWORD",
                IMAGE,
            ],
            env=child_env,
        )
        .decode()
        .strip()
    )
    if not re.fullmatch(r"[0-9a-f]{64}", container_id):
        raise DeploymentError("Could not identify the isolated restore container")
    try:
        for _ in range(60):
            ready = subprocess.run(
                ["docker", "exec", container_id, "pg_isready", "-U", "postgres"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
            )
            if ready.returncode == 0:
                break
            time.sleep(1)
        else:
            raise DeploymentError("Isolated restore database did not become ready")
        execute(
            [
                "docker",
                "exec",
                container_id,
                "createdb",
                "-U",
                "postgres",
                "circuitlab_restore_check",
            ]
        )
        with (directory / "postgres.dump").open("rb") as source:
            execute(
                [
                    "docker",
                    "exec",
                    "-i",
                    container_id,
                    "pg_restore",
                    "--exit-on-error",
                    "--no-owner",
                    "--no-acl",
                    "-U",
                    "postgres",
                    "-d",
                    "circuitlab_restore_check",
                ],
                stdin=source,
            )
        # Restore and inspect EVERY evidence row, including withdrawn history.
        # Older snapshots lack removed_at, so read it through to_jsonb.
        query = ("SELECT COALESCE(json_agg(json_build_object('key',key,'sha256',sha256,"
                 "'removed_at',to_jsonb(evidence)->>'removed_at')), '[]'::json) FROM evidence")
        rows = json.loads(
            execute(
                [
                    "docker",
                    "exec",
                    container_id,
                    "psql",
                    "-U",
                    "postgres",
                    "-d",
                    "circuitlab_restore_check",
                    "-qAt",
                    "-c",
                    query,
                ]
            )
        )
        for row in rows:
            # A withdrawn photo intentionally has no live file; its DB history remains restored.
            if row.get("removed_at") is not None:
                continue
            if inventory.get(row["key"]) != row["sha256"]:
                raise ValueError(
                    "Restored database references missing or changed evidence"
                )
        return {
            "database_restored": True,
            "referenced_images_verified": sum(row.get("removed_at") is None for row in rows),
            "evidence_records_restored": len(rows),
            "isolated_network": True,
        }
    finally:
        # Only the exact container created above, additionally checked by ownership label.
        label = (
            execute(
                [
                    "docker",
                    "inspect",
                    "--format",
                    '{{index .Config.Labels "io.circuitlab.restore-check"}}',
                    container_id,
                ]
            )
            .decode()
            .strip()
        )
        if label == "true":
            execute(["docker", "rm", "-f", "-v", container_id])


def copy_offsite(directory, target):
    if not re.fullmatch(
        r"[A-Za-z0-9_][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9.-]*:/[A-Za-z0-9_./-]+",
        target,
    ) or ".." in target.split(":", 1)[1].split("/"):
        raise ValueError(
            "Use user@host:/dedicated/private/backup/path without shell expressions"
        )
    if target.split(":", 1)[1] in {
        "/",
        "/tmp",
        "/var",
        "/srv",
        "/home",
        "/root",
        "/var/www",
    }:
        raise ValueError("Use a dedicated private remote directory")
    check_manifest(directory)
    # Target must already exist with private permissions. SSH credentials remain outside the repository.
    execute(["scp", "-o", "BatchMode=yes", "-p", "-r", str(directory), target])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, default=ROOT / ".env")
    parser.add_argument(
        "--verify-restoration",
        type=Path,
        help="Rehearse an existing snapshot; makes no production changes",
    )
    parser.add_argument(
        "--check-files", type=Path, help="Check hashes only; makes no Docker calls"
    )
    parser.add_argument(
        "--remote", help="Copy by SSH to a pre-created private off-site directory"
    )
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.check_files:
            check_manifest(args.check_files)
            evidence_inventory(args.check_files / "evidence.tar")
            result = {"files_verified": True}
        elif args.verify_restoration:
            result = rehearse_restore(args.verify_restoration)
        else:
            env = read_environment(args.env_file)
            validate_config(env)
            if os.name != "posix" or str(ROOT) != env["SITE_ROOT"]:
                raise ValueError(
                    "Run from the configured dedicated Linux project directory"
                )
            compose = [
                "docker",
                "compose",
                "--env-file",
                str(args.env_file),
                "-f",
                str(ROOT / "infra/compose.yaml"),
                "-f",
                str(ROOT / "infra/compose.production.yaml"),
            ]
            directory = create_backup(env, compose)
            remote = args.remote or env.get("BACKUP_SSH_TARGET", "")
            if remote:
                copy_offsite(directory, remote)
            result = {
                "snapshot": str(directory),
                "database_and_images_saved": True,
                "offsite_copied": bool(remote),
                "restoration_tested": False,
            }
        print(json.dumps(result, indent=2))
    except Exception as exc:
        print(
            json.dumps(
                {
                    "passed": False,
                    "failure_type": type(exc).__name__,
                    "notice": "Private command output suppressed; no live restore was attempted.",
                }
            )
        )
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
