"""Describe balanced runs. Bootstrap mounts, never repeated runs as independent cases."""

import argparse
import json
import math
import random
from collections import defaultdict
from pathlib import Path
from statistics import mean

METHODS = {"initial_only", "free_questions", "fixed_tests", "structured"}


def interval(clusters):
    if len(clusters) < 2:
        return None
    rng = random.Random(20261023)
    values = sorted(mean(rng.choices(clusters, k=len(clusters))) for _ in range(2000))
    return [values[49], values[1949]]


def summarize(rows):
    if not rows:
        raise ValueError("Empty evaluation")
    signatures = {
        (
            r["provenance"],
            r["provider"],
            r["model"],
            r["prompt_version"],
            r["plan_sha256"],
            r["labels_sha256"],
        )
        for r in rows
    }
    if len(signatures) != 1:
        raise ValueError("Do not mix provenance, providers, models, protocols or labels")
    groups, seen = defaultdict(list), set()
    for row in rows:
        if row["split"] != "evaluation":
            raise ValueError("Final reports accept evaluation split only")
        if row["method"] not in METHODS:
            raise ValueError("Unknown method")
        key = (row["case_id"], row["method"], row["repetition"])
        if key in seen:
            raise ValueError("Duplicate trial")
        seen.add(key)
        for field in [
            "diagnosis_correct",
            "abstained",
            "appropriate_abstention",
            "repair_verified",
        ]:
            if type(row[field]) is not bool:
                raise ValueError("Metrics must be booleans, not strings")
        for field in [
            "test_count",
            "query_count",
            "false_claims",
            "elapsed_seconds",
            "model_seconds",
        ]:
            value = row[field]
            if type(value) not in {int, float} or not math.isfinite(value) or value < 0:
                raise ValueError("Metrics must be finite and nonnegative")
        if row["repair_verified"] and (
            row["provenance"] != "physical_live" or not row["repair_executed_by_method"]
        ):
            raise ValueError("Replay and simulation cannot establish a repair executed by the method")
        groups[row["method"]].append(row)
    if set(groups) != METHODS:
        raise ValueError("Compare all four preregistered methods")
    pairs = [{(r["case_id"], r["repetition"]) for r in group} for group in groups.values()]
    if any(pair != pairs[0] for pair in pairs):
        raise ValueError("Methods must cover identical cases and repetitions")
    result = {
        "provenance": rows[0]["provenance"],
        "provider": rows[0]["provider"],
        "model": rows[0]["model"],
        "research_evidence": rows[0]["provider"] == "meta" and rows[0]["provenance"] != "simulation",
        "methods": {},
    }
    for method in sorted(groups):
        group = groups[method]
        mounts, families = defaultdict(list), defaultdict(list)
        for row in group:
            mounts[row["mount_id"]].append(row)
            families[row["family"]].append(row)
        fault_rows = [r for r in group if r["case_kind"] == "fault"]
        abstention_rows = [r for r in group if r["case_kind"] in {"ambiguous", "out_of_scope"}]
        accuracy = [mean(r["diagnosis_correct"] for r in cluster) for cluster in mounts.values()]
        result["methods"][method] = {
            "n_runs": len(group),
            "n_cases": len({r["case_id"] for r in group}),
            "n_mounts": len(mounts),
            "completed": sum(r["status"] == "completed" for r in group),
            "errors": sum(r["status"] != "completed" for r in group),
            "decision_accuracy": mean(accuracy),
            "mount_bootstrap95": interval(accuracy),
            "fault_diagnostic_accuracy": mean(r["diagnosis_correct"] for r in fault_rows)
            if fault_rows
            else None,
            "appropriate_abstention_rate": mean(r["appropriate_abstention"] for r in abstention_rows)
            if abstention_rows
            else None,
            "abstention_rate": mean(r["abstained"] for r in group),
            "physical_verified_repair_rate": None,
            "replayed_checks_passed": sum(r["verification_checks_passed"] for r in group),
            "false_claims": sum(r["false_claims"] for r in group),
            "mean_tests": mean(r["test_count"] for r in group),
            "mean_queries": mean(r["query_count"] for r in group),
            "mean_seconds": mean(r["elapsed_seconds"] for r in group),
            "mean_model_seconds": mean(r["model_seconds"] for r in group),
            "total_prompt_tokens": sum(r["usage"]["prompt_tokens"] for r in group)
            if all(r["usage_complete"] for r in group)
            else None,
            "total_completion_tokens": sum(r["usage"]["completion_tokens"] for r in group)
            if all(r["usage_complete"] for r in group)
            else None,
            "usage_complete": all(r["usage_complete"] for r in group),
            "estimated_usd": sum(r["estimated_usd"] for r in group)
            if all(r["estimated_usd"] is not None for r in group)
            else None,
            "by_family": {
                family: {
                    "n_runs": len(values),
                    "decision_accuracy": mean(r["diagnosis_correct"] for r in values),
                }
                for family, values in sorted(families.items())
            },
        }
    return result


def render_markdown(summary, language):
    en = language == "en"
    lines = [
        "# " + ("Diagnostic evaluation" if en else "Evaluación del diagnóstico"),
        "",
        (
            "**Simulation: validates the harness only; these are not AI or physical diagnostic results.**"
            if en
            else "**Simulación: valida únicamente el evaluador; no son resultados de diagnóstico con IA ni hardware real.**"
        )
        if not summary["research_evidence"]
        else (
            "Recorded-data evaluation; physical repair by each method was not tested."
            if en
            else "Evaluación con datos registrados; no se probó una reparación física ejecutada por cada método."
        ),
        "",
        f"{summary['provider']} · {summary['model']} · {summary['provenance']}",
        "",
        (
            "| Method | Cases / mounts | Runs | Correct decision | Mean tests | Errors |"
            if en
            else "| Método | Casos / montajes | Ejecuciones | Decisión correcta | Pruebas medias | Errores |"
        ),
        "|---|---:|---:|---:|---:|---:|",
    ]
    for method, data in summary["methods"].items():
        lines.append(
            f"| {method} | {data['n_cases']} / {data['n_mounts']} | {data['n_runs']} | "
            f"{data['decision_accuracy']:.1%} | {data['mean_tests']:.2f} | {data['errors']} |"
        )
    lines += [
        "",
        (
            "Correct decisions include appropriate abstention on ambiguous/out-of-scope cases. Errors remain in the denominator."
            if en
            else "Una decisión correcta incluye abstenerse ante ambigüedad o casos fuera del alcance. Los errores permanecen en el denominador."
        ),
        "",
        (
            "Intervals in JSON resample mounts (2,000 seeded bootstrap samples); repeated runs are not independent cases. No significance or generalization is claimed."
            if en
            else "Los intervalos JSON remuestrean montajes (2.000 muestras bootstrap con semilla); las repeticiones no son casos independientes. No se afirma significación ni generalización."
        ),
        "",
        (
            "Verified physical repair and unconfigured costs are reported as null. Simulated post-repair readings only check the scoring logic."
            if en
            else "La reparación física verificada y los costos sin configurar se informan como null. Las lecturas simuladas posteriores solo comprueban la lógica de puntuación."
        ),
        "",
    ]
    return "\n".join(lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path)
    parser.add_argument("--json-output", type=Path)
    parser.add_argument("--markdown-output", type=Path)
    parser.add_argument("--language", choices=["en", "es"], default="es")
    args = parser.parse_args()
    rows = [
        json.loads(line) for line in args.results.read_text(encoding="utf-8").splitlines() if line.strip()
    ]
    summary = summarize(rows)
    encoded = json.dumps(summary, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
    if args.json_output:
        with args.json_output.open("x", encoding="utf-8") as stream:
            stream.write(encoded)
    if args.markdown_output:
        with args.markdown_output.open("x", encoding="utf-8") as stream:
            stream.write(render_markdown(summary, args.language))
    print(encoded)
