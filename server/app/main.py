import asyncio
import logging
import time
from contextlib import asynccontextmanager, suppress
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import jwt
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.analysis import analyze, parse_candles
from app.config import Settings, get_settings
from app.db import SessionLocal, get_db
from app.entitlements import as_utc, entitlement, extend_subscription
from app.mailer import send_verification_email
from app.markets import fetch_candles, get_markets
from app.models import (EnteredTrade, PlatformSettings, Signal, SignalEvent, User, UserSettings,
                        VerificationToken, utcnow)
from app.news import get_news
from app.schemas import (AdminSettingsRequest, EnteredRequest, LoginRequest, RegisterRequest,
                         SettingsRequest, SubscriptionRequest, VerifyRequest, VerifyRequestEmail)
from app.security import (create_access_token, decode_access_token, digest_token, hash_password,
                          new_verification_token, verify_password)

logger = logging.getLogger("signal_platform")
bearer = HTTPBearer(auto_error=False)
RATE_WINDOW_SECONDS = 60
RATE_LIMIT = 10
_rate_state: dict[str, list[float]] = {}
_scan_offsets: dict[str, int] = {}


def _settings_row(db: Session) -> PlatformSettings:
    row = db.get(PlatformSettings, 1)
    if row is None:
        row = PlatformSettings(id=1)
        db.add(row)
        db.commit()
        db.refresh(row)
    return row


def _event(db: Session, signal_id: str, kind: str, details: dict | None = None) -> None:
    if db.scalar(select(SignalEvent.id).where(
        SignalEvent.signal_id == signal_id, SignalEvent.event_type == kind
    )):
        return
    db.add(SignalEvent(signal_id=signal_id, event_type=kind, details=details or {}))


def _serialize_signal(row: Signal) -> dict:
    return {
        "id": row.id, "exchange": row.exchange, "symbol": row.symbol, "direction": row.direction,
        "score": row.score, "scoreType": "technical_confluence", "timeframe": row.timeframe, "directionTimeframes": ["1d", "4h"], "triggerTimeframes": ["1h", "15m"],
        "entry": row.entry, "stopLoss": row.stop_loss, "takeProfits": [row.tp1, row.tp2, row.tp3],
        "status": row.status, "rationale": row.rationale.split("|"), "createdAt": row.created_at,
        "updatedAt": row.updated_at,
    }


async def _scan_once() -> None:
    db = SessionLocal()
    try:
        config = _settings_row(db)
        items, _ = await get_markets()
        shortlist = []
        for exchange in config.active_exchanges:
            universe = [item for item in items if item["exchange"] == exchange]
            if not universe:
                continue
            offset = _scan_offsets.get(exchange, 0) % len(universe)
            batch = universe[offset:offset + 3]
            if len(batch) < min(3, len(universe)):
                batch.extend(universe[:3 - len(batch)])
            shortlist.extend(batch)
            _scan_offsets[exchange] = (offset + len(batch)) % len(universe)
        requests = []
        for market in shortlist:
            requests.append(asyncio.gather(
                fetch_candles(market["exchange"], market["symbol"], "1d"),
                fetch_candles(market["exchange"], market["symbol"], "4h"),
                fetch_candles(market["exchange"], market["symbol"], "1h"),
                fetch_candles(market["exchange"], market["symbol"], "15m"),
                return_exceptions=True,
            ))
        results = await asyncio.gather(*requests) if requests else []
        now = utcnow()
        for market, result in zip(shortlist, results):
            if any(isinstance(bars, Exception) for bars in result):
                continue
            candidate = analyze(
                parse_candles(market["exchange"], result[0]),
                parse_candles(market["exchange"], result[1]),
                parse_candles(market["exchange"], result[2]),
                parse_candles(market["exchange"], result[3]),
            )
            if not candidate or candidate["score"] < max(65, config.min_signal_score):
                continue
            active = db.scalar(select(Signal).where(
                Signal.exchange == market["exchange"], Signal.symbol == market["symbol"],
                Signal.status == "active"
            ).order_by(Signal.created_at.desc()))
            if active and active.direction != candidate["direction"]:
                active.status = "reversed"
                active.updated_at = now
                _event(db, active.id, "reversal", {"reversedTo": candidate["direction"]})
                active = None
            if active:
                await _monitor_signal(db, active, market["exchange"], now)
                continue
            row = Signal(
                exchange=market["exchange"], symbol=market["symbol"], direction=candidate["direction"],
                score=candidate["score"], timeframe=candidate["timeframe"], entry=candidate["entry"],
                stop_loss=candidate["stopLoss"], tp1=candidate["tp1"], tp2=candidate["tp2"],
                tp3=candidate["tp3"], rationale="|".join(candidate["rationale"]),
                created_at=now, updated_at=now,
            )
            db.add(row)
            db.flush()
            _event(db, row.id, "signal_created", {"score": row.score, "scoreType": "technical_confluence"})
        # Continue monitoring active symbols even where they are no longer in the top volume shortlist.
        active_rows = db.scalars(select(Signal).where(Signal.status == "active")).all()
        visited = {(item["exchange"], item["symbol"]) for item in shortlist}
        for row in active_rows:
            if (row.exchange, row.symbol) in visited:
                continue
            await _monitor_signal(db, row, row.exchange, now)
        db.commit()
    except Exception:
        db.rollback()
        logger.exception("Signal scan failed")
    finally:
        db.close()


async def _monitor_signal(db: Session, row: Signal, exchange: str, now: datetime) -> None:
    try:
        bars = parse_candles(exchange, await fetch_candles(exchange, row.symbol, "15m", limit=3))
    except Exception:
        return
    if not bars:
        return
    candle = bars[-1]
    if ((row.direction == "long" and candle.low <= row.stop_loss)
            or (row.direction == "short" and candle.high >= row.stop_loss)):
        row.status, row.updated_at = "stopped", now
        _event(db, row.id, "stop_loss", {"price": row.stop_loss})
        return
    for number, target in enumerate((row.tp1, row.tp2, row.tp3), start=1):
        if db.scalar(select(SignalEvent.id).where(
            SignalEvent.signal_id == row.id, SignalEvent.event_type == f"take_profit_{number}"
        )):
            continue
        hit = candle.high >= target if row.direction == "long" else candle.low <= target
        if hit:
            _event(db, row.id, f"take_profit_{number}", {"price": target})
            row.updated_at = now
            if number == 3:
                row.status = "target3"
            break
    if not db.scalar(select(SignalEvent.id).where(
        SignalEvent.signal_id == row.id, SignalEvent.event_type == "entry"
    )):
        hit = candle.low <= row.entry <= candle.high
        if hit:
            _event(db, row.id, "entry", {"price": row.entry})


@asynccontextmanager
async def lifespan(_: FastAPI):
    task = asyncio.create_task(_scanner_loop())
    yield
    task.cancel()
    with suppress(asyncio.CancelledError):
        await task


async def _scanner_loop() -> None:
    while True:
        await _scan_once()
        await asyncio.sleep(300)


app = FastAPI(title="Informational Futures Signals API", version="1.0.0", lifespan=lifespan)
origins = [origin.strip() for origin in get_settings().allowed_origins.split(",") if origin.strip()]
if origins:
    app.add_middleware(CORSMiddleware, allow_origins=origins, allow_credentials=True,
                       allow_methods=["GET", "POST", "PUT"], allow_headers=["Authorization", "Content-Type", "X-Timezone"])
admin_candidates = (Path(__file__).resolve().parents[2] / "admin",
                    Path(__file__).resolve().parents[1] / "admin")
admin_directory = next((candidate for candidate in admin_candidates if candidate.is_dir()), None)
if admin_directory is not None:
    app.mount("/admin", StaticFiles(directory=admin_directory, html=True), name="admin")


@app.middleware("http")
async def rate_limit(request: Request, call_next):
    path = request.url.path
    now = time.monotonic()
    host = request.client.host if request.client else "unknown"
    auth_request = path.startswith("/api/auth/")
    key = f"{host}:{'auth' if auth_request else 'api'}"
    limit = RATE_LIMIT if auth_request else 120
    recent = [stamp for stamp in _rate_state.get(key, []) if now - stamp < RATE_WINDOW_SECONDS]
    if len(recent) >= limit:
        return JSONResponse(status_code=429, content={"detail": "Too many requests"})
    recent.append(now)
    _rate_state[key] = recent
    if len(_rate_state) > 10_000:
        _rate_state.clear()
    return await call_next(request)


async def current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
) -> User:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(status_code=401, detail="Bearer token required", headers={"WWW-Authenticate": "Bearer"})
    try:
        claims = decode_access_token(credentials.credentials, settings)
        user = db.get(User, claims["sub"])
    except (jwt.PyJWTError, KeyError, TypeError):
        user = None
    if user is None or user.email_verified_at is None:
        raise HTTPException(status_code=401, detail="Invalid or unverified account")
    return user


def admin_user(user: User = Depends(current_user)) -> User:
    if user.role != "admin":
        raise HTTPException(status_code=403, detail="Administrator access required")
    return user


def active_user(user: User = Depends(current_user)) -> User:
    if not entitlement(user)["active"]:
        raise HTTPException(status_code=403, detail="Trial or subscription access has expired")
    return user


def _verification(user: User, db: Session, settings: Settings) -> bool:
    raw = new_verification_token()
    db.add(VerificationToken(
        user_id=user.id, token_hash=digest_token(raw),
        expires_at=utcnow() + timedelta(hours=24),
    ))
    db.commit()
    try:
        return send_verification_email(user.email, raw, settings)
    except Exception:
        logger.warning("Verification email could not be sent")
        return False


@app.get("/health")
def health(db: Session = Depends(get_db)):
    from sqlalchemy import text
    db.execute(text("SELECT 1"))
    return {"status": "ok", "serverTime": utcnow()}


@app.post("/api/auth/register", status_code=201)
def register(payload: RegisterRequest, db: Session = Depends(get_db),
             settings: Settings = Depends(get_settings)):
    email = str(payload.email).lower()
    if db.scalar(select(User.id).where((User.email == email) | (User.phone == payload.phone.strip()))):
        raise HTTPException(status_code=409, detail="Email or phone is already registered")
    try:
        encoded_password = hash_password(payload.password)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    user = User(email=email, phone=payload.phone.strip(), password_hash=encoded_password,
                role="admin" if email in settings.configured_admin_emails else "user",
                trial_started_at=utcnow())
    user.settings = UserSettings()
    db.add(user)
    try:
        db.commit()
        db.refresh(user)
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(status_code=409, detail="Email or phone is already registered") from exc
    sent = _verification(user, db, settings)
    return {"id": user.id, "email": user.email, "verificationEmailSent": sent,
            "message": "Verify your email before logging in. If email delivery is not configured, contact the administrator."}


@app.post("/api/auth/verify")
def verify_email(payload: VerifyRequest, db: Session = Depends(get_db)):
    token = db.scalar(select(VerificationToken).where(VerificationToken.token_hash == digest_token(payload.token)))
    if token is None or as_utc(token.expires_at) <= utcnow():
        raise HTTPException(status_code=400, detail="Verification token is invalid or expired")
    user = db.get(User, token.user_id)
    if user is None:
        raise HTTPException(status_code=400, detail="Verification token is invalid or expired")
    user.email_verified_at = utcnow()
    db.delete(token)
    db.commit()
    return {"verified": True}


@app.post("/api/auth/verify/request")
def request_verification(payload: VerifyRequestEmail, db: Session = Depends(get_db),
                         settings: Settings = Depends(get_settings)):
    user = db.scalar(select(User).where(User.email == str(payload.email).lower()))
    if user is not None and user.email_verified_at is None:
        sent = _verification(user, db, settings)
        return {"accepted": True, "verificationEmailSent": sent}
    return {"accepted": True}


@app.post("/api/auth/login")
def login(payload: LoginRequest, db: Session = Depends(get_db),
          settings: Settings = Depends(get_settings)):
    user = db.scalar(select(User).where(User.email == str(payload.email).lower()))
    if user is None or not verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid email or password")
    if user.email_verified_at is None:
        raise HTTPException(status_code=403, detail="Email verification required")
    token = create_access_token(user.id, user.role, settings)
    return {"accessToken": token, "tokenType": "Bearer", "expiresIn": settings.access_token_minutes * 60,
            "id": user.id, "email": user.email, "role": user.role,
            "user": {"id": user.id, "email": user.email, "role": user.role}}


@app.get("/api/me/entitlement")
def my_entitlement(user: User = Depends(current_user)):
    result = entitlement(user)
    current = result["serverTime"]
    result["remainingSeconds"] = max(0, int((result["expiresAt"] - current).total_seconds()))
    return result


@app.get("/api/signals")
async def signals(_: User = Depends(active_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(Signal).where(Signal.status == "active")
                      .order_by(Signal.created_at.desc()).limit(200)).all()
    return {"items": [_serialize_signal(row) for row in rows],
            "scoreMeaning": "technical confluence score out of 100; not probability or win rate",
            "disclaimer": "Informational only; not investment advice. No exchange orders are placed."}


@app.get("/api/signals/{signal_id}/events")
def signal_events(signal_id: str, _: User = Depends(active_user), db: Session = Depends(get_db)):
    if db.get(Signal, signal_id) is None:
        raise HTTPException(status_code=404, detail="Signal not found")
    events = db.scalars(select(SignalEvent).where(SignalEvent.signal_id == signal_id)
                        .order_by(SignalEvent.observed_at.asc())).all()
    return {"items": [{"type": e.event_type, "observedAt": e.observed_at, "details": e.details}
                      for e in events],
            "delivery": {"fcmConfigured": False, "message": "Event data is available; push delivery is not implemented."}}


@app.get("/api/markets")
async def markets(query: str = Query(default="", max_length=80)):
    result, providers = await get_markets(query)
    configdb = SessionLocal()
    try:
        active = _settings_row(configdb).active_exchanges
        result = [item for item in result if item["exchange"] in active]
    finally:
        configdb.close()
    return {"items": result, "providers": providers}


@app.get("/api/news")
async def news():
    items, providers = await get_news()
    return {"items": items, "providers": providers}


@app.post("/api/me/signals/{signal_id}/entered", status_code=201)
def enter_signal(signal_id: str, payload: EnteredRequest, user: User = Depends(active_user),
                 db: Session = Depends(get_db)):
    signal = db.get(Signal, signal_id)
    if signal is None:
        raise HTTPException(status_code=404, detail="Signal not found")
    existing = db.scalar(select(EnteredTrade).where(
        EnteredTrade.user_id == user.id, EnteredTrade.signal_id == signal_id))
    if existing:
        return {"id": existing.id, "signalId": signal_id, "enteredAt": existing.entered_at,
                "note": existing.note}
    row = EnteredTrade(user_id=user.id, signal_id=signal_id, note=payload.note)
    db.add(row)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        row = db.scalar(select(EnteredTrade).where(
            EnteredTrade.user_id == user.id, EnteredTrade.signal_id == signal_id))
    return {"id": row.id, "signalId": signal_id, "enteredAt": row.entered_at, "note": row.note}


@app.get("/api/me/journal")
def journal(user: User = Depends(active_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(EnteredTrade).where(EnteredTrade.user_id == user.id)
                      .order_by(EnteredTrade.entered_at.desc()).limit(200)).all()
    return {"items": [{"id": row.id, "signalId": row.signal_id, "note": row.note,
                       "enteredAt": row.entered_at} for row in rows]}


@app.get("/api/me/settings")
def get_my_settings(user: User = Depends(current_user), db: Session = Depends(get_db)):
    row = user.settings or UserSettings(user_id=user.id)
    if row.user_id is None:
        row.user_id = user.id
    return {"emailNotifications": row.email_notifications, "pushNotifications": row.push_notifications}


@app.put("/api/me/settings")
def put_my_settings(payload: SettingsRequest, user: User = Depends(current_user),
                    db: Session = Depends(get_db)):
    row = db.get(UserSettings, user.id)
    if row is None:
        row = UserSettings(user_id=user.id)
        db.add(row)
    row.email_notifications = payload.emailNotifications
    row.push_notifications = payload.pushNotifications
    row.fcm_token = payload.fcmToken if payload.pushNotifications else None
    db.commit()
    return {"emailNotifications": row.email_notifications, "pushNotifications": row.push_notifications,
            "pushDelivery": "not_configured"}


@app.get("/api/me/alerts")
def alerts(user: User = Depends(active_user), db: Session = Depends(get_db)):
    signal_ids = db.scalars(select(EnteredTrade.signal_id).where(EnteredTrade.user_id == user.id)).all()
    if not signal_ids:
        return {"items": [], "pushDelivery": "not_configured"}
    events = db.scalars(select(SignalEvent).where(SignalEvent.signal_id.in_(signal_ids))
                        .order_by(SignalEvent.observed_at.desc()).limit(100)).all()
    return {"items": [{"signalId": e.signal_id, "type": e.event_type, "observedAt": e.observed_at,
                       "details": e.details} for e in events], "pushDelivery": "not_configured"}


@app.get("/api/me/session-hours")
def session_hours(timezone_name: str | None = Header(default=None, alias="X-Timezone"),
                  _: User = Depends(current_user)):
    try:
        zone = ZoneInfo(timezone_name or "Europe/London")
    except (ZoneInfoNotFoundError, ValueError):
        raise HTTPException(status_code=400, detail="X-Timezone must be a valid IANA timezone")
    now = datetime.now(timezone.utc)
    london = ZoneInfo("Europe/London")
    reference_date = now.astimezone(london).date()
    opening = datetime.combine(reference_date, datetime.min.time().replace(hour=8), london)
    closing = datetime.combine(reference_date, datetime.min.time().replace(hour=17), london)
    return {"reference": "London session", "timezone": getattr(zone, "key", "Europe/London"),
            "referenceHours": {"start": "08:00", "end": "17:00", "timezone": "Europe/London"},
            "localHours": {"start": opening.astimezone(zone).strftime("%H:%M"),
                           "end": closing.astimezone(zone).strftime("%H:%M"),
                           "date": opening.astimezone(zone).date().isoformat(),
                           "startAt": opening.astimezone(zone).isoformat(),
                           "endAt": closing.astimezone(zone).isoformat()}}


@app.get("/api/admin/users")
def admin_users(limit: int = Query(default=100, ge=1, le=500), offset: int = Query(default=0, ge=0),
                _: User = Depends(admin_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(User).order_by(User.created_at.desc()).offset(offset).limit(limit)).all()
    items = []
    for user in rows:
        access = entitlement(user)
        items.append({
            "id": user.id, "email": user.email, "phone": user.phone, "role": user.role,
            "emailVerified": user.email_verified_at is not None, "createdAt": user.created_at,
            "status": "active" if access["active"] else "expired", "accessEndsAt": access["expiresAt"],
            "expiresAt": access["expiresAt"], "trialEndsAt": access["trialExpiresAt"],
            "entitlement": access,
        })
    return {"items": items}


@app.post("/api/admin/users/{user_id}/subscriptions")
def admin_extend_subscription(user_id: str, payload: SubscriptionRequest,
                              _: User = Depends(admin_user), db: Session = Depends(get_db)):
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    now = utcnow()
    old_expiry = entitlement(user, now)["expiresAt"]
    starts_at = max(now, old_expiry)
    try:
        expiry = extend_subscription(user, payload.months, now)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    db.commit()
    return {"userId": user.id, "months": payload.months, "startsAt": starts_at,
            "expiresAt": expiry, "active": True}


@app.get("/api/admin/signals")
def admin_signals(limit: int = Query(default=200, ge=1, le=500), _: User = Depends(admin_user),
                  db: Session = Depends(get_db)):
    rows = db.scalars(select(Signal).order_by(Signal.created_at.desc()).limit(limit)).all()
    return {"items": [_serialize_signal(row) for row in rows]}


@app.get("/api/admin/settings")
def get_admin_settings(_: User = Depends(admin_user), db: Session = Depends(get_db)):
    row = _settings_row(db)
    return {"minSignalScore": row.min_signal_score, "activeExchanges": row.active_exchanges,
            "minimumSignalScore": row.min_signal_score, "exchanges": row.active_exchanges,
            "settings": {"minSignalScore": row.min_signal_score, "minimumSignalScore": row.min_signal_score,
                         "activeExchanges": row.active_exchanges, "exchanges": row.active_exchanges},
            "allowedExchanges": ["binance", "bybit", "okx"]}
@app.put("/api/admin/settings")
def put_admin_settings(payload: AdminSettingsRequest, _: User = Depends(admin_user),
                       db: Session = Depends(get_db)):
    row = _settings_row(db)
    row.min_signal_score = payload.minSignalScore
    row.active_exchanges = payload.activeExchanges
    row.updated_at = utcnow()
    db.commit()
    return {"minSignalScore": row.min_signal_score, "activeExchanges": row.active_exchanges,
            "minimumSignalScore": row.min_signal_score, "exchanges": row.active_exchanges,
            "settings": {"minSignalScore": row.min_signal_score, "minimumSignalScore": row.min_signal_score,
                         "activeExchanges": row.active_exchanges, "exchanges": row.active_exchanges},
            "allowedExchanges": ["binance", "bybit", "okx"]}
