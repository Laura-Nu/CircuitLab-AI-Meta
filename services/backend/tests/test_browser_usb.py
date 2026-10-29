"""Browser transport fixtures are synthetic; these tests do not verify physical acquisition."""
import time
import pytest
from sqlalchemy import select
from app.db import BrowserUSBConnection, Command, Device, Session, Measurement

P = "/api/v1"


@pytest.fixture
def usb(client, headers):
    response = client.post(P+"/devices/enroll", headers=headers, json={
        "name": "SYNTHETIC USB transport fixture", "transport": "browser_usb",
        "points": ["TP1", "TP2", "TP3"], "calibration_id": "synthetic-protocol-only", "simulated": False,
    })
    assert response.status_code == 201 and "device_token" not in response.json()
    device_id = response.json()["device_id"]
    opened = client.post(f"{P}/devices/{device_id}/browser/connect", headers=headers)
    assert opened.status_code == 201 and opened.headers["cache-control"] == "no-store"
    return device_id, {"lease": opened.json()["lease"]}


def command(client, headers, configured, database, usb):
    device_id, lease = usb
    sid = configured["id"]
    with database() as db:
        session = db.get(Session, sid)
        session.state = "awaiting_measurement"
        session.pending_test = {"point_id": "TP1", "action": "read_voltage"}
        db.commit()
    queued = client.post(f"{P}/sessions/{sid}/hardware", headers=headers, json={
        "device_id": device_id, "point_id": "TP1", "conditions_confirmed": True,
    })
    assert queued.status_code == 202
    polled = client.post(f"{P}/devices/{device_id}/browser/poll", headers=headers, json=lease)
    assert polled.status_code == 200
    payload = polled.json()["commands"][0]
    assert payload["command_id"] == queued.json()["command_id"]
    result = {"protocol_version": "1", "command_id": payload["command_id"], "point_id": "TP1",
              "status": "ok", "value": 2.5, "sample_count": 20, "unit": "V", "source": "instrumented",
              "calibration_id": "synthetic-protocol-only", "measured_at": time.time()}
    return sid, payload, result


def test_browser_connection_is_exclusive_and_private(client, headers, usb):
    device_id, lease = usb
    conflict = client.post(f"{P}/devices/{device_id}/browser/connect", headers=headers)
    assert conflict.status_code == 409 and conflict.json()["code"] == "browser_usb_in_use"
    for path in ["/devices", "/workspace"]:
        response = client.get(P+path, headers=headers)
        assert "lease_digest" not in response.text and lease["lease"] not in response.text
    bad = client.post(f"{P}/devices/{device_id}/browser/poll", headers=headers, json={"lease": "x"*48})
    assert bad.status_code == 409


def test_another_account_cannot_claim_or_read_device(client, headers, usb):
    device_id, lease = usb
    other = client.post(P+"/auth/login", json={"email": "other@example.test", "password": "test-password-123"}).json()
    auth = {"Authorization": "Bearer "+other["access_token"]}
    assert client.post(f"{P}/devices/{device_id}/browser/connect", headers=auth).status_code == 403
    assert client.post(f"{P}/devices/{device_id}/browser/poll", headers=auth, json=lease).status_code == 403


@pytest.mark.parametrize("simulated,transport", [(True,"browser_usb"), (False,"unsupported")])
def test_browser_enrollment_rejects_simulation_and_unknown_transport(client, headers, simulated, transport):
    response = client.post(P+"/devices/enroll", headers=headers, json={
        "name": "SYNTHETIC invalid enrollment", "transport": transport, "simulated": simulated,
        "points": ["TP1"], "calibration_id": "fixture"})
    assert response.status_code == 422


def test_delivers_once_and_records_result_transition_once(client, headers, configured, database, usb):
    device_id, lease = usb
    sid, payload, result = command(client, headers, configured, database, usb)
    assert client.post(f"{P}/devices/{device_id}/browser/poll", headers=headers, json=lease).json()["commands"] == []
    url = f"{P}/devices/{device_id}/browser/result"
    assert client.post(url, headers=headers, json={**lease,"result":result}).status_code == 200
    duplicate = client.post(url, headers=headers, json={**lease,"result":result})
    assert duplicate.status_code == 200 and duplicate.json()["duplicate"] is True
    with database() as db:
        rows = list(db.scalars(select(Measurement).where(Measurement.session_id == sid)))
        assert len(rows)==1 and rows[0].value==2.5
        assert db.get(Session, sid).state=="analyzing"
        assert db.get(Command,payload["command_id"]).browser_connection_id


@pytest.mark.parametrize("changes", [
    {"source":"simulated"}, {"point_id":"TP2"}, {"calibration_id":"wrong"},
    {"sample_count":19}, {"measured_at":0}, {"value":6}, {"command_id":"unknown-command"},
])
def test_incompatible_results_never_record_a_reading(client, headers, configured, database, usb, changes):
    device_id, lease = usb
    sid, _, result = command(client, headers, configured, database, usb)
    response = client.post(f"{P}/devices/{device_id}/browser/result", headers=headers, json={
        **lease, "result":{**result, **changes}})
    assert response.status_code in {409,422}
    with database() as db:
        assert db.scalar(select(Measurement).where(Measurement.session_id == sid)) is None
        assert db.get(Session,sid).state=="awaiting_measurement"


def test_disconnect_records_failure_and_new_lease_cannot_submit_old_command(client, headers, configured, database, usb):
    device_id, lease = usb
    sid, payload, result = command(client, headers, configured, database, usb)
    closed = client.post(f"{P}/devices/{device_id}/browser/disconnect", headers=headers, json=lease)
    assert closed.status_code == 204
    with database() as db:
        assert db.get(Command,payload["command_id"]).status=="disconnected"
        assert db.get(Device,device_id).last_seen is None
        assert db.get(Session,sid).state=="awaiting_measurement"
        assert db.scalar(select(Measurement)) is None
    new = client.post(f"{P}/devices/{device_id}/browser/connect",headers=headers).json()
    response = client.post(f"{P}/devices/{device_id}/browser/result",headers=headers,json={
        "lease":new["lease"],"result":result})
    assert response.status_code == 409


def test_expired_lease_cannot_renew_or_request_hardware(client, headers, configured, database, usb):
    device_id, lease = usb
    sid, payload, _ = command(client, headers, configured, database, usb)
    with database() as db:
        db.get(BrowserUSBConnection,device_id).expires=time.time()-1
        db.commit()
    assert client.post(f"{P}/devices/{device_id}/browser/poll",headers=headers,json=lease).status_code==409
    assert client.post(f"{P}/sessions/{sid}/hardware",headers=headers,json={
        "device_id":device_id,"point_id":"TP1","conditions_confirmed":True}).status_code==409
    assert client.post(f"{P}/devices/{device_id}/browser/connect",headers=headers).status_code==201
    with database() as db:
        assert db.get(Command,payload["command_id"]).status=="disconnected"


def test_revocation_stops_active_browser_connection(client, headers, database, usb):
    device_id, lease = usb
    assert client.post(f"{P}/devices/{device_id}/revoke",headers=headers).status_code==204
    assert client.post(f"{P}/devices/{device_id}/browser/poll",headers=headers,json=lease).status_code==409
    with database() as db:
        assert db.get(BrowserUSBConnection,device_id) is None


def test_browser_device_is_not_a_legacy_credential_bridge(client, headers, database, usb):
    device_id, lease=usb
    with database() as db:
        device=db.get(Device,device_id)
        assert device.transport=="browser_usb"
    # No long-lived credential is returned or copied for browser transport.
    assert lease["lease"]
