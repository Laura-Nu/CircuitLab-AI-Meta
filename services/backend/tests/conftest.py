import os
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

os.environ["AI_MODE"] = "simulation"
from app.db import Base, User, get_db  # noqa: E402
from app.main import app  # noqa: E402
from app.security import hash_password  # noqa: E402


@pytest.fixture
def database(tmp_path, monkeypatch):
    from app import accounts, main, worker
    from app.config import settings

    database_url = os.environ.get("TEST_DATABASE_URL", "sqlite://")
    options = (
        {"connect_args": {"check_same_thread": False}, "poolclass": StaticPool}
        if database_url == "sqlite://"
        else {}
    )
    engine = create_engine(database_url, **options)
    Base.metadata.create_all(engine)
    factory = sessionmaker(engine, expire_on_commit=False)
    monkeypatch.setattr(worker, "SessionLocal", factory)
    monkeypatch.setattr(accounts, "SessionLocal", factory)
    monkeypatch.setattr(main, "SessionLocal", factory)
    monkeypatch.setattr(settings(), "storage_root", str(tmp_path))
    monkeypatch.setattr(settings(), "ai_mode", "simulation")

    def dependency():
        with factory() as db:
            yield db

    app.dependency_overrides[get_db] = dependency
    with factory() as db:
        for email in ["owner@example.test", "other@example.test"]:
            db.add(User(email=email, password=hash_password("test-password-123")))
        db.commit()
    yield factory
    app.dependency_overrides.clear()
    Base.metadata.drop_all(engine)
    engine.dispose()


@pytest.fixture
def client(database):
    with TestClient(app) as client:
        yield client


@pytest.fixture
def headers(client):
    response = client.post(
        "/api/v1/auth/login", json={"email": "owner@example.test", "password": "test-password-123"}
    )
    assert response.status_code == 200
    return {"Authorization": "Bearer " + response.json()["access_token"]}


@pytest.fixture
def session(client, headers):
    result = client.post(
        "/api/v1/sessions",
        headers=headers,
        json={
            "title": "Divisor de prueba",
            "family": "voltage_divider",
            "expected": "La salida debe ser estable a 2.5 V",
            "symptoms": "La salida fluctúa cerca de cero",
            "supply_v": 5,
        },
    )
    assert result.status_code == 201
    return result.json()


@pytest.fixture
def configured(client, headers, session):
    result = client.patch(
        f"/api/v1/sessions/{session['id']}/specification",
        headers=headers,
        json={
            "version": session["version"],
            "confirmed": True,
            "connections": ["R1:5V-TP1", "R2:TP1-GND"],
            "functional_description": "Alimentación estable a 5 V, salida dentro de rango",
            "points": [{"id": "TP1", "label": "Salida", "min_v": 2.4, "max_v": 2.6}],
        },
    )
    assert result.status_code == 200, result.text
    return result.json()
