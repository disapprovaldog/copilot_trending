# Copilot Usage Prompt

> **Note:** Quota tracking only has meaning if your GitHub organization has configured a Copilot usage quota. Without an org-level quota the API returns no entitlement data and the prompt will show "unlimited" regardless of actual consumption.

This repo contains sourceable shell scripts (Zsh and PowerShell) that:

- pull your Copilot quota from `https://api.github.com/copilot_internal/user`
- compute monthly usage projection using business hours only (M-F, 8a-5p)
- write a compact status string for the shell prompt (Starship or built-in)

---

## Reading the prompt indicator

### PowerShell 7 (emoji)

```
🟢 717/12000 (6.0%) ↗ 11084 PS C:\Users\you>
```

### PowerShell 5 (ASCII fallback)

```
[G] 717/12000 (6.0%) -> 11084 PS C:\Users\you>
```

| Part | Meaning |
|---|---|
| `🟢` / `[G]` | Status icon — see colour key below |
| `717` | Premium interactions used so far this month |
| `12000` | Monthly entitlement |
| `(6.0%)` | Percent of quota consumed |
| `↗ 11084` / `-> 11084` | Projected end-of-month total, based on your current pace during business hours |

**Colour key**

| Emoji | ASCII | Used |
|---|---|---|
| 🟢 | `[G]` | < 50 % |
| 🟡 | `[Y]` | 50 – 74 % |
| 🟠 | `[O]` | 75 – 89 % |
| 🔴 | `[R]` | ≥ 90 % |
| ♾️ | `[~]` | Unlimited (no quota configured) |

**Projection methodology:** usage rate is calculated as *interactions used ÷ business hours elapsed* (M-F, 08:00–17:00 local). That rate is multiplied by total business hours in the billing month to produce the projected total. The projection is omitted on the first morning of the month before any business hours have elapsed.

The cache refreshes in the background every 5 minutes (triggered on each prompt draw). The displayed numbers are at most 5 minutes stale.

---

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
- `python3` (or `python` / `py`) — Windows Store stubs are detected and skipped automatically
- PowerShell 5.1+ or PowerShell 7 (pwsh)
- Starship (optional — if absent, status is prepended to the built-in prompt)

### PS5 vs PS7

Both versions are supported with the same script. PS7 displays emoji; PS5 uses ASCII equivalents (`[G]`, `[Y]`, `[O]`, `[R]`, `->`) because the legacy console host does not reliably render characters outside the Basic Multilingual Plane.

If you load the script from multiple profile files (e.g. `profile.ps1` and `Microsoft.PowerShell_profile.ps1`), it is safe — the script uses global guards to seed the cache and install the prompt hook only once per session.

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

> The installer adds the dot-source line to `$PROFILE.CurrentUserAllHosts`. If you want it in a host-specific profile instead, add it manually and leave the AllHosts profile empty.

---

## Commands (both shells)

| Command | Description |
|---|---|
| `copilot_usage_update` / `Update-CopilotUsage` | Force a synchronous refresh and print current status |
| `copilot_usage_info` / `Get-CopilotUsageInfo` | Print full detail report from cache |

---

## Cache files

All scripts share `~/.cache/copilot_usage/`:

| File | Contents |
|---|---|
| `prompt.txt` | Compact one-line status (read by Starship / prompt hook) |
| `detail.txt` | Full breakdown printed by `copilot_usage_info` |
| `raw.json` | Raw API response |
| `last_fetch` | Unix timestamp of last successful fetch |
