"""Restricted SSH entry point: receive an approved public artifact and deploy only CircuitLab."""
from contextlib import contextmanager
from datetime import UTC, datetime
import importlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.request
import uuid

from release_bundle import digest, extract

ROOT = Path(__file__).resolve().parents[1]
COMMAND = re.compile(r"circuitlab-deploy ([0-9a-f]{40}) ([0-9a-f]{64})")


def parse_command(command):
    match = COMMAND.fullmatch(command)
    if not match:
        raise ValueError("Only a CircuitLab deployment command is allowed")
    return match.groups()


def git(*args):
    result = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError("Project Git operation failed; inspect the VPS privately")
    return result.stdout.strip()


def approved_checkout(revision):
    if git("status", "--porcelain", "--untracked-files=no"):
        raise RuntimeError("Project has tracked local changes; deployment refused")
    git("fetch", "--no-tags", "origin", "main")
    if git("rev-parse", "refs/remotes/origin/main") != revision:
        raise RuntimeError("A newer main commit exists; this outdated deployment was refused")
    previous = git("rev-parse", "HEAD")
    result = subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", previous, revision],
                            capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError("Deployment requires a fast-forward checkout")
    git("merge", "--ff-only", revision)
    return previous


@contextmanager
def locked_project():
    import fcntl
    private = ROOT / ".tools"
    private.mkdir(exist_ok=True, mode=0o700)
    lock = private / "deployment.lock"
    with lock.open("a") as descriptor:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another CircuitLab deployment is running") from None
        try:
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)


def receive(source, revision, expected_digest):
    incoming = ROOT / ".tools/deploy/incoming"
    incoming.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not incoming.resolve().is_relative_to(ROOT):
        raise ValueError("Incoming directory is outside the project")
    path = incoming / (revision + "-" + uuid.uuid4().hex + ".tar.gz")
    total = 0
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as target:
        while block := source.read(1024 * 1024):
            total += len(block)
            if total > 256 * 1024 * 1024:
                raise ValueError("Incoming archive is too large")
            target.write(block)
    if digest(path) != expected_digest:
        raise ValueError("Incoming archive checksum mismatch")
    return path


def publish(stage, revision):
    build = ROOT / "build"
    build.mkdir(exist_ok=True, mode=0o755)
    build.chmod(0o755)
    stage = stage.resolve()
    if not stage.is_relative_to((build / "releases").resolve()) or not (stage / "app/index.html").is_file():
        raise ValueError("Public staging directory is outside the project releases")
    releases = build / "releases"
    releases.chmod(0o755)
    live = build / "site"
    if live.exists() and not live.is_dir():
        raise ValueError("Existing public website is not a directory")
    link = build / (".site-" + uuid.uuid4().hex)
    link.symlink_to(stage, target_is_directory=True)
    old = live.resolve() if live.exists() else None
    if old and not old.is_relative_to(build.resolve()):
        raise ValueError("Existing website points outside this project")
    if live.exists() and not live.is_symlink():
        legacy = build / "releases" / ("legacy-" + datetime.now(UTC).strftime("%Y%m%dT%H%M%S%f"))
        legacy.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
        live.rename(legacy)
        old = legacy
    os.replace(link, live)
    return old


def rollback_public(previous):
    if previous is not None:
        link = ROOT / "build" / (".rollback-" + uuid.uuid4().hex)
        link.symlink_to(previous, target_is_directory=True)
        os.replace(link, ROOT / "build/site")


def verify_public(origin, revision):
    for path, key, expected in [
        ("/api/v1/health/ready", "status", "ready"),
        ("/api/v1/health/live", "build_revision", revision),
        ("/release.json?revision=" + revision, "revision", revision),
    ]:
        with urllib.request.urlopen(origin + path, timeout=20) as response:
            if json.load(response).get(key) != expected:
                raise RuntimeError("Public production health or revision verification failed")


def deploy(revision, expected_digest, source):
    if os.name != "posix" or str(ROOT) != "/var/www/circuitlab":
        raise ValueError("This entry point is limited to Linux /var/www/circuitlab")
    with locked_project():
        bundle = receive(source, revision, expected_digest)
        stage = ROOT / "build/releases" / (revision + "-" + uuid.uuid4().hex)
        if not stage.resolve().is_relative_to(ROOT / "build"):
            raise ValueError("Invalid public release destination")
        # Public ancestors must be traversable by Nginx even with a private deployment umask.
        stage.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
        stage.parent.chmod(0o755)
        # Validate the artifact before changing the project checkout or running Docker.
        extract(bundle, revision, expected_digest, stage)
        previous_revision = approved_checkout(revision)
        import deploy_vps
        importlib.reload(deploy_vps)
        env = deploy_vps.read_environment(ROOT / ".env")
        deploy_vps.validate_config(env)
        if env["SITE_ROOT"] != str(ROOT):
            raise ValueError("Configured root does not match the dedicated project directory")
        env["CIRCUITLAB_IMAGE"] = env["CIRCUITLAB_IMAGE"].split(":")[0] + ":" + revision
        compose = ["docker", "compose", "--env-file", str(ROOT / ".env"), "-p", env["CIRCUITLAB_PROJECT_NAME"],
                   "-f", str(ROOT / "infra/compose.yaml"), "-f", str(ROOT / "infra/compose.production.yaml")]
        # Existing script backs up PostgreSQL, applies migrations, and verifies both API and worker.
        # Keep the old public site online until these checks pass.
        deploy_vps._apply(env, compose)
        previous_site = publish(stage, revision)
        try:
            verify_public(env["APP_ORIGIN"], revision)
        except Exception:
            rollback_public(previous_site)
            raise RuntimeError("Public verification failed; previous website restored. Review API/worker privately") from None
        manifest = ROOT / ".tools/deploy/active.json"
        manifest.write_text(json.dumps({"revision": revision, "previous_revision": previous_revision,
                                       "site": str(stage), "previous_site": str(previous_site) if previous_site else None,
                                       "image": env["CIRCUITLAB_IMAGE"]}, indent=2) + "\n", encoding="utf-8")
        manifest.chmod(0o600)
        bundle.unlink()
        print("CircuitLab deployment and HTTPS revision verified: " + revision)


def main():
    try:
        revision, expected_digest = parse_command(os.environ.get("SSH_ORIGINAL_COMMAND", ""))
        deploy(revision, expected_digest, sys.stdin.buffer)
    except Exception as error:
        # Fixed errors only: never echo command lines, env values or subprocess stderr.
        known = str(error) if type(error) in {ValueError, RuntimeError} else type(error).__name__
        print("CircuitLab deployment failed: " + known, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
