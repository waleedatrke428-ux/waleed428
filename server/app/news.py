import asyncio
import email.utils
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from urllib.parse import urlparse

import httpx

FEEDS = (
    ("CoinDesk", "https://www.coindesk.com/arc/outboundfeeds/rss/"),
    ("Cointelegraph", "https://cointelegraph.com/rss"),
)


async def get_news() -> tuple[list[dict], dict[str, str]]:
    async with httpx.AsyncClient(timeout=httpx.Timeout(8, connect=4),
                                 headers={"User-Agent": "SignalPlatform/1.0 (+public RSS reader)"}) as client:
        results = await asyncio.gather(*(client.get(url) for _, url in FEEDS), return_exceptions=True)
    items = []
    provider_status = {}
    for (expected_source, _), response in zip(FEEDS, results):
        if isinstance(response, Exception) or response.status_code != 200:
            provider_status[expected_source] = "unavailable"
            continue
        try:
            root = ET.fromstring(response.content)
            provider_status[expected_source] = "ok"
            for item in root.findall(".//item"):
                title = (item.findtext("title") or "").strip()
                link = (item.findtext("link") or "").strip()
                published = item.findtext("pubDate")
                if not title or not link or urlparse(link).scheme != "https":
                    continue
                try:
                    published_at = email.utils.parsedate_to_datetime(published) if published else None
                except (TypeError, ValueError, OverflowError):
                    published_at = None
                if published_at is not None and published_at.tzinfo is None:
                    published_at = published_at.replace(tzinfo=timezone.utc)
                items.append({"title": title, "source": expected_source, "url": link,
                              "publishedAt": published_at.astimezone(timezone.utc) if published_at else None})
        except ET.ParseError:
            provider_status[expected_source] = "unavailable"
    items.sort(key=lambda item: item["publishedAt"], reverse=True)
    return items[:50], provider_status
