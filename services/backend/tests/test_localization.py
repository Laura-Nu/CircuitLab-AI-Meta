import ast
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time
import pytest
from app.i18n import ERRORS, negotiate_language
from app.worker import claim, process
from fastapi.testclient import TestClient
from app.main import app
from app.db import Evidence, uid

P = "/api/v1"


def test_unexpected_errors_are_localized_without_exposing_paths(
    client, headers, session, database, monkeypatch
):
    from app.storage import LocalStorage

    def failed_read(self, key):
        raise OSError("private-path-must-not-appear")

    monkeypatch.setattr(LocalStorage, "get", failed_read)
    with database() as db:
        evidence = Evidence(
            session_id=session["id"],
            key=uid(),
            mime="image/jpeg",
            sha256="0" * 64,
            size=10,
            client_id="missing-file",
        )
        db.add(evidence)
        db.commit()
        evidence_id = evidence.id
    with TestClient(app, raise_server_exceptions=False) as safe_client:
        response = safe_client.get(
            f"{P}/sessions/{session['id']}/evidence/{evidence_id}",
            headers={**headers, "Accept-Language": "en"},
        )
    assert response.status_code == 500
    assert response.json() == {
        "detail": "An unexpected error occurred. Please try again.",
        "code": "internal_error",
    }
    assert response.headers["content-language"] == "en"


@pytest.mark.parametrize(
    "header,language",
    [
        (None, "es"),
        ("en-US,en;q=0.9,es;q=0.5", "en"),
        ("es-BO,en;q=0.5", "es"),
        ("fr;q=1,en;q=0.8,es;q=0.9", "es"),
        ("en;q=0,es;q=0.2", "es"),
        ("fr,de", "es"),
        ("en;q=bad,es", "es"),
    ],
)
def test_language_negotiation(header, language):
    assert negotiate_language(header) == language


def test_english_and_spanish_auth_and_validation_errors(client):
    for language, expected in [
        ("en-US", "Incorrect email or password"),
        ("es-BO", "Correo o contraseña incorrectos"),
    ]:
        response = client.post(
            P + "/auth/login",
            headers={"Accept-Language": language},
            json={"email": "absent@example.test", "password": "wrong-password"},
        )
        assert response.status_code == 401 and response.json()["detail"] == expected
        assert response.json()["code"] == "invalid_credentials"
        assert response.headers["content-language"] == language[:2]
    response = client.post(P + "/auth/login", headers={"Accept-Language": "en"}, json={"password": "x"})
    assert response.status_code == 422
    assert response.json()["code"] == "validation_error"
    assert response.json()["detail"].startswith("Check the data")
    assert "input" not in response.json()["errors"][0]


def test_english_workflow_preserves_measurements_and_both_text_versions(client, headers, configured):
    auth = {**headers, "Accept-Language": "en"}
    sid = configured["id"]
    queued = client.post(f"{P}/sessions/{sid}/analysis", headers=auth)
    assert queued.status_code == 202
    process(*claim())
    detail = client.get(f"{P}/sessions/{sid}", headers=auth).json()
    assert detail["language"] == "en"
    assert detail["pending_test"]["instruction"].startswith("SIMULATION:")
    assert detail["pending_test"]["translations"]["es"]["instruction"].startswith("SIMULACIÓN:")
    client.post(
        f"{P}/sessions/{sid}/measurements",
        headers=auth,
        json={
            "client_id": "english-001",
            "point_id": "TP1",
            "value": 0.04,
            "unit": "V",
            "measured_at": time.time(),
            "conditions_confirmed": True,
        },
    )
    process(*claim())
    detail = client.get(f"{P}/sessions/{sid}", headers=auth).json()
    assert detail["hypotheses"][0]["data"]["translations"]["en"]["cause"].startswith("The value")
    english = client.get(f"{P}/sessions/{sid}/report", headers=auth).json()
    spanish = client.get(f"{P}/sessions/{sid}/report", headers=headers).json()
    assert english["measurements"] == spanish["measurements"]
    assert english["expected"] == configured["expected"]
    assert english["presentation"]["family"] == "Voltage divider"
    assert spanish["presentation"]["family"] == "Divisor resistivo"
    assert english["limitations"][0].startswith("Only confirmed")
    markdown = client.get(f"{P}/sessions/{sid}/report?format=markdown", headers=auth)
    assert markdown.headers["content-language"] == "en"
    assert "## Measurements" in markdown.text and "## Timeline" in markdown.text
    assert "0.040 V · Manual" in markdown.text
    assert configured["expected"] in markdown.text
    assert "The value may not meet the specification" in markdown.text


def test_session_language_can_be_selected_explicitly(client, headers):
    data = {
        "title": "My circuit",
        "family": "voltage_divider",
        "expected": "Stable voltage at output",
        "symptoms": "Voltage is fluctuating",
        "supply_v": 5,
    }
    for body, header, expected in [(data, "en", "en"), ({**data, "language": "es"}, "en", "es")]:
        response = client.post(P + "/sessions", headers={**headers, "Accept-Language": header}, json=body)
        assert response.status_code == 201 and response.json()["language"] == expected
    assert client.post(P + "/sessions", headers=headers, json={**data, "language": "fr"}).status_code == 422


def test_all_public_static_errors_have_translations():
    root = Path(__file__).resolve().parents[1] / "app"
    for filename in ("main.py", "domain.py", "security.py", "storage.py", "accounts.py"):
        for node in ast.walk(ast.parse((root / filename).read_text(encoding="utf-8"))):
            if (
                isinstance(node, ast.Call)
                and getattr(node.func, "id", None) == "HTTPException"
                and len(node.args) > 1
            ):
                if isinstance(node.args[1], ast.Constant):
                    assert node.args[1].value in ERRORS, f"Untranslated error: {filename}:{node.lineno}"


def test_client_catalogs_and_generated_output_match():
    root = Path(__file__).resolve().parents[3]
    subprocess.run([sys.executable, str(root / "scripts/generate_localizations.py"), "--check"], check=True)
    en = json.loads((root / "apps/client/lib/l10n/app_en.arb").read_text(encoding="utf-8"))
    es = json.loads((root / "apps/client/lib/l10n/app_es.arb").read_text(encoding="utf-8"))
    assert set(en) == set(es)
    assert len(en) > 190


def test_upgrade_keeps_existing_session_and_defaults_to_spanish(tmp_path):
    backend = Path(__file__).resolve().parents[1]
    path = tmp_path / "migration.db"
    env = {**os.environ, "DATABASE_URL": "sqlite:///" + path.as_posix()}

    def migrate(revision):
        subprocess.run(
            [sys.executable, "-m", "alembic", "upgrade", revision],
            cwd=backend,
            env=env,
            check=True,
            capture_output=True,
        )

    migrate("0001")
    with sqlite3.connect(path) as db:
        db.execute(
            "INSERT INTO users VALUES ('owner', 'migration@example.test', 'not-a-login', 0, '1970-01-01')"
        )
        values = {
            "id": "existing",
            "owner_id": "owner",
            "title": "Original title",
            "family": "voltage_divider",
            "expected": "Original expected",
            "symptoms": "Original symptoms",
            "supply_v": 5,
            "diagnosis_mode": "simulation",
            "state": "draft",
            "version": 1,
            "specification": "{}",
            "spec_version": 0,
            "analysis_steps": 0,
            "created_at": "2026-10-26 00:00:00",
        }
        columns = ",".join(values)
        placeholders = ",".join("?" for _ in values)
        db.execute(f"INSERT INTO sessions ({columns}) VALUES ({placeholders})", tuple(values.values()))
    migrate("head")
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT title, language FROM sessions WHERE id='existing'").fetchone() == (
            "Original title",
            "es",
        )
