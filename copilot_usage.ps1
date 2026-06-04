# copilot_usage.ps1 — GitHub Copilot usage tracking + prompt for PowerShell
# Dot-source in your profile:  . /path/to/copilot_usage.ps1
#
# NOTE: Quota tracking only has meaning if your GitHub organization has
# configured a Copilot usage quota. Without an org-level quota the API
# returns no entitlement data and the prompt shows "unlimited" regardless
# of actual consumption.
#
# Requirements: gh (authenticated), python3 (or python)
#
# ─── Starship setup (optional, PowerShell 7 / pwsh) ────────────────────────
# Add to ~/.config/starship.toml:
#
# [custom.copilot]
# command = "Get-Content \"$HOME/.cache/copilot_usage/prompt.txt\""
# when    = "if (-not (Test-Path \"$HOME/.cache/copilot_usage/prompt.txt\")) { exit 1 }"
# shell   = ["pwsh", "-NoProfile", "-NonInteractive", "-Command"]
# format  = "[$output]($style) "
# style   = "bold cyan"
#
# Without Starship the status is prepended to your existing prompt automatically.
# ───────────────────────────────────────────────────────────────────────────

$global:_CopilotCacheDir    = Join-Path (Join-Path $HOME ".cache") "copilot_usage"
$global:_CopilotRefreshSecs = 300
$global:_CopilotJobId       = $null
$global:_CopilotPython      = $null
foreach ($_pyCandidate in @('python3', 'python', 'py')) {
    if (Get-Command $_pyCandidate -ErrorAction SilentlyContinue) {
        $testOut = & $_pyCandidate -c "print('ok')" 2>&1
        if ("$testOut" -match 'ok') { $global:_CopilotPython = $_pyCandidate; break }
    }
}
Remove-Variable _pyCandidate -ErrorAction SilentlyContinue

# ── embedded Python — same computation logic as the zsh version ─────────────
$global:_CopilotPyScript = @'
import sys, json, os
from datetime import datetime, timedelta

def biz_hours(a, b, biz_start=8, biz_end=17):
    """Elapsed business hours (M-F 08:00-17:00 local) between two aware datetimes."""
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

raw_file  = sys.argv[1]
cache_dir = sys.argv[2]

with open(raw_file, encoding='utf-8') as fh:
    raw = json.load(fh)

plan      = raw.get("copilot_plan", "unknown")
snapshots = raw.get("quota_snapshots", {})
reset_str = raw.get("quota_reset_date_utc") or raw.get("quota_reset_date", "")

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

    if   pct_used < 50:  icon = "\U0001f7e2"
    elif pct_used < 75:  icon = "\U0001f7e1"
    elif pct_used < 90:  icon = "\U0001f7e0"
    else:                icon = "\U0001f534"

    if biz_elapsed > 0:
        prompt = f"{icon} {used}/{entitlement} ({pct_used:.1f}%) ↗ {projected:.0f}"
    else:
        prompt = f"{icon} {used}/{entitlement} ({pct_used:.1f}%)"

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
    icon   = "♾️ "
    prompt = f"{icon} {plan} (unlimited)"
    detail = "\n".join([
        f"Plan             : {plan}",
        f"Quota            : unlimited",
        f"Quota resets     : {reset_str}",
    ])

with open(os.path.join(cache_dir, "prompt.txt"), "w", encoding="utf-8") as fh:
    fh.write(prompt)
with open(os.path.join(cache_dir, "detail.txt"), "w", encoding="utf-8") as fh:
    fh.write(detail + "\n")
'@

# ── internal: fetch API + compute projection, write cache files ─────────────
function _Copilot-Fetch {
    [CmdletBinding()]
    param(
        [string]$CacheDir = $global:_CopilotCacheDir,
        [string]$Python   = $global:_CopilotPython,
        [string]$PyScript = $global:_CopilotPyScript
    )

    if (-not $Python) {
        Write-Error "copilot_usage: python3/python not found in PATH" -ErrorAction Continue
        return $false
    }

    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

    $token = (gh auth token 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        Write-Error "copilot_usage: gh not authenticated" -ErrorAction Continue
        return $false
    }

    $headers = @{
        "Authorization"        = "Bearer $($token.Trim())"
        "Accept"               = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    try {
        $raw = Invoke-RestMethod -Uri "https://api.github.com/copilot_internal/user" `
            -Headers $headers -Method Get
    } catch {
        Write-Error "copilot_usage: API request failed: $_" -ErrorAction Continue
        return $false
    }

    $rawJsonPath = Join-Path $CacheDir "raw.json"
    $raw | ConvertTo-Json -Depth 10 | Set-Content -Path $rawJsonPath -Encoding UTF8
    [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() |
        Set-Content -Path (Join-Path $CacheDir "last_fetch")

    $tmpPy = [System.IO.Path]::GetTempFileName() + ".py"
    try {
        Set-Content -Path $tmpPy -Value $PyScript -Encoding UTF8
        & $Python $tmpPy $rawJsonPath $CacheDir 2>&1 | Out-Null
    } finally {
        Remove-Item -Path $tmpPy -Force -ErrorAction SilentlyContinue
    }
    return (Test-Path (Join-Path $CacheDir "prompt.txt"))
}

# ── public: human-readable summary ───────────────────────────────────────────
function Get-CopilotUsageInfo {
    $detailFile = Join-Path $global:_CopilotCacheDir "detail.txt"
    if (-not (Test-Path $detailFile)) {
        Write-Host "No cached data yet - run: Update-CopilotUsage"
        return
    }
    Get-Content $detailFile
    $lastFetchFile = Join-Path $global:_CopilotCacheDir "last_fetch"
    if (Test-Path $lastFetchFile) {
        $epoch = [long](Get-Content $lastFetchFile -Raw)
        $dt = [System.DateTimeOffset]::FromUnixTimeSeconds($epoch).LocalDateTime
        Write-Host "`nCached: $($dt.ToString('yyyy-MM-dd HH:mm:ss'))"
    }
}
Set-Alias copilot_usage_info Get-CopilotUsageInfo

# ── public: force a synchronous refresh ──────────────────────────────────────
function Update-CopilotUsage {
    Write-Host "Fetching GitHub Copilot usage..."
    if (_Copilot-Fetch) {
        $promptFile = Join-Path $script:_CopilotCacheDir "prompt.txt"
        if (Test-Path $promptFile) { Get-Content $promptFile -Raw | Write-Host }
    }
}
Set-Alias copilot_usage_update Update-CopilotUsage

# ── internal: fire a background refresh job when cache is stale ──────────────
function _Copilot-CheckRefresh {
    if ($global:_CopilotJobId) {
        $job = Get-Job -Id $global:_CopilotJobId -ErrorAction SilentlyContinue
        if ($job -and $job.State -in @('Completed', 'Failed', 'Stopped')) {
            Remove-Job -Id $global:_CopilotJobId -ErrorAction SilentlyContinue
            $global:_CopilotJobId = $null
        } else {
            return  # still running
        }
    }

    $lastFetchFile = Join-Path $global:_CopilotCacheDir "last_fetch"
    $lastFetch = 0
    if (Test-Path $lastFetchFile) {
        $lastFetch = [long](Get-Content $lastFetchFile -Raw)
    }
    if (([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $lastFetch) -le $global:_CopilotRefreshSecs) {
        return
    }

    $cd  = $global:_CopilotCacheDir
    $py  = $global:_CopilotPython
    $pys = $global:_CopilotPyScript

    if (-not $py) { return }

    $job = Start-Job -ScriptBlock {
        param($CacheDir, $Python, $PyScript)

        New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

        $token = (gh auth token 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $token) { return }

        $headers = @{
            "Authorization"        = "Bearer $($token.Trim())"
            "Accept"               = "application/vnd.github+json"
            "X-GitHub-Api-Version" = "2022-11-28"
        }
        try {
            $raw = Invoke-RestMethod -Uri "https://api.github.com/copilot_internal/user" `
                -Headers $headers
        } catch { return }

        $rawJsonPath = Join-Path $CacheDir "raw.json"
        $raw | ConvertTo-Json -Depth 10 | Set-Content -Path $rawJsonPath -Encoding UTF8
        [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() |
            Set-Content -Path (Join-Path $CacheDir "last_fetch")

        $tmpPy = [System.IO.Path]::GetTempFileName() + ".py"
        try {
            Set-Content -Path $tmpPy -Value $PyScript -Encoding UTF8
            & $Python $tmpPy $rawJsonPath $CacheDir 2>&1 | Out-Null
        } finally {
            Remove-Item -Path $tmpPy -Force -ErrorAction SilentlyContinue
        }
    } -ArgumentList $cd, $py, $pys

    $global:_CopilotJobId = $job.Id
}

# ── seed cache on first load if missing ──────────────────────────────────────
$global:_CopilotPromptFile = Join-Path $global:_CopilotCacheDir "prompt.txt"
if (-not (Test-Path $global:_CopilotPromptFile) -and -not $global:_CopilotSeeded) {
    $global:_CopilotSeeded = $true
    Write-Host "copilot_usage: seeding cache..." -NoNewline
    if (_Copilot-Fetch) {
        Write-Host " done"
    } else {
        Write-Host " failed - run: Update-CopilotUsage"
    }
}

# ── prompt hook: inject refresh trigger + status display ─────────────────────
if (-not $global:_CopilotPromptInstalled) {
    $global:_CopilotPromptInstalled = $true

    # Detect if Starship is driving the prompt — if so, skip display injection
    # (Starship reads prompt.txt directly via the custom.copilot block)
    $existing = Get-Item Function:prompt -ErrorAction SilentlyContinue
    $global:_CopilotHasStarship = (Get-Command starship -ErrorAction SilentlyContinue) -and
        $existing -and ($existing.ScriptBlock -match 'starship')

    if ($global:_CopilotHasStarship) {
        $global:_CopilotOrigPrompt = (Get-Item Function:prompt).ScriptBlock
        function global:prompt {
            _Copilot-CheckRefresh
            & $global:_CopilotOrigPrompt
        }
    } else {
        $global:_CopilotOrigPrompt = if (Test-Path Function:prompt) {
            (Get-Item Function:prompt).ScriptBlock
        } else {
            { "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) " }
        }
        function global:prompt {
            _Copilot-CheckRefresh
            $status = if (Test-Path $global:_CopilotPromptFile) {
                $s = (Get-Content $global:_CopilotPromptFile -Raw -Encoding UTF8).Trim()
                if ($PSVersionTable.PSVersion.Major -lt 7) {
                    $s = $s.Replace([char]::ConvertFromUtf32(0x1F7E2), '[G]').
                            Replace([char]::ConvertFromUtf32(0x1F7E1), '[Y]').
                            Replace([char]::ConvertFromUtf32(0x1F7E0), '[O]').
                            Replace([char]::ConvertFromUtf32(0x1F534), '[R]').
                            Replace([string][char]0x2197, '->').
                            Replace([string][char]0x267E, '~').
                            Replace([string][char]0xFE0F, '')
                }
                $s
            } else { $null }
            $orig = & $global:_CopilotOrigPrompt
            if ($status) { "$status $orig" } else { $orig }
        }
    }
}
