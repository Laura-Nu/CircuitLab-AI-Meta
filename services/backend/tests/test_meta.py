import json
import httpx
import pytest
from app import inference, meta
from app.config import settings
from app.schemas import DiagnosisOutput
from app.worker import validate_plan


def test_meta_uses_validated_tool_output_and_keeps_provider_audit(monkeypatch):
    monkeypatch.setattr(settings(), "ai_mode", "meta")
    monkeypatch.setattr(settings(), "meta_api_key", "test-private-key")
    monkeypatch.setattr(settings(), "meta_reasoning_model", "account-enabled-model")
    output = {
        "observations": ["Esquema confirmado"],
        "hypotheses": [
            {"cause": "Supply disconnected", "status": "proposed", "evidence_ids": [], "explanation": "Supply may be missing"},
            {"cause": "Output shorted", "status": "proposed", "evidence_ids": [], "explanation": "Output may be shorted"},
        ],
        "test_predictions": [
            {"hypothesis_index": 0, "expected_outcome": {"en": "Supply will be low", "es": "La alimentación será baja"}},
            {"hypothesis_index": 1, "expected_outcome": {"en": "Supply will be normal", "es": "La alimentación será normal"}},
        ],
        "action": "read_voltage",
        "point_id": "TP1",
        "instruction": "Medir TP1 respecto a GND",
        "rationale": "La lectura distingue alimentación de una salida incorrecta",
    }
    translated = {
        "observations": output["observations"],
        "causes": [h["cause"] for h in output["hypotheses"]],
        "explanations": [h["explanation"] for h in output["hypotheses"]],
        "instruction": output["instruction"],
        "rationale": output["rationale"],
    }
    output["translations"] = {"en": translated, "es": translated}

    def post(url, **kwargs):
        assert url.endswith("/chat/completions")
        assert kwargs["json"]["tool_choice"] == "auto"
        assert kwargs["json"]["model"] == "account-enabled-model"
        if kwargs["json"]["tools"][0]["function"]["name"] == "get_recorded_observations":
            return httpx.Response(200, request=httpx.Request("POST", url), json={
                "choices": [{"message": {"tool_calls": [{"id": "read-1", "type": "function",
                    "function": {"name": "get_recorded_observations", "arguments": "{}"}}]}}],
            })
        messages = kwargs["json"]["messages"]
        assert messages[-1]["role"] == "tool" and messages[-1]["tool_call_id"] == "read-1"
        observations = json.loads(messages[-1]["content"])
        assert observations["specification"]["points"][0]["id"] == "TP1"
        assert observations["reasoning_constraints"]["nominal_values_are_not_measurements"]
        assert observations["measurements"] == []
        return httpx.Response(
            200,
            request=httpx.Request("POST", url),
            json={
                "choices": [
                    {
                        "message": {
                            "tool_calls": [
                                {
                                    "id": "call-1",
                                    "type": "function",
                                    "function": {"name": "submit_diagnosis", "arguments": json.dumps(output)},
                                }
                            ]
                        }
                    }
                ],
                "usage": {"total_tokens": 123},
            },
        )

    monkeypatch.setattr(inference.httpx, "post", post)
    context = {"evidence": [], "measurements": [], "specification": {"points": [{"id": "TP1"}]}}
    result, audit = meta.analyze(context)
    validate_plan(result, context)
    assert result.point_id == "TP1" and audit["usage"]["total_tokens"] == 123
    assert "test-private-key" not in str(audit)


def test_provider_cannot_invent_references_or_points():
    output = DiagnosisOutput(
        observations=[],
        hypotheses=[],
        action="read_voltage",
        point_id="TP9",
        instruction="Medir el punto",
        rationale="Contrastar causas",
    )
    context = {"evidence": [], "measurements": [], "specification": {"points": [{"id": "TP1"}]}}
    with pytest.raises(ValueError):
        validate_plan(output, context)
    output.action = "propose_intervention"
    with pytest.raises(ValueError):
        validate_plan(output, context)
