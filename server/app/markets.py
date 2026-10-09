import asyncio
from dataclasses import dataclass
from datetime import datetime, timezone

import httpx


@dataclass
class ProviderResult:
    exchange: str
    markets: list[dict]
    error: str | None = None


TIMEOUT = httpx.Timeout(8.0, connect=4.0)


async def _json(client: httpx.AsyncClient, url: str, params: dict | None = None):
    response = await client.get(url, params=params)
    response.raise_for_status()
    return response.json()


async def _binance(client: httpx.AsyncClient) -> list[dict]:
    tickers, info = await asyncio.gather(
        _json(client, "https://fapi.binance.com/fapi/v1/ticker/24hr"),
        _json(client, "https://fapi.binance.com/fapi/v1/exchangeInfo"),
    )
    eligible = {
        row["symbol"]: row for row in info.get("symbols", [])
        if row.get("contractType") == "PERPETUAL"
        and row.get("quoteAsset") == "USDT"
        and row.get("status") == "TRADING"
    }
    output = []
    for row in tickers:
        market = eligible.get(row.get("symbol"))
        if market:
            output.append({
                "exchange": "binance", "symbol": market["symbol"],
                "base": market["baseAsset"], "quote": "USDT",
                "score": _liquidity_score(row.get("quoteVolume")),
                "volume": _float(row.get("quoteVolume")),
            })
    return output


async def _bybit(client: httpx.AsyncClient) -> list[dict]:
    tickers, instruments = await asyncio.gather(
        _json(client, "https://api.bybit.com/v5/market/tickers", {"category": "linear"}),
        _json(client, "https://api.bybit.com/v5/market/instruments-info", {"category": "linear", "limit": 1000}),
    )
    if tickers.get("retCode") != 0 or instruments.get("retCode") != 0:
        raise RuntimeError("Bybit returned a non-zero result code")
    instrument_rows = instruments.get("result", {}).get("list", [])
    cursor = instruments.get("result", {}).get("nextPageCursor", "")
    while cursor:
        page = await _json(client, "https://api.bybit.com/v5/market/instruments-info",
                           {"category": "linear", "limit": 1000, "cursor": cursor})
        if page.get("retCode") != 0:
            raise RuntimeError("Bybit returned a non-zero result code")
        instrument_rows.extend(page.get("result", {}).get("list", []))
        cursor = page.get("result", {}).get("nextPageCursor", "")
    eligible = {
        row["symbol"]: row for row in instrument_rows
        if row.get("quoteCoin") == "USDT"
        and row.get("contractType") == "LinearPerpetual"
        and row.get("status") == "Trading"
    }
    output = []
    for row in tickers.get("result", {}).get("list", []):
        market = eligible.get(row.get("symbol"))
        if market:
            output.append({
                "exchange": "bybit", "symbol": market["symbol"],
                "base": market["baseCoin"], "quote": "USDT",
                "score": _liquidity_score(row.get("turnover24h")),
                "volume": _float(row.get("turnover24h")),
            })
    return output


async def _okx(client: httpx.AsyncClient) -> list[dict]:
    result = await _json(client, "https://www.okx.com/api/v5/market/tickers", {"instType": "SWAP"})
    if result.get("code") != "0":
        raise RuntimeError("OKX returned a non-zero result code")
    output = []
    for row in result.get("data", []):
        inst_id = row.get("instId", "")
        pieces = inst_id.split("-")
        if len(pieces) == 3 and pieces[1] == "USDT" and pieces[2] == "SWAP":
            output.append({
                "exchange": "okx", "symbol": inst_id, "base": pieces[0], "quote": "USDT",
                "score": _liquidity_score(row.get("volCcy24h")),
                "volume": _float(row.get("volCcy24h")),
            })
    return output


def _float(value) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _liquidity_score(volume) -> int:
    # A sortable market-activity indicator, not an expected-return or signal score.
    import math
    value = max(0.0, _float(volume))
    return min(100, int(math.log10(value + 1) * 10))


async def fetch_candles(exchange: str, symbol: str, timeframe: str, limit: int = 120) -> list[list]:
    intervals = {
        "binance": {"1d": "1d", "4h": "4h", "1h": "1h", "15m": "15m"},
        "bybit": {"1d": "D", "4h": "240", "1h": "60", "15m": "15"},
        "okx": {"1d": "1D", "4h": "4H", "1h": "1H", "15m": "15m"},
    }
    duration_ms = {"1d": 86_400_000, "4h": 14_400_000, "1h": 3_600_000, "15m": 900_000}[timeframe]
    now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        if exchange == "binance":
            result = await _json(client, "https://fapi.binance.com/fapi/v1/klines",
                                 {"symbol": symbol, "interval": intervals[exchange][timeframe], "limit": limit})
            return [row for row in result if int(row[6]) < now_ms]
        if exchange == "bybit":
            result = await _json(client, "https://api.bybit.com/v5/market/kline",
                                 {"category": "linear", "symbol": symbol,
                                  "interval": intervals[exchange][timeframe], "limit": limit})
            if result.get("retCode") != 0:
                raise RuntimeError("Bybit returned a non-zero result code")
            rows = list(reversed(result.get("result", {}).get("list", [])))
            return [row for row in rows if int(row[0]) + duration_ms <= now_ms]
        if exchange == "okx":
            result = await _json(client, "https://www.okx.com/api/v5/market/candles",
                                 {"instId": symbol, "bar": intervals[exchange][timeframe], "limit": str(limit)})
            if result.get("code") != "0":
                raise RuntimeError("OKX returned a non-zero result code")
            rows = list(reversed(result.get("data", [])))
            return [row for row in rows if len(row) > 8 and row[8] == "1"]
    raise ValueError("Unsupported exchange")


async def get_markets(query: str = "") -> tuple[list[dict], dict[str, str]]:
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        providers = {
            "binance": _binance(client),
            "bybit": _bybit(client),
            "okx": _okx(client),
        }
        responses = await asyncio.gather(*providers.values(), return_exceptions=True)
    items: list[dict] = []
    status: dict[str, str] = {}
    for exchange, response in zip(providers, responses):
        if isinstance(response, Exception):
            status[exchange] = "unavailable"
            continue
        status[exchange] = "ok"
        items.extend(response)
    needle = query.strip().upper()
    if needle:
        items = [item for item in items if needle in item["symbol"] or needle in item["base"]]
    items.sort(key=lambda item: item["volume"], reverse=True)
    return [{key: value for key, value in item.items() if key != "volume"} for item in items], status
