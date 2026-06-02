#Requires -Version 5.1
<#
.SYNOPSIS
    Idempotent installer for copilot_usage.ps1 — updates $PROFILE and (optionally) starship.toml.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$CopilotScript = Join-Path $ScriptDir "copilot_usage.ps1"

if (-not (Test-Path $CopilotScript)) {
    Write-Error "Missing $CopilotScript"
    exit 1
}

# ── PowerShell profile ───────────────────────────────────────────────────────
$ProfilePath = $PROFILE.CurrentUserAllHosts
if (-not (Test-Path $ProfilePath)) {
    New-Item -ItemType File -Force -Path $ProfilePath | Out-Null
    Write-Host "Created $ProfilePath"
}

$SourceLine = ". `"$CopilotScript`""

$profileContent = Get-Content $ProfilePath -Raw -ErrorAction SilentlyContinue
if (-not $profileContent) { $profileContent = "" }

if ($profileContent -match [regex]::Escape($SourceLine)) {
    Write-Host "Profile already configured"
} elseif ($profileContent -match '(?m)^\s*\.\s+".*copilot_usage\.ps1"') {
    # Replace a stale path for the same script
    $updated = $profileContent -replace '(?m)^\s*\.\s+".*copilot_usage\.ps1"', $SourceLine
    Set-Content -Path $ProfilePath -Value $updated -NoNewline
    Write-Host "Updated dot-source line in $ProfilePath"
} else {
    Add-Content -Path $ProfilePath -Value "`n# Copilot usage prompt`n$SourceLine"
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

    $StartMarker = "# >>> copilot_usage_start >>>"
    $EndMarker   = "# <<< copilot_usage_end <<<"

    $psExe = if ($PSVersionTable.PSVersion.Major -ge 7) { "pwsh" } else { "powershell" }
    $Block = @"
[custom.copilot]
command = "Get-Content \"`$HOME/.cache/copilot_usage/prompt.txt\""
when    = "if (-not (Test-Path \"`$HOME/.cache/copilot_usage/prompt.txt\")) { exit 1 }"
shell   = ["$psExe", "-NoProfile", "-NonInteractive", "-Command"]
format  = "[`$output](`$style) "
style   = "bold cyan"
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

    Write-Host "Updated custom.copilot block in $StarshipToml"
} else {
    Write-Host "Starship config dir not found — skipping starship.toml update"
    Write-Host "  (create $StarshipToml and re-run to add the Starship block)"
}

Write-Host ""
Write-Host "Done. Reload your profile with: . `$PROFILE"
