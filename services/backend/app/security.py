import hashlib
import hmac
import secrets
import time
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session
from app.config import settings
from app.db import Token, User, get_db

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


def issue_tokens(db, user_id):
    result = {"token_type": "bearer"}
    for kind, ttl in [
        ("access", settings().access_token_ttl_minutes * 60),
        ("refresh", settings().refresh_token_ttl_days * 86400),
    ]:
        raw = secrets.token_urlsafe(48)
        db.add(Token(digest=digest(raw), user_id=user_id, kind=kind, expires=time.time() + ttl))
        result[f"{kind}_token"] = raw
    result["expires_in"] = settings().access_token_ttl_minutes * 60
    return result


def current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer), db: Session = Depends(get_db)
):
    token = db.get(Token, digest(credentials.credentials)) if credentials else None
    if not token or token.kind != "access" or token.expires < time.time():
        raise HTTPException(401, "Credencial inválida o vencida")
    user = db.get(User, token.user_id)
    if not user or not user.active:
        raise HTTPException(401, "Credencial inválida o vencida")
    return user


def administrator(user=Depends(current_user)):
    if user.role != "admin":
        raise HTTPException(403, "Se requiere una cuenta administradora")
    return user
