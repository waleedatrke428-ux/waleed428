import calendar
from datetime import datetime, timedelta, timezone

TRIAL_DAYS = 5


def as_utc(value: datetime) -> datetime:
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def entitlement(user, now: datetime | None = None) -> dict:
    current = as_utc(now or datetime.now(timezone.utc))
    trial_expiry = as_utc(user.trial_started_at) + timedelta(days=TRIAL_DAYS)
    paid_until = as_utc(user.paid_until) if user.paid_until else None
    expiry = max((trial_expiry, paid_until) if paid_until else (trial_expiry,))
    return {
        "serverTime": current,
        "trialExpiresAt": trial_expiry,
        "subscriptionExpiresAt": paid_until,
        "expiresAt": expiry,
        "active": current < expiry,
    }


def extend_subscription(user, months: int, now: datetime | None = None) -> datetime:
    if not 1 <= months <= 24:
        raise ValueError("months must be between 1 and 24")
    current = as_utc(now or datetime.now(timezone.utc))
    current_expiry = entitlement(user, current)["expiresAt"]
    starts_at = max(current, current_expiry)
    month_index = starts_at.month - 1 + months
    year = starts_at.year + month_index // 12
    month = month_index % 12 + 1
    day = min(starts_at.day, calendar.monthrange(year, month)[1])
    new_expiry = starts_at.replace(year=year, month=month, day=day)
    user.paid_until = new_expiry
    return new_expiry
