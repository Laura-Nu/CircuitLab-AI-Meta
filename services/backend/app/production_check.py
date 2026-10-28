"""Inspect the running environment; paid Meta probes require an existing investigation/image.

Never fabricates measurements, sends email, changes diagnosis state, or prints credentials.
Run inside the deployed API container so network/configuration match the VPS.
"""

import argparse
import json
import time
from sqlalchemy import func, select, text
from app.config import settings
from app.db import EmailDelivery, Event, Evidence, Measurement, ModelRun, Session, SessionLocal
from app.domain import record
from app.operations import operational_status, reserve_budget, validate_runtime


def inspect_environment():
    from app.main import app
    from app.release import deployment_metadata

    config = settings()
    checks = {
        "production_environment": config.app_env == "production",
        "real_inference_mode": config.ai_mode == "meta",
        "functional_check_route": any(
            route.path == "/api/v1/sessions/{session_id}/functional-check"
            and "POST" in getattr(route, "methods", set()) for route in app.routes
        ),
    }
    try:
        validate_runtime()
        from app.inference import profile

        profile(config)
        checks["provider_configuration"] = True
    except Exception:
        checks["provider_configuration"] = False
    report = {
        "checks": checks,
        "deployment": deployment_metadata(),
        "model": config.meta_reasoning_model or None,
        "provider": config.meta_provider,
    }
    try:
        with SessionLocal() as db:
            db.execute(text("SELECT 1 FROM users LIMIT 1"))
            checks["postgresql"] = db.bind.dialect.name == "postgresql"
            checks["migration_current"] = (
                db.execute(text("SELECT version_num FROM alembic_version")).scalar() == "0006"
            )
            report["operations"] = operational_status(db)
            checks["worker_available"] = report["operations"]["worker"]["healthy"]
            checks["email_dispatch_not_stale"] = report["operations"]["email"]["stale_pending"] == 0
            checks["queue_leases_current"] = report["operations"]["queue"]["expired_leases"] == 0
            checks["resend_configured"] = config.recovery_delivery == "resend" and bool(
                config.resend_api_key.get_secret_value().strip() and config.resend_from.strip()
            )
            report["recent_real_provider_exchanges"] = db.scalar(
                select(func.count(ModelRun.id)).where(
                    ModelRun.created_at >= time.time() - 86400,
                    ModelRun.data["run_kind"].as_string() == "provider_exchange",
                    ModelRun.data["provider"].as_string() == config.meta_provider,
                    ModelRun.data["model"].as_string() == config.meta_reasoning_model,
                    ModelRun.data["http_status"].as_integer().between(200, 299),
                )
            )
    except Exception:
        checks["database_and_operational_schema"] = False
    return report


def session_status(session_id):
    with SessionLocal() as db:
        session = db.get(Session, session_id)
        if not session:
            raise ValueError("Investigation not found")
        events = list(db.scalars(select(Event.kind).where(Event.session_id == session_id)))
        sources = dict(
            db.execute(
                select(Measurement.source, func.count(Measurement.id))
                .where(Measurement.session_id == session_id)
                .group_by(Measurement.source)
            ).all()
        )
        return {
            "id": session.id,
            "state": session.state,
            "mode": session.diagnosis_mode,
            "evidence_count": db.scalar(
                select(func.count(Evidence.id)).where(Evidence.session_id == session_id)
            ),
            "worker_diagnosis_recorded": "diagnosis_updated" in events and "job_completed" in events,
            "measurement_sources": sources,
            "functional_result_recorded": "functional_check_recorded" in events,
            "state_transitions": events.count("state_changed"),
        }


def probe_meta(session_id):
    from app.inference import exchange, profile
    from app.meta import analyze
    from app.worker import snapshot, validate_plan

    config = settings()
    if config.ai_mode != "meta":
        raise ValueError("Real inference mode required")
    provider, base, _ = profile(config)
    with SessionLocal() as db:
        session = db.get(Session, session_id)
        if not session or session.diagnosis_mode != "meta" or not session.spec_version:
            raise ValueError("A confirmed real-mode investigation is required")
        context = snapshot(db, session)
        if not context["evidence"]:
            raise ValueError("Upload a circuit image before requesting the image probe")
        # One text request plus a two-request agent cycle, bounded by two attempts.
        reserve_budget(db, session.owner_id)
        reserve_budget(db, session.owner_id)
        db.commit()
    audits = []

    def persist(audit):
        audits.append(audit)
        with SessionLocal() as db:
            db.add(ModelRun(session_id=session_id, data={**audit, "verification": True, "probe_only": True}))
            db.commit()

    text_message, text_audit = exchange(
        provider=provider,
        base=base,
        key=config.meta_api_key,
        model=config.meta_reasoning_model,
        messages=[
            {
                "role": "system",
                "content": "This is a software connectivity check, not a circuit diagnosis. Reply with CIRCUITLAB_OK.",
            },
            {"role": "user", "content": "Confirm that this real backend text request reached the model."},
        ],
        tools=[],
        max_tokens=1000,
        timeout=config.meta_timeout_seconds,
        reasoning_effort=config.meta_reasoning_effort,
        on_exchange=persist,
    )
    text_ok = bool(text_message.get("content")) and text_audit.get("finish_reason") != "length"
    output, metadata = analyze(context, on_exchange=persist)
    validate_plan(output, context)
    executions = [
        a for a in audits if a.get("run_kind") == "tool_execution" and a.get("status") == "executed"
    ]
    returned = {tool_id for a in audits for tool_id in a.get("returned_tool_call_ids", [])}
    result = {
        "text": text_ok,
        "image": any(a.get("input_image_count", 0) > 0 and a.get("status") == "received" for a in audits),
        "authorized_tool_round_trip": bool(executions)
        and all(a["tool_call_id"] in returned for a in executions),
        "diagnosis_schema_accepted": bool(metadata),
        "physical_measurement_performed": False,
    }
    with SessionLocal() as db:
        session = db.scalar(select(Session).where(Session.id == session_id).with_for_update())
        record(db, session, "production_provider_probe", result)
        db.commit()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--session-id", help="Inspect an existing investigation; never creates fixture sessions"
    )
    parser.add_argument(
        "--probe-meta", action="store_true", help="Make three real provider requests; consumes model tokens"
    )
    parser.add_argument("--email-receipt", help="Retrieve an existing Resend receipt; never sends email")
    parser.add_argument("--expect-build-revision", help="Require the running API to match a deployed Git revision")
    args = parser.parse_args()
    if args.probe_meta and not args.session_id:
        parser.error("--probe-meta requires --session-id with an uploaded circuit image")
    report = inspect_environment()
    if args.expect_build_revision:
        report["checks"]["expected_build_revision"] = (
            report["deployment"]["build_revision"] == args.expect_build_revision
            and args.expect_build_revision != "unknown"
        )
    try:
        if args.session_id:
            report["investigation"] = session_status(args.session_id)
        if args.probe_meta:
            report["live_probe"] = probe_meta(args.session_id)
            report["checks"]["live_provider_probe"] = all(
                v for k, v in report["live_probe"].items() if k != "physical_measurement_performed"
            )
        if args.email_receipt:
            from app.accounts import refresh_delivery

            with SessionLocal() as db:
                row = db.get(EmailDelivery, args.email_receipt)
                if not row:
                    raise ValueError("Email receipt not found")
                report["email_receipt"] = refresh_delivery(db, row)
                report["checks"]["email_provider_delivery"] = row.status in {"delivered", "opened", "clicked"}
    except Exception as exc:
        report["checks"]["requested_verification"] = False
        report["failure_type"] = type(exc).__name__
        if getattr(exc, "provider_http_status", None) is not None:
            report["provider_http_status"] = exc.provider_http_status
    report["scope"] = "environment_and_requested_checks"
    report["provider_inference_verified_this_run"] = report["checks"].get("live_provider_probe", False)
    report["email_provider_delivery_verified_this_run"] = report["checks"].get("email_provider_delivery", False)
    report["physical_repair_verified_this_run"] = False
    report["passed"] = all(report["checks"].values())
    report["notice"] = (
        "Availability/configuration checks do not prove provider inference, email delivery or physical repairs. Only explicitly requested live probes verify those software capabilities."
    )
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
