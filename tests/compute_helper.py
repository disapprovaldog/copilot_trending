"""
Extracted computation logic — mirrors the embedded Python in copilot_usage.zsh / copilot_usage.ps1.
Update this file whenever the embedded logic in either script changes.
"""
from datetime import datetime, timedelta


def biz_hours(a, b, biz_start=8, biz_end=17):
    """Elapsed business hours (M–F 08:00–17:00 local) between two aware datetimes."""
    if b <= a:
        return 0.0
    total = 0.0
    cur = a
    while cur.date() <= b.date():
        if cur.weekday() < 5:
            day_open  = cur.replace(hour=biz_start, minute=0, second=0, microsecond=0)
            day_close = cur.replace(hour=biz_end,   minute=0, second=0, microsecond=0)
            period_start = max(cur, day_open)
            period_end   = min(b, day_close) if b.date() == cur.date() else day_close
            if period_end > period_start:
                total += (period_end - period_start).total_seconds() / 3600.0
        cur = (cur + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    return total


def parse_iso(s):
    s = s.strip()
    if s.endswith('Z'):
        s = s[:-1] + '+00:00'
    return datetime.fromisoformat(s).astimezone()


def compute_usage(raw: dict, now: datetime) -> dict:
    """Return dict with 'prompt' and 'detail' strings given a raw API response dict and a reference time."""
    plan      = raw.get("copilot_plan", "unknown")
    snapshots = raw.get("quota_snapshots", {})
    reset_str = raw.get("quota_reset_date_utc") or raw.get("quota_reset_date", "")

    quota      = None
    quota_name = "none"
    for key in ("premium_interactions", "chat", "completions"):
        s = snapshots.get(key, {})
        if s.get("has_quota"):
            quota      = s
            quota_name = key
            break

    month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)

    if reset_str:
        reset_dt = parse_iso(reset_str)
    else:
        y, m = (now.year + 1, 1) if now.month == 12 else (now.year, now.month + 1)
        reset_dt = now.replace(year=y, month=m, day=1, hour=0, minute=0, second=0, microsecond=0)

    biz_elapsed = biz_hours(month_start, now)
    biz_total   = biz_hours(month_start, reset_dt)
    biz_remain  = max(0.0, biz_total - biz_elapsed)

    if quota:
        entitlement = int(quota.get("entitlement", 0) or 0)
        remaining   = int(quota.get("remaining",   0) or 0)
        pct_remain  = float(quota.get("percent_remaining", 100.0))
        used        = max(0, entitlement - remaining)
        pct_used    = (used / entitlement * 100.0) if entitlement else 0.0

        if biz_elapsed > 0 and entitlement > 0:
            rate      = used / biz_elapsed
            projected = rate * biz_total
            pct_proj  = projected / entitlement * 100.0
            rate_str  = f"{rate:.1f}/biz-hr"
            proj_str  = f"{projected:.0f} ({pct_proj:.0f}% of quota)"
        else:
            rate      = 0.0
            projected = 0
            pct_proj  = 0.0
            rate_str  = "n/a (no biz hrs yet)"
            proj_str  = "n/a"

        if   pct_used < 50:  icon = "🟢"
        elif pct_used < 75:  icon = "🟡"
        elif pct_used < 90:  icon = "🟠"
        else:                icon = "🔴"

        pct_used_prompt = f"{pct_used:.1f}%"
        if biz_elapsed > 0:
            prompt = f"{icon} {used}/{entitlement} ({pct_used_prompt}) ↗ {projected:.0f}"
        else:
            prompt = f"{icon} {used}/{entitlement} ({pct_used_prompt})"

        detail = "\n".join([
            f"Plan             : {plan}",
            f"Quota bucket     : {quota_name}",
            f"Used             : {used:,} / {entitlement:,}  ({pct_used:.1f}%)",
            f"Remaining        : {remaining:,}  ({pct_remain:.1f}%)",
            "",
            f"Biz hrs elapsed  : {biz_elapsed:.1f} h",
            f"Biz hrs total    : {biz_total:.1f} h",
            f"Biz hrs left     : {biz_remain:.1f} h",
            f"Rate             : {rate_str}",
            f"Projected EOM    : {proj_str}",
            "",
            f"Quota resets     : {reset_str}",
        ])
    else:
        icon   = "♾️ "
        prompt = f"{icon} {plan} (unlimited)"
        detail = "\n".join([
            f"Plan             : {plan}",
            f"Quota            : unlimited",
            f"Quota resets     : {reset_str}",
        ])

    return {"prompt": prompt, "detail": detail}
