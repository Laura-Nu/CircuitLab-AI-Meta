import hashlib
import hmac
import secrets
import time
from fastapi import Depends, HTTPException, Request, Response
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session
from app.config import settings
from app.db import AuthSession, Token, User, get_db, uid

bearer = HTTPBearer(auto_error=False)


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def hash_password(password):
    salt = secrets.token_hex(16)
    value = hashlib.scrypt(password.encode(), salt=salt.encode(), n=16384, r=8, p=1).hex()
    return f"{salt}:{value}"


def verify_password(password, stored):
    salt, expected = stored.split(":")
    actual = hashlib.scrypt(password.encode(), salt=salt.encode(), n=16384, r=8, p=1).hex()
    return hmac.compare_digest(actual, expected)


COOKIE = "circuitlab_refresh"
COOKIE_PATH = "/api/v1/auth"


def browser_origin(request: Request):
    if request.headers.get("origin", "").rstrip("/") != settings().app_origin.rstrip("/"):
        raise HTTPException(403, "Origen no autorizado")


def session_payload(session):
    return {"idle_expires_at": session.idle_expires, "idle_timeout_seconds": settings().session_idle_minutes * 60}


def set_refresh_cookie(response: Response, raw, deadline):
    response.set_cookie(COOKIE, raw, max_age=max(0, int(deadline - time.time())),
                        httponly=True, secure=settings().app_env == "production",
                        samesite="strict", path=COOKIE_PATH)


def authentication_response(result, response, web=False):
    if web:
        set_refresh_cookie(response, result.pop("refresh_token"), result["idle_expires_at"])
    return result


def issue_tokens(db, user_id, session=None, browser_refresh=None):
    now = time.time()
    if session is None:
        session = AuthSession(id=uid(), user_id=user_id, last_activity=now,
                              idle_expires=now + settings().session_idle_minutes * 60)
        db.add(session)
        db.flush()
    result = {"token_type": "bearer", **session_payload(session)}
    for kind, ttl in [
        ("access", settings().access_token_ttl_minutes * 60),
        ("refresh", settings().refresh_token_ttl_days * 86400),
    ]:
        if kind == "refresh" and browser_refresh:
            result["refresh_token"] = browser_refresh
            continue
        raw = secrets.token_urlsafe(48)
        db.add(Token(digest=digest(raw), user_id=user_id, kind=kind,
                     expires=min(now + ttl, session.idle_expires), auth_session_id=session.id))
        result[f"{kind}_token"] = raw
    result["expires_in"] = settings().access_token_ttl_minutes * 60
    return result


def current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer), db: Session = Depends(get_db)
):
    token = db.get(Token, digest(credentials.credentials)) if credentials else None
    if not token or token.kind != "access" or token.expires <= time.time():
        raise HTTPException(401, "Credencial inválida o vencida")
    session = db.get(AuthSession, token.auth_session_id) if token.auth_session_id else None
    if not session or session.idle_expires <= time.time():
        raise HTTPException(401, "Credencial inválida o vencida")
    user = db.get(User, token.user_id)
    if not user or not user.active:
        raise HTTPException(401, "Credencial inválida o vencida")
    return user


def administrator(user=Depends(current_user)):
    if user.role != "admin":
        raise HTTPException(403, "Se requiere una cuenta administradora")
    return user
