"""Administrator-only operational metrics from whitelisted audit fields, never prompts or secrets."""
from collections import Counter, defaultdict
from datetime import UTC, datetime, timedelta
import math
from typing import Literal

from fastapi import APIRouter, Depends, Query, Response
from sqlalchemy import func, select
from sqlalchemy.orm import Session as DBSession

from app.config import settings
from app.db import Job, Measurement, ModelRun, Session, Verification, get_db
from app.security import administrator
from app.operations import operational_status

router = APIRouter(prefix="/api/v1/admin", tags=["administration"])


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        return None
    try:
        value = float(value)
    except ValueError:
        return None
    return value if math.isfinite(value) and value >= 0 else None


def tokens(usage):
    usage = usage if isinstance(usage, dict) else {}
    prompt = int(number(usage.get("prompt_tokens")) or 0)
    completion = int(number(usage.get("completion_tokens")) or 0)
    total = number(usage.get("total_tokens"))
    return prompt, completion, int(total) if total is not None else prompt + completion


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = int(position)
    return round(ordered[lower] + (ordered[min(lower + 1, len(ordered) - 1)] - ordered[lower]) * (position - lower), 1)


def mode_filter(mode):
    return [] if mode == "all" else [Session.diagnosis_mode == ("meta" if mode == "real" else "simulation")]


def operational_metrics(db, days, mode, now=None):
    now = now or datetime.now(UTC)
    start = now.replace(hour=0, minute=0, second=0, microsecond=0) - timedelta(days=days - 1)
    start_ts, end_ts = start.timestamp(), now.timestamp()
    daily = {(start + timedelta(days=i)).date().isoformat(): {
        "day": (start + timedelta(days=i)).date().isoformat(), "requests": 0, "http_errors": 0,
        "transport_errors": 0, "truncated": 0, "tokens": 0, "simulation_steps": 0,
        "latency_total_ms": 0, "latency_samples": 0,
    } for i in range(days)}
    fields = ["run_kind", "provider", "model", "response_model", "status", "http_status", "duration_ms",
              "real_network_attempt", "request_sha256", "finish_reason", "tool_name"]
    columns = [ModelRun.id, ModelRun.created_at,
               *[ModelRun.data[field].as_string().label(field) for field in fields],
               ModelRun.data["usage"].label("usage"),
               ModelRun.data["output"]["action"].as_string().label("output_action")]
    query = (select(*columns).join(Session, Session.id == ModelRun.session_id)
             .where(ModelRun.created_at >= start_ts, ModelRun.created_at <= end_ts, *mode_filter(mode))
             .order_by(ModelRun.created_at.desc(), ModelRun.id.desc()).execution_options(yield_per=500))
    counts = Counter()
    durations, recent = [], []
    models = defaultdict(lambda: Counter())
    last_call = None
    for row in db.execute(query).mappings():
        day = datetime.fromtimestamp(row["created_at"], UTC).date().isoformat()
        bucket = daily[day]
        kind = row["run_kind"]
        if row["provider"] == "simulation":
            if row["output_action"]:
                counts["simulation_steps"] += 1
                bucket["simulation_steps"] += 1
            continue
        if kind == "tool_execution":
            counts["tool_executions"] += row["status"] == "executed"
            continue
        if kind == "diagnosis" and row["output_action"]:
            counts["accepted_diagnoses"] += 1
            continue
        if not kind and row["status"] == "error" and not row["request_sha256"]:
            counts["failed_diagnostic_attempts"] += 1
            continue
        actual = kind == "provider_exchange" or (kind is None and (
            row["real_network_attempt"] in (True, "true", "1", 1) or
            row["provider"] in {"meta", "baseten", "self_hosted"} and row["request_sha256"]
        ))
        if not actual:
            continue
        last_call = last_call or row["created_at"]
        status = int(number(row["http_status"]) or 0)
        transport_error = not status and row["status"] == "error"
        outcome = ("truncated" if row["finish_reason"] == "length" else
                   "http_ok" if 200 <= status < 300 else "http_error" if status else
                   "transport_error" if transport_error else "unknown")
        counts["requests"] += 1
        counts["http_ok"] += 200 <= status < 300
        counts["http_errors"] += bool(status and not 200 <= status < 300)
        counts["transport_errors"] += transport_error
        counts["unreported_status_calls"] += outcome == "unknown"
        counts["truncated"] += outcome == "truncated"
        bucket["requests"] += 1
        bucket["http_errors"] += bool(status and not 200 <= status < 300)
        bucket["transport_errors"] += transport_error
        bucket["truncated"] += outcome == "truncated"
        prompt, completion, total = tokens(row["usage"])
        reported = isinstance(row["usage"], dict) and any(number(row["usage"].get(k)) is not None
                    for k in ("prompt_tokens", "completion_tokens", "total_tokens"))
        counts["usage_reported_calls"] += reported
        counts["prompt_tokens"] += prompt
        counts["completion_tokens"] += completion
        counts["total_tokens"] += total
        bucket["tokens"] += total
        duration = number(row["duration_ms"])
        if duration is not None:
            durations.append(duration)
            bucket["latency_total_ms"] += duration
            bucket["latency_samples"] += 1
        model = str(row["model"] or row["response_model"] or "unknown")[:150]
        provider = str(row["provider"] or "unknown")[:40]
        group = models[(provider, model)]
        group["requests"] += 1
        group["http_errors"] += bool(status and not 200 <= status < 300) or transport_error
        group["tokens"] += total
        if len(recent) < 20:
            recent.append({"id": row["id"], "created_at": row["created_at"], "provider": provider,
                           "model": model, "http_status": status or None, "outcome": outcome,
                           "duration_ms": duration, "tokens": total, "usage_reported": reported})
    states = dict(db.execute(select(Session.state, func.count(Session.id)).where(
        Session.created_at >= start_ts, Session.created_at <= end_ts, *mode_filter(mode)
    ).group_by(Session.state)).all())
    sources = dict(db.execute(select(Measurement.source, func.count(Measurement.id)).join(
        Session, Session.id == Measurement.session_id
    ).where(Measurement.created_at >= start_ts, Measurement.created_at <= end_ts,
            *mode_filter(mode)).group_by(Measurement.source)).all())
    queue = dict(db.execute(select(Job.status, func.count(Job.id)).join(Session, Session.id == Job.session_id)
                            .where(Job.status.in_(["pending", "running"]), *mode_filter(mode))
                            .group_by(Job.status)).all())
    physical = db.scalar(select(func.count(Verification.id)).join(Session, Session.id == Verification.session_id)
                         .where(Verification.created_at >= start_ts, Verification.created_at <= end_ts,
                                Verification.data["physical_verification"].as_boolean().is_(True),
                                Verification.data["functional_check"]["passed"].as_boolean().is_(True), *mode_filter(mode)))
    config = settings()
    return {
        "window": {"days": days, "start": start_ts, "end": end_ts, "timezone": "UTC", "mode": mode},
        "generated_at": end_ts,
        "operations": operational_status(db),
        "runtime": {"ai_mode": config.ai_mode, "provider": config.meta_provider,
                    "model": config.meta_reasoning_model or None,
                    "configured": bool(config.meta_api_key and config.meta_reasoning_model),
                    "last_recorded_call": last_call},
        "inference": {key: counts[key] for key in (
            "requests", "http_ok", "http_errors", "transport_errors", "truncated", "prompt_tokens",
            "completion_tokens", "total_tokens", "usage_reported_calls", "accepted_diagnoses",
            "failed_diagnostic_attempts", "tool_executions", "simulation_steps", "unreported_status_calls",
        )} | {"http_success_rate": round(100 * counts["http_ok"] / (counts["requests"] - counts["unreported_status_calls"]), 1)
              if counts["requests"] > counts["unreported_status_calls"] else None,
              "latency_samples": len(durations), "mean_latency_ms": round(sum(durations) / len(durations), 1) if durations else None,
              "p95_latency_ms": percentile(durations, .95)},
        "sessions": {"created": sum(states.values()), "current_states": states,
                     "physical_verifications": physical or 0},
        "measurements": {key: sources.get(key, 0) for key in ("instrumented", "manual", "simulated", "serial_reported")},
        "queue": {"pending": queue.get("pending", 0), "running": queue.get("running", 0)},
        "daily": [{**{k: v for k, v in day.items() if k != "latency_total_ms"},
                   "mean_latency_ms": round(day["latency_total_ms"] / day["latency_samples"], 1)
                   if day["latency_samples"] else None} for day in daily.values()],
        "models": [{"provider": key[0], "model": key[1], **value} for key, value in sorted(models.items())],
        "recent_calls": recent,
        "diagnostic_accuracy": {"value": None, "reason": "No independently reviewed ground-truth dataset is linked."},
    }


@router.get("/metrics")
def metrics(response: Response, days: int = Query(default=30, ge=1, le=90),
            mode: Literal["all", "real", "simulation"] = Query(default="real"),
            user=Depends(administrator), db: DBSession = Depends(get_db)):
    response.headers["Cache-Control"] = "no-store"
    return operational_metrics(db, days, mode)
