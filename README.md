# Copilot Usage Prompt

This repo contains a sourceable Zsh script that:

- pulls your Copilot quota from:
  `https://api.github.com/copilot_internal/user`
- computes monthly usage projection using business hours only (M-F, 8a-5p)
- writes a compact status string for Starship

## Files

- `copilot_usage.zsh` – usage/projection functions and cache refresh hook
- `install_copilot_usage.sh` – idempotent installer for `~/.zshrc` and Starship config

## Requirements

- `gh` authenticated (`gh auth login`)
- `curl`
- `python3`
- `zsh`
- Starship (optional, only for prompt display)

## Manual setup

1. Add to your `~/.zshrc`:

```zsh
source /absolute/path/to/copilot_usage.zsh
```

2. Add to `~/.config/starship.toml`:

```toml
[custom.copilot]
command = "cat ~/.cache/copilot_usage/prompt.txt 2>/dev/null"
when    = "test -f ~/.cache/copilot_usage/prompt.txt"
shell   = ["sh"]
format  = "[$output]($style) "
style   = "bold cyan"
```

3. Reload shell:

```sh
exec zsh
```

4. Prime cache (optional):

```sh
copilot_usage_update
copilot_usage_info
```

## Automatic setup

Run:

```sh
./install_copilot_usage.sh
```

The installer updates the managed prompt block in place, so it is safe to run multiple times.
