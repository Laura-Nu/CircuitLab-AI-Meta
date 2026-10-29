"""Unit regressions only; these mocks never count as live-provider verification."""
import json

import httpx
import pytest
from pydantic import SecretStr

from app import inference
from app.config import Settings


def response(message, status=200):
    return httpx.Response(status, request=httpx.Request("POST", "https://api.meta.ai/v1/chat/completions"),
                          json={"choices": [{"message": message}]})


def agent(handler, sink):
    return inference.invoke_agent(
        provider="meta", base=inference.META_URL, key=SecretStr("private-provider-key"), model="enabled-model",
        messages=[{"role": "user", "content": "Read only the authorized investigation."}],
        read_tool=inference.function_tool("get_recorded_observations", {"type": "object"}),
        handler=handler, on_exchange=sink.append, tool="submit_diagnosis", schema={"type": "object"},
        max_tokens=1000, timeout=60,
    )


@pytest.mark.parametrize("name,arguments", [("run_shell", "{}"),
                                           ("get_recorded_observations", '{"session_id":"another-user"}')])
def test_unapproved_tools_and_cross_session_selectors_never_execute(monkeypatch, name, arguments):
    executed = []
    monkeypatch.setattr(inference.httpx, "post", lambda *a, **k: response({"tool_calls": [{
        "id": "call-1", "type": "function", "function": {"name": name, "arguments": arguments},
    }]}))
    with pytest.raises(ValueError):
        agent(lambda: executed.append(True), [])
    assert not executed


def test_failed_followup_preserves_receipts_and_execution_without_private_error_body(monkeypatch):
    calls, audits = [], []

    def post(url, **kwargs):
        calls.append(kwargs["json"])
        if len(calls) == 1:
            return response({"tool_calls": [{"id": "call-1", "type": "function", "function": {
                "name": "get_recorded_observations", "arguments": "{}",
            }}]})
        assert kwargs["headers"]["Authorization"] == "Bearer private-provider-key"
        assert kwargs["json"]["messages"][-1]["tool_call_id"] == "call-1"
        assert json.loads(kwargs["json"]["messages"][-1]["content"])["measurements"][0]["source"] == "simulated"
        return httpx.Response(429, request=httpx.Request("POST", url),
                              json={"error": "private-provider-key and confidential upstream body"})

    monkeypatch.setattr(inference.httpx, "post", post)
    with pytest.raises(inference.InferenceFailure) as error:
        agent(lambda: {"measurements": [{"value": .04, "source": "simulated"}]}, audits)
    assert [row["run_kind"] for row in audits] == ["provider_exchange", "tool_execution", "provider_exchange"]
    assert audits[-1]["http_status"] == 429
    assert "private-provider-key" not in str(error.value) + json.dumps(audits)
    assert "confidential upstream body" not in json.dumps(audits)


def test_model_credentials_are_redacted_in_settings_and_echoed_responses(monkeypatch):
    config = Settings(_env_file=None, meta_api_key="private-provider-key")
    assert "private-provider-key" not in repr(config)
    monkeypatch.setattr(inference.httpx, "post", lambda *a, **k: response({"content": "private-provider-key"}))
    message, audit = inference.exchange(
        provider="meta", base=inference.META_URL, key=config.meta_api_key, model="enabled-model",
        messages=[{"role": "user", "content": "test"}], tools=[], max_tokens=20, timeout=60,
    )
    assert "private-provider-key" not in json.dumps(message) + json.dumps(audit)

def test_discovery_avoids_resending_images_but_final_turn_returns_the_real_tool_result(monkeypatch):
    requests, audits = [], []
    def post(url, **kwargs):
        requests.append(kwargs["json"])
        if len(requests) == 1:
            assert "image_url" not in json.dumps(kwargs["json"]["messages"])
            assert kwargs["json"]["max_tokens"] <= 512
            return response({"tool_calls": [{"id": "read-1", "type": "function", "function": {
                "name": "get_recorded_observations", "arguments": "{}",
            }}]})
        assert "image_url" in json.dumps(kwargs["json"]["messages"])
        tool_result = next(m for m in kwargs["json"]["messages"] if m["role"] == "tool")
        assert tool_result["tool_call_id"] == "read-1" and json.loads(tool_result["content"]) == {"recorded": True}
        return response({"tool_calls": [{"id": "submit-1", "type": "function", "function": {
            "name": "submit_diagnosis", "arguments": "{}",
        }}]})
    monkeypatch.setattr(inference.httpx, "post", post)
    result, audit = inference.invoke_agent(
        provider="meta", base=inference.META_URL, key=SecretStr("private-provider-key"), model="enabled-model",
        messages=[{"role": "system", "content": "Diagnose only recorded evidence"},
                  {"role": "user", "content": [{"type": "image_url", "image_url": {"url": "data:image/png;base64,fixture"}}]}],
        discovery_messages=[{"role": "user", "content": "Read observations first"}],
        read_tool=inference.function_tool("get_recorded_observations", {"type": "object"}),
        handler=lambda: {"recorded": True}, on_exchange=audits.append,
        tool="submit_diagnosis", schema={"type": "object"}, max_tokens=5000, timeout=60,
    )
    assert result == "{}" and audit["exchange_count"] == 2
    assert [a["input_image_count"] for a in audits if a["run_kind"] == "provider_exchange"] == [0, 1]
