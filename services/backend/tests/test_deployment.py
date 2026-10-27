"""Shared-VPS preparation is reversible; deployment guards must refuse unrelated resources."""
import json
from pathlib import Path
import sys
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
import prepare_vps  # noqa: E402
import deploy_vps  # noqa: E402


def test_prepare_generates_matching_private_credentials_without_overwriting(tmp_path):
    output = prepare_vps.prepare(tmp_path / "generated", "lab.circuitlab.test")
    env = deploy_vps.read_environment(output / "runtime.env")
    assert len(env["POSTGRES_PASSWORD"]) >= 36 and env["POSTGRES_PASSWORD"] in env["DATABASE_URL"]
    assert env["META_API_KEY"] == "" and env["RESEND_API_KEY"] == ""
    assert env["SITE_ROOT"] == "/var/www/circuitlab" and env["API_BIND_PORT"] == "8014"
    nginx = (output / "circuitlab.https.conf").read_text()
    assert "@@" not in nginx and "server_name lab.circuitlab.test;" in nginx
    assert "root /var/www/circuitlab/build/site;" in nginx
    assert "127.0.0.1:8014" in nginx and "location = /api/v1/devices/connect" in nginx
    with pytest.raises(FileExistsError):
        prepare_vps.prepare(output, "lab.circuitlab.test")
    assert deploy_vps.read_environment(output / "runtime.env")["POSTGRES_PASSWORD"] == env["POSTGRES_PASSWORD"]
    with pytest.raises(ValueError, match="META_API_KEY"):
        deploy_vps.validate_config(env)
    env.update(META_API_KEY="private-test-key", RECOVERY_DELIVERY="disabled")
    assert deploy_vps.validate_config(env) == ("lab.circuitlab.test", "/var/www/circuitlab", 8014)


@pytest.mark.parametrize("domain,root,port", [
    ("lab.test;bad", "/var/www/circuitlab", 8014),
    ("https://lab.test", "/var/www/circuitlab", 8014),
    ("lab.test", "/var/www", 8014),
    ("lab.test", "/var/www/../another", 8014),
    ("lab.test", "/var/www/circuitlab", 80),
])
def test_prepare_rejects_unsafe_or_shared_targets(domain, root, port):
    with pytest.raises(ValueError):
        prepare_vps.validated_target(domain, root, port)


def test_deploy_refuses_a_compose_project_owned_by_another_directory(monkeypatch):
    calls = []

    def run(args, **kwargs):
        calls.append(args)
        if "inspect" in args:
            return SimpleNamespace(stdout=json.dumps({
                "com.docker.compose.project.working_dir": "/var/www/another-project",
                "com.docker.compose.project.config_files": "/var/www/another-project/compose.yaml",
            }))
        return SimpleNamespace(stdout=json.dumps({"ID": "foreign-container"}))

    monkeypatch.setattr(deploy_vps, "run", run)
    with pytest.raises(RuntimeError, match="different directory"):
        deploy_vps.existing_project({"CIRCUITLAB_PROJECT_NAME": "circuitlab", "CIRCUITLAB_IMAGE": "circuitlab-vps-backend:0.1.0"})
    assert all("up" not in call and "stop" not in call and "rm" not in call for call in calls)
