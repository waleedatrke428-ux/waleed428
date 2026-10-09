import {
  analyze,
  atr,
  digestToken,
  entitlement,
  hashPassword,
  rsi,
  sma,
  verifyPassword,
  type Entitlement,
} from "./index.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function trendingCandles(): [any[], any[], any[], any[]] {
  const higher = Array.from({ length: 60 }, (_, index) => ({
    open: 100 + index, high: 101 + index, low: 99 + index, close: 100 + index, volume: 100,
  }));
  const fifteen = Array.from({ length: 39 }, (_, index) => {
    const close = 110 + (index % 2 ? 0.1 : 0);
    return { open: close - 0.05, high: close + 0.2, low: close - 0.2, close, volume: 10 };
  });
  fifteen.push({ open: 110, high: 111.5, low: 109.9, close: 111.2, volume: 30 });
  return [higher, [...higher], [...higher], fifteen];
}

Deno.test("password hashes use PBKDF2 and verify only the matching password", async () => {
  const encoded = await hashPassword("a-long-unique-test-password");
  assert(encoded.startsWith("pbkdf2-sha256$310000$"), "expected PBKDF2 hash encoding");
  assert(encoded !== "a-long-unique-test-password", "password must not be stored in plain text");
  assert(await verifyPassword("a-long-unique-test-password", encoded), "expected correct password to verify");
  assert(!await verifyPassword("incorrect-password", encoded), "incorrect password must fail");
  assert(!await verifyPassword("password", "malformed"), "malformed hash must fail safely");
});

Deno.test("verification tokens are stored as SHA-256 digests", async () => {
  const digest = await digestToken("one-time-verification-token");
  assert(digest.length === 64, "expected a 256-bit hex digest");
  assert(digest !== "one-time-verification-token", "raw token must not be stored");
  assert(digest === await digestToken("one-time-verification-token"), "digest should be deterministic");
});

Deno.test("entitlement uses an exclusive five-day server trial boundary", () => {
  const start = new Date("2026-01-01T00:00:00.000Z");
  const active: Entitlement = entitlement({ trial_started_at: start.toISOString(), paid_until: null }, new Date(start.getTime() + 5 * 86_400_000 - 1));
  const expired = entitlement({ trial_started_at: start.toISOString(), paid_until: null }, new Date(start.getTime() + 5 * 86_400_000));
  assert(active.active, "trial should be active just before the expiry");
  assert(!expired.active, "trial should expire at five days");
  assert(expired.expiresAt === "2026-01-06T00:00:00.000Z", "trial expiry must be server-derived");
});

Deno.test("analysis emits only aligned confluence at or above the 65 score floor", () => {
  const candidate = analyze(...trendingCandles());
  assert(candidate !== null && candidate.score >= 65, "expected a qualified candidate");
  assert(candidate.direction === "long", "higher-timeframe consensus should set direction");
  assert(candidate.directionTimeframes.join(",") === "1d,4h", "expected source timeframe labels");
  assert(candidate.triggerTimeframes.join(",") === "1h,15m", "expected trigger timeframe labels");
  assert(candidate.stopLoss < candidate.entry && candidate.entry < candidate.tp1, "long risk levels should be ordered");
  const [daily, fourHour, hourly, fifteen] = trendingCandles();
  assert(analyze(daily.slice(0, 20), fourHour, hourly, fifteen) === null, "incomplete frames must be skipped");
  const opposed = Array.from({ length: 60 }, (_, index) => ({
    open: 200 - index, high: 201 - index, low: 199 - index, close: 200 - index, volume: 100,
  }));
  assert(analyze(daily, opposed, hourly, fifteen) === null, "opposed daily/4H trend must be rejected");
});

Deno.test("indicator calculations preserve established analysis behavior", () => {
  assert(sma([1, 2, 3, 4], 3) === 3, "SMA mismatch");
  assert(sma([1, 2], 3) === null, "short SMA input must be null");
  assert(rsi(Array.from({ length: 20 }, (_, index) => index)) === 100, "RSI mismatch");
  const flat = Array.from({ length: 20 }, () => ({ open: 10, high: 12, low: 9, close: 11, volume: 5 }));
  assert(atr(flat) === 3, "ATR mismatch");
});
