import logging
import time
from sqlalchemy import and_, or_, select
from app.config import settings
from app.catalog import localized_voltage_test
from app.db import (
    Command,
    Evidence,
    Event,
    Hypothesis,
    Job,
    Measurement,
    ModelRun,
    Session,
    SessionLocal,
    Storyboard,
    Verification,
    uid,
)
from app.domain import record, serialize, transition
from app.completion import baseline_ready
from app.meta import analyze
from app import stories
from app.operations import BudgetExceeded, functional_result, heartbeat, reserve_budget, validate_runtime

log = logging.getLogger("circuitlab.worker")


def claim(job_id=None):
    now = time.time()
    with SessionLocal() as db:
        job = db.scalar(
            select(Job)
            .where(
                or_(
                    and_(Job.status == "pending", Job.lease_until <= now),
                    and_(Job.status == "running", Job.lease_until < now),
                ),
                *([Job.id == job_id] if job_id else []),
            )
            .order_by(Job.created_at)
            .with_for_update(skip_locked=True)
            .limit(1)
        )
        if not job:
            return None
        job.status = "running"
        job.attempts += 1
        job.lease_token = uid()
        job.lease_until = now + settings().worker_lease_seconds
        result = (job.id, job.lease_token)
        db.commit()
        return result


def snapshot(db, session):
    return {
        "session_id": session.id,
        "diagnosis_mode": session.diagnosis_mode,
        "language": session.language,
        "family": session.family,
        "purpose": session.purpose,
        "expected": session.expected,
        "symptoms": session.symptoms,
        "supply_v": session.supply_v,
        "specification": session.specification,
        "evidence": [
            serialize(e) for e in db.scalars(select(Evidence).where(Evidence.session_id == session.id))
        ],
        "measurements": [
            serialize(m)
            for m in db.scalars(
                select(Measurement)
                .where(Measurement.session_id == session.id)
                .order_by(Measurement.created_at)
            )
        ],
        "previous_hypotheses": [
            h.data for h in db.scalars(select(Hypothesis).where(Hypothesis.session_id == session.id))
        ],
        "test_catalog": [localized_voltage_test(session.language)],
        "connection_confirmations": [
            e.data
            for e in db.scalars(
                select(Event).where(Event.session_id == session.id, Event.kind == "connection_confirmed")
            )
        ],
    }


def validate_plan(output, context):
    known = {r["id"] for r in context["evidence"] + context["measurements"]}
    measurements = {r["id"] for r in context["measurements"]}
    for hypothesis in output.hypotheses:
        if not set(hypothesis.evidence_ids).issubset(known):
            raise ValueError("El proveedor citó evidencia inexistente")
        if hypothesis.status == "supported_by_test" and not measurements.intersection(
            hypothesis.evidence_ids
        ):
            raise ValueError("Hipótesis respaldada sin medida")
    allowed_points = {p["id"] for p in context["specification"]["points"]}
    if output.point_id is not None and output.point_id not in allowed_points:
        raise ValueError("Punto solicitado fuera del esquema autorizado")
    if output.action in {"read_voltage", "request_manual_measurement"} and output.point_id is None:
        raise ValueError("Una medición requiere un punto autorizado")
    if output.action == "propose_intervention" and not any(
        measurements.intersection(h.evidence_ids) for h in output.hypotheses
    ):
        raise ValueError("Intervención sin evidencia de medición")


def evaluate(db, session):
    readings = list(
        db.scalars(
            select(Measurement)
            .where(Measurement.session_id == session.id, Measurement.phase == "verification")
            .order_by(Measurement.measured_at, Measurement.created_at)
        )
    )
    latest = {m.point_id: m for m in readings if m.measured_at >= session.pending_test["after"]}
    checks = []
    for point in session.specification["points"]:
        reading = latest.get(point["id"])
        checks.append(
            {
                "point_id": point["id"],
                "min_v": point["min_v"],
                "max_v": point["max_v"],
                "measurement_id": reading.id if reading else None,
                "value": reading.value if reading else None,
                "source": reading.source if reading else None,
                "passed": bool(reading and point["min_v"] <= reading.value <= point["max_v"]),
            }
        )
    functional = functional_result(db, session)
    electrical_passed = all(c["passed"] for c in checks)
    passed = electrical_passed and bool(functional and functional["passed"])
    sources = {c["source"] for c in checks}
    data = {
        "spec_version": session.spec_version,
        "criteria": session.specification,
        "checks": checks,
        "electrical_passed": electrical_passed,
        "functional_check": functional,
        "verification_basis": "mixed" if len(sources) > 1 else next(iter(sources), "missing"),
        "passed": passed,
        "physical_verification": passed
        and session.diagnosis_mode == "meta"
        and sources.issubset({"manual", "instrumented"}),
    }
    db.add(Verification(session_id=session.id, data=data))
    record(db, session, "verification_completed", data)
    transition(db, session, "resolved" if passed else "inconclusive", "functional_check")


def process(job_id, lease_token):
    try:
        with SessionLocal() as db:
            job = db.get(Job, job_id)
            if not job or job.status != "running" or job.lease_token != lease_token or job.lease_until < time.time():
                return
            session = db.get(Session, job.session_id)
            context = snapshot(db, session)
            kind = job.kind
            exhausted = session.analysis_steps >= settings().max_analysis_steps
            story = db.scalar(select(Storyboard).where(Storyboard.job_id == job.id)) if kind == "storyboard" else None
            story_input = story.snapshot if story else None
            if session.diagnosis_mode == "meta" and (
                (kind == "analysis" and not exhausted) or kind == "storyboard"
            ):
                reserve_budget(db, session.owner_id)
                db.commit()
        output = metadata = None
        story_output = None
        if kind == "storyboard":
            if story_input is None:
                raise ValueError("Missing story snapshot")
            story_output = stories.generate(story_input)
        if kind == "analysis" and not exhausted:
            def persist_exchange(audit):
                with SessionLocal() as audit_db:
                    audit_db.add(ModelRun(session_id=context["session_id"], data={**audit, "job_id": job_id}))
                    audit_db.commit()

            if context["diagnosis_mode"] == "meta":
                output, metadata = analyze(context, on_exchange=persist_exchange)
            else:
                output, metadata = analyze(context)
            validate_plan(output, context)
        with SessionLocal() as db:
            job = db.scalar(select(Job).where(Job.id == job_id).with_for_update())
            if job.status != "running" or job.lease_token != lease_token or job.lease_until < time.time():
                return
            session = db.scalar(select(Session).where(Session.id == job.session_id).with_for_update())
            if kind == "storyboard":
                story = db.scalar(select(Storyboard).where(Storyboard.job_id == job.id).with_for_update())
                story.data = story_output
                record(db, session, "story_completed", {"story_id": story.id})
            elif kind == "verification":
                evaluate(db, session)
            elif exhausted:
                transition(db, session, "inconclusive", "step_budget_exhausted")
            else:
                session.analysis_steps += 1
                data = {**output.model_dump(), "language": session.language}
                db.add(ModelRun(session_id=session.id, data={**metadata, "output": data}))
                for index, hypothesis in enumerate(output.hypotheses):
                    translations = (
                        {
                            language: {
                                "cause": translated.causes[index],
                                "explanation": translated.explanations[index],
                            }
                            for language, translated in (
                                ("en", output.translations.en),
                                ("es", output.translations.es),
                            )
                        }
                        if output.translations
                        else {}
                    )
                    db.add(
                        Hypothesis(
                            session_id=session.id,
                            data={
                                **hypothesis.model_dump(),
                                "analysis_step": session.analysis_steps,
                                "language": session.language,
                                "translations": translations,
                            },
                        )
                    )
                session.pending_test = data
                record(db, session, "diagnosis_updated", data)
                state = {
                    "request_additional_view": "awaiting_evidence",
                    "request_connection_confirmation": "awaiting_confirmation",
                    "read_voltage": "awaiting_measurement",
                    "request_manual_measurement": "awaiting_measurement",
                    "propose_intervention": "awaiting_intervention",
                    "inconclusive": "inconclusive",
                }[output.action]
                if state == "inconclusive" and baseline_ready(db, session):
                    state = "awaiting_functional_check"
                transition(db, session, state, output.rationale)
            job.status = "completed"
            job.error = None
            record(db, session, "job_completed", {"job_id": job.id})
            db.commit()
    except Exception as exc:
        # Keep secrets, provider response bodies and user images out of logs and errors.
        code = ("daily_quota_exceeded" if isinstance(exc, BudgetExceeded) else
                "provider_unavailable" if isinstance(exc, RuntimeError) else "analysis_failed")
        log.warning("Job %s failed: %s", job_id, type(exc).__name__)
        with SessionLocal() as db:
            job = db.scalar(select(Job).where(Job.id == job_id).with_for_update())
            if job.status != "running" or job.lease_token != lease_token or job.lease_until < time.time():
                return
            session = db.scalar(select(Session).where(Session.id == job.session_id).with_for_update())
            if job.kind == "storyboard":
                job.error = "story_generation_failed"
                job.status = "failed"
                record(db, session, "story_failed", {"job_id": job.id})
                db.commit()
                return
            db.add(
                ModelRun(
                    session_id=session.id,
                    data={
                        "status": "error",
                        "error": code,
                        "exception_type": type(exc).__name__,
                        "possible_provider_consumption": not isinstance(exc, BudgetExceeded),
                    },
                )
            )
            job.error = code
            status = getattr(exc, "audit", {}).get("http_status", 0)
            permanent_failure = isinstance(exc, BudgetExceeded) or (400 <= status < 500 and status not in {408, 429})
            if job.attempts < 3 and not permanent_failure:
                job.status = "pending"
                job.lease_until = time.time() + 2**job.attempts
            else:
                job.status = "failed"
                if session.state == "analyzing":
                    transition(db, session, "ready", "provider_error_retry_exhausted")
            record(db, session, "job_error", {"job_id": job.id, "code": code, "attempt": job.attempts})
            db.commit()


def expire_commands():
    with SessionLocal() as db:
        for command in db.scalars(
            select(Command)
            .where(Command.status.in_(["pending", "sent"]), Command.deadline < time.time())
            .with_for_update(skip_locked=True)
        ):
            command.status = "timeout"
            session = db.scalar(select(Session).where(Session.id == command.session_id).with_for_update())
            record(db, session, "hardware_failed", {"command_id": command.id, "status": "timeout"})
        db.commit()


def main():
    logging.basicConfig(level=logging.INFO)
    validate_runtime()
    worker_id = uid()
    from pathlib import Path
    import tempfile
    (Path(tempfile.gettempdir()) / "circuitlab-worker.id").write_text(worker_id)
    while True:
        try:
            with SessionLocal() as db:
                heartbeat(db, worker_id)
            expire_commands()
            claimed = claim()
            if claimed:
                process(*claimed)
            else:
                time.sleep(1)
        except Exception as exc:
            log.error("Worker iteration failed: %s", type(exc).__name__)
            time.sleep(3)


if __name__ == "__main__":
    main()
