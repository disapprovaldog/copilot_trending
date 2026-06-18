# claude_usage.ps1 — Claude API usage tracking + prompt for PowerShell
# Dot-source in your profile:  . /path/to/claude_usage.ps1
#
# Reads usage data from local Claude Code history (~/.claude/projects/).
# No external API calls required — all computation is local.
#
# Prompt format:  {icon} {sess%}/{wk%}/${wk_cost}/${budget}
#   sess%    — current session context window usage
#   wk%      — week-to-date spend as % of configured budget
#   wk_cost  — estimated week-to-date API cost
#   budget   — weekly budget ceiling (set $global:_ClaudeWeeklyBudget)
#
# Requirements: python3 (or python)
#
# ─── Starship setup (optional, PowerShell 7 / pwsh) ────────────────────────
# Add to ~/.config/starship.toml:
#
# [custom.claude]
# command = "Get-Content \"$HOME/.cache/claude_usage/prompt.txt\""
# when    = "if (-not (Test-Path \"$HOME/.cache/claude_usage/prompt.txt\")) { exit 1 }"
# shell   = ["pwsh", "-NoProfile", "-NonInteractive", "-Command"]
# format  = "[$output]($style) "
# style   = "bold purple"
#
# Without Starship the status is prepended to your existing prompt automatically.
# ───────────────────────────────────────────────────────────────────────────

$global:_ClaudeCacheDir     = Join-Path (Join-Path $HOME ".cache") "claude_usage"
$global:_ClaudeClaudeDir    = if ($env:CLAUDE_DIR) { $env:CLAUDE_DIR } else { Join-Path $HOME ".claude" }
$global:_ClaudeRefreshSecs  = 300
$global:_ClaudeWeeklyBudget = if ($env:CLAUDE_WEEKLY_BUDGET) { [double]$env:CLAUDE_WEEKLY_BUDGET } else { 50.0 }
$global:_ClaudeJobId        = $null
$global:_ClaudePython       = $null

function _Claude-FindPython {
    foreach ($cmd in @('python3', 'python', 'py')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { continue }
        $out = $null
        try { $out = & $cmd -c "print('ok')" 2>&1 } catch { }
        if ($LASTEXITCODE -eq 0 -and "$out" -match 'ok') { return $cmd }
    }
    return $null
}

$global:_ClaudePython = _Claude-FindPython

# ── embedded Python — same computation logic as the zsh version ─────────────
$global:_ClaudePyScript = @'
import sys, json, os, glob
from datetime import datetime

claude_dir    = sys.argv[1]
cwd           = sys.argv[2]
cache_dir     = sys.argv[3]
weekly_budget = float(sys.argv[4]) if len(sys.argv) > 4 else 50.0

PRICING = {
    'claude-fable-5':    {'in': 10.0, 'out': 50.0},
    'claude-opus-4-8':   {'in':  5.0, 'out': 25.0},
    'claude-opus-4-7':   {'in':  5.0, 'out': 25.0},
    'claude-opus-4-6':   {'in':  5.0, 'out': 25.0},
    'claude-sonnet-4-6': {'in':  3.0, 'out': 15.0},
    'claude-haiku-4-5':  {'in':  1.0, 'out':  5.0},
}
DEFAULT_PRICING = {'in': 3.0, 'out': 15.0}

def get_pricing(model):
    for k, v in PRICING.items():
        if k in (model or ''):
            return v
    return DEFAULT_PRICING

def msg_cost(usage, model):
    p  = get_pricing(model)
    i  = usage.get('input_tokens', 0)
    cr = usage.get('cache_read_input_tokens', 0)
    cw = usage.get('cache_creation_input_tokens', 0)
    o  = usage.get('output_tokens', 0)
    return (i * p['in'] + cr * p['in'] * 0.1 + cw * p['in'] * 1.25 + o * p['out']) / 1_000_000

# ── session stats: most recent JSONL for current directory ──────────────
import re
project_key = re.sub(r'[^a-zA-Z0-9]', '-', cwd)
project_dir = os.path.join(claude_dir, 'projects', project_key)

session_ctx   = 0
session_cost  = 0.0
session_model = ''
session_file  = None

if os.path.isdir(project_dir):
    files = sorted(
        glob.glob(os.path.join(project_dir, '*.jsonl')),
        key=os.path.getmtime, reverse=True
    )
    if files:
        session_file = files[0]
        last_inp, last_cr = 0, 0
        with open(session_file, encoding='utf-8', errors='replace') as fh:
            for line in fh:
                try:
                    msg   = json.loads(line)
                    usage = msg.get('message', {}).get('usage')
                    model = msg.get('message', {}).get('model', '')
                    if usage:
                        session_cost  += msg_cost(usage, model)
                        last_inp       = usage.get('input_tokens', 0)
                        last_cr        = usage.get('cache_read_input_tokens', 0)
                        session_model  = model or session_model
                except Exception:
                    pass
        session_ctx = last_inp + last_cr

# ── weekly stats: all projects, last 7 days ─────────────────────────────
week_cutoff  = datetime.now().timestamp() - 7 * 86400
all_jsonl    = glob.glob(os.path.join(claude_dir, 'projects', '*', '*.jsonl'))

week_cost    = 0.0
week_in_tok  = 0
week_out_tok = 0

for fpath in all_jsonl:
    if os.path.getmtime(fpath) < week_cutoff:
        continue
    try:
        with open(fpath, encoding='utf-8', errors='replace') as fh:
            for line in fh:
                try:
                    msg   = json.loads(line)
                    usage = msg.get('message', {}).get('usage')
                    model = msg.get('message', {}).get('model', '')
                    if usage:
                        week_cost    += msg_cost(usage, model)
                        week_in_tok  += (usage.get('input_tokens', 0) +
                                         usage.get('cache_read_input_tokens', 0))
                        week_out_tok += usage.get('output_tokens', 0)
                except Exception:
                    pass
    except Exception:
        pass

# ── compute display values ───────────────────────────────────────────────
CONTEXT_WINDOW = 1_000_000
sess_pct = session_ctx / CONTEXT_WINDOW * 100
week_pct = (week_cost / weekly_budget * 100) if weekly_budget > 0 else 0.0

if   sess_pct < 50: icon = "\U0001f7e3"   # purple circle
elif sess_pct < 75: icon = "\U0001f7e1"   # yellow circle
elif sess_pct < 90: icon = "\U0001f7e0"   # orange circle
else:               icon = "\U0001f534"   # red circle

prompt = (f"{icon} {sess_pct:.0f}%/{week_pct:.0f}%/"
          f"${week_cost:.2f}/${weekly_budget:.0f}")

detail_lines = [
    f"Session",
    f"  Context used   : {session_ctx:>12,} / {CONTEXT_WINDOW:,}  ({sess_pct:.1f}%)",
    f"  Session cost   : ${session_cost:.4f}",
    f"  Model          : {session_model or 'unknown'}",
    f"  File           : {os.path.basename(session_file) if session_file else 'none'}",
    f"",
    f"Week-to-date",
    f"  Input tokens   : {week_in_tok:>12,}",
    f"  Output tokens  : {week_out_tok:>12,}",
    f"  Estimated cost : ${week_cost:.2f}",
    f"",
    f"Budget",
    f"  Weekly budget  : ${weekly_budget:.2f}",
    f"  Used           : {week_pct:.1f}%  (${week_cost:.2f} / ${weekly_budget:.2f})",
]

with open(os.path.join(cache_dir, "prompt.txt"), "w", encoding="utf-8") as fh:
    fh.write(prompt)
with open(os.path.join(cache_dir, "detail.txt"), "w", encoding="utf-8") as fh:
    fh.write("\n".join(detail_lines) + "\n")
'@

# ── internal: compute metrics from local files, write cache ─────────────
function _Claude-Fetch {
    [CmdletBinding()]
    param(
        [string]$CacheDir    = $global:_ClaudeCacheDir,
        [string]$ClaudeDir   = $global:_ClaudeClaudeDir,
        [string]$Python      = $global:_ClaudePython,
        [string]$PyScript    = $global:_ClaudePyScript,
        [double]$Budget      = $global:_ClaudeWeeklyBudget
    )

    if (-not $Python) {
        Write-Error "claude_usage: python3/python not found in PATH" -ErrorAction Continue
        return $false
    }

    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

    $tmpPy = [System.IO.Path]::GetTempFileName() + ".py"
    try {
        Set-Content -Path $tmpPy -Value $PyScript -Encoding UTF8
        & $Python $tmpPy $ClaudeDir $PWD $CacheDir $Budget 2>&1 | Out-Null
    } finally {
        Remove-Item -Path $tmpPy -Force -ErrorAction SilentlyContinue
    }

    [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() |
        Set-Content -Path (Join-Path $CacheDir "last_fetch")

    return (Test-Path (Join-Path $CacheDir "prompt.txt"))
}

# ── public: human-readable summary ───────────────────────────────────────────
function Get-ClaudeUsageInfo {
    $detailFile = Join-Path $global:_ClaudeCacheDir "detail.txt"
    if (-not (Test-Path $detailFile)) {
        Write-Host "No cached data yet - run: Update-ClaudeUsage"
        return
    }
    Get-Content $detailFile
    $lastFetchFile = Join-Path $global:_ClaudeCacheDir "last_fetch"
    if (Test-Path $lastFetchFile) {
        $epoch = [long](Get-Content $lastFetchFile -Raw)
        $dt = [System.DateTimeOffset]::FromUnixTimeSeconds($epoch).LocalDateTime
        Write-Host "`nCached: $($dt.ToString('yyyy-MM-dd HH:mm:ss'))"
    }
}
Set-Alias claude_usage_info Get-ClaudeUsageInfo

# ── public: force a synchronous refresh ──────────────────────────────────────
function Update-ClaudeUsage {
    Write-Host "Computing Claude usage..."
    if (-not $global:_ClaudePython) { $global:_ClaudePython = _Claude-FindPython }
    if (_Claude-Fetch) {
        $promptFile = Join-Path $global:_ClaudeCacheDir "prompt.txt"
        if (Test-Path $promptFile) { Get-Content $promptFile -Raw | Write-Host }
    }
}
Set-Alias claude_usage_update Update-ClaudeUsage

# ── internal: fire a background refresh job when cache is stale ──────────────
function _Claude-CheckRefresh {
    if ($global:_ClaudeJobId) {
        $job = Get-Job -Id $global:_ClaudeJobId -ErrorAction SilentlyContinue
        if ($job -and $job.State -in @('Completed', 'Failed', 'Stopped')) {
            Remove-Job -Id $global:_ClaudeJobId -ErrorAction SilentlyContinue
            $global:_ClaudeJobId = $null
        } else {
            return
        }
    }

    $lastFetchFile = Join-Path $global:_ClaudeCacheDir "last_fetch"
    $lastFetch = 0
    if (Test-Path $lastFetchFile) {
        $lastFetch = [long](Get-Content $lastFetchFile -Raw)
    }
    if (([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $lastFetch) -le $global:_ClaudeRefreshSecs) {
        return
    }

    $cd  = $global:_ClaudeCacheDir
    $cld = $global:_ClaudeClaudeDir
    if (-not $global:_ClaudePython) { $global:_ClaudePython = _Claude-FindPython }
    $py  = $global:_ClaudePython
    $pys = $global:_ClaudePyScript
    $bgt = $global:_ClaudeWeeklyBudget
    $cwd = $PWD.Path

    if (-not $py) { return }

    $job = Start-Job -ScriptBlock {
        param($CacheDir, $ClaudeDir, $Python, $PyScript, $Budget, $Cwd)

        New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

        $tmpPy = [System.IO.Path]::GetTempFileName() + ".py"
        try {
            Set-Content -Path $tmpPy -Value $PyScript -Encoding UTF8
            & $Python $tmpPy $ClaudeDir $Cwd $CacheDir $Budget 2>&1 | Out-Null
        } finally {
            Remove-Item -Path $tmpPy -Force -ErrorAction SilentlyContinue
        }

        [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() |
            Set-Content -Path (Join-Path $CacheDir "last_fetch")
    } -ArgumentList $cd, $cld, $py, $pys, $bgt, $cwd

    $global:_ClaudeJobId = $job.Id
}

# ── seed cache on first load if missing ──────────────────────────────────────
$global:_ClaudePromptFile = Join-Path $global:_ClaudeCacheDir "prompt.txt"
if (-not (Test-Path $global:_ClaudePromptFile) -and -not $global:_ClaudeSeeded) {
    $global:_ClaudeSeeded = $true
    Write-Host "claude_usage: computing initial cache..." -NoNewline
    if (-not $global:_ClaudePython) { $global:_ClaudePython = _Claude-FindPython }
    if (_Claude-Fetch) {
        Write-Host " done"
    } else {
        Write-Host " failed - run: Update-ClaudeUsage"
    }
}

# ── prompt hook: inject refresh trigger + status display ─────────────────────
if (-not $global:_ClaudePromptInstalled) {
    $global:_ClaudePromptInstalled = $true

    $existing = Get-Item Function:prompt -ErrorAction SilentlyContinue
    $global:_ClaudeHasStarship = (Get-Command starship -ErrorAction SilentlyContinue) -and
        $existing -and ($existing.ScriptBlock -match 'starship')

    if ($global:_ClaudeHasStarship) {
        $global:_ClaudeOrigPrompt = (Get-Item Function:prompt).ScriptBlock
        function global:prompt {
            _Claude-CheckRefresh
            & $global:_ClaudeOrigPrompt
        }
    } else {
        $global:_ClaudeOrigPrompt = if (Test-Path Function:prompt) {
            (Get-Item Function:prompt).ScriptBlock
        } else {
            { "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) " }
        }
        function global:prompt {
            _Claude-CheckRefresh
            $status = if (Test-Path $global:_ClaudePromptFile) {
                $s = (Get-Content $global:_ClaudePromptFile -Raw -Encoding UTF8).Trim()
                $needsAscii = ($PSVersionTable.PSVersion.Major -lt 7) -or
                              (-not $env:WT_SESSION -and
                               [Console]::OutputEncoding.CodePage -ne 65001)
                if ($needsAscii) {
                    $s = $s.Replace([char]::ConvertFromUtf32(0x1F7E3), '[P]').
                            Replace([char]::ConvertFromUtf32(0x1F7E1), '[Y]').
                            Replace([char]::ConvertFromUtf32(0x1F7E0), '[O]').
                            Replace([char]::ConvertFromUtf32(0x1F534), '[R]')
                }
                $s
            } else { $null }
            $orig = & $global:_ClaudeOrigPrompt
            if ($status) { "$status $orig" } else { $orig }
        }
    }
}
