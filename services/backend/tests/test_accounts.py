import re
import time
from email import policy
from email.parser import BytesParser

import pytest
from sqlalchemy import select

from app.config import settings
from app.db import AccountEvent, Device, Token, User
from app.security import digest

P = "/api/v1"


@pytest.fixture
def admin(client, database, headers):
    with database() as db:
        user = db.scalar(select(User).where(User.email == "owner@example.test"))
        user.role = "admin"
        db.commit()
    return headers


@pytest.fixture
def mailbox(tmp_path, monkeypatch):
    monkeypatch.setattr(settings(), "recovery_delivery", "file")
    monkeypatch.setattr(settings(), "recovery_directory", str(tmp_path / "mail"))
    return tmp_path / "mail"


def request_token(client, mailbox, email="owner@example.test", language="en"):
    response = client.post(
        P + "/auth/forgot-password", json={"email": email}, headers={"Accept-Language": language}
    )
    assert response.status_code == 202 and response.json() == {"status": "accepted"}
    message = BytesParser(policy=policy.default).parsebytes(
        max(mailbox.glob("*.eml"), key=lambda p: p.stat().st_mtime_ns).read_bytes()
    )
    assert f"?lang={language}#/reset-password?token=" in message.get_content()
    return re.search(r"token=([A-Za-z0-9_-]+)", message.get_content())[1]


def test_account_permissions_and_no_secrets(client, headers, admin):
    other = client.post(
        P + "/auth/login", json={"email": "other@example.test", "password": "test-password-123"}
    ).json()
    forbidden = {"Authorization": "Bearer " + other["access_token"], "Accept-Language": "en"}
    for path in ["/admin/users", "/admin/events"]:
        assert client.get(P + path).status_code == 401
        response = client.get(P + path, headers=forbidden)
        assert response.status_code == 403 and response.json()["code"] == "admin_required"
    assert (
        client.post(
            P + "/admin/users",
            headers=forbidden,
            json={"email": "new@example.test", "password": "initial-password-123"},
        ).status_code
        == 403
    )
    response = client.post(
        P + "/admin/users",
        headers=admin,
        json={"email": " New@Example.test ", "password": "initial-password-123", "role": "member"},
    )
    assert response.status_code == 201
    account = response.json()
    assert set(account) == {"id", "email", "role", "active"}
    assert account["email"] == "new@example.test" and account["active"]
    assert (
        client.post(
            P + "/admin/users",
            headers=admin,
            json={"email": "new@example.test", "password": "initial-password-123"},
        ).status_code
        == 409
    )
    assert client.get(P + "/admin/users?q=new%40", headers=admin).json()["items"] == [account]
    events = client.get(P + "/admin/events", headers=admin).json()["items"]
    assert events[0]["kind"] == "user_created"
    assert "password" not in str(events)
    assert client.get(P + "/auth/me", headers=forbidden).json()["role"] == "member"


def test_deactivation_and_role_change_revoke_tokens_and_devices(client, admin, database):
    login = client.post(
        P + "/auth/login", json={"email": "other@example.test", "password": "test-password-123"}
    ).json()
    other = {"Authorization": "Bearer " + login["access_token"]}
    account = client.get(P + "/auth/me", headers=other).json()
    device = client.post(
        P + "/devices/enroll",
        headers=other,
        json={"name": "My instrument", "points": ["TP1"], "calibration_id": "cal-01", "simulated": True},
    )
    assert device.status_code == 201
    response = client.patch(
        P + "/admin/users/" + account["id"], headers=admin, json={"role": "admin", "active": False}
    )
    assert response.status_code == 200
    with database() as db:
        assert db.get(Device, device.json()["device_id"]).token_digest != digest(
            device.json()["device_token"]
        )
    assert client.get(P + "/sessions", headers=other).status_code == 401
    assert client.post(P + "/auth/refresh", json={"refresh_token": login["refresh_token"]}).status_code == 401
    assert (
        client.post(
            P + "/auth/login", json={"email": "other@example.test", "password": "test-password-123"}
        ).status_code
        == 401
    )
    assert (
        client.patch(
            P + "/admin/users/" + account["id"], headers=admin, json={"role": "admin", "active": True}
        ).status_code
        == 200
    )
    again = client.post(
        P + "/auth/login", json={"email": "other@example.test", "password": "test-password-123"}
    ).json()
    assert again["user"]["role"] == "admin"
    assert (
        client.patch(
            P + "/admin/users/" + account["id"], headers=admin, json={"role": "member", "active": True}
        ).status_code
        == 200
    )
    assert (
        client.get(
            P + "/admin/users", headers={"Authorization": "Bearer " + again["access_token"]}
        ).status_code
        == 401
    )


def test_admin_cannot_lock_themselves_out(client, admin):
    me = client.get(P + "/auth/me", headers=admin).json()
    for payload in [{"role": "member", "active": True}, {"role": "admin", "active": False}]:
        response = client.patch(P + "/admin/users/" + me["id"], headers=admin, json=payload)
        assert response.status_code == 409 and response.json()["code"] == "self_admin_change"


def test_reset_is_single_use_hashed_and_revokes_all_sessions(client, database, headers, mailbox):
    login = client.post(
        P + "/auth/login", json={"email": "owner@example.test", "password": "test-password-123"}
    ).json()
    token = request_token(client, mailbox)
    with database() as db:
        stored = db.get(Token, digest(token))
        assert stored.kind == "password_reset" and stored.expires > time.time()
        assert not db.get(Token, token)
    body = {"token": token, "password": "my-new-password-123"}
    assert client.post(P + "/auth/reset-password", json=body).status_code == 204
    assert client.post(P + "/auth/reset-password", json=body).status_code == 400
    assert client.get(P + "/sessions", headers=headers).status_code == 401
    assert client.post(P + "/auth/refresh", json={"refresh_token": login["refresh_token"]}).status_code == 401
    assert (
        client.post(
            P + "/auth/login", json={"email": "owner@example.test", "password": "test-password-123"}
        ).status_code
        == 401
    )
    assert (
        client.post(
            P + "/auth/login", json={"email": "owner@example.test", "password": body["password"]}
        ).status_code
        == 200
    )
    with database() as db:
        assert not list(db.scalars(select(Token).where(Token.kind == "password_reset")))
        assert "token" not in str([e.data for e in db.scalars(select(AccountEvent))])


def test_expired_wrong_kind_disabled_and_superseded_links(client, database, headers, mailbox):
    first = request_token(client, mailbox, language="es")
    second = request_token(client, mailbox)

    def reset(token):
        return client.post(
            P + "/auth/reset-password", json={"token": token, "password": "my-new-password-123"}
        )

    assert reset(first).status_code == 400
    assert reset(headers["Authorization"].split()[1]).status_code == 400
    with database() as db:
        db.get(Token, digest(second)).expires = time.time() - 1
        db.commit()
    assert reset(second).status_code == 400
    third = request_token(client, mailbox)
    with database() as db:
        db.scalar(select(User).where(User.email == "owner@example.test")).active = 0
        db.commit()
    assert reset(third).status_code == 400


def test_recovery_generic_response_and_durable_limits(client, database, mailbox):
    expected = client.post(P + "/auth/forgot-password", json={"email": "missing@example.test"})
    assert expected.status_code == 202 and not mailbox.exists()
    for _ in range(5):
        response = client.post(P + "/auth/forgot-password", json={"email": "owner@example.test"})
        assert response.json() == expected.json() and response.status_code == expected.status_code
    assert len(list(mailbox.glob("*.eml"))) == 3
    with database() as db:
        from app.db import RecoveryLimit

        assert max(r.attempts for r in db.scalars(select(RecoveryLimit))) == 6


def test_development_mail_delivery_is_disabled_in_production(client, mailbox, monkeypatch):
    monkeypatch.setattr(settings(), "app_env", "production")
    assert client.post(P + "/auth/forgot-password", json={"email": "owner@example.test"}).status_code == 202
    assert not mailbox.exists()


def test_smtp_uses_tls_and_delivery_failure_does_not_disclose_account(client, monkeypatch, caplog):
    from app import accounts

    operations = []

    class SMTP:
        def __init__(self, host, port, **kwargs):
            operations.append((host, port, kwargs["timeout"]))

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def starttls(self, context):
            operations.append("tls")

        def login(self, username, password):
            operations.append("login")

        def send_message(self, message):
            operations.append(message.get_content())
            raise OSError("secret-address-and-link-must-not-be-logged")

    monkeypatch.setattr(accounts.smtplib, "SMTP", SMTP)
    for key, value in {
        "recovery_delivery": "smtp",
        "smtp_host": "mail.example.test",
        "smtp_from": "lab@example.test",
        "smtp_username": "service",
        "smtp_password": "secret",
    }.items():
        monkeypatch.setattr(settings(), key, value)
    response = client.post(
        P + "/auth/forgot-password", json={"email": "owner@example.test"}, headers={"Accept-Language": "en"}
    )
    assert response.status_code == 202 and response.json() == {"status": "accepted"}
    assert operations[0] == ("mail.example.test", 587, 10)
    assert operations[1:3] == ["tls", "login"]
    assert "?lang=en#/reset-password?token=" in operations[-1]
    assert "OSError" in caplog.text and "secret-address" not in caplog.text
