"""No external mail is sent by these tests."""

import httpx
import pytest
from pydantic import SecretStr
from sqlalchemy import select
from app import email_probe
from app.config import settings
from app.db import EmailDelivery


def test_explicit_probe_sends_once_and_persists_only_safe_receipt(database, monkeypatch):
    monkeypatch.setattr(email_probe, "SessionLocal", database)
    monkeypatch.setattr(settings(), "resend_api_key", SecretStr("re_private_probe_key"))
    monkeypatch.setattr(settings(), "resend_from", "CircuitLab <sender@example.test>")
    calls = []

    def post(url, **kwargs):
        calls.append(kwargs)
        assert "reset-password" not in kwargs["json"]["text"]
        return httpx.Response(200, json={"id": "probe-provider-id"}, request=httpx.Request("POST", url))

    monkeypatch.setattr(email_probe.httpx, "post", post)
    receipt = email_probe.send_probe("recipient@example.test")
    assert len(calls) == 1 and receipt["status"] == "accepted"
    with database() as db:
        row = db.scalar(select(EmailDelivery))
        assert row.purpose == "operational_test" and row.user_id is None
        assert row.provider_id == "probe-provider-id"
    assert "recipient@example.test" not in str(receipt) and "re_private_probe_key" not in str(receipt)


def test_rejected_probe_does_not_retry_or_claim_delivery(database, monkeypatch):
    monkeypatch.setattr(email_probe, "SessionLocal", database)
    monkeypatch.setattr(settings(), "resend_api_key", SecretStr("re_private_probe_key"))
    monkeypatch.setattr(settings(), "resend_from", "CircuitLab <sender@example.test>")
    calls = []

    def post(url, **kwargs):
        calls.append(True)
        return httpx.Response(
            403, json={"error": "private upstream body"}, request=httpx.Request("POST", url)
        )

    monkeypatch.setattr(email_probe.httpx, "post", post)
    with pytest.raises(httpx.HTTPStatusError):
        email_probe.send_probe("recipient@example.test")
    assert len(calls) == 1
    with database() as db:
        row = db.scalar(select(EmailDelivery))
        assert row.status == "failed" and row.http_status == 403 and row.provider_id is None
