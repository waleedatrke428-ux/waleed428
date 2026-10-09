const encoder = new TextEncoder();
const decoder = new TextDecoder();
const TRIAL_DAYS = 5;
const MIN_SIGNAL_SCORE = 65;
const PASSWORD_ITERATIONS = 310_000;
const TOKEN_MINUTES = 30;
const JSON_HEADERS = { "content-type": "application/json; charset=utf-8" };
const DISCLAIMER = "Informational only; not investment advice. No exchange orders are placed.";
const SCORE_MEANING = "technical confluence score out of 100; not probability or win rate";
const EXCHANGES = ["binance", "bybit", "okx"] as const;
type Exchange = typeof EXCHANGES[number];

type User = {
  id: string; phone: string; email: string; password_hash: string; role: string;
  email_verified_at: string | null; trial_started_at: string; paid_until: string | null;
  created_at: string;
};
type Candle = { open: number; high: number; low: number; close: number; volume: number };
type Signal = {
  id: string; exchange: string; symbol: string; direction: string; score: number;
  timeframe: string; entry: number; stop_loss: number; tp1: number; tp2: number; tp3: number;
  status: string; rationale: string; created_at: string; updated_at: string;
};

class HttpError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}
class DatabaseError extends Error {
  constructor(readonly operation: string, readonly detail: string, readonly code?: string) {
    super(`Database operation failed: ${operation}`);
  }
}
type DbOptions = { method?: string; body?: unknown; prefer?: string };

function env(name: string, fallback = ""): string {
  return (Deno.env.get(name) ?? fallback).trim();
}
function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...JSON_HEADERS, ...headers } });
}
function uuid(): string { return crypto.randomUUID(); }
function b64url(bytes: Uint8Array): string {
  let binary = "";
  for (const value of bytes) binary += String.fromCharCode(value);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}
function decodeB64url(value: string): Uint8Array {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  const binary = atob(normalized + "=".repeat((4 - normalized.length % 4) % 4));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}
function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
  let difference = a.length ^ b.length;
  const count = Math.max(a.length, b.length);
  for (let i = 0; i < count; i++) difference |= (a[i % (a.length || 1)] ?? 0) ^ (b[i % (b.length || 1)] ?? 0);
  return difference === 0;
}
function secretBytes(): Uint8Array {
  const secret = env("JWT_SECRET");
  if (new TextEncoder().encode(secret).length < 32) {
    throw new Error("JWT_SECRET must contain at least 32 bytes");
  }
  return encoder.encode(secret);
}
export async function hashPassword(password: string): Promise<string> {
  if (password.length < 12 || password.length > 128) throw new HttpError(422, "Password must be between 12 and 128 characters");
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const key = await passwordKeyWithIterations(password, salt, PASSWORD_ITERATIONS);
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode("password-check")));
  return `pbkdf2-sha256$${PASSWORD_ITERATIONS}$${b64url(salt)}$${b64url(digest)}`;
}
export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  try {
    const [algorithm, iterationsText, saltText, digestText, ...extra] = stored.split("$");
    const iterations = Number(iterationsText);
    if (extra.length || algorithm !== "pbkdf2-sha256" || !Number.isInteger(iterations) ||
      iterations < 100_000 || iterations > 1_000_000) return false;
    const key = await passwordKeyWithIterations(password, decodeB64url(saltText), iterations);
    const actual = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode("password-check")));
    return constantTimeEqual(actual, decodeB64url(digestText));
  } catch { return false; }
}
async function passwordKeyWithIterations(password: string, salt: Uint8Array, iterations: number): Promise<CryptoKey> {
  const material = await crypto.subtle.importKey("raw", encoder.encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt, iterations }, material, 256,
  );
  return crypto.subtle.importKey("raw", bits, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
}
export async function digestToken(token: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(token)));
  return [...digest].map((part) => part.toString(16).padStart(2, "0")).join("");
}
function newVerificationToken(): string { return b64url(crypto.getRandomValues(new Uint8Array(32))); }
async function signJwt(user: Pick<User, "id" | "role">, now = Date.now()): Promise<string> {
  const header = b64url(encoder.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const payload = b64url(encoder.encode(JSON.stringify({
    sub: user.id, role: user.role, iat: Math.floor(now / 1000),
    exp: Math.floor(now / 1000) + TOKEN_MINUTES * 60,
  })));
  const unsigned = `${header}.${payload}`;
  const key = await crypto.subtle.importKey("raw", secretBytes(), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(unsigned)));
  return `${unsigned}.${b64url(signature)}`;
}
async function verifyJwt(token: string, now = Date.now()): Promise<{ sub: string; role?: string }> {
  try {
    const parts = token.split(".");
    if (parts.length !== 3) throw new Error("Malformed token");
    const header = JSON.parse(decoder.decode(decodeB64url(parts[0])));
    const claims = JSON.parse(decoder.decode(decodeB64url(parts[1])));
    if (header.alg !== "HS256" || typeof claims.sub !== "string" ||
      !Number.isFinite(claims.exp) || claims.exp <= Math.floor(now / 1000)) throw new Error("Invalid claims");
    const key = await crypto.subtle.importKey("raw", secretBytes(), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
    const valid = await crypto.subtle.verify("HMAC", key, decodeB64url(parts[2]), encoder.encode(`${parts[0]}.${parts[1]}`));
    if (!valid) throw new Error("Invalid signature");
    return claims;
  } catch { throw new HttpError(401, "Invalid or expired bearer token"); }
}

async function db<T>(tableOrRpc: string, query: Record<string, string> = {}, options: DbOptions = {}): Promise<T> {
  const projectUrl = env("SUPABASE_URL").replace(/\/+$/, "");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY") || env("SERVICE_ROLE_KEY");
  if (!projectUrl || !serviceKey) throw new DatabaseError(tableOrRpc, "Supabase server credentials are not configured");
  const url = `${projectUrl}/rest/v1/${tableOrRpc}`;
  const search = new URLSearchParams(query);
  const encodedQuery = search.toString();
  const response = await fetch(`${url}${encodedQuery ? `?${encodedQuery}` : ""}`, {
    method: options.method ?? "GET",
    headers: {
      apikey: serviceKey, authorization: `Bearer ${serviceKey}`,
      "content-type": "application/json", accept: "application/json",
      ...(options.prefer ? { prefer: options.prefer } : {}),
    },
    ...(options.body !== undefined ? { body: JSON.stringify(options.body) } : {}),
    signal: AbortSignal.timeout(12_000),
  });
  const text = await response.text();
  if (!response.ok) {
    let code: string | undefined;
    try {
      const body = JSON.parse(text);
      if (typeof body.code === "string") code = body.code;
    } catch { /* Do not expose or log provider error bodies. */ }
    console.error("Supabase database request failed", { operation: tableOrRpc, status: response.status, code });
    throw new DatabaseError(tableOrRpc, `HTTP ${response.status}`, code);
  }
  if (!text) return undefined as T;
  try { return JSON.parse(text) as T; }
  catch {
    console.error("Supabase returned an invalid database response", { operation: tableOrRpc });
    throw new DatabaseError(tableOrRpc, "Invalid response");
  }
}
async function selectRows<T>(table: string, query: Record<string, string>): Promise<T[]> {
  return await db<T[]>(table, query) ?? [];
}
async function insertRows<T>(table: string, rows: unknown, prefer = "return=representation"): Promise<T[]> {
  return await db<T[]>(table, {}, { method: "POST", body: rows, prefer }) ?? [];
}
async function updateRows<T>(table: string, query: Record<string, string>, patch: unknown): Promise<T[]> {
  return await db<T[]>(table, query, { method: "PATCH", body: patch, prefer: "return=representation" }) ?? [];
}
function one<T>(rows: T[]): T | null { return rows.length ? rows[0] : null; }
function isoNow(): string { return new Date().toISOString(); }
function eq(value: string): string { return `eq.${value}`; }

export type Entitlement = {
  serverTime: string; trialExpiresAt: string; subscriptionExpiresAt: string | null;
  expiresAt: string; active: boolean;
};
export function entitlement(user: Pick<User, "trial_started_at" | "paid_until">, now = new Date()): Entitlement {
  const trialEnd = new Date(new Date(user.trial_started_at).getTime() + TRIAL_DAYS * 86_400_000);
  const paidEnd = user.paid_until ? new Date(user.paid_until) : null;
  const expires = paidEnd && paidEnd > trialEnd ? paidEnd : trialEnd;
  return {
    serverTime: now.toISOString(), trialExpiresAt: trialEnd.toISOString(),
    subscriptionExpiresAt: paidEnd?.toISOString() ?? null, expiresAt: expires.toISOString(),
    active: now.getTime() < expires.getTime(),
  };
}
export function addCalendarMonths(value: Date, months: number): Date {
  const result = new Date(value);
  const originalDay = result.getUTCDate();
  result.setUTCDate(1);
  result.setUTCMonth(result.getUTCMonth() + months);
  const lastDay = new Date(Date.UTC(result.getUTCFullYear(), result.getUTCMonth() + 1, 0)).getUTCDate();
  result.setUTCDate(Math.min(originalDay, lastDay));
  return result;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
async function bodyJson(request: Request): Promise<Record<string, unknown>> {
  const text = await request.text();
  if (encoder.encode(text).length > 16_384) throw new HttpError(413, "Request body is too large");
  let value: unknown;
  try { value = JSON.parse(text); } catch { throw new HttpError(400, "Invalid JSON body"); }
  if (!isObject(value)) throw new HttpError(422, "A JSON object is required");
  return value;
}
async function optionalBodyJson(request: Request): Promise<Record<string, unknown>> {
  if (!request.headers.get("content-length") && !request.headers.get("content-type")) return {};
  const text = await request.text();
  if (!text.trim()) return {};
  if (encoder.encode(text).length > 16_384) throw new HttpError(413, "Request body is too large");
  let value: unknown;
  try { value = JSON.parse(text); } catch { throw new HttpError(400, "Invalid JSON body"); }
  if (!isObject(value)) throw new HttpError(422, "A JSON object is required");
  return value;
}
function stringField(body: Record<string, unknown>, name: string, min: number, max: number): string {
  const value = body[name];
  if (typeof value !== "string" || value.length < min || value.length > max) {
    throw new HttpError(422, `Invalid ${name}`);
  }
  return value;
}
function emailField(body: Record<string, unknown>): string {
  const value = stringField(body, "email", 3, 320).trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) throw new HttpError(422, "Invalid email");
  return value;
}
function phoneField(body: Record<string, unknown>): string {
  const value = stringField(body, "phone", 7, 32).trim();
  if (!/^[+0-9(). -]+$/.test(value)) throw new HttpError(422, "Invalid phone");
  return value;
}
function isoSort(value: string): number {
  const parsed = new Date(value).getTime();
  return Number.isFinite(parsed) ? parsed : 0;
}
function sanitizeError(error: unknown): Response {
  if (error instanceof HttpError) return json({ detail: error.message }, error.status);
  if (error instanceof DatabaseError) return json({ detail: "Database temporarily unavailable" }, 503);
  console.error("API request failed", error);
  return json({ detail: "Internal server error" }, 500);
}
function routePath(url: URL): string {
  let path = url.pathname;
  const functionIndex = path.indexOf("/functions/v1/api");
  if (functionIndex >= 0) path = path.slice(functionIndex + "/functions/v1/api".length);
  if (!path || path === "/") return "/";
  if (path.startsWith("/api/")) path = path.slice(4);
  if (!path.startsWith("/")) path = `/${path}`;
  return path.replace(/\/+$/, "") || "/";
}
const rateState = new Map<string, number[]>();
function enforceRate(request: Request, path: string): void {
  const forwarded = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";
  const category = path.startsWith("/auth/") ? "auth" : "api";
  const key = `${forwarded}:${category}`;
  const now = Date.now();
  const recent = (rateState.get(key) ?? []).filter((stamp) => now - stamp < 60_000);
  const limit = category === "auth" ? 10 : 120;
  if (recent.length >= limit) throw new HttpError(429, "Too many requests");
  recent.push(now);
  rateState.set(key, recent);
  if (rateState.size > 10_000) rateState.clear();
}

async function currentUser(request: Request): Promise<User> {
  const auth = request.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(auth);
  if (!match) throw new HttpError(401, "Bearer token required");
  const claims = await verifyJwt(match[1]);
  const user = one(await selectRows<User>("users", { select: "*", id: eq(claims.sub), limit: "1" }));
  if (!user || !user.email_verified_at) throw new HttpError(401, "Invalid or unverified account");
  return user;
}
async function authorized(request: Request, needsActive = false, needsAdmin = false): Promise<User> {
  const user = await currentUser(request);
  if (needsAdmin && user.role !== "admin") throw new HttpError(403, "Administrator access required");
  if (needsActive && !entitlement(user).active) throw new HttpError(403, "Trial or subscription access has expired");
  return user;
}
async function sendVerificationEmail(email: string, token: string): Promise<boolean> {
  const apiKey = env("BREVO_API_KEY");
  const from = env("SMTP_FROM");
  if (!apiKey || !from) return false;
  const response = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST", headers: { "content-type": "application/json", accept: "application/json", "api-key": apiKey },
    body: JSON.stringify({
      sender: { name: "Crypto Albalhousi", email: from }, to: [{ email }],
      subject: "Verify your Crypto Albalhousi account",
      textContent: `Verify your email using this one-time token in the app: ${token}\nToken expires in 24 hours. Do not share it.`,
    }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) {
    console.error("Verification email delivery failed", { status: response.status });
    return false;
  }
  return true;
}
async function createVerification(user: User): Promise<boolean> {
  const token = newVerificationToken();
  await insertRows("verification_tokens", {
    id: uuid(), user_id: user.id, token_hash: await digestToken(token),
    expires_at: new Date(Date.now() + 24 * 60 * 60_000).toISOString(), created_at: isoNow(),
  });
  try { return await sendVerificationEmail(user.email, token); }
  catch (error) {
    console.error("Verification email delivery failed", error);
    return false;
  }
}

function serializeSignal(row: Signal): Record<string, unknown> {
  return {
    id: row.id, exchange: row.exchange, symbol: row.symbol, direction: row.direction,
    score: row.score, scoreType: "technical_confluence", timeframe: row.timeframe,
    directionTimeframes: ["1d", "4h"], triggerTimeframes: ["1h", "15m"],
    entry: row.entry, stopLoss: row.stop_loss, takeProfits: [row.tp1, row.tp2, row.tp3],
    status: row.status, rationale: row.rationale.split("|"),
    createdAt: row.created_at, updatedAt: row.updated_at,
  };
}
type PlatformSettings = { min_signal_score: number; active_exchanges: string[] };
async function getSettingsRow(): Promise<PlatformSettings> {
  const row = one(await selectRows<PlatformSettings>("platform_settings", { select: "*", id: "eq.1", limit: "1" }));
  if (!row) throw new DatabaseError("platform_settings", "Seed row 1 is missing");
  return row;
}

function float(value: unknown): number {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}
function liquidityScore(volume: unknown): number {
  return Math.min(100, Math.floor(Math.log10(Math.max(0, float(volume)) + 1) * 10));
}
type Market = { exchange: Exchange; symbol: string; base: string; quote: string; score: number; volume: number };
async function externalJson(url: string): Promise<any> {
  const response = await fetch(url, { signal: AbortSignal.timeout(8_000), headers: { accept: "application/json" } });
  if (!response.ok) throw new Error(`Provider returned HTTP ${response.status}`);
  return await response.json();
}
async function binanceMarkets(): Promise<Market[]> {
  const [tickers, info] = await Promise.all([
    externalJson("https://fapi.binance.com/fapi/v1/ticker/24hr"),
    externalJson("https://fapi.binance.com/fapi/v1/exchangeInfo"),
  ]);
  const eligible = new Map((info.symbols ?? []).filter((row: any) =>
    row.contractType === "PERPETUAL" && row.quoteAsset === "USDT" && row.status === "TRADING")
    .map((row: any) => [row.symbol, row]));
  return (tickers as any[]).flatMap((row) => {
    const market = eligible.get(row.symbol) as any;
    return market ? [{ exchange: "binance" as const, symbol: market.symbol, base: market.baseAsset, quote: "USDT",
      score: liquidityScore(row.quoteVolume), volume: float(row.quoteVolume) }] : [];
  });
}
async function bybitMarkets(): Promise<Market[]> {
  const [tickerResult, instrumentResult] = await Promise.all([
    externalJson("https://api.bybit.com/v5/market/tickers?category=linear"),
    externalJson("https://api.bybit.com/v5/market/instruments-info?category=linear&limit=1000"),
  ]);
  if (tickerResult.retCode !== 0 || instrumentResult.retCode !== 0) throw new Error("Bybit returned a non-zero result code");
  const instruments = [...(instrumentResult.result?.list ?? [])];
  let cursor = instrumentResult.result?.nextPageCursor ?? "";
  let pages = 0;
  while (cursor && pages++ < 10) {
    const page = await externalJson(`https://api.bybit.com/v5/market/instruments-info?category=linear&limit=1000&cursor=${encodeURIComponent(cursor)}`);
    if (page.retCode !== 0) throw new Error("Bybit returned a non-zero result code");
    instruments.push(...(page.result?.list ?? []));
    cursor = page.result?.nextPageCursor ?? "";
  }
  if (cursor) throw new Error("Bybit instruments pagination exceeded the safety limit");
  const eligible = new Map(instruments.filter((row: any) =>
    row.quoteCoin === "USDT" && row.contractType === "LinearPerpetual" && row.status === "Trading")
    .map((row: any) => [row.symbol, row]));
  return (tickerResult.result?.list ?? []).flatMap((row: any) => {
    const market = eligible.get(row.symbol) as any;
    return market ? [{ exchange: "bybit" as const, symbol: market.symbol, base: market.baseCoin, quote: "USDT",
      score: liquidityScore(row.turnover24h), volume: float(row.turnover24h) }] : [];
  });
}
async function okxMarkets(): Promise<Market[]> {
  const result = await externalJson("https://www.okx.com/api/v5/market/tickers?instType=SWAP");
  if (result.code !== "0") throw new Error("OKX returned a non-zero result code");
  return (result.data ?? []).flatMap((row: any) => {
    const pieces = String(row.instId ?? "").split("-");
    return pieces.length === 3 && pieces[1] === "USDT" && pieces[2] === "SWAP"
      ? [{ exchange: "okx" as const, symbol: row.instId, base: pieces[0], quote: "USDT",
        score: liquidityScore(row.volCcy24h), volume: float(row.volCcy24h) }] : [];
  });
}
async function getMarkets(): Promise<{ items: Market[]; providers: Record<string, string> }> {
  const providers = { binance: "unavailable", bybit: "unavailable", okx: "unavailable" } as Record<string, string>;
  const tasks = [binanceMarkets(), bybitMarkets(), okxMarkets()];
  const names: Exchange[] = ["binance", "bybit", "okx"];
  const items: Market[] = [];
  const results = await Promise.allSettled(tasks);
  results.forEach((result, index) => {
    if (result.status === "fulfilled") {
      providers[names[index]] = "ok";
      items.push(...result.value);
    } else console.error("Market provider unavailable", { exchange: names[index], error: String(result.reason) });
  });
  items.sort((a, b) => b.volume - a.volume);
  return { items, providers };
}
const INTERVALS: Record<Exchange, Record<string, string>> = {
  binance: { "1d": "1d", "4h": "4h", "1h": "1h", "15m": "15m" },
  bybit: { "1d": "D", "4h": "240", "1h": "60", "15m": "15" },
  okx: { "1d": "1D", "4h": "4H", "1h": "1H", "15m": "15m" },
};
const DURATION: Record<string, number> = { "1d": 86_400_000, "4h": 14_400_000, "1h": 3_600_000, "15m": 900_000 };
async function fetchCandles(exchange: Exchange, symbol: string, timeframe: string, limit = 120): Promise<unknown[][]> {
  const now = Date.now();
  let raw: unknown[][];
  if (exchange === "binance") {
    raw = await externalJson(`https://fapi.binance.com/fapi/v1/klines?symbol=${encodeURIComponent(symbol)}&interval=${INTERVALS[exchange][timeframe]}&limit=${limit}`);
    return raw.filter((row) => Number(row[6]) < now);
  }
  if (exchange === "bybit") {
    const result = await externalJson(`https://api.bybit.com/v5/market/kline?category=linear&symbol=${encodeURIComponent(symbol)}&interval=${INTERVALS[exchange][timeframe]}&limit=${limit}`);
    if (result.retCode !== 0) throw new Error("Bybit returned a non-zero result code");
    raw = [...(result.result?.list ?? [])].reverse();
    return raw.filter((row) => Number(row[0]) + DURATION[timeframe] <= now);
  }
  const result = await externalJson(`https://www.okx.com/api/v5/market/candles?instId=${encodeURIComponent(symbol)}&bar=${INTERVALS[exchange][timeframe]}&limit=${limit}`);
  if (result.code !== "0") throw new Error("OKX returned a non-zero result code");
  raw = [...(result.data ?? [])].reverse();
  return raw.filter((row) => row.length > 8 && row[8] === "1");
}
export function parseCandles(exchange: string, raw: unknown[][]): Candle[] {
  if (!EXCHANGES.includes(exchange as Exchange)) return [];
  return raw.flatMap((row) => {
    const values = row.slice(1, 6).map((value) => typeof value === "number" ? value : Number(value));
    if (values.length !== 5 || values.some((value) => !Number.isFinite(value))) return [];
    const [open, high, low, close, volume] = values;
    return [{ open, high, low, close, volume }];
  });
}
export function sma(values: number[], period: number): number | null {
  return values.length < period ? null : values.slice(-period).reduce((sum, item) => sum + item, 0) / period;
}
export function rsi(closes: number[], period = 14): number | null {
  if (closes.length <= period) return null;
  const changes = [];
  for (let index = closes.length - period; index < closes.length; index++) changes.push(closes[index] - closes[index - 1]);
  const gains = changes.reduce((sum, change) => sum + Math.max(change, 0), 0) / period;
  const losses = changes.reduce((sum, change) => sum + Math.max(-change, 0), 0) / period;
  if (losses === 0) return gains ? 100 : 50;
  return 100 - 100 / (1 + gains / losses);
}
export function atr(candles: Candle[], period = 14): number | null {
  if (candles.length <= period) return null;
  let total = 0;
  for (let index = candles.length - period; index < candles.length; index++) {
    const candle = candles[index], previous = candles[index - 1].close;
    total += Math.max(candle.high - candle.low, Math.abs(candle.high - previous), Math.abs(candle.low - previous));
  }
  return total / period;
}
function trend(candles: Candle[]): string | null {
  if (candles.length < 30) return null;
  const closes = candles.map((candle) => candle.close);
  const fast = sma(closes, 20), slow = sma(closes, 50) ?? sma(closes, 30);
  if (fast === null || slow === null) return null;
  if (fast > slow && closes.at(-1)! > fast) return "long";
  if (fast < slow && closes.at(-1)! < fast) return "short";
  return null;
}
export function analyze(daily: Candle[], fourHour: Candle[], hourly: Candle[], fifteenMinute: Candle[]) {
  if ([daily, fourHour, hourly, fifteenMinute].some((frame) => frame.length < 30)) return null;
  const dailyDirection = trend(daily), fourHourDirection = trend(fourHour);
  if (!dailyDirection || fourHourDirection !== dailyDirection) return null;
  const direction = dailyDirection;
  const hourlyAligned = trend(hourly) === direction;
  const closes = fifteenMinute.map((candle) => candle.close);
  const recent = fifteenMinute.slice(-21, -1);
  if (!recent.length) return null;
  const support = Math.min(...recent.map((item) => item.low));
  const resistance = Math.max(...recent.map((item) => item.high));
  const trigger = fifteenMinute.at(-1)!;
  const momentum = rsi(closes), volatility = atr(fifteenMinute);
  if (momentum === null || volatility === null || volatility <= 0) return null;
  let score = 30;
  const reasons = ["1D and 4H market direction aligned"];
  if (hourlyAligned) { score += 15; reasons.push("1H trigger context aligned"); }
  const level = direction === "long" ? support : resistance;
  if (Math.abs(trigger.close - level) <= volatility * 1.5) {
    score += 15; reasons.push("15m trigger near recent support/resistance");
  }
  if (direction === "long" ? trigger.close > trigger.open : trigger.close < trigger.open) {
    score += 10; reasons.push("15m trigger candle aligned");
  }
  const averageVolume = fifteenMinute.slice(-21, -1).reduce((sum, item) => sum + item.volume, 0) / 20;
  if (averageVolume > 0 && trigger.volume >= averageVolume * 1.2) {
    score += 10; reasons.push("15m trigger volume expansion");
  }
  if ((direction === "long" && momentum >= 45 && momentum <= 68) ||
    (direction === "short" && momentum >= 32 && momentum <= 55)) {
    score += 10; reasons.push("15m momentum in directional confirmation range");
  }
  if ((direction === "long" && trigger.close > resistance) ||
    (direction === "short" && trigger.close < support)) {
    score += 10; reasons.push("15m recent structure break");
  }
  score = Math.min(100, score);
  if (score < MIN_SIGNAL_SCORE) return null;
  const entry = trigger.close;
  const stopLoss = direction === "long" ? Math.min(support, entry - volatility * 1.5) :
    Math.max(resistance, entry + volatility * 1.5);
  const risk = Math.abs(entry - stopLoss);
  if (risk <= 0) return null;
  const sign = direction === "long" ? 1 : -1;
  return {
    direction, score, timeframe: "15m", directionTimeframes: ["1d", "4h"],
    triggerTimeframes: ["1h", "15m"], entry, stopLoss,
    tp1: entry + sign * risk, tp2: entry + sign * risk * 2, tp3: entry + sign * risk * 3, rationale: reasons,
  };
}
async function eventExists(signalId: string, type: string): Promise<boolean> {
  return (await selectRows<{ id: string }>("signal_events", {
    select: "id", signal_id: eq(signalId), event_type: eq(type), limit: "1",
  })).length > 0;
}
async function addEvent(signalId: string, type: string, details: Record<string, unknown> = {}): Promise<void> {
  if (await eventExists(signalId, type)) return;
  await db("signal_events", { on_conflict: "signal_id,event_type" }, {
    method: "POST", prefer: "resolution=ignore-duplicates,return=minimal",
    body: {
    id: uuid(), signal_id: signalId, event_type: type, observed_at: isoNow(), details,
    },
  });
}
async function monitorSignal(signal: Signal): Promise<void> {
  try {
    const candles = parseCandles(signal.exchange, await fetchCandles(signal.exchange as Exchange, signal.symbol, "15m", 3));
    if (!candles.length) return;
    const candle = candles.at(-1)!;
    if ((signal.direction === "long" && candle.low <= signal.stop_loss) ||
      (signal.direction === "short" && candle.high >= signal.stop_loss)) {
      await updateRows("signals", { id: eq(signal.id), status: eq("active") }, { status: "stopped", updated_at: isoNow() });
      await addEvent(signal.id, "stop_loss", { price: signal.stop_loss });
      return;
    }
    for (const [index, target] of [signal.tp1, signal.tp2, signal.tp3].entries()) {
      const number = index + 1, type = `take_profit_${number}`;
      if (await eventExists(signal.id, type)) continue;
      const hit = signal.direction === "long" ? candle.high >= target : candle.low <= target;
      if (hit) {
        await addEvent(signal.id, type, { price: target });
        await updateRows("signals", { id: eq(signal.id), status: eq("active") }, {
          ...(number === 3 ? { status: "target3" } : {}), updated_at: isoNow(),
        });
        break;
      }
    }
    if (!await eventExists(signal.id, "entry") && candle.low <= signal.entry && signal.entry <= candle.high) {
      await addEvent(signal.id, "entry", { price: signal.entry });
    }
  } catch (error) { console.error("Signal lifecycle monitoring failed", { signalId: signal.id, error: String(error) }); }
}
export async function runScan(): Promise<{ scanned: number; created: number; providers: Record<string, string> }> {
  const settings = await getSettingsRow();
  const { items, providers } = await getMarkets();
  const shortlist: Market[] = [];
  for (const exchange of settings.active_exchanges as Exchange[]) {
    const universe = items.filter((item) => item.exchange === exchange);
    if (!universe.length) continue;
    const offset = (Math.floor(Date.now() / 300_000) * 3) % universe.length;
    for (let index = 0; index < Math.min(3, universe.length); index++) {
      shortlist.push(universe[(offset + index) % universe.length]);
    }
  }
  let created = 0;
  await Promise.all(shortlist.map(async (market) => {
    try {
      const frames = await Promise.all((["1d", "4h", "1h", "15m"] as const).map((frame) =>
        fetchCandles(market.exchange, market.symbol, frame)));
      const candidate = analyze(...frames.map((bars) => parseCandles(market.exchange, bars)) as [Candle[], Candle[], Candle[], Candle[]]);
      if (!candidate || candidate.score < Math.max(MIN_SIGNAL_SCORE, settings.min_signal_score)) return;
      const active = one(await selectRows<Signal>("signals", {
        select: "*", exchange: eq(market.exchange), symbol: eq(market.symbol), status: eq("active"),
        order: "created_at.desc", limit: "1",
      }));
      if (active && active.direction !== candidate.direction) {
        const updated = await updateRows<Signal>("signals", { id: eq(active.id), status: eq("active") },
          { status: "reversed", updated_at: isoNow() });
        if (updated.length) await addEvent(active.id, "reversal", { reversedTo: candidate.direction });
      } else if (active) {
        await monitorSignal(active);
        return;
      }
      const now = isoNow();
      const signal = one(await insertRows<Signal>("signals", {
        id: uuid(), exchange: market.exchange, symbol: market.symbol, direction: candidate.direction,
        score: candidate.score, timeframe: candidate.timeframe, entry: candidate.entry,
        stop_loss: candidate.stopLoss, tp1: candidate.tp1, tp2: candidate.tp2, tp3: candidate.tp3,
        status: "active", rationale: candidate.rationale.join("|"), created_at: now, updated_at: now,
      }));
      if (signal) {
        await addEvent(signal.id, "signal_created", { score: signal.score, scoreType: "technical_confluence" });
        created++;
      }
    } catch (error) {
      console.error("Signal candidate scan failed", { exchange: market.exchange, symbol: market.symbol, error: String(error) });
    }
  }));
  const activeSignals = await selectRows<Signal>("signals", { select: "*", status: eq("active"), limit: "1000" });
  const visited = new Set(shortlist.map((market) => `${market.exchange}:${market.symbol}`));
  for (const signal of activeSignals) {
    if (!visited.has(`${signal.exchange}:${signal.symbol}`)) await monitorSignal(signal);
  }
  return { scanned: shortlist.length, created, providers };
}

function tagText(item: string, name: string): string | null {
  const found = new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)<\\/${name}>`, "i").exec(item);
  if (!found) return null;
  return found[1].replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1").replace(/<[^>]+>/g, "").trim();
}
async function getNews(): Promise<{ items: Record<string, unknown>[]; providers: Record<string, string> }> {
  const feeds = [
    ["CoinDesk", "https://www.coindesk.com/arc/outboundfeeds/rss/"],
    ["Cointelegraph", "https://cointelegraph.com/rss"],
  ] as const;
  const providers: Record<string, string> = {};
  const results = await Promise.all(feeds.map(async ([source, url]) => {
    try {
      const response = await fetch(url, { signal: AbortSignal.timeout(8_000), headers: { "user-agent": "SignalPlatform/1.0 (+public RSS reader)" } });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const xml = await response.text();
      providers[source] = "ok";
      return [...xml.matchAll(/<item(?:\s[^>]*)?>([\s\S]*?)<\/item>/gi)].flatMap((match) => {
        const item = match[1];
        const title = tagText(item, "title"), link = tagText(item, "link"), published = tagText(item, "pubDate");
        if (!title || !link) return [];
        try {
          const parsed = new URL(link);
          if (parsed.protocol !== "https:") return [];
          const date = published ? new Date(published) : null;
          return [{ title, source, url: parsed.toString(), publishedAt: date && !Number.isNaN(date.getTime()) ? date.toISOString() : null }];
        } catch { return []; }
      });
    } catch (error) {
      providers[source] = "unavailable";
      console.error("News provider unavailable", { source, error: String(error) });
      return [];
    }
  }));
  const items = results.flat().sort((a, b) => isoSort(b.publishedAt ?? "") - isoSort(a.publishedAt ?? ""));
  return { items: items.slice(0, 50), providers };
}

function timezoneOffset(date: Date, timezone: string): number {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
  }).formatToParts(date);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  const represented = Date.UTC(Number(values.year), Number(values.month) - 1, Number(values.day),
    Number(values.hour), Number(values.minute), Number(values.second));
  return represented - Math.floor(date.getTime() / 1000) * 1000;
}
function zonedLocalTime(year: number, month: number, day: number, hour: number, timezone: string): Date {
  const target = Date.UTC(year, month - 1, day, hour);
  let result = new Date(target);
  for (let i = 0; i < 3; i++) result = new Date(target - timezoneOffset(result, timezone));
  return result;
}
function localParts(date: Date, timezone: string) {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).formatToParts(date);
  return Object.fromEntries(parts.map((part) => [part.type, part.value]));
}
async function handleRequest(request: Request): Promise<Response> {
  const url = new URL(request.url);
  const origins = env("ALLOWED_ORIGINS").split(",").map((origin) => origin.trim()).filter(Boolean);
  const origin = request.headers.get("origin");
  const cors: Record<string, string> = {
    "access-control-allow-methods": "GET, POST, PUT, OPTIONS",
    "access-control-allow-headers": "authorization, content-type, x-timezone, x-scan-secret, apikey",
    "access-control-max-age": "86400",
    ...(origin && (origins.length === 0 || origins.includes(origin)) ? { "access-control-allow-origin": origins.includes(origin) ? origin : "*" } : {}),
    vary: "Origin",
  };
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  try {
    if (origin && origins.length > 0 && !origins.includes(origin)) throw new HttpError(403, "Origin is not allowed");
    const path = routePath(url);
    enforceRate(request, path);
    const method = request.method.toUpperCase();
    let result: unknown;
    let status = 200;
    if (path === "/health" && method === "GET") {
      const settings = await getSettingsRow();
      result = { status: "ok", serverTime: isoNow(), signalThreshold: settings.min_signal_score };
    } else if (path === "/auth/register" && method === "POST") {
      const payload = await bodyJson(request);
      const email = emailField(payload), phone = phoneField(payload), password = stringField(payload, "password", 12, 128);
      const [emailMatch, phoneMatch] = await Promise.all([
        selectRows<User>("users", { select: "id", email: eq(email), limit: "1" }),
        selectRows<User>("users", { select: "id", phone: eq(phone), limit: "1" }),
      ]);
      if (emailMatch.length || phoneMatch.length) throw new HttpError(409, "Email or phone is already registered");
      const admins = env("ADMIN_EMAILS").split(",").map((entry) => entry.trim().toLowerCase()).filter(Boolean);
      const id = uuid(), now = isoNow();
      let user: User | null;
      try {
        user = one(await db<User[]>("rpc/register_user", {}, {
          method: "POST",
          body: {
            p_id: id, p_email: email, p_phone: phone, p_password_hash: await hashPassword(password),
            p_role: admins.includes(email) ? "admin" : "user", p_created_at: now,
          },
        }));
      } catch (error) {
        if (error instanceof DatabaseError && error.code === "23505") {
          throw new HttpError(409, "Email or phone is already registered");
        }
        throw error;
      }
      if (!user) throw new DatabaseError("rpc/register_user", "Registration returned no user");
      const sent = await createVerification(user);
      result = {
        id: user.id, email: user.email, verificationEmailSent: sent,
        message: "Verify your email before logging in. If email delivery is not configured, contact the administrator.",
      };
      status = 201;
    } else if (path === "/auth/verify" && method === "POST") {
      const token = stringField(await bodyJson(request), "token", 32, 128);
      const verified = await db<boolean>("rpc/consume_verification_token", {}, {
        method: "POST", body: { p_token_hash: await digestToken(token) },
      });
      if (!verified) throw new HttpError(400, "Verification token is invalid or expired");
      result = { verified: true };
    } else if (path === "/auth/verify/request" && method === "POST") {
      const email = emailField(await bodyJson(request));
      const user = one(await selectRows<User>("users", { select: "*", email: eq(email), limit: "1" }));
      if (user && !user.email_verified_at) {
        result = { accepted: true, verificationEmailSent: await createVerification(user) };
      } else result = { accepted: true };
    } else if (path === "/auth/login" && method === "POST") {
      const payload = await bodyJson(request), email = emailField(payload);
      const password = stringField(payload, "password", 1, 128);
      const user = one(await selectRows<User>("users", { select: "*", email: eq(email), limit: "1" }));
      if (!user || !await verifyPassword(password, user.password_hash)) throw new HttpError(401, "Invalid email or password");
      if (!user.email_verified_at) throw new HttpError(403, "Email verification required");
      const accessToken = await signJwt(user);
      result = {
        accessToken, tokenType: "Bearer", expiresIn: TOKEN_MINUTES * 60,
        id: user.id, email: user.email, role: user.role,
        user: { id: user.id, email: user.email, role: user.role },
      };
    } else if (path === "/me/entitlement" && method === "GET") {
      const user = await authorized(request), access = entitlement(user);
      result = { ...access, remainingSeconds: Math.max(0, Math.floor((Date.parse(access.expiresAt) - Date.parse(access.serverTime)) / 1000)) };
    } else if (path === "/me/session-hours" && method === "GET") {
      await authorized(request);
      const timezone = request.headers.get("x-timezone") || "Europe/London";
      let london: Record<string, string>;
      try { london = localParts(new Date(), "Europe/London"); new Intl.DateTimeFormat("en", { timeZone: timezone }); }
      catch { throw new HttpError(400, "X-Timezone must be a valid IANA timezone"); }
      const year = Number(london.year), month = Number(london.month), day = Number(london.day);
      const opening = zonedLocalTime(year, month, day, 8, "Europe/London");
      const closing = zonedLocalTime(year, month, day, 17, "Europe/London");
      const localOpen = localParts(opening, timezone), localClose = localParts(closing, timezone);
      result = {
        reference: "London session", timezone,
        referenceHours: { start: "08:00", end: "17:00", timezone: "Europe/London" },
        localHours: {
          start: `${localOpen.hour}:${localOpen.minute}`, end: `${localClose.hour}:${localClose.minute}`,
          date: `${localOpen.year}-${localOpen.month}-${localOpen.day}`,
          startAt: opening.toISOString(), endAt: closing.toISOString(),
        },
      };
    } else if (path === "/me/journal" && method === "GET") {
      const user = await authorized(request, true);
      const rows = await selectRows<any>("entered_trades", {
        select: "id,signal_id,note,entered_at", user_id: eq(user.id), order: "entered_at.desc", limit: "200",
      });
      result = { items: rows.map((row) => ({ id: row.id, signalId: row.signal_id, note: row.note, enteredAt: row.entered_at })) };
    } else if (path === "/me/settings" && method === "GET") {
      const user = await authorized(request);
      const row = one(await selectRows<any>("user_settings", {
        select: "email_notifications,push_notifications", user_id: eq(user.id), limit: "1",
      }));
      if (!row) throw new DatabaseError("user_settings", "User settings row is missing");
      result = { emailNotifications: row.email_notifications, pushNotifications: row.push_notifications };
    } else if (path === "/me/settings" && method === "PUT") {
      const user = await authorized(request), payload = await bodyJson(request);
      if (typeof payload.emailNotifications !== "boolean" || typeof payload.pushNotifications !== "boolean") {
        throw new HttpError(422, "Invalid notification settings");
      }
      if (payload.fcmToken !== undefined && payload.fcmToken !== null &&
        (typeof payload.fcmToken !== "string" || payload.fcmToken.length > 512)) throw new HttpError(422, "Invalid fcmToken");
      const row = one(await db<any[]>("user_settings", { on_conflict: "user_id" }, {
        method: "POST", body: {
          user_id: user.id, email_notifications: payload.emailNotifications,
          push_notifications: payload.pushNotifications,
          fcm_token: payload.pushNotifications ? (payload.fcmToken ?? null) : null,
        }, prefer: "resolution=merge-duplicates,return=representation",
      }));
      if (!row) throw new DatabaseError("user_settings", "Settings upsert returned no row");
      result = { emailNotifications: row.email_notifications, pushNotifications: row.push_notifications, pushDelivery: "not_configured" };
    } else if (path === "/me/alerts" && method === "GET") {
      const user = await authorized(request, true);
      const entered = await selectRows<{ signal_id: string }>("entered_trades", { select: "signal_id", user_id: eq(user.id), limit: "500" });
      if (!entered.length) result = { items: [], pushDelivery: "not_configured" };
      else {
        const ids = `in.(${entered.map((row) => row.signal_id).join(",")})`;
        const events = await selectRows<any>("signal_events", {
          select: "signal_id,event_type,observed_at,details", signal_id: ids, order: "observed_at.desc", limit: "100",
        });
        result = { items: events.map((event) => ({
          signalId: event.signal_id, type: event.event_type, observedAt: event.observed_at, details: event.details,
        })), pushDelivery: "not_configured" };
      }
    } else if (path === "/signals" && method === "GET") {
      await authorized(request, true);
      const rows = await selectRows<Signal>("signals", {
        select: "*", status: eq("active"), score: `gte.${MIN_SIGNAL_SCORE}`, order: "created_at.desc", limit: "200",
      });
      result = { items: rows.map(serializeSignal), scoreMeaning: SCORE_MEANING, disclaimer: DISCLAIMER };
    } else {
      const eventMatch = /^\/signals\/([^/]+)\/events$/.exec(path);
      const enteredMatch = /^\/me\/signals\/([^/]+)\/entered$/.exec(path);
      const subscriptionMatch = /^\/admin\/users\/([^/]+)\/subscriptions$/.exec(path);
      if (eventMatch && method === "GET") {
        await authorized(request, true);
        const signalId = decodeURIComponent(eventMatch[1]);
        const signal = one(await selectRows<Signal>("signals", { select: "id", id: eq(signalId), limit: "1" }));
        if (!signal) throw new HttpError(404, "Signal not found");
        const events = await selectRows<any>("signal_events", {
          select: "event_type,observed_at,details", signal_id: eq(signalId), order: "observed_at.asc", limit: "500",
        });
        result = {
          items: events.map((event) => ({ type: event.event_type, observedAt: event.observed_at, details: event.details })),
          delivery: { fcmConfigured: false, message: "Event data is available; push delivery is not implemented." },
        };
      } else if (enteredMatch && method === "POST") {
        const user = await authorized(request, true), signalId = decodeURIComponent(enteredMatch[1]);
        const payload = await optionalBodyJson(request);
        if (payload.note !== undefined && payload.note !== null && (typeof payload.note !== "string" || payload.note.length > 2000)) {
          throw new HttpError(422, "Invalid note");
        }
        if (!one(await selectRows<{ id: string }>("signals", { select: "id", id: eq(signalId), limit: "1" }))) {
          throw new HttpError(404, "Signal not found");
        }
        const created = one(await db<any[]>("entered_trades", { on_conflict: "user_id,signal_id" }, {
          method: "POST", body: { id: uuid(), user_id: user.id, signal_id: signalId, note: payload.note ?? null, entered_at: isoNow() },
          prefer: "resolution=ignore-duplicates,return=representation",
        }));
        const row = created ?? one(await selectRows<any>("entered_trades", {
          select: "id,signal_id,entered_at,note", user_id: eq(user.id), signal_id: eq(signalId), limit: "1",
        }));
        if (!row) throw new DatabaseError("entered_trades", "Trade insert returned no row");
        result = { id: row.id, signalId: row.signal_id, enteredAt: row.entered_at, note: row.note };
        status = 201;
      } else if (path === "/markets" && method === "GET") {
        const query = url.searchParams.get("query") ?? "";
        if (query.length > 80) throw new HttpError(422, "Query is too long");
        const [marketData, settings] = await Promise.all([getMarkets(), getSettingsRow()]);
        const needle = query.trim().toUpperCase();
        const items = marketData.items.filter((item) =>
          settings.active_exchanges.includes(item.exchange) &&
          (!needle || item.symbol.toUpperCase().includes(needle) || item.base.toUpperCase().includes(needle)))
          .map(({ volume: _volume, ...item }) => item);
        result = { items, providers: marketData.providers };
      } else if (path === "/news" && method === "GET") {
        result = await getNews();
      } else if (path === "/admin/users" && method === "GET") {
        await authorized(request, false, true);
        const limit = Number(url.searchParams.get("limit") ?? 100);
        const offset = Number(url.searchParams.get("offset") ?? 0);
        if (!Number.isInteger(limit) || limit < 1 || limit > 500 || !Number.isInteger(offset) || offset < 0) {
          throw new HttpError(422, "Invalid pagination");
        }
        const users = await selectRows<User>("users", {
          select: "*", order: "created_at.desc", limit: String(limit), offset: String(offset),
        });
        result = { items: users.map((user) => {
          const access = entitlement(user);
          return {
            id: user.id, email: user.email, phone: user.phone, role: user.role,
            emailVerified: !!user.email_verified_at, createdAt: user.created_at,
            status: access.active ? "active" : "expired", accessEndsAt: access.expiresAt,
            expiresAt: access.expiresAt, trialEndsAt: access.trialExpiresAt, entitlement: access,
          };
        }) };
      } else if (subscriptionMatch && method === "POST") {
        await authorized(request, false, true);
        const months = Number((await bodyJson(request)).months);
        if (!Number.isInteger(months) || months < 1 || months > 24) throw new HttpError(422, "months must be between 1 and 24");
        const userId = decodeURIComponent(subscriptionMatch[1]);
        const user = one(await selectRows<User>("users", { select: "*", id: eq(userId), limit: "1" }));
        if (!user) throw new HttpError(404, "User not found");
        const now = new Date(), current = entitlement(user, now);
        const starts = new Date(Math.max(now.getTime(), Date.parse(current.expiresAt)));
        const expiry = addCalendarMonths(starts, months);
        const updated = await updateRows<User>("users", { id: eq(userId) }, { paid_until: expiry.toISOString() });
        if (!updated.length) throw new DatabaseError("users", "Subscription update returned no user");
        result = { userId, months, startsAt: starts.toISOString(), expiresAt: expiry.toISOString(), active: true };
      } else if (path === "/admin/signals" && method === "GET") {
        await authorized(request, false, true);
        const limit = Number(url.searchParams.get("limit") ?? 200);
        if (!Number.isInteger(limit) || limit < 1 || limit > 500) throw new HttpError(422, "Invalid limit");
        const rows = await selectRows<Signal>("signals", { select: "*", order: "created_at.desc", limit: String(limit) });
        result = { items: rows.map(serializeSignal) };
      } else if (path === "/admin/settings" && method === "GET") {
        await authorized(request, false, true);
        const settings = await getSettingsRow();
        result = {
          minSignalScore: settings.min_signal_score, activeExchanges: settings.active_exchanges,
          minimumSignalScore: settings.min_signal_score, exchanges: settings.active_exchanges,
          settings: {
            minSignalScore: settings.min_signal_score, minimumSignalScore: settings.min_signal_score,
            activeExchanges: settings.active_exchanges, exchanges: settings.active_exchanges,
          },
          allowedExchanges: EXCHANGES,
        };
      } else if (path === "/admin/settings" && method === "PUT") {
        await authorized(request, false, true);
        const payload = await bodyJson(request);
        const score = Number(payload.minSignalScore ?? payload.minimumSignalScore);
        const activeExchanges = payload.activeExchanges ?? payload.exchanges;
        if (!Number.isInteger(score) || score < MIN_SIGNAL_SCORE || score > 100) {
          throw new HttpError(422, "minSignalScore must be between 65 and 100");
        }
        if (!Array.isArray(activeExchanges) || !activeExchanges.length ||
          activeExchanges.some((item) => typeof item !== "string" || !EXCHANGES.includes(item as Exchange)) ||
          new Set(activeExchanges).size !== activeExchanges.length) {
          throw new HttpError(422, "activeExchanges may contain unique values from binance, bybit, okx");
        }
        const updated = one(await updateRows<PlatformSettings>("platform_settings", { id: "eq.1" }, {
          min_signal_score: score, active_exchanges: activeExchanges, updated_at: isoNow(),
        }));
        if (!updated) throw new DatabaseError("platform_settings", "Settings update returned no row");
        result = {
          minSignalScore: updated.min_signal_score, activeExchanges: updated.active_exchanges,
          minimumSignalScore: updated.min_signal_score, exchanges: updated.active_exchanges,
          settings: {
            minSignalScore: updated.min_signal_score, minimumSignalScore: updated.min_signal_score,
            activeExchanges: updated.active_exchanges, exchanges: updated.active_exchanges,
          },
          allowedExchanges: EXCHANGES,
        };
      } else if (path === "/scan" && method === "POST") {
        const scanSecret = env("SCAN_SECRET");
        const supplied = request.headers.get("x-scan-secret") ??
          (/^Bearer\s+(.+)$/i.exec(request.headers.get("authorization") ?? "")?.[1] ?? "");
        if (!scanSecret || !supplied || !constantTimeEqual(encoder.encode(scanSecret), encoder.encode(supplied))) {
          throw new HttpError(401, "Invalid scan authorization");
        }
        result = { status: "ok", ...(await runScan()) };
      } else {
        const knownPath = ["/health", "/auth/register", "/auth/verify", "/auth/verify/request", "/auth/login",
          "/me/entitlement", "/me/session-hours", "/me/journal", "/me/settings", "/me/alerts", "/signals",
          "/markets", "/news", "/admin/users", "/admin/signals", "/admin/settings", "/scan"].includes(path) ||
          /^\/(signals\/[^/]+\/events|me\/signals\/[^/]+\/entered|admin\/users\/[^/]+\/subscriptions)$/.test(path);
        if (knownPath) throw new HttpError(405, "Method not allowed");
        throw new HttpError(404, "Not found");
      }
    }
    return json(result, status, cors);
  } catch (error) {
    const response = sanitizeError(error);
    return new Response(response.body, { status: response.status, headers: { ...JSON_HEADERS, ...cors } });
  }
}

if (import.meta.main) Deno.serve(handleRequest);
