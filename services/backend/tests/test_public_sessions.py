"""Public roles and real server-side inactivity, without waiting four hours."""
import time
import pytest
from sqlalchemy import select
from app.config import settings
from app.db import AccountEvent, AuthSession, Token, User
from app.security import COOKIE, digest

P = "/api/v1"
PASSWORD = "member-password-123"


def test_public_registration_is_member_only_and_audited(client, database):
    result = client.post(P + "/auth/register", json={"email": " Student@Example.test ", "password": PASSWORD})
    assert result.status_code == 201
    data = result.json()
    assert data["user"]["role"] == "member" and data["user"]["email"] == "student@example.test"
    assert data["idle_timeout_seconds"] == 14400
    headers = {"Authorization": "Bearer " + data["access_token"]}
    assert client.get(P + "/admin/metrics", headers=headers).status_code == 403
    assert client.get(P + "/sessions", headers=headers).json() == []
    with database() as db:
        user = db.scalar(select(User).where(User.email == "student@example.test"))
        assert db.scalar(select(AccountEvent).where(AccountEvent.user_id == user.id)).kind == "member_registered"
        assert db.scalar(select(AuthSession).where(AuthSession.user_id == user.id)).idle_expires > time.time()
    assert client.post(P + "/auth/register", json={"email": "student@example.test", "password": PASSWORD}).status_code == 409
    assert client.post(P + "/auth/register", json={"email": "admin-attempt@example.test", "password": PASSWORD, "role": "admin"}).status_code == 422


def test_browser_cookie_restores_without_exposing_refresh_or_extending_idle(client):
    origin = {"Origin": settings().app_origin}
    result = client.post(P + "/auth/login", headers=origin,
                         json={"email": "owner@example.test", "password": "test-password-123", "client": "web"})
    assert result.status_code == 200
    assert "refresh_token" not in result.json()
    cookie = result.headers["set-cookie"]
    assert "HttpOnly" in cookie and "SameSite=strict" in cookie and "Path=/api/v1/auth" in cookie
    assert result.headers["cache-control"] == "no-store"
    assert COOKIE in client.cookies
    for _ in range(2):
        restored = client.post(P + "/auth/refresh", headers=origin, json={})
        assert restored.status_code == 200
        assert "refresh_token" not in restored.json()
        assert restored.json()["idle_expires_at"] == pytest.approx(result.json()["idle_expires_at"], abs=0.000001, rel=0)
    headers = {"Authorization": "Bearer " + restored.json()["access_token"]}
    assert client.get(P + "/auth/me", headers=headers).status_code == 200
    assert client.post(P + "/auth/logout", headers=headers).status_code == 204
    assert COOKIE not in client.cookies
    assert client.post(P + "/auth/refresh", headers=origin, json={}).status_code == 401


def test_browser_origin_and_secure_cookie(client, monkeypatch):
    body = {"email": "owner@example.test", "password": "test-password-123", "client": "web"}
    assert client.post(P + "/auth/login", json=body, headers={"Origin": "https://untrusted.example"}).status_code == 403
    monkeypatch.setattr(settings(), "app_env", "production")
    response = client.post(P + "/auth/login", json=body, headers={"Origin": settings().app_origin})
    assert response.status_code == 200 and "; Secure" in response.headers["set-cookie"]


def test_polling_and_refresh_cannot_keep_an_idle_session_alive(client, monkeypatch):
    clock = [float(int(time.time()))]
    monkeypatch.setattr(time, "time", lambda: clock[0])
    tokens = client.post(P + "/auth/login", json={"email": "owner@example.test", "password": "test-password-123"}).json()
    deadline = tokens["idle_expires_at"]
    for hour in range(1, 4):
        clock[0] += 3600
        response = client.post(P + "/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
        assert response.status_code == 200
        tokens = response.json()
        assert tokens["idle_expires_at"] == deadline
        assert client.get(P + "/sessions", headers={"Authorization": "Bearer " + tokens["access_token"]}).status_code == 200
    clock[0] = deadline
    assert client.post(P + "/auth/refresh", json={"refresh_token": tokens["refresh_token"]}).status_code == 401
    assert client.get(P + "/auth/me", headers={"Authorization": "Bearer " + tokens["access_token"]}).status_code == 401


def test_human_activity_extends_only_the_current_session(client, database, monkeypatch):
    clock = [float(int(time.time()))]
    monkeypatch.setattr(time, "time", lambda: clock[0])
    first = client.post(P + "/auth/login", json={"email": "owner@example.test", "password": "test-password-123"}).json()
    other = client.post(P + "/auth/login", json={"email": "owner@example.test", "password": "test-password-123"}).json()
    clock[0] += 600
    headers = {"Authorization": "Bearer " + first["access_token"]}
    touched = client.post(P + "/auth/activity", headers=headers)
    assert touched.status_code == 200 and touched.json()["idle_expires_at"] == clock[0] + 14400
    with database() as db:
        token = db.get(Token, digest(other["refresh_token"]))
        assert db.get(AuthSession, token.auth_session_id).idle_expires == other["idle_expires_at"]
    clock[0] = first["idle_expires_at"] + 1
    renewed = client.post(P + "/auth/refresh", json={"refresh_token": first["refresh_token"]})
    assert renewed.status_code == 200
    assert client.post(P + "/auth/refresh", json={"refresh_token": other["refresh_token"]}).status_code == 401
    clock[0] = touched.json()["idle_expires_at"]
    assert client.post(P + "/auth/refresh", json={"refresh_token": renewed.json()["refresh_token"]}).status_code == 401
    assert client.post(P + "/auth/activity", headers=headers).status_code == 401


def test_registration_rate_limit(client):
    for number in range(10):
        assert client.post(P + "/auth/register", json={"email": f"member{number}@example.test", "password": PASSWORD}).status_code == 201
    response = client.post(P + "/auth/register", json={"email": "overflow@example.test", "password": PASSWORD}, headers={"Accept-Language": "en"})
    assert response.status_code == 429 and response.json()["code"] == "registration_rate_limited"
