import hashlib
import secrets
from datetime import datetime, timedelta, timezone

import jwt
from pwdlib import PasswordHash

from app.config import Settings

password_hash = PasswordHash.recommended()


def hash_password(password: str) -> str:
    if len(password) < 12 or len(password) > 128:
        raise ValueError("Password must be between 12 and 128 characters")
    return password_hash.hash(password)


def verify_password(password: str, encoded: str) -> bool:
    try:
        return password_hash.verify(password, encoded)
    except Exception:
        return False


def new_verification_token() -> str:
    return secrets.token_urlsafe(32)


def digest_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def create_access_token(user_id: str, role: str, settings: Settings) -> str:
    now = datetime.now(timezone.utc)
    return jwt.encode(
        {"sub": user_id, "role": role, "iat": now, "exp": now + timedelta(minutes=settings.access_token_minutes)},
        settings.jwt_secret,
        algorithm="HS256",
    )


def decode_access_token(token: str, settings: Settings) -> dict:
    return jwt.decode(token, settings.jwt_secret, algorithms=["HS256"])
