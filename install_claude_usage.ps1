#Requires -Version 5.1
<#
.SYNOPSIS
    Idempotent installer for claude_usage.ps1 — updates $PROFILE and (optionally) starship.toml.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClaudeScript = Join-Path $ScriptDir "claude_usage.ps1"

if (-not (Test-Path $ClaudeScript)) {
    Write-Error "Missing $ClaudeScript"
    exit 1
}

# ── Python check ─────────────────────────────────────────────────────────────
function Find-Python {
    foreach ($cmd in @('python3', 'python', 'py')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { continue }
        $ver = $null
        try {
            $ver = & $cmd --version 2>&1
        } catch { }
        if ($LASTEXITCODE -eq 0 -and "$ver" -match 'Python \d') { return $cmd }
    }
    return $null
}

$pythonCmd = Find-Python
if (-not $pythonCmd) {
    Write-Host ""
    Write-Host "⚠  Python 3 was not found in PATH." -ForegroundColor Yellow
    Write-Host "   claude_usage.ps1 requires Python 3 to compute usage metrics." -ForegroundColor Yellow
    Write-Host ""

    $hasWinget  = [bool](Get-Command winget  -ErrorAction SilentlyContinue)
    $hasChoco   = [bool](Get-Command choco   -ErrorAction SilentlyContinue)

    $options = [System.Collections.Generic.List[string]]::new()
    if ($hasWinget) { $options.Add("winget  — install via Windows Package Manager (latest Python.Python.3.x)") }
    if ($hasChoco)  { $options.Add("choco   — install via Chocolatey (choco install python)") }
    $options.Add("store   — open the Microsoft Store Python 3 page")
    $options.Add("manual  — open python.org download page in your browser")
    $options.Add("skip    — continue without installing Python (cache refresh will fail)")

    Write-Host "How would you like to install Python?" -ForegroundColor Cyan
    for ($i = 0; $i -lt $options.Count; $i++) {
        Write-Host "  [$($i+1)] $($options[$i])"
    }
    Write-Host ""

    $choice = Read-Host "Enter a number (default: skip)"

    $idx = 0
    [void][int]::TryParse($choice.Trim(), [ref]$idx)

    $label = if ($idx -ge 1 -and $idx -le $options.Count) { ($options[$idx - 1] -split '\s+')[0] } else { "skip" }

    switch ($label) {
        "winget" {
            Write-Host "Searching winget for Python 3…" -ForegroundColor Cyan
            $searchLines = winget search --id Python.Python --source winget --accept-source-agreements 2>&1
            $pkgId = $searchLines |
                Select-String 'Python\.Python\.3\.\d+' |
                ForEach-Object { $_.Matches[0].Value } |
                Sort-Object -Descending |
                Select-Object -First 1
            if (-not $pkgId) { $pkgId = 'Python.Python.3.13' }
            Write-Host "Running: winget install --id $pkgId --source winget -e" -ForegroundColor Cyan
            winget install --id $pkgId --source winget -e --accept-package-agreements --accept-source-agreements
            $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                        [System.Environment]::GetEnvironmentVariable('PATH', 'User')
            $pythonCmd = Find-Python
            if ($pythonCmd) {
                Write-Host "Python installed and found as '$pythonCmd'." -ForegroundColor Green
            } else {
                Write-Host "Installation finished. You may need to restart your shell for PATH to update." -ForegroundColor Yellow
            }
        }
        "choco" {
            Write-Host "Running: choco install python -y" -ForegroundColor Cyan
            choco install python -y
            $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                        [System.Environment]::GetEnvironmentVariable('PATH', 'User')
            $pythonCmd = Find-Python
            if ($pythonCmd) {
                Write-Host "Python installed and found as '$pythonCmd'." -ForegroundColor Green
            } else {
                Write-Host "Installation finished. You may need to restart your shell for PATH to update." -ForegroundColor Yellow
            }
        }
        "store" {
            Write-Host "Opening Microsoft Store…" -ForegroundColor Cyan
            Start-Process "ms-windows-store://pdp/?productid=9NRWMJLIVE9S"
            Write-Host "Re-run this installer after Python is installed." -ForegroundColor Yellow
        }
        "manual" {
            Write-Host "Opening https://www.python.org/downloads/ in your browser…" -ForegroundColor Cyan
            Start-Process "https://www.python.org/downloads/"
            Write-Host "Re-run this installer after Python is installed." -ForegroundColor Yellow
        }
        default {
            Write-Host "Skipping Python installation — cache refresh will fail until Python 3 is available." -ForegroundColor Yellow
        }
    }
    Write-Host ""
}

# ── PowerShell profile ───────────────────────────────────────────────────────
$ProfilePath = $PROFILE.CurrentUserAllHosts
if (-not (Test-Path $ProfilePath)) {
    New-Item -ItemType File -Force -Path $ProfilePath | Out-Null
    Write-Host "Created $ProfilePath"
}

$SourceLine = ". `"$ClaudeScript`""

$profileContent = Get-Content $ProfilePath -Raw -ErrorAction SilentlyContinue
if (-not $profileContent) { $profileContent = "" }

if ($profileContent -match [regex]::Escape($SourceLine)) {
    Write-Host "Profile already configured"
} elseif ($profileContent -match '(?m)^\s*\.\s+".*claude_usage\.ps1"') {
    $updated = $profileContent -replace '(?m)^\s*\.\s+".*claude_usage\.ps1"', $SourceLine
    Set-Content -Path $ProfilePath -Value $updated -NoNewline
    Write-Host "Updated dot-source line in $ProfilePath"
} else {
    Add-Content -Path $ProfilePath -Value "`n# Claude usage prompt`n$SourceLine"
    Write-Host "Added dot-source line to $ProfilePath"
}

# ── Starship config (optional) ───────────────────────────────────────────────
$StarshipDir  = if ($env:STARSHIP_CONFIG) {
    Split-Path $env:STARSHIP_CONFIG
} elseif ($env:XDG_CONFIG_HOME) {
    $env:XDG_CONFIG_HOME
} else {
    Join-Path $HOME ".config"
}
$StarshipToml = Join-Path $StarshipDir "starship.toml"

if (Test-Path (Split-Path $StarshipToml)) {
    if (-not (Test-Path $StarshipToml)) {
        New-Item -ItemType File -Force -Path $StarshipToml | Out-Null
    }

    $StartMarker = "# >>> claude_usage_start >>>"
    $EndMarker   = "# <<< claude_usage_end <<<"

    $psExe = if ($PSVersionTable.PSVersion.Major -ge 7) { "pwsh" } else { "powershell" }
    $Block = @"
[custom.claude]
command = "Get-Content \"`$HOME/.cache/claude_usage/prompt.txt\""
when    = "if (-not (Test-Path \"`$HOME/.cache/claude_usage/prompt.txt\")) { exit 1 }"
shell   = ["$psExe", "-NoProfile", "-NonInteractive", "-Command"]
format  = "[`$output](`$style) "
style   = "bold purple"
"@

    $tomlContent = Get-Content $StarshipToml -Raw -ErrorAction SilentlyContinue
    if (-not $tomlContent) { $tomlContent = "" }

    $startIdx = $tomlContent.IndexOf($StartMarker)
    $endIdx   = $tomlContent.IndexOf($EndMarker)

    if ($startIdx -ge 0 -and $endIdx -gt $startIdx) {
        $before  = $tomlContent.Substring(0, $startIdx)
        $after   = $tomlContent.Substring($endIdx + $EndMarker.Length)
        $updated = $before + $StartMarker + "`n" + $Block + "`n" + $EndMarker + $after
        Set-Content -Path $StarshipToml -Value $updated -NoNewline
    } else {
        $sep = if ($tomlContent -and -not $tomlContent.EndsWith("`n")) { "`n`n" } else { "`n" }
        Add-Content -Path $StarshipToml -Value "$sep$StartMarker`n$Block`n$EndMarker"
    }

    Write-Host "Updated custom.claude block in $StarshipToml"
} else {
    Write-Host "Starship config dir not found — skipping starship.toml update"
    Write-Host "  (create $StarshipToml and re-run to add the Starship block)"
}

$refreshOk = $false
$previousEap = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    . $ClaudeScript
    $refreshOk = _Claude-Fetch
} catch {
    $refreshOk = $false
} finally {
    $ErrorActionPreference = $previousEap
}

if ($refreshOk) {
    Write-Host "Refreshed Claude usage cache"
} else {
    Write-Host "Could not refresh Claude usage cache right now"
}

Write-Host ""
Write-Host "Done. Reload your profile with: . `$PROFILE"
