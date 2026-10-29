import time
from sqlalchemy import select
from app.db import Measurement, Session
from app.worker import claim, process

P = "/api/v1"


def healthy_fixture(database, configured, state="inconclusive", source="simulated"):
    with database() as db:
        session = db.get(Session, configured["id"])
        session.state = state
        session.analysis_steps = 2
        db.add(Measurement(session_id=session.id, client_id="baseline-fixture", point_id="TP1",
                           value=2.5, unit="V", source=source, phase="diagnosis", measured_at=time.time()))
        db.commit()
    return configured["id"]


def body(passed=True):
    return {"client_id": "baseline-check-001", "passed": passed,
            "observations": "Isolated virtual functional assertion, not hardware.",
            "performed_at": time.time(), "confirmed": True}


def test_healthy_baseline_closes_without_inventing_a_repair(client, headers, configured, database):
    sid = healthy_fixture(database, configured)
    result = client.post(f"{P}/sessions/{sid}/baseline-check", headers=headers, json=body())
    assert result.status_code == 201
    report = client.get(f"{P}/sessions/{sid}/report", headers=headers).json()
    assert report["state"] == "no_fault_found"
    assert report["interventions"] == []
    verification = report["verifications"][-1]["data"]
    assert verification["assessment_kind"] == "baseline"
    assert verification["physical_verification"] is False
    assert verification["passed"] is True
    # Retrying the same submission must not create a second finalization record.
    assert client.post(f"{P}/sessions/{sid}/baseline-check", headers=headers, json=body()).status_code == 201
    assert len(client.get(f"{P}/sessions/{sid}/report", headers=headers).json()["verifications"]) == 1


def test_baseline_requires_all_ranges_and_a_fresh_functional_observation(client, headers, configured, database):
    sid = healthy_fixture(database, configured)
    stale = body()
    stale["performed_at"] = time.time() - 100
    assert client.post(f"{P}/sessions/{sid}/baseline-check", headers=headers, json=stale).status_code == 422
    with database() as db:
        reading = db.scalar(select(Measurement).where(Measurement.session_id == sid))
        reading.value = 0.1
        db.commit()
    assert client.post(f"{P}/sessions/{sid}/baseline-check", headers=headers, json=body()).status_code == 409


def test_failed_baseline_remains_unresolved(client, headers, configured, database):
    sid = healthy_fixture(database, configured, "awaiting_functional_check")
    result = client.post(f"{P}/sessions/{sid}/baseline-check", headers=headers, json=body(False))
    assert result.status_code == 201
    report = client.get(f"{P}/sessions/{sid}/report", headers=headers).json()
    assert report["state"] == "inconclusive"
    assert report["verifications"][-1]["data"]["passed"] is False
    assert report["verifications"][-1]["data"]["physical_verification"] is False


def test_close_records_reason_and_does_not_verify(client, headers, configured, database):
    sid = configured["id"]
    current = client.get(f"{P}/sessions/{sid}", headers=headers).json()
    payload = {"version": current["version"], "reason": "No hardware available for this review.", "confirmed": True}
    closed = client.post(f"{P}/sessions/{sid}/close", headers=headers, json=payload)
    assert closed.status_code == 200
    report = client.get(f"{P}/sessions/{sid}/report", headers=headers).json()
    assert report["state"] == "cancelled"
    assert not report["verifications"]
    assert next(e for e in report["events"] if e["kind"] == "investigation_closed")["data"]["reason"] == payload["reason"]
    assert client.post(f"{P}/sessions/{sid}/analysis", headers=headers).status_code == 409


def test_close_cannot_interrupt_active_work_or_use_stale_version(client, headers, configured, database):
    sid = configured["id"]
    assert client.post(f"{P}/sessions/{sid}/close", headers=headers,
                       json={"version": 1, "reason": "Stop this isolated review.", "confirmed": True}).status_code == 409
    client.post(f"{P}/sessions/{sid}/analysis", headers=headers)
    s = client.get(f"{P}/sessions/{sid}", headers=headers).json()
    assert client.post(f"{P}/sessions/{sid}/close", headers=headers,
                       json={"version": s["version"], "reason": "Stop this isolated review.", "confirmed": True}).status_code == 409


def test_worker_hands_healthy_readings_to_functional_check(client, headers, configured, database, monkeypatch):
    from app.schemas import DiagnosisOutput
    from app import worker
    sid = healthy_fixture(database, configured, "ready")
    monkeypatch.setattr(worker, "analyze", lambda context: (
        DiagnosisOutput(observations=["Within declared ranges"], hypotheses=[], action="inconclusive",
                        instruction="Perform the functional check", rationale="No fault supported by these readings"),
        {"provider": "simulation", "model": "unit-fixture"},
    ))
    queued = client.post(f"{P}/sessions/{sid}/analysis", headers=headers).json()
    process(*claim(queued["job_id"]))
    detail = client.get(f"{P}/sessions/{sid}", headers=headers).json()
    assert detail["state"] == "awaiting_functional_check"
    assert detail["completion"]["baseline_available"] is True
    assert detail["completion"]["terminal"] is False

def test_reader_cannot_close_or_finalize_someone_elses_baseline(client, headers, configured, database):
    sid = healthy_fixture(database, configured)
    login = client.post(P + "/auth/login", json={"email": "other@example.test", "password": "test-password-123"}).json()
    other = {"Authorization": "Bearer " + login["access_token"]}
    assert client.post(f"{P}/sessions/{sid}/baseline-check", headers=other, json=body()).status_code == 403
    assert client.post(f"{P}/sessions/{sid}/close", headers=other,
                       json={"version": 1, "reason": "Not my investigation", "confirmed": True}).status_code == 403


def test_failed_baseline_cannot_be_overwritten_using_the_same_old_readings(client, headers, configured, database):
    sid = healthy_fixture(database, configured, "awaiting_functional_check")
    assert client.post(f"{P}/sessions/{sid}/baseline-check", headers=headers, json=body(False)).status_code == 201
    retry = body(True)
    retry["client_id"] = "another-baseline-assertion"
    assert client.post(f"{P}/sessions/{sid}/baseline-check", headers=headers, json=retry).status_code == 409
