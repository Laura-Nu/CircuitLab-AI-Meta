"""Account administration and single-use recovery. No credentials in API responses or audit."""

import logging
import re
import secrets
import time
from email.message import EmailMessage
from pathlib import Path
from urllib.parse import urlencode

import httpx
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, Request, Response
from sqlalchemy import case, delete, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app import schemas as s
from app.config import settings
from app.db import AccountEvent, Device, EmailDelivery, RecoveryLimit, SessionLocal, Token, User, get_db, uid
from app.i18n import request_language
from app.security import administrator, authentication_response, browser_origin, current_user, digest, hash_password, issue_tokens

router = APIRouter(prefix="/api/v1", tags=["accounts"])
log = logging.getLogger("circuitlab.accounts")


def public_user(user):
    return {"id": user.id, "email": user.email, "role": user.role, "active": bool(user.active)}


def audit(db, actor, user, kind, data=None):
    db.add(AccountEvent(actor_id=actor, user_id=user.id, kind=kind, data=data or {}))


def revoke(db, user_id):
    db.execute(delete(Token).where(Token.user_id == user_id))


def recovery_available():
    config = settings()
    return (
        (config.recovery_delivery == "file" and config.app_env == "development")
        or (
            config.recovery_delivery == "resend"
            and bool(config.resend_api_key.get_secret_value().strip() and config.resend_from.strip())
        )
    )


def deliver_recovery(email, raw, language, delivery_id=None):
    """After the generic HTTP response. Development files stay outside the public web root."""
    config = settings()
    query = urlencode({"token": raw})
    link = f"{config.app_origin.rstrip('/')}/app/?lang={language}#/reset-password?{query}"
    english = language == "en"
    message = EmailMessage()
    message["Subject"] = (
        "Reset your CircuitLab password" if english else "Restablece tu contraseña de CircuitLab"
    )
    message["From"] = config.resend_from.strip() or "circuitlab@localhost"
    message["To"] = email
    message.set_content(
        (
            f"Use this link within {config.recovery_ttl_minutes} minutes to choose a new password:\n\n"
            if english
            else f"Usa este enlace dentro de {config.recovery_ttl_minutes} minutos para elegir otra contraseña:\n\n"
        )
        + link
        + "\n\n"
        + (
            "If you did not request this, ignore this message. The link works once."
            if english
            else "Si no lo solicitaste, ignora este mensaje. El enlace funciona una sola vez."
        )
    )
    status, provider_id, http_status = "failed", None, None
    try:
        if config.recovery_delivery == "file" and config.app_env == "development":
            directory = Path(config.recovery_directory)
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            for previous in directory.glob("*.eml"):
                if previous.stat().st_mtime < time.time() - config.recovery_ttl_minutes * 60:
                    previous.unlink(missing_ok=True)
            target = directory / f"{uid()}.eml"
            with target.open("xb") as output:
                target.chmod(0o600)
                output.write(bytes(message))
            status = "development_file"
        elif config.recovery_delivery == "resend" and recovery_available():
            response = httpx.post(
                "https://api.resend.com/emails",
                headers={
                    "Authorization": "Bearer " + config.resend_api_key.get_secret_value().strip(),
                    "Idempotency-Key": "recovery/" + digest(raw),
                },
                json={
                    "from": config.resend_from.strip(),
                    "to": [email],
                    "subject": str(message["Subject"]),
                    "text": message.get_content(),
                },
                timeout=10,
            )
            http_status = response.status_code
            response.raise_for_status()
            status, provider_id = "accepted", safe_resend_receipt(response)

    except Exception as exc:
        if isinstance(exc, httpx.HTTPStatusError):
            log.error(
                "Password recovery delivery failed: %s (HTTP %s)",
                type(exc).__name__,
                exc.response.status_code,
            )
        else:
            log.error("Password recovery delivery failed: %s", type(exc).__name__)
    finally:
        if delivery_id:
            try:
                with SessionLocal() as db:
                    delivery = db.get(EmailDelivery, delivery_id)
                    if delivery:
                        delivery.status, delivery.provider_id = status, provider_id
                        delivery.http_status, delivery.updated_at = http_status, time.time()
                        db.commit()
            except Exception as exc:
                log.error("Email receipt persistence failed: %s", type(exc).__name__)



def safe_resend_receipt(response):
    receipt = response.json()
    key = settings().resend_api_key.get_secret_value()
    if (not isinstance(receipt, dict) or not isinstance(receipt.get("id"), str)
            or not re.fullmatch(r"[A-Za-z0-9-]{1,200}", receipt["id"])
            or (key and key in receipt["id"])):
        raise ValueError("Invalid email delivery response")
    return receipt["id"]


def limited(db, key, maximum):
    window = int(time.time() // 900)
    table = RecoveryLimit
    db.execute(delete(table).where(table.window < window - 4))
    insert = pg_insert if db.bind.dialect.name == "postgresql" else sqlite_insert
    statement = insert(table).values(key=digest(key), window=window, attempts=1)
    statement = statement.on_conflict_do_update(
        index_elements=[table.key],
        set_={"window": window, "attempts": case((table.window == window, table.attempts + 1), else_=1)},
    ).returning(table.attempts)
    return db.scalar(statement) > maximum


def start_recovery(db, email, request, tasks, language, actor=None):
    ip = request.client.host if request.client else "unknown"
    ip_limited = limited(db, "ip:" + ip, 20)
    email_limited = limited(db, "email:" + email, 3)
    if not ip_limited and not email_limited and recovery_available():
        user = db.scalar(select(User).where(User.email == email, User.active == 1).with_for_update())
        if user:
            db.execute(delete(Token).where(Token.user_id == user.id, Token.kind == "password_reset"))
            db.execute(update(EmailDelivery).where(
                EmailDelivery.user_id == user.id, EmailDelivery.status == "pending"
            ).values(status="superseded", updated_at=time.time()))
            raw = secrets.token_urlsafe(48)
            db.add(
                Token(
                    digest=digest(raw),
                    user_id=user.id,
                    kind="password_reset",
                    expires=time.time() + settings().recovery_ttl_minutes * 60,
                )
            )
            audit(db, actor, user, "recovery_requested")
            delivery = EmailDelivery(user_id=user.id, provider="resend" if settings().recovery_delivery == "resend" else "file")
            db.add(delivery)
            db.flush()
            tasks.add_task(deliver_recovery, email, raw, language, delivery.id)
    db.commit()
    return {"status": "accepted"}


@router.post("/auth/register", status_code=201)
def register(body: s.AccountRegister, request: Request, response: Response, db: Session = Depends(get_db)):
    if body.client == "web":
        browser_origin(request)
    ip = request.client.host if request.client else "unknown"
    blocked = limited(db, "signup:" + ip, 10)
    db.commit()
    if blocked:
        raise HTTPException(429, "Demasiados registros; inténtalo en 15 minutos")
    # Role is deliberately absent from the public schema and cannot be self-assigned.
    account = User(email=body.email, password=hash_password(body.password), role="member")
    db.add(account)
    try:
        db.flush()
        audit(db, None, account, "member_registered")
        result = issue_tokens(db, account.id)
        result["user"] = public_user(account)
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, "Ya existe una cuenta con ese correo") from None
    return authentication_response(result, response, body.client == "web")


@router.get("/auth/me")
def me(user=Depends(current_user)):
    return public_user(user)


@router.post("/auth/forgot-password", status_code=202)
def forgot_password(
    body: s.AccountEmail,
    request: Request,
    tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    language=Depends(request_language),
):
    return start_recovery(db, body.email, request, tasks, language)


@router.post("/auth/reset-password", status_code=204)
def reset_password(body: s.PasswordReset, db: Session = Depends(get_db)):
    hashed = digest(body.token)
    token = db.get(Token, hashed)
    if not token or token.kind != "password_reset" or token.expires <= time.time():
        raise HTTPException(400, "Enlace inválido o vencido; solicita uno nuevo")
    user = db.scalar(select(User).where(User.id == token.user_id).with_for_update())
    consumed = db.scalar(
        delete(Token)
        .where(Token.digest == hashed, Token.kind == "password_reset", Token.expires > time.time())
        .returning(Token.user_id)
    )
    if not consumed or not user or not user.active:
        db.rollback()
        raise HTTPException(400, "Enlace inválido o vencido; solicita uno nuevo")
    user.password = hash_password(body.password)
    user.failed_attempts = 0
    user.locked_until = 0
    revoke(db, user.id)
    audit(db, None, user, "password_reset")
    db.commit()


@router.get("/admin/users")
def list_users(
    q: str = Query(default="", max_length=254),
    offset: int = Query(default=0, ge=0),
    user=Depends(administrator),
    db: Session = Depends(get_db),
):
    escaped = q.strip().lower().replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    rows = db.scalars(
        select(User)
        .where(User.email.contains(escaped, escape="\\"))
        .order_by(User.email)
        .offset(offset)
        .limit(101)
    ).all()
    return {"items": [public_user(row) for row in rows[:100]], "has_more": len(rows) > 100}


@router.post("/admin/users", status_code=201)
def create_user(body: s.AccountCreate, user=Depends(administrator), db: Session = Depends(get_db)):
    account = User(email=body.email, password=hash_password(body.password), role=body.role)
    db.add(account)
    try:
        db.flush()
        audit(db, user.id, account, "user_created", {"role": account.role})
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, "Ya existe una cuenta con ese correo") from None
    return public_user(account)


@router.patch("/admin/users/{user_id}")
def update_user(
    user_id: str, body: s.AccountUpdate, user=Depends(administrator), db: Session = Depends(get_db)
):
    admins = list(
        db.scalars(
            select(User)
            .where(User.role == "admin")
            .order_by(User.id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
    )
    if not any(a.id == user.id and a.active for a in admins):
        raise HTTPException(403, "Se requiere una cuenta administradora")
    if user_id == user.id and (not body.active or body.role != "admin"):
        raise HTTPException(409, "No puedes desactivar tu cuenta ni quitarte la administración")
    account = db.scalar(select(User).where(User.id == user_id).with_for_update())
    if not account:
        raise HTTPException(404, "Cuenta inexistente")
    before = public_user(account)
    account.role, account.active = body.role, int(body.active)
    if before["role"] != body.role or before["active"] != body.active:
        revoke(db, account.id)
        if not body.active:
            for device in db.scalars(select(Device).where(Device.owner_id == account.id)):
                device.token_digest = digest(secrets.token_urlsafe(48))
        audit(
            db,
            user.id,
            account,
            "user_updated",
            {
                "before": {"role": before["role"], "active": before["active"]},
                "after": {"role": body.role, "active": body.active},
            },
        )
    db.commit()
    return public_user(account)


@router.post("/admin/users/{user_id}/recovery", status_code=202)
def admin_recovery(
    user_id: str,
    request: Request,
    tasks: BackgroundTasks,
    user=Depends(administrator),
    db: Session = Depends(get_db),
    language=Depends(request_language),
):
    account = db.get(User, user_id)
    if not account:
        raise HTTPException(404, "Cuenta inexistente")
    return start_recovery(db, account.email, request, tasks, language, user.id)


@router.get("/admin/events")
def account_events(
    offset: int = Query(default=0, ge=0), user=Depends(administrator), db: Session = Depends(get_db)
):
    rows = db.scalars(
        select(AccountEvent)
        .order_by(AccountEvent.created_at.desc(), AccountEvent.id)
        .offset(offset)
        .limit(101)
    ).all()
    return {
        "items": [
            {
                "id": e.id,
                "actor_id": e.actor_id,
                "user_id": e.user_id,
                "email": db.get(User, e.user_id).email,
                "kind": e.kind,
                "data": e.data,
                "created_at": e.created_at,
            }
            for e in rows[:100]
        ],
        "has_more": len(rows) > 100,
    }


@router.get("/admin/email-deliveries")
def email_deliveries(user=Depends(administrator), db: Session = Depends(get_db)):
    rows = db.scalars(select(EmailDelivery).order_by(EmailDelivery.created_at.desc()).limit(50))
    return {"items": [public_delivery(row) for row in rows]}


def public_delivery(row):
    return {"id": row.id, "provider": row.provider, "purpose": row.purpose, "status": row.status,
            "http_status": row.http_status, "created_at": row.created_at, "updated_at": row.updated_at,
            "can_refresh": row.provider == "resend" and bool(row.provider_id)}


def refresh_delivery(db, row):
    """Retrieve delivery status only. Provider response bodies/reset links are never persisted."""
    config = settings()
    if row.provider != "resend" or not row.provider_id or not recovery_available():
        raise HTTPException(409, "No hay un recibo de Resend disponible")
    try:
        response = httpx.get("https://api.resend.com/emails/" + row.provider_id,
                            headers={"Authorization": "Bearer " + config.resend_api_key.get_secret_value()}, timeout=10)
        response.raise_for_status()
        payload = response.json()
        allowed = {"sent", "delivered", "delivery_delayed", "bounced", "complained", "opened", "clicked",
                   "scheduled", "canceled", "failed", "suppressed"}
        if not isinstance(payload, dict) or payload.get("id") != row.provider_id or payload.get("last_event") not in allowed:
            raise ValueError("Invalid delivery status receipt")
        row.status, row.updated_at = payload["last_event"], time.time()
        db.commit()
    except Exception as exc:
        log.warning("Resend status retrieval failed: %s", type(exc).__name__)
        restricted = False
        if isinstance(exc, httpx.HTTPStatusError):
            try:
                payload = exc.response.json()
                restricted = isinstance(payload, dict) and payload.get("name") == "restricted_api_key"
            except ValueError:
                pass
        detail = ("La clave de Resend permite enviar, pero no consultar recibos" if restricted
                  else "No se pudo consultar el estado de Resend")
        failure = HTTPException(502, detail)
        failure.provider_http_status = exc.response.status_code if isinstance(exc, httpx.HTTPStatusError) else None
        failure.provider_error_code = "restricted_api_key" if restricted else None
        raise failure from None
    return public_delivery(row)


@router.post("/admin/email-deliveries/{delivery_id}/refresh")
def refresh_email_delivery(delivery_id: str, user=Depends(administrator), db: Session = Depends(get_db)):
    row = db.get(EmailDelivery, delivery_id)
    if not row:
        raise HTTPException(404, "Recibo de correo inexistente")
    return refresh_delivery(db, row)
