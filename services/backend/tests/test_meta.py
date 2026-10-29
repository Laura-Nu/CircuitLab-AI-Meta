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
        tool_result = next(m for m in messages if m["role"] == "tool")
        assert tool_result["tool_call_id"] == "read-1"
        observations = json.loads(tool_result["content"])
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

@pytest.mark.parametrize("encoding", ["native", "json", "double_json", "escaped_json"])
def test_live_container_encodings_preserve_values_and_reference_checks(encoding):
    predictions = [
        {"hypothesis_index": 0, "expected_outcome": {"en": "Input low", "es": "Entrada baja"}},
        {"hypothesis_index": 1, "expected_outcome": {"en": "Input normal", "es": "Entrada normal"}},
    ]
    translated = {
        "observations": [], "causes": ["Supply missing", "Output short"],
        "explanations": ["Check supply", "Check output"],
        "instruction": "Read the authorized input", "rationale": "Distinguish the causes",
    }
    output = {
        "observations": [],
        "hypotheses": [
            {"cause": "Supply missing", "status": "proposed", "evidence_ids": [], "explanation": "Check supply"},
            {"cause": "Output short", "status": "proposed", "evidence_ids": [], "explanation": "Check output"},
        ],
        "action": "read_voltage", "point_id": "TP9",
        "instruction": translated["instruction"], "rationale": translated["rationale"],
        "test_predictions": predictions, "translations": {"en": translated, "es": translated},
    }
    if encoding != "native":
        for field in ("test_predictions", "translations"):
            encoded = json.dumps(output[field])
            if encoding == "double_json":
                encoded = json.dumps(encoded)
            elif encoding == "escaped_json":
                encoded = json.dumps(encoded)[1:-1]
            output[field] = encoded
    result, decoded = meta.parse_diagnosis(json.dumps(output))
    assert [p.model_dump() for p in result.test_predictions] == predictions
    assert result.translations.en.instruction == translated["instruction"]
    assert set(decoded) == (set() if encoding == "native" else {"test_predictions", "translations"})
    # Correcting wire encoding never authorizes a point the circuit did not define.
    with pytest.raises(ValueError):
        validate_plan(result, {"evidence": [], "measurements": [], "specification": {"points": [{"id": "TP1"}]}})


@pytest.mark.parametrize("bad_value", [
    "not JSON", '[{"hypothesis_index": 0',
    '{"hypothesis_index": 0}', '[{"hypothesis_index": 99, "expected_outcome": {"en": "Low", "es": "Baja"}}]',
])
def test_container_decoding_never_fills_missing_or_invalid_diagnosis_fields(bad_value):
    output = {
        "observations": [], "hypotheses": [], "action": "read_voltage", "point_id": "TP1",
        "instruction": "Read the input", "rationale": "Distinguish causes", "test_predictions": bad_value,
    }
    with pytest.raises(ValueError):
        meta.parse_diagnosis(json.dumps(output))


def test_truncated_provider_json_is_rejected():
    with pytest.raises(ValueError):
        meta.parse_diagnosis('{"action": "read_voltage", "translations":')

def test_shared_prediction_text_does_not_trigger_a_paid_retry_but_competing_causes_remain_required():
    from app.schemas import HypothesisOutput, TestPrediction, BilingualText
    result = DiagnosisOutput(
        observations=[], hypotheses=[
            HypothesisOutput(cause="Supply low", status="proposed", evidence_ids=[], explanation="Input unknown"),
            HypothesisOutput(cause="Ratio wrong", status="proposed", evidence_ids=[], explanation="Ratio unknown"),
        ],
        action="read_voltage", point_id="TP1", instruction="Read input relative to common GND",
        rationale="The same observation can leave several explanations compatible.",
        test_predictions=[
            TestPrediction(hypothesis_index=i, expected_outcome=BilingualText(
                en="Normal input contradicts low supply; low input leaves ratio untested.",
                es="Entrada normal contradice alimentación baja; entrada baja no comprueba relación.",
            )) for i in (0, 1)
        ],
    )
    assert meta.validate_predictions(result) == ["en", "es"]
    result.test_predictions = result.test_predictions[:1]
    with pytest.raises(ValueError):
        meta.validate_predictions(result)
