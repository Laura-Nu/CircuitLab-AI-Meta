import time
from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.orm.exc import StaleDataError
from app.db import Event, Job, Member, Session

TRANSITIONS = {
    "draft": {"ready", "awaiting_evidence", "cancelled"},
    "ready": {"analyzing", "cancelled"},
    "awaiting_evidence": {"ready", "analyzing", "cancelled"},
    "awaiting_confirmation": {"ready", "analyzing", "cancelled"},
    "analyzing": {
        "awaiting_evidence",
        "awaiting_confirmation",
        "awaiting_measurement",
        "awaiting_intervention",
        "inconclusive",
        "ready",
    },
    "awaiting_measurement": {"analyzing", "cancelled"},
    "awaiting_intervention": {"verifying", "cancelled"},
    "verifying": {"resolved", "inconclusive", "cancelled"},
    "resolved": set(),
    "inconclusive": set(),
    "cancelled": set(),
}


def authorized(db, session_id, user, write=False):
    session = db.scalar(select(Session).where(Session.id == session_id).with_for_update())
    if not session:
        raise HTTPException(404, "Sesión inexistente")
    if session.owner_id != user.id:
        member = db.get(Member, (session_id, user.id))
        if not member or write:
            raise HTTPException(403, "Sin permiso para esta sesión")
    return session


def record(db, session, kind, data):
    session.version += 1
    db.add(Event(session_id=session.id, sequence=session.version, kind=kind, data=data))


def transition(db, session, state, reason):
    if state not in TRANSITIONS.get(session.state, set()):
        raise HTTPException(409, f"Transición inválida: {session.state} → {state}")
    previous = session.state
    session.state = state
    record(db, session, "state_changed", {"from": previous, "to": state, "reason": reason})


def enqueue(db, session, kind="analysis"):
    active = db.scalar(
        select(Job).where(Job.session_id == session.id, Job.status.in_(["pending", "running"]))
    )
    if active:
        return active
    if kind == "analysis":
        if not session.spec_version:
            raise HTTPException(409, "Confirma el esquema y los criterios funcionales antes del análisis")
        if session.state == "awaiting_measurement":
            raise HTTPException(409, "Registra la medición solicitada antes de continuar")
        if session.state == "awaiting_confirmation":
            raise HTTPException(409, "Confirma físicamente la conexión solicitada antes de continuar")
        transition(db, session, "analyzing", "analysis_requested")
    job = Job(session_id=session.id, kind=kind, lease_until=time.time())
    db.add(job)
    db.flush()
    record(db, session, "job_queued", {"job_id": job.id, "kind": kind})
    return job


def serialize(row):
    return {col.name: getattr(row, col.name) for col in row.__table__.columns}


def commit(db):
    try:
        db.commit()
    except StaleDataError:
        db.rollback()
        raise HTTPException(409, "La sesión cambió; vuelve a cargarla")
