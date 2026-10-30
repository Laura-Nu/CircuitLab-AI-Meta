"""Structured serial ingestion uses reported values, never fabricated instrument readings."""
import json
import time

import pytest
from pydantic import ValidationError
from sqlalchemy import select

from app.db import Event, Job, Measurement, Session
from app.schemas import SerialTelemetry
from app.worker import claim, process, snapshot
from test_project_observations import project as module_project

P = "/api/v1"
project = module_project


def packet(value=23.5, unit="°C", channel="dht11.temperature", sensor="DHT11", label="Temperature"):
    return json.dumps({"circuitlab": 1, "channel": channel, "value": value, "unit": unit,
                       "sensor": sensor, "board": "Arduino UNO", "label": label}, ensure_ascii=False)


def request(row, value=23.5, unit="°C", point="TP1", client_id="serial-reading-001"):
    return {"client_id": client_id, "point_id": point, "line": packet(value, unit),
            "received_at": time.time(), "conditions_confirmed": True,
            "spec_version": row["spec_version"], "request_version": row["version"]}


def start(client, headers, sid):
    assert client.post(f"{P}/sessions/{sid}/analysis", headers=headers).status_code == 202
    process(*claim())
    return client.get(f"{P}/sessions/{sid}", headers=headers).json()


def test_three_module_usb_pipeline_advances_without_transcription(client, headers, project, database):
    sid = project["id"]
    row = start(client, headers, sid)
    modules = [(1, 23.5, "°C", "dht11.temperature", "DHT11", "Temperature"),
               (2, True, "boolean", "rc522.card", "RC522", "RFID card detected"),
               (3, "FIX", "text", "neo8m.status", "NEO-8M", "GPS status")]
    for index, value, unit, channel, sensor, label in modules:
        assert row["state"] == "awaiting_measurement"
        assert row["pending_test"]["point_id"] == f"TP{index}"
        assert row["pending_test"]["requested_at"] > 0
        body = request(row, value, unit, f"TP{index}", f"serial-auto-{index}")
        body["line"] = packet(value, unit, channel, sensor, label)
        result = client.post(f"{P}/sessions/{sid}/serial-readings", headers=headers, json=body)
        assert result.status_code == 201, result.text
        assert result.json()["value"] == value
        assert result.json()["source"] == "serial_reported"
        assert result.json()["calibration_id"] is None
        with database() as db:
            jobs = list(db.scalars(select(Job).where(Job.session_id == sid, Job.status == "pending")))
            assert len(jobs) == 1
        process(*claim())
        row = client.get(f"{P}/sessions/{sid}", headers=headers).json()
    assert row["state"] == "awaiting_functional_check"
    with database() as db:
        session = db.get(Session, sid)
        session.diagnosis_mode = "meta"
        db.commit()
        assert len(list(db.scalars(select(Event).where(
            Event.session_id == sid, Event.kind == "serial_reading_received")))) == 3
        provenance = snapshot(db, session)["serial_provenance"]
        assert {(entry["channel"], entry["sensor"], entry["board"], entry["label"]) for entry in provenance} == {
            (channel, sensor, "Arduino UNO", label) for _, _, _, channel, sensor, label in modules}
        assert all(entry["measurement_id"] and entry["received_at"] for entry in provenance)
        assert all("line" not in entry and "id" not in entry for entry in provenance)
    check = client.post(f"{P}/sessions/{sid}/baseline-check", headers=headers, json={
        "client_id": "serial-functional-001", "passed": True, "confirmed": True,
        "observations": "All declared module functions were observed", "performed_at": time.time(),
    })
    assert check.status_code == 201, check.text
    row = client.get(f"{P}/sessions/{sid}", headers=headers).json()
    assessment = row["verifications"][0]["data"]
    assert row["state"] == "no_fault_found"
    assert assessment["verification_basis"] == "serial_reported"
    assert not assessment["physical_verification"] and not assessment["physical_functional_check"]
    report = client.get(f"{P}/sessions/{sid}/report?format=markdown", headers=headers)
    assert "informado por la placa" in report.text and "°C" in report.text
    assert "Declarado por el firmware" in report.text
    for _, _, _, channel, sensor, label in modules:
        assert channel in report.text and sensor in report.text and label in report.text
    assert "placa: Arduino UNO" in report.text
    english = client.get(f"{P}/sessions/{sid}/report?format=markdown", headers={**headers, "Accept-Language": "en"})
    assert "Declared by firmware" in english.text and "board: Arduino UNO" in english.text


def test_usb_retries_are_idempotent_private_and_cannot_replace_payload(client, headers, project, database):
    sid = project["id"]
    row = start(client, headers, sid)
    body = request(row)
    other = client.post(P + "/auth/login", json={"email": "other@example.test", "password": "test-password-123"}).json()
    denied = client.post(f"{P}/sessions/{sid}/serial-readings",
                         headers={"Authorization": "Bearer " + other["access_token"]}, json=body)
    assert denied.status_code == 403
    first = client.post(f"{P}/sessions/{sid}/serial-readings", headers=headers, json=body)
    assert first.status_code == 201, first.text
    again = client.post(f"{P}/sessions/{sid}/serial-readings", headers=headers, json=body)
    assert again.status_code == 201 and again.json()["id"] == first.json()["id"]
    conflict = client.post(f"{P}/sessions/{sid}/serial-readings", headers={**headers, "Accept-Language": "en"},
                           json={**body, "line": packet(24)})
    assert conflict.status_code == 409 and conflict.json()["code"] == "serial_reading_conflict"
    assert "identifier" in conflict.json()["detail"]
    with database() as db:
        assert len(list(db.scalars(select(Measurement).where(Measurement.session_id == sid)))) == 1
        assert len(list(db.scalars(select(Job).where(Job.session_id == sid, Job.status == "pending")))) == 1


@pytest.mark.parametrize("change,status,code", [
    ({"request_version": 1}, 409, "version_conflict"),
    ({"spec_version": 99}, 409, "version_conflict"),
    ({"received_at": 1}, 422, "serial_reading_stale"),
    ({"received_at": 1e200}, 422, "serial_reading_stale"),
    ({"line": "temperature=23.5"}, 422, "serial_reading_invalid"),
    ({"line": packet(2.5, "V")}, 422, "measurement_type_mismatch"),
    ({"point_id": "TP3"}, 422, "wrong_test_point"),
    ({"point_id": "TP9"}, 422, "point_not_authorized"),
])
def test_usb_readings_reject_stale_or_incompatible_requests(client, headers, project, change, status, code):
    sid = project["id"]
    row = start(client, headers, sid)
    response = client.post(f"{P}/sessions/{sid}/serial-readings", headers=headers, json={**request(row), **change})
    assert response.status_code == status, response.text
    assert response.json()["code"] == code


def test_usb_requires_new_packet_after_request_and_intervention(client, headers, configured, database):
    sid = configured["id"]
    row = start(client, headers, sid)
    body = request(row, 2500, "mV")
    body["received_at"] = row["pending_test"]["requested_at"] - 0.001
    assert client.post(f"{P}/sessions/{sid}/serial-readings", headers=headers, json=body).status_code == 422
    with database() as db:
        session = db.get(Session, sid)
        session.state = "verifying"
        session.pending_test = {"after": time.time(), "intervention_id": "synthetic-intervention"}
        session.diagnosis_mode = "meta"
        db.commit()
    row = client.get(f"{P}/sessions/{sid}", headers=headers).json()
    old = request(row, 2500, "mV")
    old["received_at"] = row["pending_test"]["after"] - 0.001
    assert client.post(f"{P}/sessions/{sid}/serial-readings", headers=headers, json=old).status_code == 422
    future = {**request(row, 2500, "mV"), "received_at": time.time() + 30}
    assert client.post(f"{P}/sessions/{sid}/serial-readings", headers=headers, json=future).status_code == 422
    fresh = request(row, 2500, "mV")
    response = client.post(f"{P}/sessions/{sid}/serial-readings", headers=headers, json=fresh)
    assert response.status_code == 201, response.text
    assert response.json()["value"] == 2.5 and response.json()["unit"] == "V"
    assert response.json()["phase"] == "verification"
    functional = client.post(f"{P}/sessions/{sid}/functional-check", headers=headers, json={
        "client_id": "usb-verification-functional", "passed": True, "confirmed": True,
        "observations": "The declared synthetic operation was observed", "performed_at": time.time(),
    })
    assert functional.status_code == 201, functional.text
    assert client.post(f"{P}/sessions/{sid}/verification", headers=headers).status_code == 202
    process(*claim())
    row = client.get(f"{P}/sessions/{sid}", headers=headers).json()
    assert row["state"] == "resolved"
    assert row["verifications"][0]["data"]["passed"]
    assert not row["verifications"][0]["data"]["physical_verification"]


def test_old_diagnosis_request_uses_recorded_event_time_without_new_metadata(client, headers, project, database):
    sid = project["id"]
    row = start(client, headers, sid)
    with database() as db:
        session = db.get(Session, sid)
        session.pending_test = {k: v for k, v in session.pending_test.items() if k != "requested_at"}
        event = db.scalar(select(Event).where(
            Event.session_id == sid, Event.kind == "diagnosis_updated",
        ).order_by(Event.sequence.desc()).limit(1))
        threshold = event.created_at
        db.commit()
    old = {**request(row), "received_at": threshold - 0.001}
    assert client.post(f"{P}/sessions/{sid}/serial-readings", headers=headers, json=old).status_code == 422
    same_tick = {**request(row), "received_at": threshold}
    response = client.post(f"{P}/sessions/{sid}/serial-readings", headers=headers, json=same_tick)
    assert response.status_code == 201, response.text


@pytest.mark.parametrize("mutation", [
    {"circuitlab": True}, {"circuitlab": "1"}, {"circuitlab": 2}, {"channel": "bad channel"},
    {"channel": "a" * 81}, {"value": "23.5"}, {"value": True}, {"value": float("nan")},
    {"value": float("inf")}, {"unit": " V"}, {"unit": "C\x7f"}, {"value": 5.1, "unit": "V"},
    {"value": 5001, "unit": "mV"}, {"value": 1, "unit": "boolean"},
    {"value": True, "unit": "text"}, {"value": " ", "unit": "text"},
    {"value": "x" * 501, "unit": "text"}, {"sensor": " "}, {"sensor": None},
    {"value": "FIX\n", "unit": "text"}, {"value": "FIX\x7f", "unit": "text"},
    {"value": "FIX\x85", "unit": "text"},
    {"board": "UNO\n"}, {"label": " Temperature"}, {"unexpected": "command"},
])
def test_serial_packet_contract_is_strict(mutation):
    original = json.loads(packet())
    with pytest.raises(ValidationError):
        SerialTelemetry.model_validate({**original, **mutation})


@pytest.mark.parametrize("value,unit", [(False, "boolean"), ("FIX", "text"), (" FIX ", "text"), (-4.2, "°C"), (3300, "mV")])
def test_serial_packet_preserves_real_value_types(value, unit):
    parsed = SerialTelemetry.model_validate({"circuitlab": 1, "channel": "module/channel", "value": value, "unit": unit})
    assert parsed.value == value
    assert type(parsed.value) is (type(value) if type(value) in (bool, str) else float)
