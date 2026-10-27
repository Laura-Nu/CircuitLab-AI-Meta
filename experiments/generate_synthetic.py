"""Create 18 synthetic fixtures. These are a plumbing check, never research evidence."""

import argparse
import json
import random
from pathlib import Path


def generate(directory):
    directory.mkdir(parents=True, exist_ok=True)
    catalog = [
        "supply_disconnected",
        "signal_short_ground",
        "signal_short_supply",
        "healthy",
    ]
    combinations = [
        (family, kind)
        for family in ["led_resistor", "voltage_divider", "analog_sensor"]
        for kind in catalog + ["ambiguous", "out_of_scope"]
    ]
    random.Random(20261023).shuffle(combinations)
    public, observations, labels = [], {}, {}
    for i, (family, kind) in enumerate(combinations):
        case_id = f"S{i + 1:03}"
        target = 2.0 if family == "led_resistor" else 2.5
        points = [
            {"id": "TP1", "label": "Supply", "min_v": 4.9, "max_v": 5},
            {
                "id": "TP2",
                "label": "Output",
                "min_v": target - 0.1,
                "max_v": target + 0.1,
            },
            {"id": "TP3", "label": "Ground", "min_v": 0, "max_v": 0.05},
        ]
        public.append(
            {
                "case_id": case_id,
                "mount_id": f"synthetic-mount-{i + 1}",
                "split": "evaluation",
                "family": family,
                "expected": f"Supply 5 V, output {target} V, common ground.",
                "symptoms": "Please check the output; the visual observation is uncertain.",
                "connections": ["Supply:TP1", "Output:TP2", "Ground:TP3"],
                "connections_confirmed": kind != "ambiguous",
                "scope_confirmed": kind != "out_of_scope",
                "points": points,
                "diagnosis_catalog": catalog,
                "questions": {"connection_check": "Are all declared connections confirmed?"},
            }
        )
        values = {
            "supply_disconnected": [0, 0, 0],
            "signal_short_ground": [5, 0, 0],
            "signal_short_supply": [5, 5, 0],
        }.get(kind, [5, target, 0])

        def readings(values, phase):
            return [
                {
                    "id": f"{case_id}-{phase}-{j}",
                    "point_id": f"TP{j + 1}",
                    "value": v,
                    "source": "simulated",
                    "measured_at": 1792800000 + (60 if phase == "post" else 0),
                    "calibration_id": "synthetic-reference",
                }
                for j, v in enumerate(values)
            ]

        observations[case_id] = {
            "readings": {r["point_id"]: r for r in readings(values, "pre")},
            "answers": {"connection_check": "Not confirmed" if kind == "ambiguous" else "Confirmed"},
        }
        fault = kind in catalog[:3]
        labels[case_id] = {
            "kind": "fault" if fault else kind,
            "accepted_diagnoses": [kind] if kind in catalog else [],
            "intervention_for": kind if fault else None,
            "intervention_confirmed_at": 1792800030 if fault else None,
            "post_readings": readings([5, target, 0], "post") if fault else [],
        }
    files = {
        "cases.jsonl": "".join(json.dumps(c) + "\n" for c in public),
        "observations.private.json": json.dumps(
            {
                "provenance": "simulation",
                "hardware_version": "synthetic-1",
                "firmware_version": "none",
                "catalog_version": "voltage-dc-v1",
                "cases": observations,
            },
            indent=2,
        ),
        "labels.private.json": json.dumps(labels, indent=2),
    }
    for name, data in files.items():
        target = directory / name
        with target.open("x", encoding="utf-8") as output:
            output.write(data)
    return len(public)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    print(f"{generate(args.output)} synthetic cases / casos sintéticos: {args.output}")
