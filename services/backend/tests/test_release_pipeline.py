"""Deployment preparation guards tested locally; no remote SSH or production mutations."""
import io
import os
import json
from pathlib import Path
import sys
import tarfile
from types import SimpleNamespace
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts"))
import release_bundle as bundle  # noqa: E402
import deploy_gateway as gateway  # noqa: E402
import ci_ship  # noqa: E402

REVISION = "a" * 40


def public_site(tmp_path):
    site = tmp_path / "public"
    for folder in ("app", "downloads"):
        (site / folder).mkdir(parents=True)
    (site / "index.html").write_text("Landing", encoding="utf-8")
    (site / "app/index.html").write_text("App", encoding="utf-8")
    apk = site / "downloads/circuitlab-ai.apk"
    apk.write_bytes(b"UNIT APK CONTENT")
    (site / "downloads/circuitlab-ai.apk.sha256").write_text(bundle.digest(apk))
    return site


def test_checked_public_bundle_roundtrip_and_tamper_detection(tmp_path):
    site = public_site(tmp_path)
    (site / "app/.last_build_id").write_text("local-flutter-build-stamp")
    archive = bundle.package(REVISION, tmp_path / "release.tar.gz", site)
    destination = bundle.extract(archive, REVISION, bundle.digest(archive), tmp_path / "stage")
    assert (destination / "app/index.html").read_text() == "App"
    assert not (destination / "app/.last_build_id").exists()
    assert json.loads((destination / "release.json").read_text())["revision"] == REVISION
    with pytest.raises(ValueError, match="checksum"):
        bundle.extract(archive, REVISION, "0" * 64, tmp_path / "tampered")
    with pytest.raises(ValueError, match="approved commit"):
        bundle.extract(archive, "b" * 40, bundle.digest(archive), tmp_path / "wrong-commit")


@pytest.mark.parametrize("name", ["../.env", "/etc/passwd", ".env", "app/.env", "app/private.pem",
                                   "app/../secret", "app\\private.key", "backend/main.py"])
def test_public_paths_reject_traversal_and_private_files(name):
    with pytest.raises(ValueError):
        bundle.public_name(name)


@pytest.mark.parametrize("kind", ["symlink", "duplicate", "traversal"])
def test_archive_rejected_before_extraction(tmp_path, kind):
    archive = tmp_path / "bad.tar.gz"
    with tarfile.open(archive, "w:gz") as output:
        item = tarfile.TarInfo("../escape" if kind == "traversal" else "app/index.html")
        if kind == "symlink":
            item.type = tarfile.SYMTYPE
            item.linkname = "/etc/passwd"
            output.addfile(item)
        else:
            item.size = 1
            output.addfile(item, io.BytesIO(b"x"))
            if kind == "duplicate":
                output.addfile(item, io.BytesIO(b"x"))
    stage = tmp_path / "stage"
    with pytest.raises(ValueError):
        bundle.extract(archive, REVISION, bundle.digest(archive), stage)
    assert not stage.exists()


@pytest.mark.parametrize("command", ["bash", "circuitlab-deploy " + REVISION + " " + "f"*64 + "; id",
                                     "circuitlab-deploy ../branch " + "f"*64, ""])
def test_forced_ssh_refuses_shell_and_unapproved_arguments(command):
    with pytest.raises(ValueError):
        gateway.parse_command(command)


def test_forced_command_parses_only_exact_release_identity():
    assert gateway.parse_command("circuitlab-deploy " + REVISION + " " + "f"*64) == (REVISION, "f"*64)


def test_dirty_or_outdated_checkout_is_never_merged(monkeypatch):
    calls = []
    def git(*args):
        calls.append(args)
        if args[0] == "status":
            return " M apps/client/pubspec.lock"
        return ""
    monkeypatch.setattr(gateway, "git", git)
    with pytest.raises(RuntimeError, match="local changes"):
        gateway.approved_checkout(REVISION)
    assert len(calls) == 1
    calls.clear()
    def git_outdated(*args):
        calls.append(args)
        return "b"*40 if args[0] == "rev-parse" else ""
    monkeypatch.setattr(gateway, "git", git_outdated)
    with pytest.raises(RuntimeError, match="newer main"):
        gateway.approved_checkout(REVISION)
    assert not any(args[0] == "merge" for args in calls)


def test_transport_pins_host_key_and_cleans_private_files(tmp_path, monkeypatch, capsys):
    archive = bundle.package(REVISION, tmp_path / "site.tar.gz", public_site(tmp_path))
    env = {"CIRCUITLAB_SSH_HOST": "vps.example.test", "CIRCUITLAB_SSH_USER": "deploy",
           "CIRCUITLAB_SSH_KEY": "UNIT-PRIVATE-KEY", "CIRCUITLAB_SSH_KNOWN_HOSTS": "UNIT-HOST-KEY"}
    paths = []
    def run(args, **kwargs):
        assert "StrictHostKeyChecking=yes" in args and "HostKeyAlias=circuitlab-vps" in args
        assert kwargs["stdin"].read() == archive.read_bytes()
        key = Path(args[args.index("-i") + 1])
        paths.append(key)
        assert key.read_text().strip() == env["CIRCUITLAB_SSH_KEY"]
        return SimpleNamespace(returncode=0)
    monkeypatch.setattr(ci_ship.subprocess, "run", run)
    ci_ship.ship(REVISION, archive, env)
    assert not paths[0].exists()
    output = capsys.readouterr().out
    assert env["CIRCUITLAB_SSH_KEY"] not in output and env["CIRCUITLAB_SSH_KNOWN_HOSTS"] not in output


def test_transport_refuses_corrupt_artifact_before_ssh(tmp_path, monkeypatch):
    archive = bundle.package(REVISION, tmp_path / "site.tar.gz", public_site(tmp_path))
    archive.write_bytes(b"corrupted")
    env = {"CIRCUITLAB_SSH_HOST": "vps.example.test", "CIRCUITLAB_SSH_USER": "deploy",
           "CIRCUITLAB_SSH_KEY": "UNIT", "CIRCUITLAB_SSH_KNOWN_HOSTS": "UNIT"}
    monkeypatch.setattr(ci_ship.subprocess, "run", lambda *a, **k: pytest.fail("Must not open SSH"))
    with pytest.raises(ValueError, match="checksum"):
        ci_ship.ship(REVISION, archive, env)

@pytest.mark.skipif(os.name != "posix", reason="Production symlink publication uses Linux semantics")
def test_publication_preserves_previous_site_and_rolls_back_without_touching_other_projects(tmp_path, monkeypatch):
    project = tmp_path / "circuitlab"
    old = project / "build/site"
    old.mkdir(parents=True)
    (old / "index.html").write_text("Previous")
    stage = project / "build/releases/new"
    (stage / "app").mkdir(parents=True)
    (stage / "app/index.html").write_text("New app")
    (stage / "index.html").write_text("New")
    stage.parent.chmod(0o700)
    other = tmp_path / "other-project"
    other.mkdir()
    (other / "untouched").write_text("Keep")
    monkeypatch.setattr(gateway, "ROOT", project)
    previous = gateway.publish(stage, REVISION)
    assert old.is_symlink() and (old / "index.html").read_text() == "New"
    assert stage.parent.stat().st_mode & 0o777 == 0o755
    assert (previous / "index.html").read_text() == "Previous"
    gateway.rollback_public(previous)
    assert (old / "index.html").read_text() == "Previous"
    assert (other / "untouched").read_text() == "Keep"


@pytest.mark.parametrize("status,stderr,expected", [
    (255, "Host key verification failed.", "ssh_host_key"),
    (255, "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!", "ssh_host_key"),
    (255, 'Load key "/tmp/private": error in libcrypto', "ssh_private_key"),
    (255, "unit@host: Permission denied (publickey).", "ssh_authentication"),
    (255, "ssh: connect to host unit port 22: Connection refused", "ssh_connection"),
    (255, "Disconnected without known detail", "ssh_transport"),
    (127, "bash: circuitlab-deploy: command not found", "ssh_forced_command"),
    (2, "/usr/bin/python3: can't open file '/var/www/circuitlab/scripts/deploy_gateway.py': No such file", "remote_gateway_missing"),
    (1, "CircuitLab deployment failed: Project has tracked local changes; deployment refused", "dirty_checkout"),
    (1, "CircuitLab deployment failed: Project Git operation failed; inspect the VPS privately", "remote_git_failed"),
    (1, "CircuitLab deployment failed: ConfigurationError", "remote_configuration"),
    (1, "CircuitLab deployment failed: DeploymentError", "remote_backend_failed"),
    (1, "CircuitLab deployment failed: untrusted provider response", "remote_failure"),
])
def test_ssh_diagnostics_are_fixed_categories_and_never_forward_remote_output(status, stderr, expected):
    sensitive = "UNIT-SECRET-MUST-NOT-APPEAR"
    result = SimpleNamespace(returncode=status, stderr=(stderr + "\n" + sensitive).encode())
    code, message = ci_ship.deployment_failure(result)
    assert code == expected
    assert sensitive not in message and sensitive not in code
    assert "untrusted provider response" not in message


def test_failed_shipping_cleans_key_and_reports_safe_reason_only(tmp_path, monkeypatch, capsys):
    archive = bundle.package(REVISION, tmp_path / "site.tar.gz", public_site(tmp_path))
    env = {"CIRCUITLAB_SSH_HOST": "vps.example.test", "CIRCUITLAB_SSH_USER": "deploy",
           "CIRCUITLAB_SSH_KEY": "UNIT-PRIVATE-KEY", "CIRCUITLAB_SSH_KNOWN_HOSTS": "UNIT-HOST-KEY"}
    paths = []
    def run(args, **kwargs):
        paths.append(Path(args[args.index("-i") + 1]))
        return SimpleNamespace(returncode=255, stderr=b"Permission denied (publickey). UNIT-PRIVATE-KEY", stdout=b"UNIT-OTHER-SECRET")
    monkeypatch.setattr(ci_ship.subprocess, "run", run)
    with pytest.raises(RuntimeError, match="ssh_authentication") as failure:
        ci_ship.ship(REVISION, archive, env)
    assert "UNIT-PRIVATE-KEY" not in str(failure.value) and "UNIT-OTHER-SECRET" not in str(failure.value)
    assert not paths[0].exists()
    assert "UNIT-" not in capsys.readouterr().out


@pytest.mark.parametrize("stage", list(ci_ship.BACKEND_STAGES))
def test_backend_failure_stage_survives_the_legacy_gateway_without_exposing_output(stage, capsys):
    import deploy_vps
    with pytest.raises(deploy_vps.DeploymentError):
        with deploy_vps.backend_stage(stage):
            raise deploy_vps.DeploymentError("UNIT-PRIVATE-PROCESS-OUTPUT")
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "UNIT-PRIVATE-PROCESS-OUTPUT" not in captured.err
    result = SimpleNamespace(returncode=1, stderr=(
        captured.err + "CircuitLab deployment failed: DeploymentError\\nUNIT-PRIVATE-PROCESS-OUTPUT").encode())
    code, message = ci_ship.deployment_failure(result)
    assert code == "backend_" + stage and message == ci_ship.BACKEND_STAGES[stage]
    assert "UNIT-PRIVATE-PROCESS-OUTPUT" not in message


def test_untrusted_backend_stage_is_never_echoed():
    result = SimpleNamespace(returncode=1, stderr=b"CircuitLab backend stage failed: UNIT-SECRET")
    code, message = ci_ship.deployment_failure(result)
    assert code == "remote_failure" and "UNIT-SECRET" not in message
