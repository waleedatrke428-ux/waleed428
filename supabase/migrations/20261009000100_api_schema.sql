create extension if not exists pgcrypto;

create table public.users (
  id uuid primary key default gen_random_uuid(),
  phone varchar(32) not null unique,
  email varchar(320) not null unique,
  password_hash varchar(255) not null,
  role varchar(16) not null default 'user' check (role in ('user', 'admin')),
  email_verified_at timestamptz,
  trial_started_at timestamptz not null default now(),
  paid_until timestamptz,
  created_at timestamptz not null default now()
);
create unique index users_email_lower_idx on public.users (lower(email));

create table public.verification_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  token_hash char(64) not null unique,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index verification_tokens_user_id_idx on public.verification_tokens(user_id);
create index verification_tokens_expires_at_idx on public.verification_tokens(expires_at);

create table public.signals (
  id uuid primary key default gen_random_uuid(),
  exchange varchar(16) not null check (exchange in ('binance', 'bybit', 'okx')),
  symbol varchar(48) not null,
  direction varchar(8) not null check (direction in ('long', 'short')),
  score integer not null check (score between 65 and 100),
  timeframe varchar(16) not null,
  entry double precision not null,
  stop_loss double precision not null,
  tp1 double precision not null,
  tp2 double precision not null,
  tp3 double precision not null,
  status varchar(16) not null default 'active'
    check (status in ('active', 'stopped', 'target3', 'reversed')),
  rationale text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index signals_state_created_idx on public.signals(status, created_at desc);
create index signals_symbol_exchange_status_idx on public.signals(exchange, symbol, status);
create unique index signals_one_active_market_idx on public.signals(exchange, symbol) where status = 'active';

create table public.entered_trades (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  signal_id uuid not null references public.signals(id) on delete cascade,
  note text check (note is null or char_length(note) <= 2000),
  entered_at timestamptz not null default now(),
  constraint entered_trades_user_signal_unique unique(user_id, signal_id)
);
create index entered_trades_user_id_idx on public.entered_trades(user_id);
create index entered_trades_signal_id_idx on public.entered_trades(signal_id);
create index entered_trades_entered_at_idx on public.entered_trades(entered_at desc);

create table public.user_settings (
  user_id uuid primary key references public.users(id) on delete cascade,
  email_notifications boolean not null default true,
  push_notifications boolean not null default false,
  fcm_token varchar(512)
);

create table public.platform_settings (
  id integer primary key check (id = 1),
  min_signal_score integer not null default 65 check (min_signal_score between 65 and 100),
  active_exchanges jsonb not null default '["binance","bybit","okx"]'::jsonb
    check (
      jsonb_typeof(active_exchanges) = 'array'
      and jsonb_array_length(active_exchanges) > 0
      and active_exchanges <@ '["binance","bybit","okx"]'::jsonb
    ),
  updated_at timestamptz not null default now()
);
insert into public.platform_settings(id) values (1);

create table public.signal_events (
  id uuid primary key default gen_random_uuid(),
  signal_id uuid not null references public.signals(id) on delete cascade,
  event_type varchar(32) not null,
  observed_at timestamptz not null default now(),
  details jsonb not null default '{}'::jsonb,
  constraint signal_events_signal_type_unique unique(signal_id, event_type)
);
create index signal_events_signal_id_idx on public.signal_events(signal_id);
create index signal_events_observed_at_idx on public.signal_events(observed_at desc);

alter table public.users enable row level security;
alter table public.verification_tokens enable row level security;
alter table public.signals enable row level security;
alter table public.entered_trades enable row level security;
alter table public.user_settings enable row level security;
alter table public.platform_settings enable row level security;
alter table public.signal_events enable row level security;

revoke all on table public.users, public.verification_tokens, public.signals,
  public.entered_trades, public.user_settings, public.platform_settings, public.signal_events
  from public, anon, authenticated;
grant all on table public.users, public.verification_tokens, public.signals,
  public.entered_trades, public.user_settings, public.platform_settings, public.signal_events
  to service_role;

create or replace function public.register_user(
  p_id uuid,
  p_phone text,
  p_email text,
  p_password_hash text,
  p_role text,
  p_created_at timestamptz
)
returns setof public.users
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.users(id, phone, email, password_hash, role, trial_started_at, created_at)
  values (p_id, p_phone, p_email, p_password_hash, p_role, p_created_at, p_created_at);
  insert into public.user_settings(user_id) values (p_id);
  return query select * from public.users where id = p_id;
end;
$$;
revoke all on function public.register_user(uuid, text, text, text, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.register_user(uuid, text, text, text, text, timestamptz)
  to service_role;

create or replace function public.consume_verification_token(p_token_hash text)
returns boolean
language sql
security definer
set search_path = ''
as $$
  with consumed as (
    delete from public.verification_tokens
    where token_hash = p_token_hash and expires_at > now()
    returning user_id
  ),
  verified as (
    update public.users
    set email_verified_at = now()
    where id in (select user_id from consumed) and email_verified_at is null
    returning id
  )
  select exists(select 1 from verified);
$$;
revoke all on function public.consume_verification_token(text) from public, anon, authenticated;
grant execute on function public.consume_verification_token(text) to service_role;
