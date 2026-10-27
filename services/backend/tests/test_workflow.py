import io
import time
from PIL import Image
from sqlalchemy import select
from app.db import Command, Job, Session
from app.main import accept_result
from app.schemas import HardwareResult
from app.worker import claim, process

P = "/api/v1"


def run_job():
    claimed = claim()
    assert claimed
    process(*claimed)


def start(client, headers, configured):
    sid = configured["id"]
    result = client.post(f"{P}/sessions/{sid}/analysis", headers=headers)
    assert result.status_code == 202
    run_job()
    return sid


def measure(client, headers, sid, value, key="manual-001"):
    return client.post(
        f"{P}/sessions/{sid}/measurements",
        headers=headers,
        json={
            "client_id": key,
            "point_id": "TP1",
            "value": value,
            "unit": "V",
            "measured_at": time.time(),
            "conditions_confirmed": True,
        },
    )


def test_full_diagnosis_and_deterministic_verification(client, headers, configured):
    sid = start(client, headers, configured)
    assert client.get(f"{P}/sessions/{sid}", headers=headers).json()["state"] == "awaiting_measurement"
    assert measure(client, headers, sid, 0.04).status_code == 201
    run_job()
    assert client.get(f"{P}/sessions/{sid}", headers=headers).json()["state"] == "awaiting_intervention"
    result = client.post(
        f"{P}/sessions/{sid}/interventions",
        headers=headers,
        json={"description": "Reconecté R2 a GND", "confirmed": True},
    )
    assert result.status_code == 201
    assert client.post(f"{P}/sessions/{sid}/verification", headers=headers).status_code == 409
    assert measure(client, headers, sid, 2.5, "post-001").status_code == 201
    assert client.post(f"{P}/sessions/{sid}/verification", headers=headers).status_code == 202
    run_job()
    report = client.get(f"{P}/sessions/{sid}/report", headers=headers).json()
    assert report["state"] == "resolved"
    assert report["verifications"][0]["data"]["checks"][0]["value"] == 2.5
    assert report["verifications"][0]["data"]["physical_verification"] is False
    assert report["model_runs"][0]["data"]["provider"] == "simulation"
    sequences = [e["sequence"] for e in report["events"]]
    assert sequences == sorted(set(sequences))


def test_failed_repair_is_inconclusive(client, headers, configured):
    sid = start(client, headers, configured)
    measure(client, headers, sid, 0.04)
    run_job()
    client.post(
        f"{P}/sessions/{sid}/interventions",
        headers=headers,
        json={"description": "Revisé el cable sin éxito", "confirmed": True},
    )
    measure(client, headers, sid, 0.1, "post-002")
    client.post(f"{P}/sessions/{sid}/verification", headers=headers)
    run_job()
    assert client.get(f"{P}/sessions/{sid}", headers=headers).json()["state"] == "inconclusive"


def test_measurement_idempotency(client, headers, configured):
    sid = start(client, headers, configured)
    first = measure(client, headers, sid, 0.04)
    second = measure(client, headers, sid, 0.04)
    assert first.json()["id"] == second.json()["id"]
    assert len(client.get(f"{P}/sessions/{sid}", headers=headers).json()["measurements"]) == 1


def test_authorization_includes_evidence_jobs_reports(client, headers, configured):
    sid = configured["id"]
    queued = client.post(f"{P}/sessions/{sid}/analysis", headers=headers).json()
    other = client.post(
        f"{P}/auth/login", json={"email": "other@example.test", "password": "test-password-123"}
    ).json()
    auth = {"Authorization": "Bearer " + other["access_token"]}
    for path in [
        f"/sessions/{sid}",
        f"/sessions/{sid}/report",
        f"/sessions/{sid}/events",
        f"/jobs/{queued['job_id']}",
        f"/sessions/{sid}/evidence/absent",
    ]:
        assert client.get(P + path, headers=auth).status_code == 403
    assert client.get(P + "/sessions", headers=auth).json() == []


def test_specification_version_and_frozen_criteria(client, headers, configured):
    sid = configured["id"]
    body = {**configured["specification"], "version": 1}
    assert client.patch(f"{P}/sessions/{sid}/specification", headers=headers, json=body).status_code == 409
    start(client, headers, configured)
    current = client.get(f"{P}/sessions/{sid}", headers=headers).json()
    body["version"] = current["version"]
    assert client.patch(f"{P}/sessions/{sid}/specification", headers=headers, json=body).status_code == 409


def test_invalid_points_and_nonfinite_voltage(client, headers, configured):
    sid = start(client, headers, configured)
    base = {
        "client_id": "invalid-001",
        "point_id": "TP9",
        "value": 1,
        "unit": "V",
        "measured_at": time.time(),
        "conditions_confirmed": True,
    }
    assert client.post(f"{P}/sessions/{sid}/measurements", headers=headers, json=base).status_code == 422
    for value in [6, -1, "NaN", "Infinity"]:
        assert (
            client.post(
                f"{P}/sessions/{sid}/measurements",
                headers=headers,
                json={**base, "point_id": "TP1", "value": value},
            ).status_code
            == 422
        )


def test_millivolt_conversion(client, headers, configured):
    sid = start(client, headers, configured)
    result = client.post(
        f"{P}/sessions/{sid}/measurements",
        headers=headers,
        json={
            "client_id": "millivolt-001",
            "point_id": "TP1",
            "value": 2500,
            "unit": "mV",
            "measured_at": time.time(),
            "conditions_confirmed": True,
        },
    )
    assert result.status_code == 201
    assert result.json()["value"] == 2.5


def test_image_validation_metadata_and_idempotency(client, headers, session):
    path = f"{P}/sessions/{session['id']}/evidence"
    invalid = client.post(
        path, headers=headers, data={"client_id": "image-0001"}, files={"file": ("x.jpg", b"not an image")}
    )
    assert invalid.status_code == 422
    image = Image.new("RGB", (30, 30), "red")
    stream = io.BytesIO()
    image.save(stream, format="JPEG", exif=b"private-metadata")
    result = client.post(
        path,
        headers=headers,
        data={"client_id": "image-0001"},
        files={"file": ("../../test.jpg", stream.getvalue())},
    )
    assert result.status_code == 201
    duplicate = client.post(
        path, headers=headers, data={"client_id": "image-0001"}, files={"file": ("x", b"duplicate")}
    )
    assert duplicate.json()["id"] == result.json()["id"]
    download = client.get(path + "/" + result.json()["id"], headers=headers)
    assert b"private-metadata" not in download.content
    assert download.headers["cache-control"] == "no-store"


def test_expired_lease_recovered_and_stale_worker_fenced(client, headers, configured, database):
    response = client.post(f"{P}/sessions/{configured['id']}/analysis", headers=headers).json()
    old = claim()
    with database() as db:
        db.get(Job, response["job_id"]).lease_until = time.time() - 1
        db.commit()
    replacement = claim()
    assert old[0] == replacement[0] and old[1] != replacement[1]
    process(*old)
    with database() as db:
        assert db.get(Job, old[0]).status == "running"
    process(*replacement)
    with database() as db:
        assert db.get(Job, old[0]).status == "completed"
        assert db.get(Session, configured["id"]).analysis_steps == 1


def test_provider_failure_is_not_diagnosis(client, headers, configured, database, monkeypatch):
    from app import worker

    def fail(_):
        raise RuntimeError("secret provider message")

    monkeypatch.setattr(worker, "analyze", fail)
    queued = client.post(f"{P}/sessions/{configured['id']}/analysis", headers=headers).json()
    for _ in range(3):
        with database() as db:
            db.get(Job, queued["job_id"]).lease_until = 0
            db.commit()
        run_job()
    detail = client.get(f"{P}/sessions/{configured['id']}", headers=headers).json()
    assert detail["state"] == "ready"
    assert detail["jobs"][0]["status"] == "failed"
    assert "secret" not in str(detail)


def test_pairing_is_authenticated_single_use_reader(client, headers, configured):
    sid = configured["id"]
    code = client.post(f"{P}/sessions/{sid}/pairing", headers=headers).json()["code"]
    assert client.post(P + "/pairing/redeem", json={"code": code}).status_code == 401
    other = client.post(
        P + "/auth/login", json={"email": "other@example.test", "password": "test-password-123"}
    ).json()
    auth = {"Authorization": "Bearer " + other["access_token"]}
    assert client.post(P + "/pairing/redeem", headers=auth, json={"code": code}).status_code == 200
    assert client.post(P + "/pairing/redeem", headers=auth, json={"code": code}).status_code == 422
    assert client.get(f"{P}/sessions/{sid}", headers=auth).json()["can_edit"] is False
    assert client.post(f"{P}/sessions/{sid}/analysis", headers=auth).status_code == 403


def test_refresh_rotation_and_logout(client, headers):
    tokens = client.post(
        P + "/auth/login", json={"email": "owner@example.test", "password": "test-password-123"}
    ).json()
    assert (
        client.post(P + "/auth/refresh", json={"refresh_token": tokens["refresh_token"]}).status_code == 200
    )
    assert (
        client.post(P + "/auth/refresh", json={"refresh_token": tokens["refresh_token"]}).status_code == 401
    )
    assert client.post(P + "/auth/logout", headers=headers).status_code == 204
    assert client.get(P + "/sessions", headers=headers).status_code == 401


def test_login_attempt_budget(client):
    for _ in range(5):
        assert (
            client.post(
                P + "/auth/login", json={"email": "owner@example.test", "password": "wrong-password"}
            ).status_code
            == 401
        )
    assert (
        client.post(
            P + "/auth/login", json={"email": "owner@example.test", "password": "test-password-123"}
        ).status_code
        == 429
    )


def test_hardware_result_idempotency_and_provenance(client, headers, configured, database):
    from app.db import Device

    sid = start(client, headers, configured)
    device = client.post(
        P + "/devices/enroll",
        headers=headers,
        json={"name": "Simulated bench", "points": ["TP1"], "calibration_id": "cal-test", "simulated": True},
    ).json()
    with database() as db:
        db.get(Device, device["device_id"]).last_seen = time.time()
        db.commit()
    result = client.post(
        f"{P}/sessions/{sid}/hardware",
        headers=headers,
        json={"device_id": device["device_id"], "point_id": "TP1", "conditions_confirmed": True},
    )
    assert result.status_code == 202
    payload = HardwareResult(
        protocol_version="1",
        command_id=result.json()["command_id"],
        status="ok",
        point_id="TP1",
        value=0.04,
        sample_count=20,
        source="simulated",
        calibration_id="cal-test",
        measured_at=time.time(),
    )
    with database() as db:
        device = db.get(Device, device["device_id"])
        accept_result(db, device, payload)
        db.commit()
        accept_result(db, device, payload)
        db.commit()
    readings = client.get(f"{P}/sessions/{sid}", headers=headers).json()["measurements"]
    assert len(readings) == 1 and readings[0]["source"] == "simulated"


def test_timeout_never_becomes_zero(client, headers, configured, database):
    from app.worker import expire_commands
    from app.db import Device

    sid = start(client, headers, configured)
    d = client.post(
        P + "/devices/enroll",
        headers=headers,
        json={"name": "Timed out", "points": ["TP1"], "calibration_id": "cal-test", "simulated": True},
    ).json()
    with database() as db:
        db.get(Device, d["device_id"]).last_seen = time.time()
        db.commit()
    client.post(
        f"{P}/sessions/{sid}/hardware",
        headers=headers,
        json={"device_id": d["device_id"], "point_id": "TP1", "conditions_confirmed": True},
    )
    with database() as db:
        db.scalar(select(Command)).deadline = time.time() - 1
        db.commit()
    expire_commands()
    detail = client.get(f"{P}/sessions/{sid}", headers=headers).json()
    assert detail["measurements"] == [] and detail["state"] == "awaiting_measurement"
    with database() as db:
        assert db.scalar(select(Command)).status == "timeout"


def test_step_budget_ends_cycle(client, headers, configured, database):
    with database() as db:
        db.get(Session, configured["id"]).analysis_steps = 8
        db.commit()
    sid = start(client, headers, configured)
    assert client.get(f"{P}/sessions/{sid}", headers=headers).json()["state"] == "inconclusive"


def test_websocket_command_round_trip(client, headers, configured, database):
    from app.db import Device

    sid = start(client, headers, configured)
    d = client.post(
        P + "/devices/enroll",
        headers=headers,
        json={"name": "WebSocket bench", "points": ["TP1"], "calibration_id": "cal-ws", "simulated": True},
    ).json()
    with database() as db:
        db.get(Device, d["device_id"]).last_seen = time.time()
        db.commit()
    client.post(
        f"{P}/sessions/{sid}/hardware",
        headers=headers,
        json={"device_id": d["device_id"], "point_id": "TP1", "conditions_confirmed": True},
    )
    with client.websocket_connect(
        P + "/devices/connect", headers={"Authorization": "Bearer " + d["device_token"]}
    ) as socket:
        command = socket.receive_json()
        assert command["point_id"] == "TP1" and command["protocol_version"] == "1"
        result = {
            "protocol_version": "1",
            "command_id": command["command_id"],
            "point_id": "TP1",
            "status": "ok",
            "value": 0.04,
            "sample_count": 20,
            "source": "simulated",
            "calibration_id": "cal-ws",
            "measured_at": time.time(),
        }
        socket.send_json(result)
        assert socket.receive_json() == {"ack": command["command_id"]}
        socket.send_json(result)
        assert socket.receive_json() == {"ack": command["command_id"]}
    detail = client.get(f"{P}/sessions/{sid}", headers=headers).json()
    assert len(detail["measurements"]) == 1
