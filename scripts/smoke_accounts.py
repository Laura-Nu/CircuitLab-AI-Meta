"""Opt-in account/recovery smoke test against the loopback development demo only."""

import argparse
import re
import secrets
import time
from email import policy
from email.parser import BytesParser
from pathlib import Path
from urllib.parse import urlparse

import httpx


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8000/api/v1")
    parser.add_argument("--language", choices=["es", "en"], default="es")
    parser.add_argument("--mailbox", type=Path, default=Path(".tools/dev/recovery"))
    args = parser.parse_args()
    if urlparse(args.url).hostname not in {"localhost", "127.0.0.1"}:
        parser.error(
            "Only the isolated loopback demo is supported / Solo demo local aislada"
        )
    with httpx.Client(
        base_url=args.url, timeout=15, headers={"Accept-Language": args.language}
    ) as api:
        assert api.get("/health/live").json()["ai_mode"] == "simulation"

        def login(email, password):
            response = api.post(
                "/auth/login", json={"email": email, "password": password}
            )
            response.raise_for_status()
            return response.json()

        admin = login("demo@circuitlab.local", "CircuitLab-demo-2026")
        assert admin["user"]["role"] == "admin"
        auth = {"Authorization": "Bearer " + admin["access_token"]}
        email = f"account-smoke-{secrets.token_hex(5)}@example.test"
        password, replacement = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
        created = api.post(
            "/admin/users", headers=auth, json={"email": email, "password": password}
        )
        assert created.status_code == 201
        user_id = created.json()["id"]
        original = login(email, password)
        path = "/admin/users/" + user_id
        assert (
            api.patch(
                path, headers=auth, json={"role": "member", "active": False}
            ).status_code
            == 200
        )
        assert (
            api.get(
                "/sessions",
                headers={"Authorization": "Bearer " + original["access_token"]},
            ).status_code
            == 401
        )
        assert (
            api.patch(
                path, headers=auth, json={"role": "member", "active": True}
            ).status_code
            == 200
        )
        assert (
            api.post("/auth/forgot-password", json={"email": email}).status_code == 202
        )
        message = None
        deadline = time.monotonic() + 5
        while message is None and time.monotonic() < deadline:
            messages = [
                BytesParser(policy=policy.default).parsebytes(p.read_bytes())
                for p in args.mailbox.glob("*.eml")
            ]
            message = next((m for m in messages if m["To"] == email), None)
            if message is None:
                time.sleep(0.1)
        if message is None:
            raise TimeoutError("Local recovery message was not delivered")
        token = re.search(r"token=([A-Za-z0-9_-]+)", message.get_content())[1]
        assert f"?lang={args.language}#/reset-password" in message.get_content()
        reset = {"token": token, "password": replacement}
        assert api.post("/auth/reset-password", json=reset).status_code == 204
        assert api.post("/auth/reset-password", json=reset).status_code == 400
        assert (
            api.post(
                "/auth/login", json={"email": email, "password": password}
            ).status_code
            == 401
        )
        assert login(email, replacement)["user"]["id"] == user_id
        # Preserve audit evidence, but leave the synthetic account deactivated.
        assert (
            api.patch(
                path, headers=auth, json={"role": "member", "active": False}
            ).status_code
            == 200
        )
        print(
            "Account creation, revocation and recovery passed (private local email)."
            if args.language == "en"
            else "Alta, revocación y recuperación verificadas (correo local privado)."
        )


if __name__ == "__main__":
    main()
