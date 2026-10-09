from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest

from app.analysis import Candle, analyze, atr, rsi, sma
from app.entitlements import entitlement, extend_subscription
from app.schemas import AdminSettingsRequest
from app.security import create_access_token, decode_access_token, digest_token, hash_password, new_verification_token, verify_password
from app.config import get_settings


def test_indicators_have_defined_values():
    assert sma([1, 2, 3, 4], 3) == 3
    assert sma([1, 2], 3) is None
    assert rsi([float(i) for i in range(20)]) == 100
    bars = [Candle(10, 12, 9, 11, 5) for _ in range(20)]
    assert atr(bars) == 3


def _trending_bars():
    higher = [Candle(100 + i, 101 + i, 99 + i, 100 + i, 100) for i in range(60)]
    fifteen_minute = []
    for i in range(39):
        close = 110 + (0.1 if i % 2 else 0)
        fifteen_minute.append(Candle(close - 0.05, close + 0.2, close - 0.2, close, 10))
    fifteen_minute.append(Candle(110, 111.5, 109.9, 111.2, 30))
    return higher, higher.copy(), higher.copy(), fifteen_minute


def test_analysis_emits_only_confluence_at_or_above_threshold():
    daily, four_hour, hourly, fifteen_minute = _trending_bars()
    candidate = analyze(daily, four_hour, hourly, fifteen_minute)
    assert candidate is not None
    assert candidate["score"] >= 65
    assert candidate["direction"] == "long"
    assert candidate["directionTimeframes"] == ["1d", "4h"]
    assert candidate["triggerTimeframes"] == ["1h", "15m"]
    assert candidate["stopLoss"] < candidate["entry"] < candidate["tp1"]
    assert analyze(daily[:20], four_hour, hourly, fifteen_minute) is None


def test_analysis_rejects_candidate_below_confluence_threshold():
    daily, four_hour, _, fifteen_minute = _trending_bars()
    hourly = [Candle(110, 110.1, 109.9, 110, 100) for _ in range(60)]
    fifteen_minute[-1] = Candle(111, 111.1, 109.8, 110, 10)
    assert analyze(daily, four_hour, hourly, fifteen_minute) is None


def test_daily_and_four_hour_direction_must_agree():
    daily, _, hourly, fifteen_minute = _trending_bars()
    four_hour = [Candle(200 - i, 201 - i, 199 - i, 200 - i, 100) for i in range(60)]
    assert analyze(daily, four_hour, hourly, fifteen_minute) is None


def test_entitlement_boundary_is_server_utc_and_exclusive():
    now = datetime(2026, 1, 1, tzinfo=timezone.utc)
    user = SimpleNamespace(trial_started_at=now, paid_until=None)
    active = entitlement(user, now + timedelta(days=5) - timedelta(microseconds=1))
    expired = entitlement(user, now + timedelta(days=5))
    assert active["active"]
    assert not expired["active"]
    assert active["expiresAt"] == now + timedelta(days=5)


def test_manual_subscription_starts_after_access_ends():
    now = datetime(2026, 1, 1, tzinfo=timezone.utc)
    user = SimpleNamespace(trial_started_at=now, paid_until=now + timedelta(days=40))
    result = extend_subscription(user, 1, now)
    assert result == datetime(2026, 3, 10, tzinfo=timezone.utc)
    assert user.paid_until == result


def test_password_and_bearer_token_security_basics():
    with pytest.raises(ValueError):
        hash_password("short")
    encoded = hash_password("a-long-unique-test-password")
    assert encoded != "a-long-unique-test-password"
    assert verify_password("a-long-unique-test-password", encoded)
    assert not verify_password("incorrect-password", encoded)
    raw = new_verification_token()
    assert raw != digest_token(raw)
    token = create_access_token("user-id", "user", get_settings())
    assert decode_access_token(token, get_settings())["sub"] == "user-id"


def test_admin_settings_cannot_lower_score_threshold_or_enable_unknown_provider():
    with pytest.raises(Exception):
        AdminSettingsRequest(minSignalScore=64, activeExchanges=["binance"])
    with pytest.raises(Exception):
        AdminSettingsRequest(minSignalScore=65, activeExchanges=["imaginary"])
    assert AdminSettingsRequest(minSignalScore=65, activeExchanges=["okx"]).minSignalScore == 65
