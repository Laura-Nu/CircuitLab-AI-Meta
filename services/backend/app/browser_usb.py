"""Short, authenticated browser connections sharing the fixed hardware command protocol."""
import secrets
import time
from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy import select
from app.db import BrowserUSBConnection, Command, Device, Session, get_db, uid
from app.domain import commit, record
from app.schemas import BrowserUSBLease, BrowserUSBResult, HardwareResult
from app.security import current_user, digest

router = APIRouter(prefix="/api/v1/devices")
LEASE_SECONDS = 15


def owned_device(db, device_id, user):
    device = db.scalar(select(Device).where(Device.id == device_id).with_for_update())
    if not device or device.owner_id != user.id:
        raise HTTPException(403, "Dispositivo no autorizado")
    if device.transport != "browser_usb" or device.simulated:
        raise HTTPException(409, "Registra un instrumento USB del navegador")
    return device


def connection(db, device, lease):
    row = db.get(BrowserUSBConnection, device.id)
    if not row or row.expires <= time.time() or not secrets.compare_digest(row.lease_digest, digest(lease)):
        raise HTTPException(409, "La conexión USB venció; vuelve a conectar")
    return row


def fail_commands(db, device):
    from app.main import accept_result
    for command in db.scalars(select(Command).where(
        Command.device_id == device.id, Command.status.in_(["pending", "sent"])
    ).with_for_update()):
        accept_result(db, device, HardwareResult(
            protocol_version="1", command_id=command.id, point_id=command.payload["point_id"],
            status="disconnected", sample_count=0, source="instrumented", calibration_id=device.calibration_id,
            measured_at=time.time(),
        ))


@router.post("/{device_id}/browser/connect", status_code=201)
def connect(device_id: str, user=Depends(current_user), db=Depends(get_db)):
    device = owned_device(db, device_id, user)
    old = db.get(BrowserUSBConnection, device.id)
    if old and old.expires > time.time():
        raise HTTPException(409, "Este instrumento está conectado en otra pestaña")
    fail_commands(db, device)
    token = secrets.token_urlsafe(48)
    row = old or BrowserUSBConnection(device_id=device.id)
    row.id = uid()
    row.lease_digest = digest(token)
    row.expires = time.time() + LEASE_SECONDS
    db.add(row)
    device.last_seen = time.time()
    db.commit()
    return {"lease": token, "expires_in": LEASE_SECONDS, "device_id": device.id,
            "points": device.points, "calibration_id": device.calibration_id}


@router.post("/{device_id}/browser/poll")
def poll(device_id: str, body: BrowserUSBLease, user=Depends(current_user), db=Depends(get_db)):
    device = owned_device(db, device_id, user)
    row = connection(db, device, body.lease)
    row.expires = time.time() + LEASE_SECONDS
    device.last_seen = time.time()
    outgoing = []
    for command in db.scalars(select(Command).where(
        Command.device_id == device.id, Command.status.in_(["pending", "sent"])
    ).with_for_update()):
        if command.deadline < time.time():
            command.status = "timeout"
            session = db.scalar(select(Session).where(Session.id == command.session_id).with_for_update())
            record(db, session, "hardware_failed", {"command_id": command.id, "status": "timeout"})
        elif command.status == "pending":
            command.status = "sent"
            command.browser_connection_id = row.id
            outgoing.append(command.payload)
    commit(db)
    return {"commands": outgoing, "expires_in": LEASE_SECONDS, "server_time": time.time()}


@router.post("/{device_id}/browser/result")
def result(device_id: str, body: BrowserUSBResult, user=Depends(current_user), db=Depends(get_db)):
    from app.main import accept_result
    device = owned_device(db, device_id, user)
    row = connection(db, device, body.lease)
    command = db.scalar(select(Command).where(Command.id == body.result.command_id).with_for_update())
    if (not command or command.device_id != device.id or command.browser_connection_id != row.id
            or body.result.source != "instrumented"):
        raise HTTPException(409, "La lectura no pertenece a esta conexión USB")
    if command.status not in {"sent", "pending"}:
        if command.result == body.result.model_dump():
            return {"ack": command.id, "duplicate": True}
        raise HTTPException(409, "El comando USB ya finalizó")
    try:
        accept_result(db, device, body.result)
    except ValueError:
        raise HTTPException(422, "Resultado incompatible con el comando o calibración") from None
    row.expires = time.time() + LEASE_SECONDS
    device.last_seen = time.time()
    commit(db)
    return {"ack": command.id, "status": command.status}


@router.post("/{device_id}/browser/disconnect", status_code=204)
def disconnect(device_id: str, body: BrowserUSBLease, user=Depends(current_user), db=Depends(get_db)):
    device = owned_device(db, device_id, user)
    row = connection(db, device, body.lease)
    fail_commands(db, device)
    device.last_seen = None
    db.delete(row)
    commit(db)
    return Response(status_code=204)
