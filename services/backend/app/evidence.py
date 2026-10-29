"""Withdraw an uploaded image without erasing the audit trail of previous conclusions."""
import time
from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy import select
from app.db import Command, Evidence, Event, Hypothesis, Job, get_db
from app.domain import authorized, commit, record
from app.schemas import EvidenceRemoval
from app.security import current_user
from app.storage import LocalStorage

router = APIRouter(prefix="/api/v1/sessions")


def review_required(db, session_id):
    removed = db.scalar(select(Event.sequence).where(
        Event.session_id == session_id, Event.kind == "evidence_removed",
        Event.data["invalidates_analysis"].as_boolean().is_(True),
    ).order_by(Event.sequence.desc()).limit(1)) or 0
    analyzed = db.scalar(select(Event.sequence).where(
        Event.session_id == session_id, Event.kind == "diagnosis_updated",
    ).order_by(Event.sequence.desc()).limit(1)) or 0
    return removed > analyzed


@router.delete("/{session_id}/evidence/{evidence_id}", status_code=204)
def remove_evidence(session_id: str, evidence_id: str, body: EvidenceRemoval,
                    user=Depends(current_user), db=Depends(get_db)):
    session = authorized(db, session_id, user, write=True)
    evidence = db.get(Evidence, evidence_id)
    if not evidence or evidence.session_id != session.id:
        raise HTTPException(404, "Evidencia inexistente")
    if evidence.removed_at is not None:
        delete_file(evidence.key)
        return Response(status_code=204)
    if session.version != body.version:
        raise HTTPException(409, "Versión desactualizada; recarga la sesión")
    # A running inference may still be reading the image. Wait instead of racing its snapshot.
    if db.scalar(select(Job.id).where(
        Job.session_id == session.id, Job.status.in_(["pending", "running"]),
    ).limit(1)):
        raise HTTPException(409, "Espera a que termine el análisis antes de eliminar la foto")
    invalidates = session.analysis_steps > 0
    evidence.removed_at = time.time()
    record(db, session, "evidence_removed", {
        "evidence_id": evidence.id, "sha256": evidence.sha256,
        "removed_by": user.id, "invalidates_analysis": invalidates,
    })
    if invalidates:
        for hypothesis in db.scalars(select(Hypothesis).where(Hypothesis.session_id == session.id)):
            hypothesis.data = {**hypothesis.data, "status": "discarded",
                               "withdrawn_context": True}
        for command in db.scalars(select(Command).where(
            Command.session_id == session.id, Command.status.in_(["pending", "sent"]),
        )):
            command.status = "cancelled"
            record(db, session, "hardware_failed", {
                "command_id": command.id, "status": "precondition_failed",
                "reason": "evidence_withdrawn",
            })
        previous = session.state
        session.pending_test = None
        session.state = "ready" if session.spec_version else "draft"
        record(db, session, "state_changed", {
            "from": previous, "to": session.state, "reason": "evidence_withdrawn",
        })
    commit(db)
    # Revoke access transactionally first; never leave a failed DB write with a missing live file.
    delete_file(evidence.key)
    return Response(status_code=204)


def delete_file(key):
    try:
        LocalStorage().delete(key)
    except OSError:
        raise HTTPException(503, "La foto fue retirada; vuelve a intentar para completar el borrado del archivo") from None
