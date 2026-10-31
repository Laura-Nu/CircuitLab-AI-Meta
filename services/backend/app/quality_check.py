"""Opt-in real-provider smoke checks using declared synthetic observations, never hardware proof."""
import argparse
import json
import logging
import time
from copy import deepcopy
from pathlib import Path

from app import meta
from app.config import settings
from app.inference import redacted
from app.worker import validate_plan


def cases():
    base = {
        "session_id": "quality-fixture", "diagnosis_mode": "meta", "language": "es",
        "family": "voltage_divider", "purpose": "diagnosis", "supply_v": 5,
        "expected": "Unloaded divider output 2.35-2.65 V, input 4.85-5 V.",
        "symptoms": "Declared synthetic scenario: output is low; not a physical test.",
        "setup": {}, "evidence": [], "measurements": [], "previous_hypotheses": [],
        "connection_confirmations": [], "serial_captures": [], "serial_provenance": [],
        "specification": {
            "connections": ["Input TP2--R1 10k--output TP1--R2 required 10k--GND; unloaded."],
            "functional_description": "Output stays within criterion for ten seconds.",
            "points": [
                {"id": "TP1", "label": "Divider output", "value_kind": "voltage", "min_v": 2.35, "max_v": 2.65},
                {"id": "TP2", "label": "Supply input", "value_kind": "voltage", "min_v": 4.85, "max_v": 5},
            ],
        },
    }
    def reading(identifier, point, value, unit="V", instant=100):
        return {"id": identifier, "point_id": point, "value": value, "unit": unit,
                "source": "simulated", "phase": "diagnosis", "measured_at": instant, "created_at": instant}
    low = deepcopy(base)
    low["measurements"] = [reading("output-low", "TP1", .455)]
    healthy = deepcopy(base)
    healthy.update(purpose="check_operation", symptoms="")
    healthy["measurements"] = [reading("output-ok", "TP1", 2.5), reading("input-ok", "TP2", 5)]
    sensor = deepcopy(base)
    sensor.update(family="custom", purpose="check_operation", symptoms="", supply_v=3.3,
                  expected="Temperature 20-30 C and card detection false with no card present.",
                  setup={"board": "ESP32", "modules": "Temperature sensor and RFID reader"})
    sensor["specification"] = {
        "connections": ["Declared firmware publishes temperature and card_detected over USB."],
        "functional_description": "Bring a card near the reader and observe a change, then remove it.",
        "points": [
            {"id": "TP1", "label": "Temperature", "kind": "sensor", "value_kind": "number",
             "unit": "C", "min_value": 20, "max_value": 30},
            {"id": "TP2", "label": "Card detected, no card present", "kind": "reported_state",
             "value_kind": "boolean", "expected_state": False},
        ],
    }
    sensor["measurements"] = [reading("temperature-ok", "TP1", 25, "C")]
    false_ok = deepcopy(sensor)
    false_ok["language"] = "en"
    false_ok["measurements"].append(reading("card-absent", "TP2", False, "boolean"))
    newest = deepcopy(healthy)
    newest["measurements"] = [
        reading("old-output-bad", "TP1", .455, instant=90),
        reading("new-output-ok", "TP1", 2.5, instant=110),
        reading("input-ok", "TP2", 5, instant=110),
    ]
    return [
        ("low_output_unknown_supply", low, {"read_voltage", "request_manual_measurement"}, "TP2"),
        ("healthy_requires_functional_check", healthy, {"inconclusive"}, None),
        ("reported_boolean_not_gpio", sensor, {"request_manual_measurement"}, "TP2"),
        ("expected_false_is_valid", false_ok, {"inconclusive"}, None),
        ("latest_reading_supersedes_old_value", newest, {"inconclusive"}, None),
    ]


def run(output):
    config = settings()
    if config.ai_mode != "meta":
        raise RuntimeError("Configure real Meta inference; this check never accepts simulation")
    rows = []
    for name, context, actions, point in cases():
        started = time.monotonic()
        receipts = []
        row = {"case": name, "synthetic_inputs": True, "physical_verification": False}
        try:
            result, audit = meta.analyze(context, on_exchange=receipts.append)
            validate_plan(result, context)
            exchanges = [r for r in receipts if r.get("run_kind") == "provider_exchange"]
            actual = len(exchanges) == 2 and all(r.get("http_status") == 200 for r in exchanges)
            tool_returned = any(r.get("run_kind") == "tool_execution" and
                                r.get("tool_name") == "get_recorded_observations" and
                                r.get("status") == "executed" for r in receipts)
            row.update(passed=actual and tool_returned and result.action in actions and result.point_id == point,
                       action=result.action, point_id=result.point_id, output=result.model_dump(),
                       usage=audit.get("usage"), provider=audit.get("provider"), model=audit.get("model"),
                       prompt_version=audit.get("prompt_version"), real_provider_response=actual,
                       exchange_count=audit.get("exchange_count"), input_text_chars=audit.get("input_text_chars"))
        except Exception as exc:
            row.update(passed=False, error_type=type(exc).__name__)
        row["elapsed_ms"] = round((time.monotonic() - started) * 1000)
        row["receipts"] = receipts
        rows.append(row)
        # Audit content stays in the explicitly selected private directory.
        output.write_text(json.dumps(redacted({"cases": rows}, config.meta_api_key),
                                     ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps({k: row[k] for k in ("case", "passed", "elapsed_ms")}), flush=True)
    return all(r["passed"] for r in rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="Authorize ten paid provider exchanges (five cases)")
    parser.add_argument("--output", type=Path, required=True, help="New private JSON file outside tracked paths")
    args = parser.parse_args()
    if not args.live:
        parser.error("--live is required; this consumes real model tokens")
    root = Path(__file__).resolve().parents[3]
    target = args.output.resolve()
    private = (root / ".tools").resolve()
    if not target.is_relative_to(private) or target.exists():
        parser.error("Choose a new output file inside the ignored .tools directory")
    target.parent.mkdir(parents=True, exist_ok=True)
    logging.disable(logging.CRITICAL)
    raise SystemExit(0 if run(target) else 1)


if __name__ == "__main__":
    main()
