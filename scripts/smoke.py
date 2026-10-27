"""Opt-in loopback integration test. Creates a clearly labelled synthetic session."""

import argparse
import uuid
import time
from urllib.parse import urlparse
import httpx


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8000/api/v1")
    parser.add_argument("--language", choices=["en", "es"], default="es")
    args = parser.parse_args()
    if urlparse(args.url).hostname not in {"localhost", "127.0.0.1"}:
        parser.error("El smoke test crea datos sintéticos y solo admite localhost")
    with httpx.Client(base_url=args.url, timeout=15) as api:
        api.headers["Accept-Language"] = args.language
        mode = api.get("/health/live").json()["ai_mode"]
        if mode != "simulation":
            raise SystemExit("Este smoke test requiere AI_MODE=simulation")
        tokens = api.post(
            "/auth/login", json={"email": "demo@circuitlab.local", "password": "CircuitLab-demo-2026"}
        )
        tokens.raise_for_status()
        api.headers["Authorization"] = "Bearer " + tokens.json()["access_token"]

        def post(path, data=None):
            response = api.post(path, json=data)
            response.raise_for_status()
            return response.json()

        def wait_job(job_id):
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                job = api.get("/jobs/" + job_id).json()
                if job["status"] == "completed":
                    return
                if job["status"] == "failed":
                    raise RuntimeError("Trabajo fallido")
                time.sleep(0.25)
            raise TimeoutError("Worker no respondió en 30 s")

        session = post(
            "/sessions",
            {
                "title": "SIMULACIÓN · Prueba integrada de software",
                "family": "voltage_divider",
                "expected": "Valor sintético de 2.5 V",
                "symptoms": "Valor sintético inicial de 0.04 V",
                "supply_v": 5,
            },
        )
        path = "/sessions/" + session["id"]
        response = api.patch(
            path + "/specification",
            json={
                "version": session["version"],
                "confirmed": True,
                "connections": ["SINTÉTICO: R1:5V-TP1", "SINTÉTICO: R2:TP1-GND"],
                "functional_description": "Comprobación de software con datos sintéticos; no valida hardware",
                "points": [{"id": "TP1", "label": "Salida de prueba", "min_v": 2.4, "max_v": 2.6}],
            },
        )
        response.raise_for_status()
        wait_job(post(path + "/analysis")["job_id"])

        def measurement(value, key):
            return post(
                path + "/measurements",
                {
                    "client_id": key + session["id"],
                    "point_id": "TP1",
                    "value": value,
                    "unit": "V",
                    "measured_at": time.time(),
                    "conditions_confirmed": True,
                },
            )

        measurement(0.04, "synthetic-before-")
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if api.get(path).json()["state"] == "awaiting_intervention":
                break
            time.sleep(0.25)
        else:
            raise TimeoutError("No se completó el análisis de la medida")
        post(
            path + "/interventions",
            {"description": "Intervención sintética para verificar el flujo de software", "confirmed": True},
        )
        measurement(2.5, "synthetic-after-")
        post(path + "/functional-check", {
            "client_id": "synthetic-functional-" + uuid.uuid4().hex,
            "passed": True, "observations": "Synthetic fixture observation; no physical test performed",
            "performed_at": time.time(), "confirmed": True,
        })
        wait_job(post(path + "/verification")["job_id"])
        report = api.get(path + "/report").json()
        assert report["state"] == "resolved"
        assert len(report["measurements"]) == 2
        assert report["model_runs"][0]["data"]["provider"] == "simulation"
        assert report["language"] == args.language
        markdown = api.get(path + "/report?format=markdown")
        assert ("## Measurements" if args.language == "en" else "## Mediciones") in markdown.text
        print(
            (
                "Integrated workflow completed in SIMULATION mode. Session: "
                if args.language == "en"
                else "Flujo integrado completado en modo SIMULACIÓN. Sesión: "
            )
            + session["id"]
        )


if __name__ == "__main__":
    main()
