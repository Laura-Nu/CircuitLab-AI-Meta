"""Synthetic API regression checks, without real firmware or provider requests."""
import time

import pytest
from sqlalchemy import select

from app.db import BrowserUSBConnection, Command, Event, Measurement, Session, normalized_instant
from app.schemas import ManualMeasurement, Point
from app.worker import claim, process, snapshot

P = "/api/v1"


@pytest.fixture
def project(client, headers):
    created = client.post(P + "/sessions", headers=headers, json={
        "title": "UNO multi-module fixture", "family": "microcontroller", "purpose": "check_operation",
        "setup": "Arduino UNO, DHT11, RC522 and NEO-8M; synthetic fixture only",
        "expected": "Read the declared temperature, card state and GPS status", "supply_v": 5,
    })
    assert created.status_code == 201, created.text
    row = created.json()
    configured = client.patch(f"{P}/sessions/{row['id']}/specification", headers=headers, json={
        "version": row["version"], "confirmed": True,
        "connections": ["Synthetic fixture with confirmed interfaces and module supplies"],
        "functional_description": "Synthetic complete module operation check under the declared conditions",
        "points": [
            {"id": "TP1", "kind": "numeric", "label": "DHT11 temperature", "value_kind": "number",
             "unit": "°C", "min_value": -10, "max_value": 40},
            {"id": "TP2", "kind": "digital_state", "label": "RC522 card detected", "value_kind": "boolean",
             "expected_state": True},
            {"id": "TP3", "kind": "text", "label": "GPS status", "value_kind": "text", "expected_text": "FIX"},
        ],
    })
    assert configured.status_code == 200, configured.text
    return configured.json()


def test_multi_module_check_keeps_units_and_requires_functional_observation(client, headers, project, database):
    sid = project["id"]
    assert client.post(f"{P}/sessions/{sid}/analysis", headers=headers).status_code == 202
    process(*claim())
    for index, value, unit in [(1, -2.5, "°C"), (2, True, "boolean"), (3, "FIX", "text")]:
        result = client.post(f"{P}/sessions/{sid}/measurements", headers=headers, json={
            "client_id": f"module-reading-{index}", "point_id": f"TP{index}", "value": value,
            "unit": unit, "conditions_confirmed": True, "measured_at": time.time(),
        })
        assert result.status_code == 201, result.text
        assert result.json()["value"] == value and result.json()["unit"] == unit
        process(*claim())
    row = client.get(f"{P}/sessions/{sid}", headers=headers).json()
    assert row["state"] == "awaiting_functional_check"
    assert not row["verifications"]
    result = client.post(f"{P}/sessions/{sid}/baseline-check", headers=headers, json={
        "client_id": "module-functional-check", "passed": True, "confirmed": True,
        "observations": "All declared synthetic module behaviors were observed", "performed_at": time.time(),
    })
    assert result.status_code == 201, result.text
    row = client.get(f"{P}/sessions/{sid}", headers=headers).json()
    assert row["state"] == "no_fault_found" and not row["verifications"][0]["data"]["physical_verification"]
    report = client.get(f"{P}/sessions/{sid}/report?format=markdown", headers=headers)
    assert "°C" in report.text and "FIX" in report.text and "RC522" in report.text
    with database() as db:
        reading = db.scalar(select(Measurement).where(Measurement.session_id == sid, Measurement.unit == "text"))
        assert reading.text_value == "FIX" and reading.value is None and reading.boolean_value is None


def test_serial_capture_is_private_bounded_idempotent_and_enters_analysis_context(client, headers, project, database):
    sid = project["id"]
    body = {"client_id": "serial-capture-001", "baud_rate": 9600,
            "lines": ["DHT11 temperature=23.5 C humidity=48 %", "RFID detected=true", "GPS fix=false"]}
    first = client.post(f"{P}/sessions/{sid}/serial-captures", headers=headers, json=body)
    assert first.status_code == 201, first.text
    repeated = client.post(f"{P}/sessions/{sid}/serial-captures", headers=headers, json=body)
    assert repeated.json()["id"] == first.json()["id"]
    with database() as db:
        context = snapshot(db, db.get(Session, sid))
        assert context["setup"].startswith("Arduino UNO")
        assert context["serial_captures"][0]["lines"] == body["lines"]
        assert not context["serial_captures"][0]["physical_verification"]
        assert db.scalar(select(Measurement).where(Measurement.session_id == sid)) is None
        assert len(list(db.scalars(select(Event).where(Event.kind == "serial_captured")))) == 1
    other = client.post(P + "/auth/login", json={"email": "other@example.test", "password": "test-password-123"}).json()
    assert client.post(f"{P}/sessions/{sid}/serial-captures",
                       headers={"Authorization": "Bearer " + other["access_token"]}, json=body).status_code == 403
    for mutation in ({"lines": ["x" * 501]}, {"lines": []}, {"baud_rate": 123}):
        assert client.post(f"{P}/sessions/{sid}/serial-captures", headers=headers,
                           json={**body, **mutation}).status_code == 422
    assert client.post(f"{P}/sessions/{sid}/analysis", headers=headers).status_code == 202
    assert client.post(f"{P}/sessions/{sid}/serial-captures", headers=headers,
                       json={**body, "client_id": "capture-during-inference"}).status_code == 409


def test_adc_cannot_measure_temperature(client, headers, project, database):
    sid = project["id"]
    with database() as db:
        row = db.get(Session, sid)
        row.state, row.pending_test = "awaiting_measurement", {"point_id": "TP1"}
        db.commit()
    device = client.post(P + "/devices/enroll", headers=headers, json={
        "name": "Isolated ADC fixture", "transport": "browser_usb", "points": ["TP1"], "calibration_id": "fixture",
    }).json()["device_id"]
    client.post(f"{P}/devices/{device}/browser/connect", headers=headers)
    response = client.post(f"{P}/sessions/{sid}/hardware", headers=headers, json={
        "device_id": device, "point_id": "TP1", "conditions_confirmed": True,
    })
    assert response.status_code == 422
    wrong = client.post(f"{P}/sessions/{sid}/measurements", headers=headers, json={
        "client_id": "wrong-unit-reading", "point_id": "TP1", "value": 2.5, "unit": "V",
        "conditions_confirmed": True, "measured_at": time.time(),
    })
    assert wrong.status_code == 422


def test_digital_disconnect_completes_pending_command(client, headers, project, database):
    sid = project["id"]
    with database() as db:
        row = db.get(Session, sid)
        row.state, row.pending_test = "awaiting_measurement", {"point_id": "TP2"}
        db.commit()
    device = client.post(P + "/devices/enroll", headers=headers, json={
        "name": "Isolated digital fixture", "transport": "browser_usb", "points": ["TP2"], "calibration_id": "fixture",
    }).json()["device_id"]
    lease = client.post(f"{P}/devices/{device}/browser/connect", headers=headers).json()["lease"]
    queued = client.post(f"{P}/sessions/{sid}/hardware", headers=headers, json={
        "device_id": device, "point_id": "TP2", "conditions_confirmed": True,
    }).json()["command_id"]
    assert client.post(f"{P}/devices/{device}/browser/disconnect", headers=headers, json={"lease": lease}).status_code == 204
    with database() as db:
        assert db.get(Command, queued).status == "disconnected"
        assert db.get(BrowserUSBConnection, device) is None


def test_program_status_cannot_be_acquired_as_an_electrical_pin(client, headers, project, database):
    from app.schemas import DiagnosisOutput
    from app.worker import validate_plan
    sid = project["id"]
    with database() as db:
        row = db.get(Session, sid)
        points = [dict(p) for p in row.specification["points"]]
        points[1].update(kind="reported_state", label="GPS valid fix")
        row.specification = {**row.specification, "points": points}
        row.state, row.pending_test = "awaiting_measurement", {"point_id": "TP2"}
        db.commit()
        context = snapshot(db, row)
        with pytest.raises(ValueError, match="not an ADC or GPIO read"):
            validate_plan(DiagnosisOutput(
                action="read_digital", point_id="TP2", observations=[], hypotheses=[],
                instruction="Synthetic instrument request", rationale="Synthetic validation fixture",
            ), context)
    # The schema can represent false as a program state, but cannot label volts as one.
    assert Point(id="TP2", label="GPS fix", kind="reported_state", value_kind="boolean",
                 expected_state=False).expected_state is False
    with pytest.raises(ValueError):
        Point(id="TP2", label="Wrong type", kind="reported_state", min_v=0, max_v=3.3)
    device = client.post(P + "/devices/enroll", headers=headers, json={
        "name": "Isolated GPIO fixture", "transport": "browser_usb", "points": ["TP2"], "calibration_id": "fixture",
    }).json()["device_id"]
    client.post(f"{P}/devices/{device}/browser/connect", headers=headers)
    rejected = client.post(f"{P}/sessions/{sid}/hardware", headers=headers, json={
        "device_id": device, "point_id": "TP2", "conditions_confirmed": True,
    })
    assert rejected.status_code == 422, rejected.text
    recorded = client.post(f"{P}/sessions/{sid}/measurements", headers=headers, json={
        "client_id": "actual-program-status", "point_id": "TP2", "value": False, "unit": "boolean",
        "conditions_confirmed": True, "measured_at": time.time(),
    })
    assert recorded.status_code == 201, recorded.text
    assert recorded.json()["value"] is False and recorded.json()["source"] == "manual"


def test_json_timestamp_threshold_matches_persisted_precision():
    from app.db import UTCInstant
    from sqlalchemy.dialects.sqlite import dialect
    for instant in (1780000000.1234562, 1780000000.1234567):
        column = UTCInstant()
        restored = column.process_result_value(column.process_bind_param(instant, dialect()), dialect())
        assert normalized_instant(instant) == restored


@pytest.mark.parametrize("fraction", [0.1234562, 0.1234567])
def test_legacy_json_threshold_accepts_a_same_tick_reading(
    client, headers, configured, database, monkeypatch, fraction,
):
    from test_workflow import start, measure, functional, run_job
    sid = start(client, headers, configured)
    assert measure(client, headers, sid, 0.04).status_code == 201
    run_job()
    assert client.post(f"{P}/sessions/{sid}/interventions", headers=headers, json={
        "description": "Synthetic timestamp intervention", "confirmed": True,
    }).status_code == 201
    instant = int(time.time()) + 1 + fraction
    with database() as db:
        row = db.get(Session, sid)
        row.pending_test = {**row.pending_test, "after": instant}
        db.commit()
    monkeypatch.setattr(time, "time", lambda: instant)
    assert measure(client, headers, sid, 2.5, "timestamp-post-reading").status_code == 201
    assert functional(client, headers, sid).status_code == 201
    result = client.post(f"{P}/sessions/{sid}/verification", headers=headers)
    assert result.status_code == 202, result.text
    process(*claim(result.json()["job_id"]))
    assert client.get(f"{P}/sessions/{sid}", headers=headers).json()["state"] == "resolved"


@pytest.mark.parametrize("value,unit", [(True, "°C"), ("23.5", "°C"), (0, "text"), ("", "text"), (float("nan"), "°C")])
def test_sensor_observations_reject_wrong_types(value, unit):
    with pytest.raises(ValueError):
        ManualMeasurement(client_id="typed-sensor-reading", point_id="TP1", value=value, unit=unit,
                          measured_at=time.time(), conditions_confirmed=True)


def test_sensor_criteria_require_unit_and_exact_comparable_target():
    for extra in ({"unit": "°C"}, {"unit": "V", "min_value": 0, "max_value": 5}):
        with pytest.raises(ValueError):
            Point(id="TP1", label="Temperature", kind="numeric", value_kind="number", **extra)


@pytest.mark.parametrize("board", ["Arduino UNO", "ESP32", "Raspberry Pi Pico", "Raspberry Pi", "STM32"])
def test_board_description_is_open_and_preserves_multiple_modules(client, headers, board):
    result = client.post(P + "/sessions", headers=headers, json={
        "title": "Multi-module project fixture", "family": "microcontroller", "purpose": "check_operation",
        "setup": f"{board} with temperature, humidity, RFID, GPS and additional modules",
        "expected": "Observe every declared module under its confirmed conditions", "supply_v": 3.3,
    })
    assert result.status_code == 201, result.text
    assert result.json()["setup"].startswith(board)


def test_32_mixed_observations_complete_without_the_old_eight_step_cutoff(client, headers):
    created = client.post(P + "/sessions", headers=headers, json={
        "title": "32 observations fixture", "family": "microcontroller", "purpose": "check_operation",
        "setup": "ESP32 and multiple synthetic sensor modules", "supply_v": 3.3,
        "expected": "All declared module observations must satisfy their individual criteria",
    }).json()
    path = f"{P}/sessions/{created['id']}"
    definitions = [
        ({"kind": "numeric", "value_kind": "number", "unit": "°C", "min_value": -40, "max_value": 100}, 22, "°C"),
        ({"kind": "numeric", "value_kind": "number", "unit": "%", "min_value": 0, "max_value": 100}, 50, "%"),
        ({"kind": "digital_state", "value_kind": "boolean", "expected_state": False}, False, "boolean"),
        ({"kind": "text", "value_kind": "text", "expected_text": "FIX"}, "FIX", "text"),
    ]
    points = [{"id": f"TP{i + 1}", "label": f"Module observation {i + 1}", **definitions[i % 4][0]}
              for i in range(32)]
    specification = {
        "version": created["version"], "confirmed": True,
        "connections": ["Synthetic confirmed wiring and compatible individual module supplies"],
        "functional_description": "Observe the complete synthetic project under the stated condition",
        "points": points,
    }
    configured = client.patch(path + "/specification", headers=headers, json=specification)
    assert configured.status_code == 200, configured.text
    assert client.patch(path + "/specification", headers=headers, json={
        **specification, "version": configured.json()["version"],
        "points": [*points, {**points[0], "id": "TP33"}],
    }).status_code == 422
    assert client.post(path + "/analysis", headers=headers).status_code == 202
    process(*claim())
    for i in range(32):
        _, value, unit = definitions[i % 4]
        recorded = client.post(path + "/measurements", headers=headers, json={
            "client_id": f"many-modules-{i + 1}", "point_id": f"TP{i + 1}", "value": value,
            "unit": unit, "conditions_confirmed": True, "measured_at": time.time(),
        })
        assert recorded.status_code == 201, recorded.text
        item = claim()
        assert item, f"Missing continuation at observation {i + 1}"
        process(*item)
    row = client.get(path, headers=headers).json()
    assert len(row["measurements"]) == 32
    assert row["analysis_steps"] == 33 and row["state"] == "awaiting_functional_check"
    completed = client.post(path + "/baseline-check", headers=headers, json={
        "client_id": "many-modules-functional", "passed": True, "confirmed": True,
        "observations": "Complete synthetic multi-module behavior observed", "performed_at": time.time(),
    })
    assert completed.status_code == 201, completed.text
    assert client.get(path, headers=headers).json()["state"] == "no_fault_found"
