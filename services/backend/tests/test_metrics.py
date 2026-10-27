"""Metrics count network exchanges once and never equate transport success with accuracy."""
import json
import time
from datetime import UTC, datetime, timedelta

from sqlalchemy import select

from app.db import Job, Measurement, ModelRun, Session, User, Verification

P = "/api/v1"


def administrator_headers(database, headers):
    with database() as db:
        db.scalar(select(User).where(User.email == "owner@example.test")).role = "admin"
        db.commit()
    return headers


def test_metrics_require_active_administrator(client, headers, database):
    assert client.get(P + "/admin/metrics").status_code == 401
    assert client.get(P + "/admin/metrics", headers=headers).status_code == 403
    admin = administrator_headers(database, headers)
    for query in ("days=0", "days=91", "mode=invalid"):
        assert client.get(P + "/admin/metrics?" + query, headers=admin).status_code == 422
    response = client.get(P + "/admin/metrics?days=7", headers=admin)
    assert response.status_code == 200 and response.headers["Cache-Control"] == "no-store"
    data = response.json()
    assert data["inference"]["requests"] == 0
    assert data["inference"]["p95_latency_ms"] is None
    assert data["inference"]["http_success_rate"] is None
    assert len(data["daily"]) == 7
    assert data["diagnostic_accuracy"]["value"] is None


def test_real_audits_are_counted_once_with_separate_simulation_and_measurement_sources(client, database, headers):
    admin = administrator_headers(database, headers)
    now = time.time()
    with database() as db:
        owner = db.scalar(select(User).where(User.email == "owner@example.test"))
        real = Session(owner_id=owner.id, title="Private session", family="voltage_divider", expected="Private spec",
                       symptoms="Private symptom", supply_v=5, diagnosis_mode="meta")
        simulated = Session(owner_id=owner.id, title="Fixture", family="voltage_divider", expected="Fixture spec",
                            symptoms="Fixture symptom", supply_v=5, diagnosis_mode="simulation")
        db.add_all([real, simulated])
        db.flush()
        for duration, status, total in ((100, 200, 100), (300, 429, 0)):
            db.add(ModelRun(session_id=real.id, data={
                "run_kind": "provider_exchange", "provider": "meta", "model": "enabled-model",
                "http_status": status, "duration_ms": duration, "status": "received" if status == 200 else "error",
                "usage": {"prompt_tokens": 60, "completion_tokens": 40, "total_tokens": total} if total else {},
                "response_message": {"content": "PRIVATE prompt, raw answer and private-api-key must not leave metrics"},
            }))
        db.add_all([
            ModelRun(session_id=real.id, data={"run_kind": "diagnosis", "provider": "meta", "model": "enabled-model",
                     "real_network_attempt": True, "duration_ms": 400, "usage": {"total_tokens": 100},
                     "output": {"action": "read_voltage"}, "exchanges": [{"usage": {"total_tokens": 100}}]}),
            ModelRun(session_id=real.id, data={"run_kind": "tool_execution", "status": "executed", "provider": "meta",
                     "result": {"private": "Private measurement payload"}}),
            ModelRun(session_id=real.id, data={"status": "error", "error": "analysis_failed"}),
            ModelRun(session_id=simulated.id, data={"provider": "simulation", "output": {"action": "read_voltage"}}),
            Measurement(session_id=real.id, client_id="simulated-fixture", point_id="TP1", value=.04,
                        measured_at=now, source="simulated"),
            Measurement(session_id=real.id, client_id="instrument", point_id="TP1", value=2.5,
                        measured_at=now, source="instrumented"),
            Verification(session_id=real.id, data={"passed": True, "physical_verification": False}),
            Job(session_id=real.id, kind="analysis", status="pending"),
        ])
        db.commit()
    response = client.get(P + "/admin/metrics?days=30&mode=all", headers=admin)
    data = response.json()
    inference = data["inference"]
    assert inference["requests"] == 2 and inference["total_tokens"] == 100
    assert inference["http_success_rate"] == 50 and inference["http_errors"] == 1
    assert inference["mean_latency_ms"] == 200 and inference["p95_latency_ms"] == 290
    assert inference["accepted_diagnoses"] == 1 and inference["failed_diagnostic_attempts"] == 1
    assert inference["tool_executions"] == 1 and inference["simulation_steps"] == 1
    assert inference["usage_reported_calls"] == 1
    assert data["measurements"] == {"instrumented": 1, "manual": 0, "simulated": 1}
    assert data["sessions"]["physical_verifications"] == 0 and data["queue"]["pending"] == 1
    assert sum(d["requests"] for d in data["daily"]) == 2
    assert len(data["recent_calls"]) == 2 and data["models"][0]["requests"] == 2
    assert not any(value in response.text for value in ("PRIVATE", "private-api-key", "Private spec", "Private symptom"))
    real = client.get(P + "/admin/metrics?mode=real", headers=admin).json()
    simulation = client.get(P + "/admin/metrics?mode=simulation", headers=admin).json()
    assert real["inference"]["simulation_steps"] == 0
    assert simulation["inference"]["requests"] == 0 and simulation["inference"]["simulation_steps"] == 1
    assert data["diagnostic_accuracy"]["value"] is None
    assert "usage" not in json.dumps(data["runtime"])


def test_metrics_window_uses_call_time_and_keeps_current_queue(client, database, headers):
    admin = administrator_headers(database, headers)
    old = (datetime.now(UTC) - timedelta(days=100)).timestamp()
    with database() as db:
        owner = db.scalar(select(User).where(User.email == "owner@example.test"))
        session = Session(owner_id=owner.id, title="Old session", family="voltage_divider", expected="Expected",
                          symptoms="Symptoms", supply_v=5, diagnosis_mode="meta", created_at=old)
        db.add(session)
        db.flush()
        base = {"run_kind": "provider_exchange", "provider": "meta", "model": "enabled-model",
                "http_status": 200, "status": "received"}
        db.add_all([ModelRun(session_id=session.id, data=base, created_at=old),
                    ModelRun(session_id=session.id, data={**base, "finish_reason": "length"}),
                    Job(session_id=session.id, status="pending", created_at=old)])
        db.commit()
    data = client.get(P + "/admin/metrics?days=7", headers=admin).json()
    assert data["sessions"]["created"] == 0 and data["inference"]["requests"] == 1
    assert data["inference"]["truncated"] == 1 and data["recent_calls"][0]["outcome"] == "truncated"
    assert data["inference"]["p95_latency_ms"] is None and data["inference"]["usage_reported_calls"] == 0
    assert data["queue"]["pending"] == 1
