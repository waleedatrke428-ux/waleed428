# Scheduling the signal scanner

The Edge Function exposes `POST /functions/v1/api/scan`. It is not callable by
ordinary app users: every request must include the server-only `SCAN_SECRET`
as `X-Scan-Secret` (or a bearer value). Do not put that secret in either
Flutter app, source control, SQL migration values, or client-side configuration.

1. Deploy `api` and configure its server-side `SCAN_SECRET` using Supabase
   function secrets. Configure `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, and
   `JWT_SECRET` there as well; add `BREVO_API_KEY` and `SMTP_FROM` only if
   verification emails should be sent.
2. Enable the `pg_cron`, `pg_net`, and Vault extensions in the Supabase
   dashboard. In Vault, create two secrets named `signals_api_function_url`
   (the complete `https://<project-ref>.supabase.co/functions/v1/api/scan`
   URL) and `signals_api_scan_secret` (the same value configured as
   `SCAN_SECRET`). Add the actual values through the dashboard, never into a
   migration or checked-in SQL file.
3. Run this scheduling statement in the SQL editor after both Vault secrets
   exist. It invokes the scanner every five minutes without storing any
   credential in the scheduled command:

```sql
select cron.schedule(
  'signals-edge-scan',
  '*/5 * * * *',
  $scan$
    select net.http_post(
      url := (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'signals_api_function_url'
      ),
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'X-Scan-Secret', (
          select decrypted_secret
          from vault.decrypted_secrets
          where name = 'signals_api_scan_secret'
        )
      ),
      body := '{}'::jsonb
    );
  $scan$
);
```

Confirm runs and HTTP responses in the `cron.job_run_details` and `net._http_response`
views. To unschedule it, run:

```sql
select cron.unschedule('signals-edge-scan');
```

The scanner logs provider/database failures and skips unavailable market data;
it does not create placeholder signals. The function URL and scan secret must
both exist in Vault before enabling the schedule.
