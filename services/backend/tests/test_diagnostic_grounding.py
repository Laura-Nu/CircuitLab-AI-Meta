"""Regression contracts and analytical examples, not live-model or physical proof."""
import pytest
from pydantic import ValidationError
from app import meta
from app.schemas import DiagnosisOutput
from app.worker import validate_plan


def output(**changes):
    return DiagnosisOutput(
        observations=[], hypotheses=[], instruction="Request more evidence",
        rationale="The available evidence does not identify a unique cause",
        **{"action": "inconclusive", **changes},
    )


def test_divider_reference_contains_two_distinct_circuits_with_the_same_output():
    context = {"family": "voltage_divider", "measurements": []}
    guidance = meta.reasoning_constraints(context)
    examples = guidance["unloaded_divider"]["illustrative_counterexamples_not_measurements"]
    first, second = examples
    assert first["input_v"] != second["input_v"]
    assert first["bottom_ohm"] != second["bottom_ohm"]
    for example in examples:
        assert example["output_v"] == pytest.approx(
            example["input_v"] * example["bottom_ohm"] /
            (example["top_ohm"] + example["bottom_ohm"])
        )
    assert first["output_v"] == pytest.approx(second["output_v"])
    assert context["measurements"] == []
    assert "measurement_id" not in str(guidance)
    assert "unloaded_divider" not in meta.reasoning_constraints({"family": "led_resistor"})


@pytest.mark.parametrize("point", [None, "", "null", " NULL ", "None", "undefined", "n/a"])
def test_absent_model_point_is_normalized_without_inventing_a_point(point):
    result = output(point_id=point)
    assert result.point_id is None
    validate_plan(result, {"evidence": [], "measurements": [],
                           "specification": {"points": [{"id": "TP1"}]}})


@pytest.mark.parametrize("point", ["GND", "TP0", "TP100", "unknown", 123])
def test_invalid_model_points_are_rejected(point):
    with pytest.raises(ValidationError):
        output(point_id=point)


@pytest.mark.parametrize("action", ["read_voltage", "request_manual_measurement"])
def test_measurement_requires_a_real_authorized_point(action):
    result = output(action=action, point_id="null")
    with pytest.raises(ValueError, match="punto autorizado"):
        validate_plan(result, {"evidence": [], "measurements": [],
                               "specification": {"points": [{"id": "TP1"}]}})


def test_connection_confirmation_cannot_name_an_unauthorized_point():
    with pytest.raises(ValueError, match="fuera del esquema"):
        validate_plan(output(action="request_connection_confirmation", point_id="TP9"),
                      {"evidence": [], "measurements": [],
                       "specification": {"points": [{"id": "TP1"}]}})


def test_public_compatibility_metadata_does_not_echo_environment_values(client, monkeypatch):
    monkeypatch.setenv("CIRCUITLAB_BUILD_REVISION", "private-not-a-git-revision")
    health = client.get("/api/v1/health/live").json()
    assert health["api_contract_version"] == "2"
    assert {"functional_checks", "role_aware_reports"}.issubset(health["capabilities"])
    assert health["build_revision"] == "unknown"
    assert "private-not-a-git-revision" not in str(health)
    monkeypatch.setenv("CIRCUITLAB_BUILD_REVISION", "a" * 40)
    assert client.get("/api/v1/health/live").json()["build_revision"] == "a" * 40
