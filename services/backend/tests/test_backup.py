"""Backup integrity and isolation boundaries; no production restore is performed by unit tests."""

import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
from types import SimpleNamespace
import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
import backup_vps  # noqa: E402


def snapshot(tmp_path, member="11111111-1111-1111-1111-111111111111", link=False):
    (tmp_path / "postgres.dump").write_bytes(b"unit-only-not-a-real-pg-dump")
    with tarfile.open(tmp_path / "evidence.tar", "w") as archive:
        item = tarfile.TarInfo(member)
        if link:
            item.type = tarfile.SYMTYPE
            item.linkname = "/etc/passwd"
            archive.addfile(item)
        else:
            item.size = 5
            archive.addfile(item, io.BytesIO(b"image"))
    manifest = {
        "format": 1,
        "files": {
            name: {"bytes": (tmp_path / name).stat().st_size, "sha256": backup_vps.file_hash(tmp_path / name)}
            for name in backup_vps.FILES
        },
    }
    (tmp_path / "manifest.json").write_text(json.dumps(manifest))
    return tmp_path


def test_snapshot_integrity_detects_modified_backup(tmp_path):
    directory = snapshot(tmp_path)
    assert backup_vps.check_manifest(directory)["format"] == 1
    assert list(backup_vps.evidence_inventory(directory / "evidence.tar").values()) == [
        hashlib.sha256(b"image").hexdigest()
    ]
    (directory / "postgres.dump").write_bytes(b"tampered")
    with pytest.raises(ValueError, match="checksum"):
        backup_vps.check_manifest(directory)


@pytest.mark.parametrize(
    "member,link", [("../../.env", False), (".env", False), ("11111111-1111-1111-1111-111111111111", True)]
)
def test_archive_links_and_traversal_are_never_extracted(tmp_path, member, link):
    directory = snapshot(tmp_path, member, link)
    with pytest.raises(ValueError, match="archive"):
        backup_vps.evidence_inventory(directory / "evidence.tar")


def test_restore_rehearsal_has_no_network_ports_or_production_target(tmp_path, monkeypatch):
    directory = snapshot(tmp_path)
    calls = []
    cid = "a" * 64

    def execute(args, **kwargs):
        calls.append(args)
        if "run" in args:
            assert args[args.index("--network") + 1] == "none"
            assert not any(arg in args for arg in ("-p", "--publish", "--network=host"))
            return cid.encode()
        if "inspect" in args:
            return b"true"
        if "psql" in args:
            return json.dumps(
                [
                    {
                        "key": "11111111-1111-1111-1111-111111111111",
                        "sha256": hashlib.sha256(b"image").hexdigest(),
                    },
                    {"key": "22222222-2222-2222-2222-222222222222", "sha256": "retained-history",
                     "removed_at": "2026-10-29T12:00:00Z"},
                ]
            ).encode()
        return b""

    monkeypatch.setattr(backup_vps, "execute", execute)
    monkeypatch.setattr(backup_vps.subprocess, "run", lambda *a, **k: SimpleNamespace(returncode=0))
    result = backup_vps.rehearse_restore(directory)
    assert result["database_restored"] and result["referenced_images_verified"] == 1
    assert result["evidence_records_restored"] == 2
    assert calls[-1] == ["docker", "rm", "-f", "-v", cid]
    assert all("compose" not in args for args in calls)


@pytest.mark.parametrize(
    "target",
    [
        "host:/tmp/../etc",
        "user@host:/tmp;shutdown",
        "-oProxyCommand=bad",
        "-oUser@host:/private/backups",
        "user@host:/",
    ],
)
def test_offsite_copy_rejects_shell_options_and_shared_root(tmp_path, monkeypatch, target):
    monkeypatch.setattr(
        backup_vps, "execute", lambda *a, **k: pytest.fail("Unsafe remote must never execute")
    )
    with pytest.raises(ValueError):
        backup_vps.copy_offsite(tmp_path, target)
