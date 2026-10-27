"""Evaluator-only scoring. Never expose these labels to the diagnostic service."""

import argparse
import json
from pathlib import Path

from experiments.contracts import Label, Plan
from experiments.runner import file_hash, load_cases


def score(row, case, label, plan):
    decision = row.get("decision") or {}
    completed = row["status"] == "completed"
    abstained = completed and decision.get("action") == "abstain"
    needs_abstention = label.kind in {"ambiguous", "out_of_scope"}
    diagnosis = decision.get("diagnosis")
    correct = completed and (
        abstained
        if needs_abstention
        else decision.get("action") == "diagnose" and diagnosis in label.accepted_diagnoses
    )
    # Recorded post-intervention data are not a repair executed by a benchmark method.
    post = {r.point_id: r for r in sorted(label.post_readings, key=lambda r: r.measured_at)}
    checks_passed = bool(
        label.kind == "fault"
        and label.intervention_confirmed_at
        and label.intervention_for == diagnosis
        and correct
        and all(
            p.id in post
            and post[p.id].status == "ok"
            and post[p.id].measured_at > label.intervention_confirmed_at
            and p.min_v <= post[p.id].value <= p.max_v
            for p in case.points
        )
    )
    physical_record = checks_passed and all(r.source != "simulated" for r in label.post_readings)
    repair_claims, invented_references = 0, 0
    for entry in row.get("trace", []):
        if "output" not in entry:
            continue
        repair_claims += int(bool(entry["output"].get("claims_repair")))
        initial_ids = {e["id"] for e in entry["input"]["initial"]["evidence"]}
        measured_ids = {r["id"] for r in entry["input"]["measurements"]}
        invented_references += len(set(entry["output"]["evidence_ids"]) - initial_ids - measured_ids)
    unsupported_diagnosis = int(needs_abstention and decision.get("action") == "diagnose")
    false_claims = repair_claims + invented_references + unsupported_diagnosis
    input_rate, output_rate = plan.input_usd_per_million, plan.output_usd_per_million
    cost = None
    if row["usage_complete"] and input_rate is not None and output_rate is not None:
        cost = (
            row["usage"]["prompt_tokens"] * input_rate + row["usage"]["completion_tokens"] * output_rate
        ) / 1_000_000
    return {
        **{key: value for key, value in row.items() if key != "trace"},
        "case_kind": label.kind,
        "diagnosis_correct": bool(correct),
        "abstained": abstained,
        "appropriate_abstention": abstained and needs_abstention,
        "verification_checks_passed": checks_passed,
        "recorded_physical_repair_verified": bool(physical_record and row["provenance"] == "physical_replay"),
        "repair_verified": False,
        "repair_executed_by_method": False,
        "false_claims": false_claims,
        "unverified_repair_claims": repair_claims,
        "invented_references": invented_references,
        "unsupported_diagnosis_claims": unsupported_diagnosis,
        "estimated_usd": cost,
    }


def score_files(trials, cases_path, labels_path, manifest_path, output):
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if file_hash(cases_path) != manifest["cases_sha256"]:
        raise ValueError("Cases changed after prediction")
    plan = Plan.model_validate(manifest["plan"])
    rows = [json.loads(line) for line in trials.read_text(encoding="utf-8").splitlines() if line.strip()]
    cases = {c.case_id: c for c in load_cases(cases_path)}
    labels = {
        key: Label.model_validate(value)
        for key, value in json.loads(labels_path.read_text(encoding="utf-8")).items()
    }
    if set(labels) != set(cases):
        raise ValueError("Evaluator labels must match the public cases exactly")
    expected = {(c, m, r) for c in cases for m in plan.methods for r in range(1, plan.repetitions + 1)}
    actual = [(r["case_id"], r["method"], r["repetition"]) for r in rows]
    if set(actual) != expected or len(actual) != len(expected):
        raise ValueError("Incomplete or duplicate trials; failed trials remain in the denominator")
    scored = []
    for row in rows:
        if row["provider"] != manifest["provider"] or row["model"] != manifest["model"]:
            raise ValueError("Provider/model mismatch")
        if row["prompt_sha256"] != manifest["prompt_sha256"]:
            raise ValueError("Prompt mismatch")
        if row["provenance"] != manifest["provenance"] or row["plan_sha256"] != manifest["plan_sha256"]:
            raise ValueError("Provenance or plan mismatch")
        case = cases[row["case_id"]]
        if not set(labels[case.case_id].accepted_diagnoses).issubset(set(case.diagnosis_catalog)):
            raise ValueError("Evaluator diagnosis is outside the preregistered catalog")
        if row["split"] != case.split or row["mount_id"] != case.mount_id or row["family"] != case.family:
            raise ValueError("Case metadata mismatch")
        result = score(row, case, labels[case.case_id], plan)
        result["labels_sha256"] = file_hash(labels_path)
        scored.append(result)
    with output.open("x", encoding="utf-8") as stream:
        for row in scored:
            stream.write(json.dumps(row, ensure_ascii=False) + "\n")
    return scored


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trials", type=Path, required=True)
    parser.add_argument("--cases", type=Path, required=True)
    parser.add_argument("--labels", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    rows = score_files(args.trials, args.cases, args.labels, args.manifest, args.output)
    print(f"{len(rows)} scored trials / ejecuciones puntuadas: {args.output}")


if __name__ == "__main__":
    main()
