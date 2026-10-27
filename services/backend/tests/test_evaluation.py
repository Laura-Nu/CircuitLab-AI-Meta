import copy
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from experiments.contracts import Label, ObservationSet, Plan, PublicCase, Step  # noqa: E402
from experiments.generate_synthetic import generate  # noqa: E402
from experiments.runner import MetaProvider, SimulationProvider, load_cases, public_input, run, run_trial  # noqa: E402
from experiments.scoring import score, score_files  # noqa: E402
from scripts.evaluate import render_markdown, summarize  # noqa: E402


@pytest.fixture
def dataset(tmp_path):
    data, output = tmp_path / "data", tmp_path / "run"
    generate(data)
    run(
        data / "cases.jsonl",
        data / "observations.private.json",
        ROOT / "experiments/plan.v1.json",
        output,
        SimulationProvider(),
    )
    rows = score_files(
        output / "trials.jsonl",
        data / "cases.jsonl",
        data / "labels.private.json",
        output / "manifest.json",
        output / "scored.jsonl",
    )
    return data, output, rows


def test_all_four_methods_are_balanced_and_no_replay_is_a_physical_repair(dataset):
    data, output, rows = dataset
    assert len(rows) == 144
    assert all(r["status"] == "completed" for r in rows)
    assert not any(r["repair_verified"] or r["recorded_physical_repair_verified"] for r in rows)
    assert any(r["verification_checks_passed"] for r in rows)
    summary = summarize(rows)
    assert not summary["research_evidence"]
    assert len(summary["methods"]) == 4
    for method, values in summary["methods"].items():
        assert values["n_cases"] == values["n_mounts"] == 18
        assert values["n_runs"] == 36 and values["errors"] == 0
        assert values["physical_verified_repair_rate"] is None and values["estimated_usd"] is None
    assert summary["methods"]["initial_only"]["mean_tests"] == 0
    assert summary["methods"]["fixed_tests"]["mean_tests"] == 3
    assert "Simulación" in render_markdown(summary, "es")
    assert "Simulation" in render_markdown(summary, "en")


def test_labels_and_unrequested_measurements_never_enter_initial_model_context(dataset):
    data, output, _ = dataset
    cases = {c.case_id: c for c in load_cases(data / "cases.jsonl")}
    for line in (output / "trials.jsonl").read_text(encoding="utf-8").splitlines():
        row = json.loads(line)
        for entry in row["trace"]:
            if "input" not in entry:
                continue
            initial = entry["input"]["initial"]
            assert initial == public_input(cases[row["case_id"]])
            assert not {
                "case_id",
                "mount_id",
                "readings",
                "kind",
                "accepted_diagnoses",
                "post_readings",
            }.intersection(initial)
            if row["method"] == "initial_only":
                assert entry["input"]["measurements"] == [] and entry["input"]["answers"] == {}


def test_repeated_trials_do_not_increase_independent_mounts_or_narrow_interval(dataset):
    _, _, rows = dataset
    original = summarize(rows)
    duplicates = copy.deepcopy(rows)
    for row in duplicates:
        row["repetition"] += 2
        row["run_id"] += "-repeat"
    repeated = summarize(rows + duplicates)
    for method in original["methods"]:
        before, after = original["methods"][method], repeated["methods"][method]
        assert before["n_mounts"] == after["n_mounts"] == 18
        assert before["mount_bootstrap95"] == after["mount_bootstrap95"]


@pytest.mark.parametrize(
    "mutation", ["duplicate", "mixed", "string_bool", "missing_method", "nan", "physical_claim"]
)
def test_reports_reject_misleading_or_invalid_data(dataset, mutation):
    _, _, source = dataset
    rows = copy.deepcopy(source)
    if mutation == "duplicate":
        rows.append(rows[0])
    elif mutation == "mixed":
        rows[0]["provenance"] = "physical_replay"
    elif mutation == "string_bool":
        rows[0]["diagnosis_correct"] = "false"
    elif mutation == "missing_method":
        rows = [r for r in rows if r["method"] != "initial_only"]
    elif mutation == "nan":
        rows[0]["elapsed_seconds"] = float("nan")
    else:
        rows[0]["repair_verified"] = True
    with pytest.raises(ValueError):
        summarize(rows)


def test_split_separation_and_public_contract_reject_label_leakage(tmp_path):
    data = tmp_path / "data"
    generate(data)
    cases = load_cases(data / "cases.jsonl")
    leaked = cases[0].model_dump() | {"accepted_diagnoses": ["healthy"]}
    with pytest.raises(ValueError):
        PublicCase.model_validate(leaked)
    second = cases[1].model_dump() | {"mount_id": cases[0].mount_id, "split": "development"}
    target = tmp_path / "leaked.jsonl"
    target.write_text(json.dumps(cases[0].model_dump()) + "\n" + json.dumps(second), encoding="utf-8")
    with pytest.raises(ValueError, match="physical mount"):
        load_cases(target)


def test_scoring_requires_complete_trials_and_unchanged_cases(dataset):
    data, output, _ = dataset
    truncated = output / "incomplete.jsonl"
    truncated.write_text((output / "trials.jsonl").read_text().splitlines()[0] + "\n")
    with pytest.raises(ValueError, match="Incomplete"):
        score_files(
            truncated,
            data / "cases.jsonl",
            data / "labels.private.json",
            output / "manifest.json",
            output / "should-not-exist.jsonl",
        )
    with (data / "cases.jsonl").open("a") as stream:
        stream.write("\n")
    with pytest.raises(ValueError, match="changed"):
        score_files(
            output / "trials.jsonl",
            data / "cases.jsonl",
            data / "labels.private.json",
            output / "manifest.json",
            output / "should-not-exist.jsonl",
        )


@pytest.mark.parametrize(
    "bad_step",
    [
        Step(
            action="measure",
            target="TP99",
            hypotheses=["healthy", "signal_short_ground"],
            rationale="bad point",
        ),
        Step(
            action="measure",
            target="TP1",
            evidence_ids=["invented"],
            hypotheses=["healthy", "signal_short_ground"],
            rationale="bad reference",
        ),
    ],
)
def test_invalid_provider_output_is_a_recorded_failure_not_a_dropped_trial(dataset, bad_step):
    data, _, _ = dataset
    case = load_cases(data / "cases.jsonl")[0]
    oracle = ObservationSet.model_validate_json((data / "observations.private.json").read_text())
    plan = Plan.model_validate_json((ROOT / "experiments/plan.v1.json").read_text())
    provider = SimpleNamespace(name="meta", model="fake", call=lambda *args: (bad_step, {}))
    row = run_trial(case, oracle.cases[case.case_id], provider, plan, "structured", 1, [])
    assert row["status"] == "error" and row["model_calls"] == 1
    row.update(provenance="simulation", usage_complete=False)
    label = Label(kind="healthy", accepted_diagnoses=["healthy"])
    result = score(row, case, label, plan)
    assert result["diagnosis_correct"] is False
    if bad_step.evidence_ids:
        assert result["invented_references"] == 1 and result["false_claims"] == 1


def test_meta_adapter_keeps_model_budget_and_images_and_never_exports_key(monkeypatch):
    from app import inference

    recorded = {}

    def post(url, **kwargs):
        recorded.update(kwargs["json"])
        result = Step(action="abstain", rationale="Insufficient evidence")
        payload = {
            "choices": [
                {
                    "message": {
                        "tool_calls": [
                            {
                                "function": {
                                    "name": "submit_evaluation_step",
                                    "arguments": result.model_dump_json(),
                                }
                            }
                        ]
                    }
                }
            ],
            "usage": {"prompt_tokens": 120, "completion_tokens": 20},
        }
        import httpx
        return httpx.Response(200, request=httpx.Request("POST", url), json=payload)

    monkeypatch.setattr(inference.httpx, "post", post)
    provider = MetaProvider(
        SimpleNamespace(
            meta_provider="self_hosted",
            meta_api_key="secret-never-exported",
            meta_reasoning_model="enabled-model",
            meta_api_base_url="https://provider.test/v1",
        )
    )
    plan = Plan.model_validate_json((ROOT / "experiments/plan.v1.json").read_text())
    step, usage = provider.call({"initial": {}}, "free_questions", [], plan)
    assert recorded["model"] == "enabled-model" and recorded["max_tokens"] == plan.max_tokens_per_call
    assert "secret-never-exported" not in json.dumps(recorded)
    assert step.action == "abstain" and usage["prompt_tokens"] == 120


@pytest.mark.parametrize("problem", ["mixed_sources", "missing_point"])
def test_invalid_observation_sets_fail_before_running_a_method(dataset, problem):
    data, _, _ = dataset
    path = data / "observations.private.json"
    observations = json.loads(path.read_text())
    case = next(iter(observations["cases"].values()))
    if problem == "mixed_sources":
        case["readings"]["TP1"]["source"] = "instrumented"
    else:
        del case["readings"]["TP1"]
    path.write_text(json.dumps(observations))
    with pytest.raises(ValueError):
        run(
            data / "cases.jsonl",
            path,
            ROOT / "experiments/plan.v1.json",
            data / "invalid-run",
            SimulationProvider(),
        )
    assert not (data / "invalid-run").exists()
