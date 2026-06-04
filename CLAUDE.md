# copilot_trending

Shell scripts (Zsh and PowerShell) that track GitHub Copilot quota usage and display a status indicator in the terminal prompt.

## Structure

| File | Role |
|---|---|
| `copilot_usage.zsh` | Zsh functions + precmd hook; sourced into `~/.zshrc` |
| `copilot_usage.ps1` | PowerShell equivalent; dot-sourced into `$PROFILE` |
| `install_copilot_usage.sh` | Idempotent Zsh installer (updates `~/.zshrc` + Starship config) |
| `install_copilot_usage.ps1` | Idempotent PowerShell installer |
| `tests/compute_helper.py` | Extracted Python computation logic used by pytest |
| `tests/test_python_logic.py` | pytest unit tests for the business-hours model and quota computation |
| `tests/test_copilot_usage.bats` | BATS integration tests for the Zsh script |
| `tests/test_copilot_usage.Tests.ps1` | Pester tests for the PowerShell script |

## Running tests

### Python unit tests (requires pytest)
```sh
python -m pytest tests/test_python_logic.py -v
```

### Zsh tests (requires bats-core ≥ 1.7 and zsh)
```sh
bats tests/test_copilot_usage.bats
```

### PowerShell tests (requires Pester ≥ 5)
```powershell
Invoke-Pester tests/test_copilot_usage.Tests.ps1 -Output Detailed
```

## Architecture

Both scripts share identical computation logic, embedded in Python:

1. **API fetch** — calls `https://api.github.com/copilot_internal/user` authenticated via `gh auth token`
2. **Business-hours model** — M–F 08:00–17:00 local time; drives usage rate and EOM projection
3. **Quota bucket priority** — `premium_interactions` → `chat` → `completions`; first bucket with `has_quota: true` wins; falls back to "unlimited"
4. **Cache** — writes to `~/.cache/copilot_usage/{prompt.txt,detail.txt,raw.json,last_fetch}`; refreshes every 5 minutes via a precmd/prompt hook

The Zsh version passes raw JSON inline to Python via a heredoc. The PowerShell version writes the embedded script string to a temp `.py` file and invokes it.

## Key invariants

- `prompt.txt` stores `%%` (double percent) on the Zsh path. Starship generates a zsh prompt string processed by zsh's prompt expansion, which renders `%%` as a literal `%`. The Python write step does `prompt.replace('%', '%%')` to double any `%` in the computed string. `copilot_usage_update` un-escapes with `${prompt_str//\%\%/%}` before displaying. The PowerShell path does not do this doubling (PowerShell prompt strings don't use `%%` escaping).
- PS5 (Windows PowerShell 5.1) cannot reliably render characters outside the Basic Multilingual Plane, so the prompt hook replaces emoji with ASCII fallbacks: `[G]` `[Y]` `[O]` `[R]` `->` `~`.
- The Zsh background refresh uses `( _copilot_usage_fetch &>/dev/null & )` (subshell). PowerShell uses `Start-Job`.
- The PowerShell script uses global guards (`$global:_CopilotSeeded`, `$global:_CopilotPromptInstalled`) so it is safe to dot-source from multiple profile files.

## Development notes

- Keep the embedded Python logic identical between `copilot_usage.zsh` and `copilot_usage.ps1`. When changing the computation, update both and update `tests/compute_helper.py` to match.
- Do not introduce a shared Python file dependency — the scripts are designed to be self-contained single-file sources.
- CI runs on Ubuntu (Python + Zsh + PS7) and Windows (PS7 + PS5).
