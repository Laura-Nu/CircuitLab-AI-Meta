"""Isolated protocol/behavior fixtures; no live Meta or physical measurements."""
import io
import time
from PIL import Image
import pytest
from pydantic import ValidationError
from sqlalchemy import select
from app.db import Evidence, Event, Hypothesis, Job, Measurement, Session
from app.schemas import ManualMeasurement, Point
from app.storage import LocalStorage
from app.worker import claim, process, snapshot

P = "/api/v1"


def run_job():
    item = claim()
    assert item
    process(*item)


@pytest.fixture
def digital(client, headers):
    row = client.post(P + "/sessions", headers=headers, json={
        "title": "SYNTHETIC digital operation", "purpose": "check_operation",
        "family": "digital_signal", "expected": "Confirmed output remains false while idle",
        "supply_v": 3.3,
    }).json()
    result = client.patch(f"{P}/sessions/{row['id']}/specification", headers=headers, json={
        "version": row["version"], "confirmed": True,
        "connections": ["UNIT FIXTURE: output to compatible instrument input and common ground"],
        "functional_description": "UNIT FIXTURE: idle output remains false for the stated observation",
        "points": [{"id": "TP1", "label": "Idle output", "kind": "digital_state",
                    "value_kind": "boolean", "expected_state": False}],
    })
    assert result.status_code == 200, result.text
    return result.json()


@pytest.mark.parametrize("value", [0, 1, "false", "true", None])
def test_boolean_manual_requires_native_json_boolean(value):
    with pytest.raises(ValidationError):
        ManualMeasurement(client_id="unit-typed-false", point_id="TP1", unit="boolean",
                          value=value, measured_at=time.time(), conditions_confirmed=True)


@pytest.mark.parametrize("value", [True, False])
def test_volts_never_accept_a_boolean(value):
    with pytest.raises(ValidationError):
        ManualMeasurement(client_id="unit-typed-value", point_id="TP1", unit="V",
                          value=value, measured_at=time.time(), conditions_confirmed=True)


def test_boolean_spec_requires_explicit_expected_state_without_voltage_bounds():
    assert Point(id="TP1", label="State", value_kind="boolean", expected_state=False).expected_state is False
    for extra in ({}, {"expected_state": 0}, {"expected_state": False, "min_v": 0, "max_v": 1}):
        with pytest.raises(ValidationError):
            Point(id="TP1", label="State", value_kind="boolean", **extra)


def test_manual_false_persists_as_boolean_and_requires_functional_check(client, headers, digital, database):
    path = f"{P}/sessions/{digital['id']}"
    assert client.post(path + "/analysis", headers=headers).status_code == 202
    run_job()
    row = client.get(path, headers=headers).json()
    assert row["state"] == "awaiting_measurement"
    base = {"client_id": "unit-false-reading", "point_id": "TP1", "measured_at": time.time(),
            "conditions_confirmed": True}
    assert client.post(path + "/measurements", headers=headers,
                       json={**base, "value": 0, "unit": "V"}).status_code == 422
    response = client.post(path + "/measurements", headers=headers,
                           json={**base, "value": False, "unit": "boolean"})
    assert response.status_code == 201, response.text
    run_job()
    row = client.get(path, headers=headers).json()
    assert row["measurements"][0]["value"] is False
    assert row["measurements"][0]["unit"] == "boolean"
    assert row["state"] != "resolved" and row["completion"]["baseline_available"] is True
    with database() as db:
        reading = db.scalar(select(Measurement).where(Measurement.session_id == digital["id"]))
        assert reading.value is None and reading.boolean_value is False
    completed = client.post(path + "/baseline-check", headers=headers, json={
        "client_id": "unit-false-functional", "passed": True, "confirmed": True,
        "observations": "SYNTHETIC fixture observation only; no physical device",
        "performed_at": time.time(),
    })
    assert completed.status_code == 201, completed.text
    row = client.get(path, headers=headers).json()
    assert row["state"] == "no_fault_found"
    check = row["verifications"][-1]["data"]["checks"][0]
    assert check["value"] is False and check["expected_state"] is False and check["passed"] is True
    assert row["verifications"][-1]["data"]["physical_verification"] is False
    report = client.get(path + "/report?format=markdown",
                        headers={**headers, "Accept-Language": "en"})
    assert report.status_code == 200 and "false" in report.text


@pytest.mark.parametrize("observed", [True, False])
def test_usb_digital_result_preserves_boolean_and_rejects_voltage(client, headers, digital, database, observed):
    sid = digital["id"]
    device = client.post(P + "/devices/enroll", headers=headers, json={
        "name": "SYNTHETIC USB fixture", "transport": "browser_usb",
        "points": ["TP1"], "calibration_id": "unit-fixture-only", "simulated": False,
    }).json()["device_id"]
    lease = client.post(f"{P}/devices/{device}/browser/connect", headers=headers).json()["lease"]
    with database() as db:
        row = db.get(Session, sid)
        row.state = "awaiting_measurement"
        row.pending_test = {"action": "request_manual_measurement", "point_id": "TP1"}
        db.commit()
    response = client.post(f"{P}/sessions/{sid}/hardware", headers=headers, json={
        "device_id": device, "point_id": "TP1", "conditions_confirmed": True})
    assert response.status_code == 202, response.text
    command = client.post(f"{P}/devices/{device}/browser/poll", headers=headers,
                           json={"lease": lease}).json()["commands"][0]
    assert command["action"] == "read_digital"
    result = {"protocol_version": "1", "command_id": command["command_id"], "status": "ok",
              "point_id": "TP1", "value": observed, "unit": "boolean", "sample_count": 20,
              "source": "instrumented", "calibration_id": "unit-fixture-only", "measured_at": time.time()}
    url = f"{P}/devices/{device}/browser/result"
    assert client.post(url, headers=headers, json={"lease": lease,
                       "result": {**result, "value": 0, "unit": "V"}}).status_code == 422
    reply = client.post(url, headers=headers, json={"lease": lease, "result": result})
    assert reply.status_code == 200, reply.text
    duplicate = client.post(url, headers=headers, json={"lease": lease, "result": result})
    assert duplicate.json()["duplicate"] is True
    with database() as db:
        rows = list(db.scalars(select(Measurement).where(Measurement.session_id == sid)))
        assert len(rows) == 1 and rows[0].boolean_value is observed and rows[0].value is None
        assert db.get(Session, sid).state == "analyzing"


def photo(client, headers, sid, client_id="unit-evidence-photo"):
    output = io.BytesIO()
    Image.new("RGB", (16, 16), color="green").save(output, format="PNG")
    response = client.post(f"{P}/sessions/{sid}/evidence", headers=headers,
                           data={"client_id": client_id},
                           files={"file": ("unit.png", output.getvalue(), "image/png")})
    assert response.status_code == 201, response.text
    return response.json()


def test_remove_photo_reclaims_file_and_quota_without_erasing_audit(client, headers, configured, database):
    sid = configured["id"]
    uploaded = photo(client, headers, sid)
    path = f"{P}/sessions/{sid}"
    row = client.get(path, headers=headers).json()
    with database() as db:
        key = db.get(Evidence, uploaded["id"]).key
    assert LocalStorage().path(key).exists()
    body = {"version": row["version"], "confirmed": True}
    url = path + "/evidence/" + uploaded["id"]
    assert client.request("DELETE", url, headers=headers, json={**body, "version": 1}).status_code == 409
    other = client.post(P + "/auth/login",
                        json={"email": "other@example.test", "password": "test-password-123"}).json()
    assert client.request("DELETE", url, headers={"Authorization": "Bearer " + other["access_token"]},
                          json=body).status_code == 403
    assert client.request("DELETE", url, headers=headers, json=body).status_code == 204
    assert client.request("DELETE", url, headers=headers, json=body).status_code == 204
    assert not LocalStorage().path(key).exists()
    assert client.get(url, headers=headers).status_code == 404
    row = client.get(path, headers=headers).json()
    assert row["evidence"] == [] and row["evidence_review_required"] is False
    assert len(row["removed_evidence"]) == 1
    assert photo(client, headers, sid, "unit-new-photo-id")["id"] != uploaded["id"]
    with database() as db:
        assert db.scalar(select(Event).where(Event.session_id == sid, Event.kind == "evidence_removed"))


def test_remove_used_photo_waits_for_job_then_invalidates_derived_conclusions(client, headers, configured, database):
    sid = configured["id"]
    uploaded = photo(client, headers, sid)
    path = f"{P}/sessions/{sid}"
    assert client.post(path + "/analysis", headers=headers).status_code == 202
    row = client.get(path, headers=headers).json()
    url = path + "/evidence/" + uploaded["id"]
    assert client.request("DELETE", url, headers=headers,
                          json={"version": row["version"], "confirmed": True}).status_code == 409
    run_job()
    row = client.get(path, headers=headers).json()
    assert client.post(path + "/measurements", headers=headers, json={
        "client_id": "unit-low-after-photo", "point_id": "TP1", "value": 0.04, "unit": "V",
        "measured_at": time.time(), "conditions_confirmed": True,
    }).status_code == 201
    run_job()
    row = client.get(path, headers=headers).json()
    assert row["hypotheses"]
    assert client.request("DELETE", url, headers=headers,
                          json={"version": row["version"], "confirmed": True}).status_code == 204
    row = client.get(path, headers=headers).json()
    assert row["state"] == "ready" and row["pending_test"] is None
    assert row["evidence_review_required"] is True
    assert all(h["data"]["status"] == "discarded" for h in row["hypotheses"])
    with database() as db:
        context = snapshot(db, db.get(Session, sid))
        assert context["evidence"] == [] and context["previous_hypotheses"] == []
        assert db.scalar(select(Hypothesis).where(Hypothesis.session_id == sid)) is not None
        assert db.scalar(select(Job).where(Job.session_id == sid)) is not None
    assert client.post(path + "/analysis", headers=headers).status_code == 202
    run_job()
    assert client.get(path, headers=headers).json()["evidence_review_required"] is False


def test_file_cleanup_can_retry_after_access_is_revoked(client, headers, configured, database, monkeypatch):
    sid = configured["id"]
    uploaded = photo(client, headers, sid)
    path = f"{P}/sessions/{sid}"
    row = client.get(path, headers=headers).json()
    with database() as db:
        key = db.get(Evidence, uploaded["id"]).key
    original = LocalStorage.delete
    attempts = []
    def temporarily_locked(storage, item):
        attempts.append(item)
        if len(attempts) == 1:
            raise OSError("SYNTHETIC storage lock")
        original(storage, item)
    monkeypatch.setattr(LocalStorage, "delete", temporarily_locked)
    url = path + "/evidence/" + uploaded["id"]
    body = {"version": row["version"], "confirmed": True}
    first = client.request("DELETE", url, headers={**headers, "Accept-Language": "en"}, json=body)
    assert first.status_code == 503 and first.json()["code"] == "evidence_cleanup_pending"
    assert client.get(url, headers=headers).status_code == 404
    assert LocalStorage().path(key).exists()
    assert client.request("DELETE", url, headers=headers, json=body).status_code == 204
    assert not LocalStorage().path(key).exists()
    with database() as db:
        events = list(db.scalars(select(Event).where(Event.session_id == sid, Event.kind == "evidence_removed")))
        assert len(events) == 1
