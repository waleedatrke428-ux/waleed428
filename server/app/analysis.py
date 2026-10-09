from dataclasses import dataclass


@dataclass
class Candle:
    open: float
    high: float
    low: float
    close: float
    volume: float


def parse_candles(exchange: str, raw: list[list]) -> list[Candle]:
    result = []
    for row in raw:
        try:
            if exchange in {"binance", "bybit", "okx"}:
                values = row[1:6]
            else:
                continue
            result.append(Candle(*(float(value) for value in values)))
        except (TypeError, ValueError, IndexError):
            continue
    return result


def sma(values: list[float], period: int) -> float | None:
    if len(values) < period:
        return None
    return sum(values[-period:]) / period


def rsi(closes: list[float], period: int = 14) -> float | None:
    if len(closes) <= period:
        return None
    changes = [closes[index] - closes[index - 1] for index in range(len(closes) - period, len(closes))]
    gains = sum(max(change, 0) for change in changes) / period
    losses = sum(max(-change, 0) for change in changes) / period
    if losses == 0:
        return 100.0 if gains else 50.0
    return 100 - (100 / (1 + gains / losses))


def atr(candles: list[Candle], period: int = 14) -> float | None:
    if len(candles) <= period:
        return None
    true_ranges = []
    for index in range(len(candles) - period, len(candles)):
        candle = candles[index]
        previous_close = candles[index - 1].close
        true_ranges.append(max(candle.high - candle.low, abs(candle.high - previous_close),
                               abs(candle.low - previous_close)))
    return sum(true_ranges) / period


def _trend_direction(candles: list[Candle]) -> str | None:
    if len(candles) < 30:
        return None
    closes = [item.close for item in candles]
    fast, slow = sma(closes, 20), sma(closes, 50)
    if slow is None:
        slow = sma(closes, 30)
    if fast is None or slow is None:
        return None
    if fast > slow and closes[-1] > fast:
        return "long"
    if fast < slow and closes[-1] < fast:
        return "short"
    return None


def analyze(daily: list[Candle], four_hour: list[Candle], hourly: list[Candle],
            fifteen_minute: list[Candle]) -> dict | None:
    """1D/4H consensus sets direction; 1H/15m confirm structure and trigger. Score is not probability."""
    if any(len(frame) < 30 for frame in (daily, four_hour, hourly, fifteen_minute)):
        return None
    daily_direction = _trend_direction(daily)
    four_hour_direction = _trend_direction(four_hour)
    if daily_direction is None or four_hour_direction != daily_direction:
        return None
    direction = daily_direction
    hourly_aligned = _trend_direction(hourly) == direction
    closes = [item.close for item in fifteen_minute]
    recent = fifteen_minute[-21:-1]
    if not recent:
        return None
    support = min(item.low for item in recent)
    resistance = max(item.high for item in recent)
    trigger = fifteen_minute[-1]
    momentum = rsi(closes)
    volatility = atr(fifteen_minute)
    if momentum is None or volatility is None or volatility <= 0:
        return None

    score = 30
    reasons = ["1D and 4H market direction aligned"]
    if hourly_aligned:
        score += 15
        reasons.append("1H trigger context aligned")
    level = support if direction == "long" else resistance
    if abs(trigger.close - level) <= volatility * 1.5:
        score += 15
        reasons.append("15m trigger near recent support/resistance")
    if trigger.close > trigger.open if direction == "long" else trigger.close < trigger.open:
        score += 10
        reasons.append("15m trigger candle aligned")
    average_volume = sum(item.volume for item in fifteen_minute[-21:-1]) / 20
    if average_volume > 0 and trigger.volume >= average_volume * 1.2:
        score += 10
        reasons.append("15m trigger volume expansion")
    if (direction == "long" and 45 <= momentum <= 68) or (direction == "short" and 32 <= momentum <= 55):
        score += 10
        reasons.append("15m momentum in directional confirmation range")
    if (direction == "long" and trigger.close > resistance) or (direction == "short" and trigger.close < support):
        score += 10
        reasons.append("15m recent structure break")
    score = min(100, score)
    if score < 65:
        return None

    entry = trigger.close
    stop = (min(support, entry - volatility * 1.5) if direction == "long"
            else max(resistance, entry + volatility * 1.5))
    risk = abs(entry - stop)
    if risk <= 0:
        return None
    sign = 1 if direction == "long" else -1
    return {
        "direction": direction, "score": score, "timeframe": "15m",
        "directionTimeframes": ["1d", "4h"], "triggerTimeframes": ["1h", "15m"],
        "entry": entry, "stopLoss": stop,
        "tp1": entry + sign * risk, "tp2": entry + sign * risk * 2,
        "tp3": entry + sign * risk * 3,
        "rationale": reasons,
    }
