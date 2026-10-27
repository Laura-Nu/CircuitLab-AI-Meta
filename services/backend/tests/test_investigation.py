import copy
import json
import time

import httpx
import pytest
from sqlalchemy import select

from app import inference, meta, stories, worker
from app.config import Settings, settings
from app.db import Job, ModelRun, Session, Storyboard


def test_baseten_profile_has_bounded_images_and_preserves_real_provider_receipts(monkeypatch):
    config = settings()
    monkeypatch.setattr(config, "ai_mode", "meta")
    monkeypatch.setattr(config, "meta_provider", "baseten")
    monkeypatch.setattr(config, "meta_api_key", "private-baseten-key")
    monkeypatch.setattr(config, "meta_reasoning_model", "meta-models/muse-spark-open-1026")
    output = {"observations": [], "hypotheses": [], "action": "inconclusive",
              "instruction": "Need more information", "rationale": "No defensible conclusion"}
    text = {"observations": [], "causes": [], "explanations": [],
            "instruction": output["instruction"], "rationale": output["rationale"]}
    output["translations"] = {"en": text, "es": text}
    calls = []

    def post(url, **kwargs):
        calls.append(kwargs)
        assert url == inference.BASETEN_URL + "/chat/completions"
        assert "response_format" not in kwargs["json"]
        if kwargs["json"]["tools"][0]["function"]["name"] == "get_recorded_observations":
            return httpx.Response(200, request=httpx.Request("POST", url), json={
                "choices": [{"message": {"tool_calls": [{"id": "read-1", "type": "function",
                    "function": {"name": "get_recorded_observations", "arguments": "{}"}}]}}],
            })
        return httpx.Response(200, request=httpx.Request("POST", url), headers={"x-request-id": "receipt-123"},
                              json={"id": "response-123", "model": "meta-models/muse-spark-open-1026",
                                    "choices": [{"message": {"tool_calls": [{"function": {
                                        "name": "submit_diagnosis", "arguments": json.dumps(output),
                                    }}]}}], "usage": {"total_tokens": 120}})

    monkeypatch.setattr(inference.httpx, "post", post)
    _, audit = meta.analyze({"evidence": []})
    assert audit["provider"] == "baseten" and audit["request_id"] == "receipt-123"
    assert audit["response_model"] == config.meta_reasoning_model
    assert audit["open_weight_candidate"] and not audit["weights_independently_verified"]
    assert len(audit["request_sha256"]) == 64 and "private-baseten-key" not in json.dumps(audit)
    with pytest.raises(ValueError, match="image limit"):
        meta.analyze({"evidence": [{}] * 9})
    assert len(calls) == 2 and calls[0]["timeout"] == config.meta_timeout_seconds


@pytest.mark.parametrize("endpoint", ["http://remote.test/v1", "https://key:secret@host.test/v1",
                                      "https://host.test/v1?key=secret", "https://host.test/v1#secret"])
def test_custom_endpoint_rejects_unsafe_configuration(endpoint):
    config = Settings(_env_file=None, meta_provider="self_hosted", meta_api_base_url=endpoint,
                      meta_api_key="private-key", meta_reasoning_model="muse-glimmer")
    with pytest.raises(ValueError):
        inference.profile(config)


def test_provider_timeout_must_fit_lease_and_story_simulation_is_not_production():
    with pytest.raises(ValueError):
        Settings(_env_file=None, meta_timeout_seconds=90, worker_lease_seconds=100)
    with pytest.raises(ValueError):
        Settings(_env_file=None, app_env="production", storyboard_mode="simulation")


def test_a_real_session_cannot_silently_use_simulation(monkeypatch):
    monkeypatch.setattr(settings(), "ai_mode", "simulation")
    with pytest.raises(RuntimeError, match="session inference mode"):
        meta.analyze({"diagnosis_mode": "meta"})


def test_media_body_budget_is_checked_before_the_paid_request(monkeypatch):
    monkeypatch.setattr(inference, "BASETEN_MAX_BODY_BYTES", 100)
    with pytest.raises(ValueError, match="body limit"):
        inference.invoke(provider="baseten", base=inference.BASETEN_URL, key="secret", model="muse-spark-open",
                         messages=[{"role": "user", "content": "x" * 100}], tool="test", schema={},
                         max_tokens=10, timeout=60)


def finish_simulation(client, headers, configured):
    sid = configured["id"]
    assert client.post(f"/api/v1/sessions/{sid}/analysis", headers=headers).status_code == 202
    worker.process(*worker.claim())
    assert client.post(f"/api/v1/sessions/{sid}/measurements", headers=headers, json={
        "client_id": "story-initial-reading", "point_id": "TP1", "value": .04,
        "unit": "V", "conditions_confirmed": True, "measured_at": time.time(),
    }).status_code == 201
    worker.process(*worker.claim())
    assert client.post(f"/api/v1/sessions/{sid}/interventions", headers=headers, json={
        "description": "Synthetic demonstration intervention", "confirmed": True,
    }).status_code == 201
    assert client.post(f"/api/v1/sessions/{sid}/measurements", headers=headers, json={
        "client_id": "story-final-reading", "point_id": "TP1", "value": 2.5,
        "unit": "V", "conditions_confirmed": True, "measured_at": time.time(),
    }).status_code == 201
    assert client.post(f"/api/v1/sessions/{sid}/functional-check", headers=headers, json={
        "client_id": "story-synthetic-functional", "passed": True,
        "observations": "Synthetic observation for a unit-test story", "performed_at": time.time(), "confirmed": True,
    }).status_code == 201
    assert client.post(f"/api/v1/sessions/{sid}/verification", headers=headers).status_code == 202
    worker.process(*worker.claim())
    return sid


def test_story_is_durable_bilingual_idempotent_and_never_changes_diagnosis(
    client, headers, configured, database, monkeypatch,
):
    monkeypatch.setattr(settings(), "storyboard_mode", "simulation")
    sid = finish_simulation(client, headers, configured)
    before = client.get(f"/api/v1/sessions/{sid}", headers=headers).json()
    request = client.post(f"/api/v1/sessions/{sid}/storyboards", headers=headers)
    assert request.status_code == 202, request.text
    row = request.json()
    duplicate = client.post(f"/api/v1/sessions/{sid}/storyboards", headers=headers).json()
    assert row["id"] == duplicate["id"] and row["status"] == "pending"
    worker.process(*worker.claim())
    after = client.get(f"/api/v1/sessions/{sid}", headers=headers).json()
    story = after["storyboards"][0]
    assert story["status"] == "completed" and not story["stale"]
    assert story["data"]["simulation"] and story["data"]["audit"]["provider"] == "simulation"
    assert story["data"]["diagnosis_mode"] == "simulation"
    assert story["data"]["frames"][0]["source_ids"] == ["specification"]
    assert all(set(f["headline"]) == {"en", "es"} for f in story["data"]["frames"])
    assert after["state"] == before["state"] and after["pending_test"] == before["pending_test"]
    assert after["analysis_steps"] == before["analysis_steps"]
    assert len(after["agent_trace"]) == 2
    assert not after["verifications"][0]["data"]["physical_verification"]
    assert client.post(f"/api/v1/sessions/{sid}/storyboards", headers=headers).json()["id"] == row["id"]
    assert worker.claim() is None
    with database() as db:
        assert len(list(db.scalars(select(Storyboard)))) == 1
        assert len(list(db.scalars(select(ModelRun)))) == 2


def test_story_access_readiness_and_configuration(client, headers, configured, monkeypatch):
    sid = configured["id"]
    route = f"/api/v1/sessions/{sid}/storyboards"
    assert client.post(route, headers=headers).status_code == 409
    sid = finish_simulation(client, headers, configured)
    route = f"/api/v1/sessions/{sid}/storyboards"
    assert client.post(route, headers=headers).status_code == 503
    monkeypatch.setattr(settings(), "storyboard_mode", "simulation")
    other = client.post("/api/v1/auth/login", json={"email": "other@example.test", "password": "test-password-123"}).json()
    other_headers = {"Authorization": "Bearer " + other["access_token"]}
    assert client.post(route, headers=other_headers).status_code == 403
    code = client.post(f"/api/v1/sessions/{sid}/pairing", headers=headers).json()["code"]
    assert client.post("/api/v1/pairing/redeem", headers=other_headers, json={"code": code}).status_code == 200
    assert client.post(route, headers=other_headers).status_code == 403
    assert client.get(f"/api/v1/sessions/{sid}", headers=other_headers).status_code == 200


def test_story_failure_needs_explicit_retry_and_is_fenced(client, headers, configured, monkeypatch, database):
    monkeypatch.setattr(settings(), "storyboard_mode", "simulation")
    sid = finish_simulation(client, headers, configured)
    route = f"/api/v1/sessions/{sid}/storyboards"
    row = client.post(route, headers=headers).json()
    original = stories.generate

    def failed(_):
        raise RuntimeError("private-provider-error-body")

    monkeypatch.setattr(stories, "generate", failed)
    worker.process(*worker.claim())
    current = client.get(f"/api/v1/sessions/{sid}", headers=headers).json()
    assert current["storyboards"][0]["status"] == "failed"
    assert "private-provider-error-body" not in json.dumps(current)
    assert worker.claim() is None and current["state"] == "resolved"
    assert client.post(route, headers=headers).json()["id"] == row["id"]
    job_id, old_token = worker.claim()

    def lose_lease(snapshot):
        result = original(snapshot)
        with database() as db:
            job = db.get(Job, job_id)
            job.lease_token = "replacement-token"
            db.commit()
        return result

    monkeypatch.setattr(stories, "generate", lose_lease)
    worker.process(job_id, old_token)
    with database() as db:
        assert db.get(Storyboard, row["id"]).data is None


def test_wonder_story_rejects_invented_sources_and_keeps_receipt(client, headers, configured, monkeypatch, database):
    sid = finish_simulation(client, headers, configured)
    with database() as db:
        snapshot = stories.source_snapshot(db, db.get(Session, sid))
    monkeypatch.setattr(settings(), "storyboard_mode", "simulation")
    preview = stories.generate(snapshot)
    output = {"title": preview["title"], "frames": preview["frames"]}
    monkeypatch.setattr(settings(), "storyboard_mode", "meta")
    from pydantic import SecretStr
    monkeypatch.setattr(settings(), "storyboard_api_key", SecretStr("wonder-private-key"))

    def post(url, **kwargs):
        assert url == inference.META_URL + "/chat/completions"
        assert kwargs["json"]["model"] == "muse-wonder-1.0"
        assert "tool_choice" in kwargs["json"]
        return httpx.Response(200, request=httpx.Request("POST", url), json={
            "model": "muse-wonder-1.0", "id": "wonder-response", "choices": [{"message": {
                "tool_calls": [{"function": {"name": "submit_circuit_story", "arguments": json.dumps(output)}}],
            }}],
        })

    monkeypatch.setattr(inference.httpx, "post", post)
    result = stories.generate(snapshot)
    assert result["audit"]["response_id"] == "wonder-response" and not result["simulation"]
    assert "wonder-private-key" not in json.dumps(result)
    output["frames"] = copy.deepcopy(output["frames"])
    output["frames"][0]["source_ids"] = ["invented-source"]
    with pytest.raises(ValueError, match="missing"):
        stories.generate(snapshot)
