# Informational futures-signals API

This is a separate FastAPI/PostgreSQL service. It is informational only: it never
places exchange orders, and its 0â€“100 technical-confluence score is not a
probability, win rate, or investment recommendation.

## Local startup

1. Copy `.env.example` to `.env` in this directory. Set `JWT_SECRET` to a
   private random value of at least 32 characters; do not commit `.env`.
   Set `POSTGRES_PASSWORD` to an alphanumeric local password (compose uses it
   in the local database URL). Add `ADMIN_EMAILS` as a comma-separated list of
   addresses that may become administrators when registering.
2. From this directory run `docker compose up --build`.
3. The API is at `http://localhost:8000`; OpenAPI docs are at `/docs`. Health
   check is `GET /health`. On first start the container applies Alembic
   migrations before serving traffic.

The compose build context is the project root so the image can copy the server
code. Management is performed by the separate Android manager app; this API
does not serve a web dashboard. Both Android apps must use this API base URL
over HTTPS (`API_BASE_URL` in GitHub Actions; `MANAGER_API_BASE_URL` may
override it for the manager). The old PHP-only host cannot provide the
authentication, entitlement, signal, or management API. On a VPS, terminate
TLS in a reverse proxy and proxy the API and health check to the container; for
example:

```nginx
location /api/ { proxy_pass http://127.0.0.1:8000; }
location = /health { proxy_pass http://127.0.0.1:8000; }
```

Persist the compose `postgres_data` volume and protect the host/DB network. For
production, replace local passwords/secrets, use TLS, set `APP_BASE_URL` and
restrict `ALLOWED_ORIGINS`. No deployment or credential provisioning is done
by this repository.

## Free trial deployment

The repository includes a Render Blueprint in `../render.yaml`. For a free
trial, create a Supabase PostgreSQL project and a Render Blueprint from this
repository; supply the Supabase connection string as `DATABASE_URL` (use the
`postgresql+psycopg://` SQLAlchemy driver and require TLS), and keep the
generated `JWT_SECRET`. Set `ADMIN_EMAILS` to the administrator's email.
Supabase's free database currently has a 500 MB limit and may pause after a
week without activity; Render's free API sleeps after 15 minutes without
requests and can take about a minute to wake. The scanner pauses while the API
is asleep, so this is suitable only for a test/closed beta, not timely production
signals. Confirm the current quotas and availability in the providers'
dashboards before using real subscriber data.

Render blocks outbound SMTP ports on free services. To send account-verification
mail there, configure a Brevo account, verify a sender address, then provide
`BREVO_API_KEY` and that address as `SMTP_FROM` in Render's environment. The
mailer uses Brevo's HTTPS API when that key is present and retains SMTP support
for other deployments. Never commit provider keys or send them in chat.

After Render deploys successfully, copy its HTTPS service URL into the GitHub
repository variable `API_BASE_URL` under **Settings → Secrets and variables →
Actions → Variables**. Re-run the Android workflow to bake that URL into both
APK files. The manager app uses `MANAGER_API_BASE_URL` only when you explicitly
set it; otherwise it shares `API_BASE_URL`.

## Configuration

| Variable | Purpose |
| --- | --- |
| `DATABASE_URL` | SQLAlchemy PostgreSQL URL |
| `JWT_SECRET` | HS256 signing secret, minimum 32 characters |
| `ACCESS_TOKEN_MINUTES` | Bearer-token lifetime (default 30) |
| `ADMIN_EMAILS` | Emails assigned the admin role at registration; still require email verification |
| `APP_BASE_URL` | Service URL for deployment integrations |
| `BREVO_API_KEY` | Optional HTTPS transactional-email API key (used before SMTP) |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM`, `SMTP_STARTTLS` | SMTP verification-email delivery |
| `ALLOWED_ORIGINS` | Comma-separated browser origins for CORS; same-origin needs no extra origin |
| `POSTGRES_PASSWORD` | Compose-only database password |

If neither Brevo (`BREVO_API_KEY` and `SMTP_FROM`) nor SMTP delivery is
configured, registration remains pending verification and the API reports
`verificationEmailSent: false`; it never returns a verification token in the
HTTP response. Configure one of those mail providers and call
`POST /api/auth/verify/request` to send a token. FCM/push delivery is not
implemented; event and user alert data are exposed for later integration, but
no push is represented as sent.

## API contract

All timestamps are ISO 8601 UTC unless a field explicitly describes a local
display timezone. JSON errors use FastAPI's `detail`.

### Flutter client

- `POST /api/auth/register` body `{ "phone", "email", "password" }`; creates a
  five-day server-timed trial immediately, but requires verified email before
  login. Passwords are Argon2-hashed.
- `POST /api/auth/login` body `{ "email", "password" }`; returns
  `{ "accessToken", "tokenType": "Bearer", "expiresIn", "id", "email", "role", "user" }`.
  A verified account is required. The manager app additionally requires the
  returned role to be `admin`.
- `POST /api/auth/verify` body `{ "token" }`; consumes a single-use token.
  `POST /api/auth/verify/request` body `{ "email" }` requests another email;
  its generic response avoids account enumeration.
- `GET /api/me/entitlement` requires bearer auth and returns
  `{ serverTime, trialExpiresAt, subscriptionExpiresAt, expiresAt, active, remainingSeconds }`.
  The trial ends exactly five days from server-recorded registration time;
  access is inactive at the exclusive expiry boundary.
- `GET /api/signals` requires a bearer token and active entitlement. Response:
  `{ "items": [...] }` (plus score meaning and disclaimer). Signal items include
  `id`, `exchange`, `symbol`, `direction`, `score`, `scoreType:
  "technical_confluence"`, `timeframe`, `entry`, `stopLoss`, `takeProfits`
  (TP1â€“TP3 array), `status`, `rationale`, and UTC timestamps. Only candidates
  with score >=65 are stored/published.
- `GET /api/markets?query=` is public and returns `{ "items":
  [{ "exchange", "symbol", "base", "quote", "score" }], "providers": {...} }`.
  `score` here is a logarithmic 24-hour activity/sort index, not the technical
  signal score. Provider errors are reported as `unavailable`; other exchanges
  can still return data. Search matches symbol/base across the complete
  provider market lists (subject to provider pagination).
- `GET /api/news` is public and returns `{ "items":
  [{ "title", "source", "url", "publishedAt" }], "providers": {...} }`.
  Headlines are link-only and retain RSS source attribution.
- `POST /api/me/signals/{id}/entered` body `{ "note"?: string }` records a
  user-specific entered-trade journal entry; repeating it is idempotent.
  `GET /api/me/journal` lists that user's entries.
- `GET /api/me/alerts` lists event records for signals the user entered;
  `GET/PUT /api/me/settings` manages per-user alert preferences. The client may
  send `X-Timezone: Europe/Paris` (IANA timezone derived from device settings,
  not GPS) to `GET /api/me/session-hours`; London reference hours (08:00â€“17:00)
  are also returned converted to that local timezone.
- `GET /api/signals/{id}/events` returns persisted entry, stop, target, reversal
  and signal-created event data. The response explicitly reports that FCM
  delivery is not configured.

### Manager app administration

Every `/api/admin/*` request is authorized by the role stored in PostgreSQL;
the token's role claim alone is never trusted. Admin accounts are bootstrapped
only for configured `ADMIN_EMAILS`, after normal email verification. Register
the configured administrator email using the user app, complete email
verification, and sign in to the separate manager app. The manager app has no
public registration flow.

- `GET /api/admin/users` -> `{ "items": [{ "id", "email", "phone", "role",
  "status", "accessEndsAt", "expiresAt", "trialEndsAt", "entitlement", ... }] }`.
- `POST /api/admin/users/{id}/subscriptions` body `{ "months": 1..24 }` ->
  `{ "userId", "months", "startsAt", "expiresAt", "active" }`. Calendar months
  begin at the later of server-now or existing entitlement expiry.
- `GET /api/admin/signals` -> `{ "items": [signal, ...] }`.
- `GET /api/admin/settings` -> `{ "minSignalScore", "activeExchanges",
  "minimumSignalScore", "exchanges", "settings", "allowedExchanges" }`.
- `PUT /api/admin/settings` accepts either canonical Flutter fields
  `{ "minSignalScore": 65..100, "activeExchanges": ["binance","bybit","okx"] }`
  (legacy aliases are also accepted). Both naming styles are returned for
  compatibility; validation rejects score <65 and
  unknown/duplicate exchange IDs.

## Scanner and explicit boundaries

The automatic scanner calls only public market-data endpoints: Binance USDâ“ˆ-M
Futures, Bybit linear perpetuals, and OKX USDT swaps. Every five minutes it
cycles through all listed markets in batches of three per enabled exchange. The
1D and 4H moving-average directions must agree before a candidate is considered;
1H trend supplies trigger-context confluence; closed 15m candles supply the entry trigger, local support/resistance, volume, RSI, and structure-break checks. It stores only scores at/above the configured floor
(never below 65). Lifecycle
monitoring records entry/SL/TP1â€“TP3 and qualified opposite-signal reversals.
Provider failures skip affected symbols and are logged; public market/news
responses include per-provider availability rather than fabricating results.
Scanning is a single-process in-memory scheduler; run one API worker/replica
unless a distributed scan lease is added. The deterministic rules have not been
backtested and carry no performance or profitability claims.

This core does not send FCM/email notifications beyond verification, calculate
exchange execution prices, execute trades, collect GPS, or claim that any
signal is profitable. Signals may be absent when market data is unavailable
or no analysis qualifies. Manual subscriptions only extend access; no payment
gateway or SMS verification is included.

## Tests

With the dependencies in `requirements.txt` installed, run `pytest -q` from
this directory. Tests cover indicator outputs, the >=65 signal gate, entitlement
expiry boundary, calendar-month extension, password/token handling and admin
settings validation.
