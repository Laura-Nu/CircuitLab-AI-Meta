"""Isolated regressions; fixture observations never count as physical or live-provider verification."""

import io
import time
import pytest
from PIL import Image
from sqlalchemy import select
from starlette.websockets import WebSocketDisconnect
from app import accounts, main, worker
from app.config import settings
from app.db import Device, EmailDelivery, Job, Measurement, Session, UsageCounter, User
from app.operations import BudgetExceeded, ensure_budget, heartbeat, operational_status, reserve_budget
from app.schemas import HardwareResult
from app.security import digest
from test_workflow import functional, measure, run_job, start

P = "/api/v1"


def prepare_verification(client, headers, configured):
    sid = start(client, headers, configured)
    measure(client, headers, sid, 0.04)
    run_job()
    assert (
        client.post(
            f"{P}/sessions/{sid}/interventions",
            headers=headers,
            json={"description": "Isolated synthetic intervention", "confirmed": True},
        ).status_code
        == 201
    )
    assert measure(client, headers, sid, 2.5, "after-audit-001").status_code == 201
    return sid


def test_voltage_pass_cannot_replace_missing_or_failed_functional_check(client, headers, configured):
    sid = prepare_verification(client, headers, configured)
    response = client.post(f"{P}/sessions/{sid}/verification", headers=headers)
    assert response.status_code == 409 and response.json()["code"] == "functional_check_required"
    assert functional(client, headers, sid, passed=False).status_code == 201
    assert client.post(f"{P}/sessions/{sid}/verification", headers=headers).status_code == 202
    run_job()
    result = client.get(f"{P}/sessions/{sid}", headers=headers).json()
    check = result["verifications"][0]["data"]
    assert result["state"] == "inconclusive" and check["electrical_passed"]
    assert not check["passed"] and not check["physical_verification"]


def test_functional_check_is_fresh_authorized_idempotent_and_retains_manual_basis(
    client, headers, configured, database
):
    sid = prepare_verification(client, headers, configured)
    body = {
        "client_id": "functional-test-001",
        "passed": True,
        "observations": "Unit fixture: observed expected behavior",
        "performed_at": configured["created_at"],
        "confirmed": True,
    }
    assert client.post(f"{P}/sessions/{sid}/functional-check", headers=headers, json=body).status_code == 422
    body["performed_at"] = time.time()
    other = client.post(
        P + "/auth/login", json={"email": "other@example.test", "password": "test-password-123"}
    ).json()
    assert (
        client.post(
            f"{P}/sessions/{sid}/functional-check",
            headers={"Authorization": "Bearer " + other["access_token"]},
            json=body,
        ).status_code
        == 403
    )
    first = client.post(f"{P}/sessions/{sid}/functional-check", headers=headers, json=body)
    second = client.post(f"{P}/sessions/{sid}/functional-check", headers=headers, json=body)
    assert (
        first.status_code == second.status_code == 201
        and first.json()["event_id"] == second.json()["event_id"]
    )
    with database() as db:
        db.get(Session, sid).diagnosis_mode = "meta"
        db.commit()
    assert client.post(f"{P}/sessions/{sid}/verification", headers=headers).status_code == 202
    run_job()
    result = client.get(f"{P}/sessions/{sid}/report", headers=headers).json()
    check = result["verifications"][0]["data"]
    assert check["physical_verification"] and check["verification_basis"] == "manual"
    assert check["functional_check"]["source"] == "human_observation"
    markdown = client.get(f"{P}/sessions/{sid}/report?format=markdown", headers=headers).text
    assert body["observations"] in markdown


def test_production_rejects_legacy_simulated_devices_on_all_hardware_paths(
    client, headers, configured, database, monkeypatch
):
    sid = start(client, headers, configured)
    with database() as db:
        owner = db.get(Session, sid).owner_id
        device = Device(
            owner_id=owner,
            name="Legacy fixture",
            token_digest=digest("legacy-test-token"),
            points=["TP1"],
            calibration_id="fixture-only",
            simulated=1,
            last_seen=time.time(),
        )
        db.add(device)
        db.commit()
        device_id = device.id
    monkeypatch.setattr(settings(), "app_env", "production")
    response = client.post(
        f"{P}/sessions/{sid}/hardware",
        headers=headers,
        json={"device_id": device_id, "point_id": "TP1", "conditions_confirmed": True},
    )
    assert response.status_code == 422
    assert client.get(P + "/health/live").json()["simulation_allowed"] is False
    with pytest.raises(WebSocketDisconnect) as closed:
        with client.websocket_connect(
            P + "/devices/connect", headers={"Authorization": "Bearer legacy-test-token"}
        ):
            pytest.fail("A legacy simulator must never connect in production")
    assert closed.value.code == 4401
    result = HardwareResult(
        protocol_version="1",
        command_id="no-command",
        status="ok",
        point_id="TP1",
        value=0.04,
        sample_count=20,
        source="simulated",
        calibration_id="fixture-only",
        measured_at=time.time(),
    )
    with database() as db:
        with pytest.raises(ValueError, match="Simulation"):
            main.accept_result(db, db.get(Device, device_id), result)
        assert not list(db.scalars(select(Measurement)))


def test_daily_budget_is_atomic_across_scopes_and_shared_across_sessions(database, monkeypatch):
    monkeypatch.setattr(settings(), "daily_ai_jobs_per_user", 1)
    monkeypatch.setattr(settings(), "daily_ai_jobs_global", 2)
    with database() as db:
        reserve_budget(db, "first")
        db.commit()
    with database() as db:
        with pytest.raises(BudgetExceeded):
            reserve_budget(db, "first")
        db.rollback()
        assert db.get(UsageCounter, ("global", int(time.time() // 86400))).attempts == 1
        reserve_budget(db, "second")
        db.commit()
    with database() as db:
        with pytest.raises(BudgetExceeded):
            ensure_budget(db, "third")


def test_worker_never_calls_provider_after_quota_is_exhausted(
    client, headers, configured, database, monkeypatch
):
    monkeypatch.setattr(settings(), "daily_ai_jobs_per_user", 1)
    with database() as db:
        row = db.get(Session, configured["id"])
        row.diagnosis_mode = "meta"
        db.commit()
        owner = row.owner_id
    result = client.post(f"{P}/sessions/{configured['id']}/analysis", headers=headers)
    assert result.status_code == 202
    with database() as db:
        reserve_budget(db, owner)
        db.commit()
    monkeypatch.setattr(worker, "analyze", lambda *a, **k: pytest.fail("No provider call is permitted"))
    run_job()
    with database() as db:
        job = db.get(Job, result.json()["job_id"])
        assert job.status == "failed" and job.error == "daily_quota_exceeded"
    assert client.post(f"{P}/sessions/{configured['id']}/analysis", headers=headers).status_code == 429


def test_production_readiness_detects_missing_or_stale_worker(client, database, monkeypatch):
    monkeypatch.setattr(settings(), "app_env", "production")
    assert client.get(P + "/health/ready").status_code == 503
    with database() as db:
        heartbeat(db, "unit-test-worker")
        assert operational_status(db)["worker"]["healthy"]
    assert client.get(P + "/health/ready").status_code == 200
    now = time.time()
    monkeypatch.setattr(time, "time", lambda: now + settings().worker_lease_seconds + 60)
    assert client.get(P + "/health/ready").status_code == 503


def test_storage_quota_rejects_upload_without_leaving_an_orphan(client, headers, configured, monkeypatch):
    monkeypatch.setattr(settings(), "max_storage_mb_per_user", 0.0001)
    image = io.BytesIO()
    Image.new("RGB", (10, 10), "white").save(image, format="PNG")
    response = client.post(
        f"{P}/sessions/{configured['id']}/evidence",
        headers=headers,
        data={"client_id": "over-storage-limit"},
        files={"file": ("photo.png", image.getvalue(), "image/png")},
    )
    assert response.status_code == 413 and response.json()["code"] == "storage_quota_exceeded"
    from pathlib import Path

    assert not list(Path(settings().storage_root).iterdir())


def test_resend_receipt_records_acceptance_and_only_exposes_safe_status(
    client, headers, database, monkeypatch
):
    from pydantic import SecretStr

    monkeypatch.setattr(settings(), "recovery_delivery", "resend")
    monkeypatch.setattr(settings(), "resend_api_key", SecretStr("re_private_test"))
    monkeypatch.setattr(settings(), "resend_from", "CircuitLab <test@example.test>")
    import httpx

    monkeypatch.setattr(
        accounts.httpx,
        "post",
        lambda url, **kwargs: httpx.Response(
            200, json={"id": "email-id"}, request=httpx.Request("POST", url)
        ),
    )
    assert client.post(P + "/auth/forgot-password", json={"email": "owner@example.test"}).status_code == 202
    with database() as db:
        row = db.scalar(select(EmailDelivery))
        assert row.status == "accepted" and row.provider_id == "email-id"
        receipt_id = row.id
        db.scalar(select(User).where(User.email == "owner@example.test")).role = "admin"
        db.commit()

    def get(url, **kwargs):
        assert url == "https://api.resend.com/emails/email-id"
        return httpx.Response(
            200,
            json={
                "id": "email-id",
                "last_event": "delivered",
                "to": ["private@example.test"],
                "text": "private-reset-link",
            },
            request=httpx.Request("GET", url),
        )

    monkeypatch.setattr(accounts.httpx, "get", get)
    response = client.post(f"{P}/admin/email-deliveries/{receipt_id}/refresh", headers=headers)
    assert response.status_code == 200 and response.json()["status"] == "delivered"
    assert all(
        secret not in response.text
        for secret in ("private@example.test", "private-reset-link", "re_private_test")
    )
    with database() as db:
        assert db.get(EmailDelivery, receipt_id).status == "delivered"


def test_receipt_refresh_requires_admin_and_unavailable_receipt_is_not_delivery(client, headers, database):
    assert client.get(P + "/admin/email-deliveries").status_code == 401
    assert client.get(P + "/admin/email-deliveries", headers=headers).status_code == 403
    with database() as db:
        user = db.scalar(select(User).where(User.email == "owner@example.test"))
        user.role = "admin"
        row = EmailDelivery(user_id=user.id)
        db.add(row)
        db.commit()
        receipt_id = row.id
    assert client.post(f"{P}/admin/email-deliveries/{receipt_id}/refresh", headers=headers).status_code == 409


def test_probe_requires_existing_evidence_before_any_paid_call(client, configured, database, monkeypatch):
    from app import production_check, inference

    monkeypatch.setattr(production_check, "SessionLocal", database)
    monkeypatch.setattr(settings(), "ai_mode", "meta")
    monkeypatch.setattr(inference, "profile", lambda config: ("meta", inference.META_URL, 12))
    monkeypatch.setattr(inference, "exchange", lambda **kwargs: pytest.fail("No image: no paid call"))
    with database() as db:
        db.get(Session, configured["id"]).diagnosis_mode = "meta"
        db.commit()
    with pytest.raises(ValueError, match="image"):
        production_check.probe_meta(configured["id"])


def test_postgresql_parallel_reservations_never_exceed_the_shared_budget(database, monkeypatch):
    from concurrent.futures import ThreadPoolExecutor

    with database() as db:
        if db.bind.dialect.name != "postgresql":
            pytest.skip("Concurrency assertion requires PostgreSQL row locks")
    monkeypatch.setattr(settings(), "daily_ai_jobs_per_user", 2)
    monkeypatch.setattr(settings(), "daily_ai_jobs_global", 3)

    def attempt(_):
        with database() as db:
            try:
                reserve_budget(db, "shared-owner")
                db.commit()
                return True
            except BudgetExceeded:
                db.rollback()
                return False

    with ThreadPoolExecutor(max_workers=8) as pool:
        assert sum(pool.map(attempt, range(8))) == 2
    with database() as db:
        assert db.get(UsageCounter, ("global", int(time.time() // 86400))).attempts == 2


def test_resend_send_only_key_reports_actionable_error_without_leaking_provider_body(
    client, headers, database, monkeypatch
):
    from pydantic import SecretStr
    import httpx

    monkeypatch.setattr(settings(), "recovery_delivery", "resend")
    monkeypatch.setattr(settings(), "resend_api_key", SecretStr("re_private_restricted"))
    monkeypatch.setattr(settings(), "resend_from", "CircuitLab <test@example.test>")
    with database() as db:
        user = db.scalar(select(User).where(User.email == "owner@example.test"))
        user.role = "admin"
        row = EmailDelivery(user_id=user.id, status="accepted", provider_id="safe-provider-id")
        db.add(row)
        db.commit()
        receipt_id = row.id
    monkeypatch.setattr(
        accounts.httpx,
        "get",
        lambda url, **kw: httpx.Response(
            401,
            request=httpx.Request("GET", url),
            json={"name": "restricted_api_key", "message": "private re_private_restricted provider body"},
        ),
    )
    response = client.post(f"{P}/admin/email-deliveries/{receipt_id}/refresh", headers=headers)
    assert response.status_code == 502 and response.json()["code"] == "resend_read_permission_required"
    assert "re_private_restricted" not in response.text and "provider body" not in response.text
    with database() as db:
        assert db.get(EmailDelivery, receipt_id).status == "accepted"


def test_delayed_older_reading_cannot_replace_the_latest_post_intervention_observation(
    client, headers, configured, database
):
    sid = prepare_verification(client, headers, configured)
    assert functional(client, headers, sid).status_code == 201
    with database() as db:
        session = db.get(Session, sid)
        latest = db.scalar(
            select(Measurement).where(Measurement.session_id == sid, Measurement.phase == "verification")
        )
        # Keep observation times distinct even when the host clock returns the
        # same tick for intervention and acquisition. Arrival order is not capture order.
        latest.measured_at = session.pending_test["after"] + 1
        db.add(
            Measurement(
                session_id=sid,
                client_id="delayed-older-reading",
                point_id="TP1",
                source="manual",
                value=0.1,
                phase="verification",
                measured_at=(session.pending_test["after"] + latest.measured_at) / 2,
            )
        )
        db.commit()
    assert client.post(f"{P}/sessions/{sid}/verification", headers=headers).status_code == 202
    run_job()
    result = client.get(f"{P}/sessions/{sid}", headers=headers).json()
    assert result["state"] == "resolved" and result["verifications"][0]["data"]["checks"][0]["value"] == 2.5
