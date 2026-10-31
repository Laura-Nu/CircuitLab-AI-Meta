"""Response context regressions; these fixtures are not real-model accuracy measurements."""
import copy

import pytest

from app import meta
from app.quality_check import cases


def test_observations_are_sent_once_without_losing_a_reading_or_provenance():
    context = cases()[0][1]
    context["serial_captures"] = [{"id": "capture-1", "lines": ["value=0.455"]}]
    context["serial_provenance"] = [{"measurement_id": "output-low", "channel": "output"}]
    original = copy.deepcopy(context)
    brief, recorded = meta.response_context(context)
    for field in ("measurements", "specification", "connection_confirmations", "serial_captures", "serial_provenance"):
        assert field not in brief
        assert recorded[field] == context[field]
    assert recorded["physical_verification"] is False
    assert context == original


def test_latest_reading_is_selected_by_observation_time_not_upload_order():
    context = cases()[-1][1]
    context["measurements"].reverse()
    _, recorded = meta.response_context(context)
    checks = {r["point_id"]: r for r in recorded["criterion_review"]}
    assert checks["TP1"]["measurement_id"] == "new-output-ok"
    assert checks["TP1"]["matches_criterion"] is True
    assert len(recorded["measurements"]) == 3  # Old evidence remains available to explain changes.


def test_false_boolean_is_valid_and_missing_is_distinct_from_out_of_range():
    _, sensor, *_ = cases()[2]
    _, missing = meta.response_context(sensor)
    assert missing["criterion_review"][1]["measurement_id"] is None
    assert missing["criterion_review"][1]["matches_criterion"] is None
    _, false_ok, *_ = cases()[3]
    _, recorded = meta.response_context(false_ok)
    assert all(r["matches_criterion"] is True for r in recorded["criterion_review"])


def test_only_latest_hypotheses_are_reused_without_promoting_them_to_facts():
    context = cases()[0][1]
    context["previous_hypotheses"] = [
        {"cause": "Older proposal", "analysis_step": 1},
        {"cause": "Current proposal", "analysis_step": 2},
    ]
    context["evidence"] = [{"id": "photo-1", "key": "private-path", "sha256": "hash", "mime": "image/jpeg"}]
    brief, _ = meta.response_context(context)
    assert brief["previous_hypotheses"] == [context["previous_hypotheses"][1]]
    assert brief["evidence"] == [{"id": "photo-1", "mime": "image/jpeg"}]
    assert len(context["previous_hypotheses"]) == 2


def test_live_quality_check_cannot_pass_simulated_or_missing_provider_receipts(tmp_path, monkeypatch):
    from app import quality_check
    from app.config import settings
    monkeypatch.setattr(settings(), "ai_mode", "meta")
    monkeypatch.setattr(quality_check, "cases", lambda: [cases()[1]])
    result, _ = meta.demo_analysis(cases()[1][1])
    monkeypatch.setattr(meta, "analyze", lambda *a, **k: (result, {"provider": "simulation"}))
    assert quality_check.run(tmp_path / "result.json") is False


def test_live_quality_check_refuses_simulation_configuration(tmp_path, monkeypatch):
    from app.quality_check import run
    from app.config import settings
    monkeypatch.setattr(settings(), "ai_mode", "simulation")
    with pytest.raises(RuntimeError, match="never accepts simulation"):
        run(tmp_path / "result.json")

def test_compacted_request_preserves_image_and_returns_observations_to_the_model(monkeypatch):
    import json
    from app.config import settings
    monkeypatch.setattr(settings(), "ai_mode", "meta")
    monkeypatch.setattr(settings(), "meta_api_key", "unit-test-only-key")
    monkeypatch.setattr(settings(), "meta_reasoning_model", "unit-test-only-model")
    context = cases()[1][1]
    context["evidence"] = [{"id": "photo-1", "key": "private-storage-key", "mime": "image/png"}]
    monkeypatch.setattr(meta.LocalStorage, "get", lambda self, key: b"image-fixture-bytes")
    def invoke(**kwargs):
        content = kwargs["messages"][-1]["content"]
        brief = json.loads(content[0]["text"])
        assert "measurements" not in brief and "private-storage-key" not in str(brief)
        assert content[1]["type"] == "image_url"
        assert content[1]["image_url"]["url"] == "data:image/png;base64,aW1hZ2UtZml4dHVyZS1ieXRlcw=="
        assert kwargs["handler"]()["measurements"] == context["measurements"]
        text = {"observations": [], "causes": [], "explanations": [],
                "instruction": "Perform the functional check", "rationale": "All values are in range"}
        return json.dumps({
            "action": "inconclusive", "observations": [], "hypotheses": [],
            "instruction": text["instruction"], "rationale": text["rationale"],
            "translations": {"en": text, "es": text},
        }), {}
    monkeypatch.setattr(meta, "invoke_agent", invoke)
    result, audit = meta.analyze(context)
    assert result.action == "inconclusive"
    assert audit["context_measurement_count"] == 2 and audit["input_evidence_ids"] == ["photo-1"]
