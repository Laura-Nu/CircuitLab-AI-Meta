"""Operational checks and atomic daily attempt budgets; no secrets in public output."""

import time
from pathlib import Path
from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from app.config import settings
from app.db import EmailDelivery, Event, Job, UsageCounter, WorkerHeartbeat


class BudgetExceeded(RuntimeError):
    pass


def limits(owner_id):
    config = settings()
    return [("global", config.daily_ai_jobs_global), ("user:" + owner_id, config.daily_ai_jobs_per_user)]


def ensure_budget(db, owner_id):
    day = int(time.time() // 86400)
    for scope, limit in limits(owner_id):
        row = db.get(UsageCounter, (scope, day))
        if row and row.attempts >= limit:
            raise BudgetExceeded("Daily inference attempt budget exhausted")


def reserve_budget(db, owner_id):
    """One attempt covers at most two model calls. Retries each reserve another attempt.

    The caller commits both scopes together; failures must roll the transaction back.
    """
    day = int(time.time() // 86400)
    insert = pg_insert if db.bind.dialect.name == "postgresql" else sqlite_insert
    for scope, limit in limits(owner_id):
        statement = insert(UsageCounter).values(scope=scope, day=day, attempts=1)
        statement = statement.on_conflict_do_update(
            index_elements=[UsageCounter.scope, UsageCounter.day],
            set_={"attempts": UsageCounter.attempts + 1},
            where=UsageCounter.attempts < limit,
        ).returning(UsageCounter.attempts)
        if db.scalar(statement) is None:
            raise BudgetExceeded("Daily inference attempt budget exhausted")


def functional_result(db, session):
    after = (session.pending_test or {}).get("after", 0)
    for event in db.scalars(
        select(Event)
        .where(Event.session_id == session.id, Event.kind == "functional_check_recorded")
        .order_by(Event.sequence.desc())
    ):
        data = event.data
        if (
            data.get("after") == after
            and data.get("spec_version") == session.spec_version
            and after <= data.get("performed_at", 0) <= time.time() + 30
        ):
            return {"event_id": event.id, **data}
    return None


def heartbeat(db, worker_id):
    now = time.time()
    db.merge(WorkerHeartbeat(id=worker_id, last_seen=now))
    db.execute(delete(WorkerHeartbeat).where(WorkerHeartbeat.last_seen < now - 86400))
    db.commit()


def operational_status(db):
    now = time.time()
    threshold = settings().worker_lease_seconds + 30
    latest = db.scalar(select(func.max(WorkerHeartbeat.last_seen)))
    active = db.scalar(
        select(func.count(WorkerHeartbeat.id)).where(WorkerHeartbeat.last_seen >= now - threshold)
    )
    oldest = db.scalar(select(func.min(Job.created_at)).where(Job.status == "pending"))
    expired = db.scalar(select(func.count(Job.id)).where(Job.status == "running", Job.lease_until < now))
    emails = dict(
        db.execute(
            select(EmailDelivery.status, func.count(EmailDelivery.id))
            .where(EmailDelivery.created_at >= now - 86400)
            .group_by(EmailDelivery.status)
        ).all()
    )
    stale_emails = db.scalar(
        select(func.count(EmailDelivery.id)).where(
            EmailDelivery.status == "pending", EmailDelivery.created_at < now - 60
        )
    )
    usage = db.get(UsageCounter, ("global", int(now // 86400)))
    return {
        "worker": {
            "healthy": bool(active),
            "active": active or 0,
            "last_seen": latest,
            "stale_after_seconds": threshold,
        },
        "queue": {
            "oldest_pending_seconds": round(max(0, now - oldest)) if oldest else 0,
            "expired_leases": expired or 0,
        },
        "email": {
            "last_24h": emails,
            "stale_pending": stale_emails or 0,
            "receipt_is_inbox_confirmation": False,
        },
        "budget": {
            "day_timezone": "UTC",
            "used_attempts": usage.attempts if usage else 0,
            "global_limit": settings().daily_ai_jobs_global,
            "per_user_limit": settings().daily_ai_jobs_per_user,
        },
    }


def validate_runtime():
    config = settings()
    if config.app_env != "production":
        return
    from app.inference import profile
    from urllib.parse import urlsplit

    if not config.database_url.startswith("postgresql") or config.ai_mode != "meta":
        raise RuntimeError("Production requires PostgreSQL and AI_MODE=meta")
    origin = urlsplit(config.app_origin)
    if origin.scheme != "https" or not origin.hostname or origin.username or origin.query or origin.fragment:
        raise RuntimeError("Production requires an HTTPS application origin")
    profile(config)
    if config.recovery_delivery == "file":
        raise RuntimeError("Production recovery cannot use development files")
    if config.recovery_delivery == "resend" and not (
        config.resend_api_key.get_secret_value().strip() and config.resend_from.strip()
    ):
        raise RuntimeError("Production Resend configuration is incomplete")


def main():
    import argparse
    from app.db import SessionLocal

    parser = argparse.ArgumentParser(description="Check this worker's persisted heartbeat.")
    parser.add_argument("--worker-id-file", default="/tmp/circuitlab-worker.id")
    args = parser.parse_args()
    try:
        worker_id = Path(args.worker_id_file).read_text().strip()
        with SessionLocal() as db:
            row = db.get(WorkerHeartbeat, worker_id)
            healthy = bool(row and row.last_seen >= time.time() - settings().worker_lease_seconds - 30)
    except Exception:
        healthy = False
    print("Worker healthy" if healthy else "Worker unavailable")
    raise SystemExit(0 if healthy else 1)


if __name__ == "__main__":
    main()
