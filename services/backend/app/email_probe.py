"""Send exactly one operator-requested test email; never logs the recipient or service key."""

import argparse
import getpass
import json
import time
import httpx
from app.accounts import public_delivery, refresh_delivery, safe_resend_receipt
from app.config import settings
from app.db import EmailDelivery, SessionLocal
from app.schemas import AccountEmail


def send_probe(recipient):
    config = settings()
    recipient = AccountEmail(email=recipient).email
    if not config.resend_api_key.get_secret_value().strip() or not config.resend_from.strip():
        raise ValueError("Resend configuration is incomplete")
    with SessionLocal() as db:
        row = EmailDelivery(purpose="operational_test", provider="resend", user_id=None)
        db.add(row)
        db.commit()
        receipt_id = row.id
    status, provider_id, http_status = "failed", None, None
    try:
        response = httpx.post(
            "https://api.resend.com/emails",
            headers={
                "Authorization": "Bearer " + config.resend_api_key.get_secret_value(),
                "Idempotency-Key": "production-probe/" + receipt_id,
            },
            json={
                "from": config.resend_from,
                "to": [recipient],
                "subject": "CircuitLab AI - email delivery test / prueba de correo",
                "text": "This is the single CircuitLab AI email test you requested. It contains no password reset links or credentials.\n\nEste es el único correo de prueba de CircuitLab AI que solicitaste. No contiene enlaces de recuperación ni credenciales.",
            },
            timeout=15,
        )
        http_status = response.status_code
        response.raise_for_status()
        provider_id = safe_resend_receipt(response)
        status = "accepted"
    finally:
        with SessionLocal() as db:
            row = db.get(EmailDelivery, receipt_id)
            row.status, row.provider_id = status, provider_id
            row.http_status, row.updated_at = http_status, time.time()
            db.commit()
    with SessionLocal() as db:
        return public_delivery(db.get(EmailDelivery, receipt_id))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--send", action="store_true", help="Explicitly send one paid-provider test message")
    action.add_argument("--receipt-id", help="Check an existing receipt; sends no email")
    parser.add_argument(
        "--recipient-stdin", action="store_true", help="Read the recipient from standard input"
    )
    args = parser.parse_args()
    try:
        if args.send:
            recipient = (
                input().strip()
                if args.recipient_stdin
                else getpass.getpass("Test recipient email (not logged): ").strip()
            )
            result = send_probe(recipient)
        else:
            with SessionLocal() as db:
                row = db.get(EmailDelivery, args.receipt_id)
                if not row:
                    raise ValueError("Receipt not found")
                result = refresh_delivery(db, row)
        print(json.dumps(result, indent=2))
    except Exception as exc:
        result = {"passed": False, "failure_type": type(exc).__name__}
        if isinstance(exc, httpx.HTTPStatusError):
            result["http_status"] = exc.response.status_code
        if args.receipt_id:
            result["receipt_id"] = args.receipt_id
        provider_status = getattr(exc, "provider_http_status", None)
        if provider_status is not None:
            result["provider_http_status"] = provider_status
        print(json.dumps(result))
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
