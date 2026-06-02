# copilot_usage.zsh — GitHub Copilot usage tracking + Starship prompt
# Source in ~/.zshrc:  source /path/to/copilot_usage.zsh
#
# Requirements: gh (authenticated), python3, curl
#
# ─── Starship setup ────────────────────────────────────────────────────────
# Add to ~/.config/starship.toml:
#
# [custom.copilot]
# command = "cat ~/.cache/copilot_usage/prompt.txt 2>/dev/null"
# when    = "test -f ~/.cache/copilot_usage/prompt.txt"
# shell   = ["sh"]
# format  = "[$output]($style) "
# style   = "bold cyan"
# ───────────────────────────────────────────────────────────────────────────

_COPILOT_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/copilot_usage"
_COPILOT_REFRESH_SECS=300   # re-fetch every 5 minutes

# ── internal: fetch API + compute projection, write cache files ──────────
_copilot_usage_fetch() {
  local cache_dir="$_COPILOT_CACHE_DIR"
  mkdir -p "$cache_dir"

  local token
  token=$(gh auth token 2>/dev/null) || {
    print -u2 "copilot_usage: gh not authenticated"; return 1
  }

  local raw
  raw=$(curl -sf -L \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/copilot_internal/user 2>/dev/null) || {
    print -u2 "copilot_usage: API request failed"; return 1
  }

  printf '%s\n' "$raw" > "$cache_dir/raw.json"
  date +%s > "$cache_dir/last_fetch"

  # All computation in one Python call — avoids repeated subprocess overhead
  python3 - "$raw" "$cache_dir" <<'PYEOF'
import sys, json, os
from datetime import datetime, timedelta

def biz_hours(a, b, biz_start=8, biz_end=17):
    """Elapsed business hours (M–F 08:00–17:00 local) between two aware datetimes."""
    if b <= a:
        return 0.0
    total = 0.0
    cur = a
    while cur.date() <= b.date():
        if cur.weekday() < 5:            # Monday=0 … Friday=4
            day_open  = cur.replace(hour=biz_start, minute=0, second=0, microsecond=0)
            day_close = cur.replace(hour=biz_end,   minute=0, second=0, microsecond=0)
            period_start = max(cur, day_open)
            period_end   = min(b, day_close) if b.date() == cur.date() else day_close
            if period_end > period_start:
                total += (period_end - period_start).total_seconds() / 3600.0
        cur = (cur + timedelta(days=1)).replace(
            hour=0, minute=0, second=0, microsecond=0)
    return total

def parse_iso(s):
    s = s.strip()
    if s.endswith('Z'):
        s = s[:-1] + '+00:00'
    return datetime.fromisoformat(s).astimezone()

raw       = json.loads(sys.argv[1])
cache_dir = sys.argv[2]

plan      = raw.get("copilot_plan", "unknown")
snapshots = raw.get("quota_snapshots", {})
reset_str = raw.get("quota_reset_date_utc") or raw.get("quota_reset_date", "")

# Pick the first quota bucket that actually has a limit
quota = None
quota_name = "none"
for key in ("premium_interactions", "chat", "completions"):
    s = snapshots.get(key, {})
    if s.get("has_quota"):
        quota      = s
        quota_name = key
        break

now         = datetime.now().astimezone()
month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)

if reset_str:
    reset_dt = parse_iso(reset_str)
else:
    # Fall back: first of next month
    y, m = (now.year + 1, 1) if now.month == 12 else (now.year, now.month + 1)
    reset_dt = now.replace(year=y, month=m, day=1,
                           hour=0, minute=0, second=0, microsecond=0)

biz_elapsed = biz_hours(month_start, now)
biz_total   = biz_hours(month_start, reset_dt)
biz_remain  = max(0.0, biz_total - biz_elapsed)

if quota:
    entitlement  = int(quota.get("entitlement", 0) or 0)
    remaining    = int(quota.get("remaining",   0) or 0)
    pct_remain   = float(quota.get("percent_remaining", 100.0))
    used         = max(0, entitlement - remaining)
    pct_used     = (used / entitlement * 100.0) if entitlement else 0.0

    # Rate-based projection over full billing period
    if biz_elapsed > 0 and entitlement > 0:
        rate        = used / biz_elapsed          # interactions per biz-hour
        projected   = rate * biz_total
        pct_proj    = projected / entitlement * 100.0
        rate_str    = f"{rate:.1f}/biz-hr"
        proj_str    = f"{projected:.0f} ({pct_proj:.0f}% of quota)"
    else:
        rate        = 0.0
        projected   = 0
        pct_proj    = 0.0
        rate_str    = "n/a (no biz hrs yet)"
        proj_str    = "n/a"

    # Status icon based on % used
    if   pct_used < 50:  icon = "🟢"
    elif pct_used < 75:  icon = "🟡"
    elif pct_used < 90:  icon = "🟠"
    else:                icon = "🔴"

    # Compact prompt string consumed by Starship
    if biz_elapsed > 0:
        prompt = f"{icon} {used}/{entitlement} ({pct_used:.0f}%) ↗ {projected:.0f}"
    else:
        prompt = f"{icon} {used}/{entitlement} ({pct_used:.0f}%)"

    # Full detail for copilot_usage_info
    detail = "\n".join([
        f"Plan             : {plan}",
        f"Quota bucket     : {quota_name}",
        f"Used             : {used:,} / {entitlement:,}  ({pct_used:.1f}%)",
        f"Remaining        : {remaining:,}  ({pct_remain:.1f}%)",
        f"",
        f"Biz hrs elapsed  : {biz_elapsed:.1f} h",
        f"Biz hrs total    : {biz_total:.1f} h",
        f"Biz hrs left     : {biz_remain:.1f} h",
        f"Rate             : {rate_str}",
        f"Projected EOM    : {proj_str}",
        f"",
        f"Quota resets     : {reset_str}",
    ])
else:
    # Unlimited plan — nothing meaningful to project
    icon   = "♾️ "
    prompt = f"{icon} {plan} (unlimited)"
    detail = "\n".join([
        f"Plan             : {plan}",
        f"Quota            : unlimited",
        f"Quota resets     : {reset_str}",
    ])

with open(os.path.join(cache_dir, "prompt.txt"), "w") as fh:
    fh.write(prompt)
with open(os.path.join(cache_dir, "detail.txt"), "w") as fh:
    fh.write(detail + "\n")
PYEOF
}

# ── public: human-readable summary ──────────────────────────────────────
copilot_usage_info() {
  local detail="$_COPILOT_CACHE_DIR/detail.txt"
  if [[ ! -f "$detail" ]]; then
    print "No cached data yet — run: copilot_usage_update"
    return 1
  fi
  cat "$detail"
  printf '\nCached: %s\n' \
    "$(date -r "$(< "$_COPILOT_CACHE_DIR/last_fetch")" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
       || date -d "@$(< "$_COPILOT_CACHE_DIR/last_fetch")" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
       || cat "$_COPILOT_CACHE_DIR/last_fetch")"
}

# ── public: force a synchronous refresh ─────────────────────────────────
copilot_usage_update() {
  print "Fetching GitHub Copilot usage…"
  if _copilot_usage_fetch; then
    print "$(< "$_COPILOT_CACHE_DIR/prompt.txt")"
  fi
}

# ── internal: precmd hook — async refresh when cache is stale ───────────
_copilot_usage_precmd() {
  local last_fetch=0
  [[ -f "$_COPILOT_CACHE_DIR/last_fetch" ]] && last_fetch=$(< "$_COPILOT_CACHE_DIR/last_fetch")
  if (( $(date +%s) - last_fetch > _COPILOT_REFRESH_SECS )); then
    ( _copilot_usage_fetch &>/dev/null & )
  fi
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _copilot_usage_precmd
