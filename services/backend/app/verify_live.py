"""Opt-in real-provider verification. Creates an explicitly synthetic bench in PostgreSQL.

Never imported by the application or unit tests. Run deliberately; it consumes model tokens.
The bridge source must be importable for the simulated instrument round trip.
"""
import argparse
import base64
import io
import json
import logging
import secrets
import time

from fastapi.testclient import TestClient
from PIL import Image, ImageDraw
from sqlalchemy import delete, select

from app import worker
from app.config import settings
from app.db import Device, ModelRun, Session, SessionLocal, Token, User, engine
from app.domain import record
from app.inference import exchange, profile, secret_value
from app.main import app
from app.security import digest, hash_password

P = "/api/v1"


def schematic():
    image = Image.new("RGB", (800, 480), "white")
    draw = ImageDraw.Draw(image)
    draw.text((25, 20), "SYNTHETIC CIRCUIT FIXTURE - NOT A HARDWARE PHOTO", fill="black")
    draw.text((25, 50), "Declared topology: 5V -- R1 10k -- TP1 -- R2 10k -- GND", fill="black")
    draw.line([(380, 110), (380, 150)], fill="black", width=4)
    draw.rectangle((350, 150, 410, 230), outline="black", width=4)
    draw.line([(380, 230), (380, 290)], fill="black", width=4)
    draw.ellipse((373, 263, 387, 277), fill="red")
    draw.rectangle((350, 290, 410, 370), outline="black", width=4)
    draw.line([(380, 370), (380, 410)], fill="black", width=4)
    for position, label in [((420, 110), "5 V"), ((430, 185), "R1 10k ohm"),
                            ((430, 260), "TP1: output (target 2.4-2.6 V)"),
                            ((430, 325), "R2 10k ohm"), ((420, 410), "GND")]:
        draw.text(position, label, fill="black")
    output = io.BytesIO()
    image.save(output, format="PNG")
    return output.getvalue()


def run(resume_session=None):
    logging.disable(logging.CRITICAL)
    config = settings()
    provider, base, _ = profile(config)
    if config.ai_mode != "meta" or engine.dialect.name != "postgresql":
        raise RuntimeError("Live verification requires AI_MODE=meta and PostgreSQL")
    if provider not in {"meta", "baseten"}:
        raise RuntimeError("Live verification requires an official hosted provider profile")
    key = secret_value(config.meta_api_key)
    password = secrets.token_urlsafe(40)
    email = "live-check-" + secrets.token_hex(6) + "@example.test"
    with SessionLocal() as db:
        if resume_session:
            previous = db.get(Session, resume_session)
            if not previous or not previous.title.startswith("LIVE META / SIMULATED BENCH:"):
                raise RuntimeError("Only this verifier's synthetic sessions can be resumed")
            user = db.get(User, previous.owner_id)
            if not user.email.startswith("live-check-") or not user.email.endswith("@example.test"):
                raise RuntimeError("Only verifier-owned accounts can be resumed")
            email = user.email
            user.password, user.active = hash_password(password), 1
        else:
            user = User(email=email, password=hash_password(password))
            db.add(user)
        db.commit()
        user_id = user.id
    summary = {"provider": provider, "model": config.meta_reasoning_model, "real_model_calls": True,
               "hardware": "simulated", "physical_verification": False, "checks": {}}
    sid = None
    try:
        with TestClient(app, raise_server_exceptions=False) as client:
            login = client.post(P + "/auth/login", json={"email": email, "password": password})
            if login.status_code != 200:
                raise RuntimeError("Verification account login failed")
            headers = {"Authorization": "Bearer " + login.json()["access_token"], "Accept-Language": "en"}

            def api(method, path, expected=200, **kwargs):
                response = client.request(method, P + path, headers=headers, **kwargs)
                if key in response.text:
                    raise RuntimeError("Credential exposure detected")
                if response.status_code != expected:
                    raise RuntimeError("Backend endpoint failed: " + path + " HTTP " + str(response.status_code))
                return response.json() if response.content else None

            if resume_session:
                sid = resume_session
                summary["session_id"] = sid
                path = "/sessions/" + sid
                current = api("GET", path)
                evidence = current["evidence"][0]
                summary["resumed"] = True
            else:
                session = api("POST", "/sessions", 201, json={
                    "title": "LIVE META / SIMULATED BENCH: voltage divider",
                    "language": "en", "family": "voltage_divider", "supply_v": 5,
                    "expected": "Synthetic 5 V divider with two equal 10k resistors: TP1 should be 2.4-2.6 V.",
                    "symptoms": "SIMULATED BENCH ONLY: output is reported near ground instead of mid-supply. "
                                "No physical circuit is connected. Request a discriminating DC voltage check; "
                                "fixture observations will be supplied explicitly as simulated measurements.",
                })
                sid = session["id"]
                summary["session_id"] = sid
                path = "/sessions/" + sid
                api("PATCH", path + "/specification", json={
                    "version": session["version"], "confirmed": True,
                    "connections": ["5V -- R1 (10k ohm) -- TP1", "TP1 -- R2 (10k ohm) -- GND"],
                    "functional_description": "Synthetic fixture only: steady 5 V supply, common GND; TP1 2.4-2.6 V.",
                    "points": [{"id": "TP1", "label": "Divider output", "min_v": 2.4, "max_v": 2.6}],
                })
                evidence = api("POST", path + "/evidence", 201,
                               data={"client_id": "synthetic-schematic-" + secrets.token_hex(6)},
                               files={"file": ("synthetic-schematic.png", schematic(), "image/png")})
            summary["evidence_id"] = evidence["id"]
            summary["evidence_sha256"] = evidence["sha256"]
            summary["evidence_kind"] = "synthetic schematic; not a physical photograph"

            def persist(audit):
                with SessionLocal() as db:
                    db.add(ModelRun(session_id=sid, data=audit))
                    db.commit()

            blue = io.BytesIO()
            Image.new("RGB", (128, 128), "blue").save(blue, format="PNG")
            for name, content, expected in [
                ("text", [{"type": "text", "text": "Reply exactly CIRCUITLAB_READY, with no other text."}],
                 "CIRCUITLAB_READY"),
                ("image", [{"type": "text", "text": "Name the dominant color of this synthetic test image. "
                           "Reply with the English color name only."},
                           {"type": "image_url", "image_url": {"url": "data:image/png;base64," +
                            base64.b64encode(blue.getvalue()).decode()}}], "blue"),
            ]:
                if resume_session:
                    with SessionLocal() as db:
                        previous_calls = db.scalars(select(ModelRun).where(ModelRun.session_id == sid)
                                                    .order_by(ModelRun.created_at.desc()))
                        previous = next((r.data for r in previous_calls
                                         if r.data.get("verification") == name
                                         and r.data.get("model") == config.meta_reasoning_model), None)
                    previous_text = ((previous or {}).get("response_message", {}).get("content") or "").strip()
                    if previous and previous.get("http_status") == 200 and previous_text.casefold() == expected.casefold():
                        summary["checks"][name] = {"status": "passed", "reused_existing_real_receipt": True,
                                                  **{k: previous.get(k) for k in ("request_id", "response_id", "response_model")}}
                        continue
                try:
                    message, audit = exchange(
                        provider=provider, base=base, key=config.meta_api_key, model=config.meta_reasoning_model,
                        messages=[{"role": "user", "content": content}], tools=[], max_tokens=1024,
                        timeout=config.meta_timeout_seconds,
                        on_exchange=lambda row, name=name: persist({**row, "verification": name}),
                    )
                    actual = (message.get("content") or "").strip().strip(".\"' ").casefold()
                    summary["checks"][name] = {
                        "status": "passed" if actual == expected.casefold() else "failed",
                        "http_status": audit["http_status"], "request_id": audit["request_id"],
                        "response_id": audit["response_id"], "response_model": audit["response_model"],
                    }
                except Exception as exc:
                    summary["checks"][name] = {"status": "blocked", "exception_type": type(exc).__name__,
                                              "http_status": getattr(exc, "audit", {}).get("http_status")}

            def process_job(job_id):
                claimed = worker.claim(job_id)
                if not claimed:
                    raise RuntimeError("Verification job could not be claimed")
                worker.process(*claimed)
                job = api("GET", "/jobs/" + job_id)
                if job["status"] != "completed":
                    raise RuntimeError("Real diagnosis failed: " + (job["error"] or job["status"]))

            try:
                queued = api("POST", path + "/analysis", 202)
                process_job(queued["job_id"])
                current = api("GET", path)
                if current["state"] != "awaiting_measurement" or not current["hypotheses"]:
                    raise RuntimeError("Model did not request the minimum diagnostic measurement")
                point = current["pending_test"]["point_id"]
                from bridge.adapters.simulated import SimulatedAdapter
                device = api("POST", "/devices/enroll", 201, json={
                    "name": "EXPLICIT SIMULATED BENCH", "points": [point],
                    "calibration_id": "synthetic-fixture-not-calibrated", "simulated": True,
                })
                adapter = SimulatedAdapter({
                    "device_id": device["device_id"], "points": [point], "simulate": True,
                    "calibration_id": "synthetic-fixture-not-calibrated", "simulated_values": {point: 0.04},
                })
                with client.websocket_connect(P + "/devices/connect", headers={
                    "Authorization": "Bearer " + device["device_token"],
                }) as socket:
                    for _ in range(50):
                        devices = api("GET", "/devices")
                        if any(d["id"] == device["device_id"] and d["last_seen"] for d in devices):
                            break
                        time.sleep(.05)
                    command = api("POST", path + "/hardware", 202, json={
                        "device_id": device["device_id"], "point_id": point, "conditions_confirmed": True,
                    })
                    payload = socket.receive_json()
                    if payload.get("command_id") != command["command_id"]:
                        raise RuntimeError("Unexpected instrument command")
                    socket.send_json(adapter.read(payload))
                    if socket.receive_json().get("ack") != command["command_id"]:
                        raise RuntimeError("Simulated reading was not accepted")
                current = api("GET", path)
                assert current["measurements"][-1]["source"] == "simulated"
                pending = next(j for j in current["jobs"] if j["status"] == "pending")
                process_job(pending["id"])
                current = api("GET", path)
                assert current["analysis_steps"] >= 2 and current["state"] != "resolved"
                assert not current["verifications"] and not current["interventions"]
                with SessionLocal() as db:
                    rows = [r.data for r in db.scalars(select(ModelRun).where(ModelRun.session_id == sid))]
                executions = [r for r in rows if r.get("run_kind") == "tool_execution"]
                returned = {call for r in rows for call in r.get("returned_tool_call_ids", [])}
                assert len(executions) >= 2 and all(r["tool_call_id"] in returned for r in executions)
                assert any(r["result"]["measurements"] for r in executions)
                summary["checks"]["tool_calling"] = {"status": "passed", "executed_tools": len(executions),
                                                      "function": "get_recorded_observations"}
                summary["checks"]["minimum_session"] = {
                    "status": "passed", "analysis_steps": current["analysis_steps"], "state": current["state"],
                    "hypotheses": len(current["hypotheses"]), "measurements": len(current["measurements"]),
                    "measurement_source": "simulated", "command_id": command["command_id"],
                    "verification_records": len(current["verifications"]),
                }
            except Exception as exc:
                summary["checks"]["minimum_session"] = {"status": "blocked", "exception_type": type(exc).__name__,
                                                        "reason": str(exc)[:200].replace(key, "[REDACTED]")}
                summary["checks"].setdefault("tool_calling", {"status": "not_verified"})
            report = api("GET", path + "/report")
            assert key not in json.dumps(report)
            summary["checks"]["credential_in_api_response"] = {"status": "passed", "exposed": False}
            with SessionLocal() as db:
                session = db.get(Session, sid)
                record(db, session, "integration_verification", summary)
                db.commit()
    finally:
        with SessionLocal() as db:
            db.execute(delete(Token).where(Token.user_id == user_id))
            db.get(User, user_id).active = 0
            for device in db.scalars(select(Device).where(Device.owner_id == user_id)):
                device.token_digest = digest(secrets.token_urlsafe(48))
            db.commit()
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resume-session", help="Resume only a verifier-owned synthetic session")
    args = parser.parse_args()
    try:
        summary = run(args.resume_session)
    except Exception as exc:
        print(json.dumps({"status": "blocked", "exception_type": type(exc).__name__}), flush=True)
        raise SystemExit(1) from None
    print(json.dumps(summary, indent=2), flush=True)
    if any(c["status"] != "passed" for c in summary["checks"].values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
