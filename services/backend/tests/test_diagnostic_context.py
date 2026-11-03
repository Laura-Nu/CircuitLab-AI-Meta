"""Reported failures and source code guide diagnosis without invented measurements."""
import time
from sqlalchemy import select

from app.db import Event, Measurement, Session
from app.schemas import DiagnosisOutput
from app.worker import claim, process, snapshot, validate_plan
from test_project_observations import project as module_project

project = module_project
P = "/api/v1"


def awaiting_reading(client, headers, project):
    sid = project["id"]
    assert client.post(f"{P}/sessions/{sid}/analysis", headers=headers).status_code == 202
    process(*claim())
    assert client.get(f"{P}/sessions/{sid}", headers=headers).json()["state"] == "awaiting_measurement"
    return sid


def test_reported_dht_error_replans_without_a_temperature_or_changed_criterion(client, headers, project, database):
    sid = awaiting_reading(client, headers, project)
    original = client.get(f"{P}/sessions/{sid}", headers=headers).json()["specification"]
    assert client.post(f"{P}/sessions/{sid}/analysis", headers=headers).status_code == 409
    evidence = client.post(f"{P}/sessions/{sid}/serial-captures", headers=headers, json={
        "client_id": "dht-error-capture", "baud_rate": 9600,
        "lines": ["ERROR: DHT11 sin lectura valida.", "GPS: POSICION VALIDA", "REGISTRO CANCELADO"],
    })
    assert evidence.status_code == 201
    evidence_id = evidence.json()["id"]
    assert client.post(f"{P}/sessions/{sid}/analysis", headers=headers,
                       json={"evidence_id": evidence_id}).status_code == 202
    with database() as db:
        context = snapshot(db, db.get(Session, sid))
        assert context["serial_captures"][0]["lines"][0] == "ERROR: DHT11 sin lectura valida."
        assert context["measurements"] == []
    process(*claim())
    row = client.get(f"{P}/sessions/{sid}", headers=headers).json()
    assert row["specification"] == original and row["measurements"] == []
    # One old error cannot skip every later requested observation.
    assert client.post(f"{P}/sessions/{sid}/analysis", headers=headers,
                       json={"evidence_id": evidence_id}).status_code == 409


def test_program_upload_is_idempotent_and_reaches_the_reasoning_context(client, headers, project, database):
    sid = awaiting_reading(client, headers, project)
    body = {"client_id": "loaded-program-001", "kind": "program",
            "content": "// Synthetic fixture, not executed\n#define DHTPIN 2\n#define DHTTYPE DHT11"}
    upload = client.post(f"{P}/sessions/{sid}/diagnostic-context", headers=headers, json=body)
    assert upload.status_code == 201, upload.text
    again = client.post(f"{P}/sessions/{sid}/diagnostic-context", headers=headers, json=body)
    assert again.json()["id"] == upload.json()["id"]
    with database() as db:
        context = snapshot(db, db.get(Session, sid))
        assert context["context_evidence"][0]["content"] == body["content"]
        assert len(list(db.scalars(select(Event).where(
            Event.session_id == sid, Event.kind == "program_submitted")))) == 1
    from app.meta import response_context
    _, observations = response_context(context)
    assert observations["context_evidence"][0]["content"] == body["content"]
    assert client.post(f"{P}/sessions/{sid}/analysis", headers=headers,
                       json={"evidence_id": upload.json()["id"]}).status_code == 202


def test_problem_note_preserves_unknown_reading_and_rejects_foreign_evidence(client, headers, project):
    sid = awaiting_reading(client, headers, project)
    body = {"client_id": "reported-problem-001", "kind": "problem", "point_id": "TP1",
            "content": "The program reports a failed read; temperature is unavailable."}
    note = client.post(f"{P}/sessions/{sid}/diagnostic-context", headers=headers, json=body)
    assert note.status_code == 201
    bad = client.post(f"{P}/sessions/{sid}/analysis", headers=headers,
                      json={"evidence_id": "not-in-this-session"})
    assert bad.status_code == 409
    other = client.post(f"{P}/auth/login", json={"email": "other@example.test", "password": "test-password-123"})
    other_headers = {"Authorization": f"Bearer {other.json()['access_token']}"}
    assert client.post(f"{P}/sessions/{sid}/diagnostic-context", headers=other_headers, json=body).status_code == 403
    assert client.post(f"{P}/sessions/{sid}/analysis", headers=headers,
                       json={"evidence_id": note.json()["id"]}).status_code == 202
    assert client.get(f"{P}/sessions/{sid}", headers=headers).json()["measurements"] == []


def test_model_can_request_program_or_propose_a_check_from_cited_logs():
    context = {"evidence": [], "measurements": [], "specification": {"points": []},
               "serial_captures": [{"id": "actual-log"}]}
    output = DiagnosisOutput(observations=["Firmware reports a failed read"], hypotheses=[],
                             action="request_program", instruction="Attach the actual program and DHT pin assignment",
                             rationale="Check configuration before claiming a hardware fault")
    validate_plan(output, context)
    output.action = "propose_intervention"
    from app.schemas import HypothesisOutput
    output.hypotheses = [HypothesisOutput(cause="Possible configuration mismatch", status="proposed",
                                         evidence_ids=["actual-log"], explanation="Check the reported failure")]
    validate_plan(output, context)
    output.hypotheses[0].status = "supported_by_test"
    import pytest
    with pytest.raises(ValueError, match="sin medida"):
        validate_plan(output, context)


def test_follow_up_reuses_editable_criteria_without_reusing_physical_results(client, headers, project, database):
    with database() as db:
        previous = db.get(Session, project["id"])
        previous.state = "inconclusive"
        db.add(Measurement(session_id=previous.id, client_id="previous-temperature", point_id="TP1",
                           value=22.5, unit="°C", source="manual", measured_at=time.time()))
        db.commit()
    body = {key: project[key] for key in ("title", "family", "expected", "symptoms", "setup", "purpose", "supply_v")}
    body["reference_session_id"] = project["id"]
    response = client.post(f"{P}/sessions", headers=headers, json=body)
    assert response.status_code == 201, response.text
    follow_up = response.json()
    assert follow_up["state"] == "draft" and follow_up["spec_version"] == 0
    assert follow_up["specification"]["points"] == project["specification"]["points"]
    assert follow_up["specification"]["confirmed"] is False
    assert client.post(f"{P}/sessions/{follow_up['id']}/analysis", headers=headers).status_code == 409
    assert client.get(f"{P}/sessions/{follow_up['id']}", headers=headers).json()["measurements"] == []


def test_model_request_program_exposes_an_upload_step(client, headers, project, monkeypatch):
    output = DiagnosisOutput(observations=["Reported sensor error needs code review"], hypotheses=[],
                             action="request_program", instruction="Attach the loaded DHT11 program and pin assignments",
                             rationale="A failed read does not establish its cause")
    monkeypatch.setattr("app.worker.analyze", lambda context: (output, {"provider": "simulation"}))
    sid = project["id"]
    assert client.post(f"{P}/sessions/{sid}/analysis", headers=headers).status_code == 202
    process(*claim())
    row = client.get(f"{P}/sessions/{sid}", headers=headers).json()
    assert row["state"] == "awaiting_evidence" and row["pending_test"]["action"] == "request_program"
