"""Payload and authorization regressions; these fixtures are not live-model evidence."""
import json
from sqlalchemy import select
from app.db import Job, Member, Session, User

P = "/api/v1"


def test_workspace_batches_only_public_account_and_small_session_summaries(client, headers, configured, database):
    response = client.get(P + "/workspace", headers=headers)
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    data = response.json()
    assert data["account"]["role"] == "member"
    assert data["health"]["provider_configured"] is False
    row = next(s for s in data["sessions"] if s["id"] == configured["id"])
    assert {"id", "title", "state", "version", "family", "supply_v"}.issubset(row)
    assert not {"specification", "pending_test", "expected", "symptoms"}.intersection(row)
    assert "password" not in json.dumps(data) and "token_digest" not in json.dumps(data)
    assert client.get(P + "/workspace").status_code == 401


def test_progress_returns_a_snapshot_once_then_only_status_and_new_events(client, headers, configured, database):
    sid = configured["id"]
    first = client.get(f"{P}/sessions/{sid}/progress", headers=headers).json()
    assert first["snapshot"]["id"] == sid and first["events"]
    version = first["version"]
    after = first["events"][-1]["sequence"]
    unchanged = client.get(f"{P}/sessions/{sid}/progress?known_version={version}&after={after}", headers=headers).json()
    assert unchanged["snapshot"] is None and unchanged["events"] == []
    assert len(json.dumps(unchanged)) < len(json.dumps(first)) / 2
    # Claiming a job changes its status without changing the circuit's event version.
    with database() as db:
        db.add(Job(session_id=sid, kind="analysis", status="running", attempts=1))
        db.commit()
    status = client.get(f"{P}/sessions/{sid}/progress?known_version={version}&after={after}", headers=headers).json()
    assert status["snapshot"] is None
    assert status["jobs"][0]["status"] == "running"
    assert status["analysis_phase"] == "reviewing"


def test_progress_and_workspace_preserve_cross_account_authorization(client, headers, configured, database):
    sid = configured["id"]
    login = client.post(P + "/auth/login", json={"email": "other@example.test", "password": "test-password-123"}).json()
    other = {"Authorization": "Bearer " + login["access_token"]}
    assert client.get(f"{P}/sessions/{sid}/progress", headers=other).status_code == 403
    assert not client.get(P + "/workspace", headers=other).json()["sessions"]
    with database() as db:
        user = db.scalar(select(User).where(User.email == "other@example.test"))
        db.add(Member(session_id=sid, user_id=user.id, role="reader"))
        db.commit()
    shared = client.get(f"{P}/sessions/{sid}/progress", headers=other).json()
    assert shared["snapshot"]["can_edit"] is False


def test_incremental_progress_includes_new_event_after_the_recorded_sequence(client, headers, configured, database):
    from app.domain import record
    sid = configured["id"]
    first = client.get(f"{P}/sessions/{sid}/progress", headers=headers).json()
    with database() as db:
        record(db, db.get(Session, sid), "unit_progress_marker", {"fixture": True})
        db.commit()
    result = client.get(
        f"{P}/sessions/{sid}/progress?known_version={first['version']}&after={first['events'][-1]['sequence']}",
        headers=headers,
    ).json()
    assert result["snapshot"] is not None
    assert [e["kind"] for e in result["events"]] == ["unit_progress_marker"]
