"""Deterministic completion readiness; an in-range baseline is not a repaired circuit."""
from sqlalchemy import select
from app.db import Command, Event, Intervention, Job, Measurement
from app.operations import functional_result

TERMINAL_STATES = {"resolved", "no_fault_found", "inconclusive", "cancelled"}


def voltage_checks(db, session, *, phase="diagnosis", after=0):
    latest = {}
    for reading in db.scalars(select(Measurement).where(
        Measurement.session_id == session.id, Measurement.phase == phase,
        Measurement.measured_at >= after,
    ).order_by(Measurement.measured_at, Measurement.created_at)):
        latest[reading.point_id] = reading
    return [
        {
            "point_id": point["id"], "label": point["label"],
            "min_v": point["min_v"], "max_v": point["max_v"],
            "measurement_id": latest[point["id"]].id if point["id"] in latest else None,
            "value": latest[point["id"]].value if point["id"] in latest else None,
            "source": latest[point["id"]].source if point["id"] in latest else None,
            "measured_at": latest[point["id"]].measured_at if point["id"] in latest else None,
            "passed": point["id"] in latest and point["min_v"] <= latest[point["id"]].value <= point["max_v"],
        }
        for point in session.specification.get("points", [])
    ]


def baseline_ready(db, session):
    if not session.spec_version or not session.analysis_steps:
        return False
    if db.scalar(select(Intervention.id).where(Intervention.session_id == session.id).limit(1)):
        return False
    previous_check = db.scalar(select(Event).where(
        Event.session_id == session.id, Event.kind == "baseline_functional_check_recorded",
    ).order_by(Event.sequence.desc()).limit(1))
    if previous_check and not previous_check.data["passed"]:
        return False
    checks = voltage_checks(db, session)
    return bool(checks) and all(check["passed"] for check in checks)


def completion_status(db, session):
    verification = session.state == "verifying"
    checks = voltage_checks(db, session, phase="verification" if verification else "diagnosis",
                            after=(session.pending_test or {}).get("after", 0) if verification else 0)
    active_job = db.scalar(select(Job.id).where(
        Job.session_id == session.id, Job.status.in_(["pending", "running"]),
    ).limit(1))
    active_command = db.scalar(select(Command.id).where(
        Command.session_id == session.id, Command.status.in_(["pending", "sent"]),
    ).limit(1))
    functional = functional_result(db, session) if verification else None
    return {
        "terminal": session.state in TERMINAL_STATES,
        "waiting_for_user": session.state not in TERMINAL_STATES and session.state != "analyzing" and not active_job,
        "can_close": session.state not in TERMINAL_STATES and not active_job and not active_command,
        "baseline_available": session.state in {"awaiting_functional_check", "inconclusive"} and baseline_ready(db, session),
        "checks": checks,
        "missing_points": [check["point_id"] for check in checks if not check["measurement_id"]],
        "functional_check": functional,
        "can_verify": verification and bool(checks) and all(check["measurement_id"] for check in checks) and functional is not None and not active_job,
    }
