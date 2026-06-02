# Copilot Usage Prompt

> **Note:** Quota tracking only has meaning if your GitHub organization has configured a Copilot usage quota. Without an org-level quota the API returns no entitlement data and the prompt will show "unlimited" regardless of actual consumption.

This repo contains sourceable shell scripts (Zsh and PowerShell) that:

- pull your Copilot quota from `https://api.github.com/copilot_internal/user`
- compute monthly usage projection using business hours only (M-F, 8a-5p)
- write a compact status string for the shell prompt (Starship or built-in)

## Files

| File | Purpose |
|---|---|
| `copilot_usage.zsh` | Zsh: usage/projection functions and precmd refresh hook |
| `install_copilot_usage.sh` | Zsh: idempotent installer for `~/.zshrc` and Starship config |
| `copilot_usage.ps1` | PowerShell: same logic, prompt hook, background refresh |
| `install_copilot_usage.ps1` | PowerShell: idempotent installer for `$PROFILE` and Starship config |

---

## Zsh setup

### Requirements

- `gh` authenticated (`gh auth login`)
- `curl`, `python3`, `zsh`
- Starship (optional)

### Manual

1. Add to `~/.zshrc`:

```zsh
source /absolute/path/to/copilot_usage.zsh
```

2. Add to `~/.config/starship.toml` (optional):

```toml
[custom.copilot]
command = "cat ~/.cache/copilot_usage/prompt.txt 2>/dev/null"
when    = "test -f ~/.cache/copilot_usage/prompt.txt"
shell   = ["sh"]
format  = "[$output]($style) "
style   = "bold cyan"
```

3. Reload: `exec zsh`

### Automatic

```sh
./install_copilot_usage.sh
```

---

## PowerShell setup

### Requirements

- `gh` authenticated (`gh auth login`)
- `python3` (or `python`)
- PowerShell 5.1+ or PowerShell 7 (pwsh)
- Starship (optional — if absent, status is prepended to the built-in prompt)

### Manual

1. Dot-source in your PowerShell profile (`$PROFILE`):

```powershell
. "/absolute/path/to/copilot_usage.ps1"
```

2. Add to `~/.config/starship.toml` (optional, requires `pwsh`):

```toml
[custom.copilot]
command = "Get-Content \"$HOME/.cache/copilot_usage/prompt.txt\""
when    = "if (-not (Test-Path \"$HOME/.cache/copilot_usage/prompt.txt\")) { exit 1 }"
shell   = ["pwsh", "-NoProfile", "-NonInteractive", "-Command"]
format  = "[$output]($style) "
style   = "bold cyan"
```

> Use `powershell` instead of `pwsh` if running Windows PowerShell 5.1.

3. Reload: `. $PROFILE`

### Automatic

```powershell
./install_copilot_usage.ps1
```

---

## Commands (both shells)

| Command | Description |
|---|---|
| `copilot_usage_update` | Force a synchronous refresh and print status |
| `copilot_usage_info` | Print full detail from cache |

PowerShell also exposes the verb-noun forms: `Update-CopilotUsage`, `Get-CopilotUsageInfo`.

## Cache files

Both scripts share `~/.cache/copilot_usage/`:

| File | Contents |
|---|---|
| `prompt.txt` | Compact one-line status (read by Starship / prompt hook) |
| `detail.txt` | Full breakdown printed by `copilot_usage_info` |
| `raw.json` | Raw API response |
| `last_fetch` | Unix timestamp of last successful fetch |
