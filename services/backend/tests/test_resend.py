"""Exercise the Resend HTTP contract without sending external email."""

import re

import httpx
import pytest
from pydantic import SecretStr
from sqlalchemy import select

from app import accounts
from app.config import Settings, settings
from app.db import Token
from app.security import digest

P = "/api/v1"


@pytest.fixture
def resend(monkeypatch):
    for key, value in {
        "recovery_delivery": "resend",
        "resend_api_key": SecretStr("re_private_test_key"),
        "resend_from": "CircuitLab AI <access@example.test>",
    }.items():
        monkeypatch.setattr(settings(), key, value)


@pytest.mark.parametrize("language", ["es", "en"])
def test_resend_recovery_payload_and_single_use_reset(
    client, database, headers, monkeypatch, resend, language
):
    sent = []

    def post(url, **kwargs):
        sent.append((url, kwargs))
        return httpx.Response(200, json={"id": "email-id"}, request=httpx.Request("POST", url))

    monkeypatch.setattr(accounts.httpx, "post", post)
    response = client.post(
        P + "/auth/forgot-password",
        json={"email": "owner@example.test"},
        headers={"Accept-Language": language},
    )
    assert response.status_code == 202 and response.json() == {"status": "accepted"}
    assert len(sent) == 1
    url, request = sent[0]
    assert url == "https://api.resend.com/emails" and request["timeout"] == 10
    assert request["headers"]["Authorization"] == "Bearer re_private_test_key"
    body = request["json"]
    assert body["from"] == "CircuitLab AI <access@example.test>"
    assert body["to"] == ["owner@example.test"]
    assert body["subject"] == (
        "Reset your CircuitLab password" if language == "en" else "Restablece tu contraseña de CircuitLab"
    )
    assert f"?lang={language}#/reset-password?token=" in body["text"]
    assert ("20 minutes" if language == "en" else "20 minutos") in body["text"]
    token = re.search(r"token=([A-Za-z0-9_-]+)", body["text"])[1]
    assert request["headers"]["Idempotency-Key"] == "recovery/" + digest(token)
    assert token not in str(request["headers"]) and token not in response.text
    with database() as db:
        assert db.get(Token, digest(token)).kind == "password_reset"
    reset = {"token": token, "password": "new-resend-password-123"}
    assert client.post(P + "/auth/reset-password", json=reset).status_code == 204
    assert client.post(P + "/auth/reset-password", json=reset).status_code == 400
    assert client.get(P + "/sessions", headers=headers).status_code == 401
    assert (
        client.post(
            P + "/auth/login", json={"email": "owner@example.test", "password": reset["password"]}
        ).status_code
        == 200
    )


@pytest.mark.parametrize("status", [401, 403, 429, 500])
def test_resend_errors_preserve_generic_response_and_hide_secrets(
    client, monkeypatch, resend, caplog, status
):
    def post(url, **kwargs):
        return httpx.Response(
            status,
            json={"message": "private-provider-error owner@example.test re_private_test_key"},
            request=httpx.Request("POST", url),
        )

    monkeypatch.setattr(accounts.httpx, "post", post)
    response = client.post(P + "/auth/forgot-password", json={"email": "owner@example.test"})
    assert response.status_code == 202 and response.json() == {"status": "accepted"}
    assert f"HTTP {status}" in caplog.text
    for secret in ["owner@example.test", "re_private_test_key", "private-provider-error", "token="]:
        assert secret not in caplog.text and secret not in response.text


def test_resend_timeout_does_not_reveal_address_or_reset_link(client, monkeypatch, resend, caplog):
    def post(url, **kwargs):
        raise httpx.ReadTimeout("private-reset-link token=not-for-logs")

    monkeypatch.setattr(accounts.httpx, "post", post)
    response = client.post(P + "/auth/forgot-password", json={"email": "owner@example.test"})
    assert response.status_code == 202
    assert "ReadTimeout" in caplog.text and "private-reset-link" not in caplog.text


@pytest.mark.parametrize("missing", ["resend_api_key", "resend_from"])
def test_resend_missing_configuration_does_not_issue_or_send_a_token(
    client, database, monkeypatch, resend, missing
):
    monkeypatch.setattr(settings(), missing, SecretStr("") if missing == "resend_api_key" else "")

    def unexpected(*args, **kwargs):
        pytest.fail("Resend must not be called without complete configuration")

    monkeypatch.setattr(accounts.httpx, "post", unexpected)
    assert client.post(P + "/auth/forgot-password", json={"email": "owner@example.test"}).status_code == 202
    with database() as db:
        assert not list(db.scalars(select(Token).where(Token.kind == "password_reset")))


def test_resend_idempotency_is_stable_and_never_exposes_the_token(monkeypatch, resend):
    keys = []

    def post(url, **kwargs):
        keys.append(kwargs["headers"]["Idempotency-Key"])
        return httpx.Response(200, json={"id": "email-id"}, request=httpx.Request("POST", url))

    monkeypatch.setattr(accounts.httpx, "post", post)
    for _ in range(2):
        accounts.deliver_recovery("owner@example.test", "same-private-reset-token", "en")
    assert keys[0] == keys[1] == "recovery/" + digest("same-private-reset-token")


@pytest.mark.parametrize("payload", [{}, {"id": None}, [], {"id": ""}])
def test_resend_rejects_invalid_success_receipts(monkeypatch, resend, caplog, payload):
    monkeypatch.setattr(
        accounts.httpx,
        "post",
        lambda url, **kwargs: httpx.Response(200, json=payload, request=httpx.Request("POST", url)),
    )
    accounts.deliver_recovery("owner@example.test", "private-reset-token", "es")
    assert "ValueError" in caplog.text and "private-reset-token" not in caplog.text


def test_resend_key_is_redacted_in_settings_representation():
    config = Settings(_env_file=None, resend_api_key="re_sensitive", recovery_delivery="resend")
    assert "re_sensitive" not in repr(config)
