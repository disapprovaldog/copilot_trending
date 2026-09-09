# copilot_trending

Shell scripts (Zsh and PowerShell) that track GitHub Copilot quota usage and Claude API usage, and display status indicators in the terminal prompt.

## Structure

### Copilot

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

### Claude

| File | Role |
|---|---|
| `claude_usage.zsh` | Zsh functions + precmd hook; sourced into `~/.zshrc` |
| `claude_usage.ps1` | PowerShell equivalent; dot-sourced into `$PROFILE` |
| `install_claude_usage.sh` | Idempotent Zsh installer (updates `~/.zshrc` + Starship config) |
| `install_claude_usage.ps1` | Idempotent PowerShell installer |
| `claude_check_usage.sh` | Standalone `/usage`-style report (no shell sourcing required) |
| `claude_check_usage.ps1` | PowerShell equivalent of the standalone report |

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

### Copilot

Both Copilot scripts share identical computation logic, embedded in Python:

1. **API fetch** — calls `https://api.github.com/copilot_internal/user` authenticated via `gh auth token`
2. **Business-hours model** — M–F 08:00–17:00 local time; drives usage rate and EOM projection
3. **Quota bucket priority** — `premium_interactions` → `chat` → `completions`; first bucket with `has_quota: true` wins; falls back to "unlimited"
4. **Cache** — writes to `~/.cache/copilot_usage/{prompt.txt,detail.txt,raw.json,last_fetch}`; refreshes every 5 minutes via a precmd/prompt hook

The Zsh version passes raw JSON inline to Python via a heredoc. The PowerShell version writes the embedded script string to a temp `.py` file and invokes it.

### Claude

Both Claude scripts compute metrics entirely from local Claude Code history (no network required):

1. **Local data source** — reads `~/.claude/projects/<project-key>/*.jsonl`; the project key is the CWD with all non-alphanumeric characters replaced by `-` (e.g., `/Users/foo/my_project` → `-Users-foo-my-project`)
2. **Session %** — context window usage: `(last_message.input_tokens + last_message.cache_read_input_tokens) / 1_000_000`
3. **Week %** — rolling 7-day estimated cost as a fraction of `_CLAUDE_WEEKLY_BUDGET` (default $50)
4. **Prompt format** — `{icon} {sess%}/{wk%}/${week_cost}/${budget}`
5. **Model pricing** — hardcoded table for Fable 5 / Opus 4.x / Sonnet 4.x / Haiku 4.x; cache reads billed at 10%, cache writes at 125% of input price
6. **Cache** — writes to `~/.cache/claude_usage/{prompt.txt,detail.txt,last_fetch}`; refreshes every 5 minutes

## Key invariants

### Copilot
- `prompt.txt` stores `%%` (double percent) on the Zsh path. Starship generates a zsh prompt string processed by zsh's prompt expansion, which renders `%%` as a literal `%`. The Python write step does `prompt.replace('%', '%%')` to double any `%` in the computed string. `copilot_usage_update` un-escapes with `${prompt_str//\%\%/%}` before displaying. The PowerShell path does not do this doubling (PowerShell prompt strings don't use `%%` escaping).
- PS5 (Windows PowerShell 5.1) cannot reliably render characters outside the Basic Multilingual Plane, so the prompt hook replaces emoji with ASCII fallbacks: `[G]` `[Y]` `[O]` `[R]` `->` `~`.
- The Zsh background refresh uses `( _copilot_usage_fetch &>/dev/null & )` (subshell). PowerShell uses `Start-Job`.
- The PowerShell script uses global guards (`$global:_CopilotSeeded`, `$global:_CopilotPromptInstalled`) so it is safe to dot-source from multiple profile files.

### Claude
- Same `%%` double-percent escaping rule applies to `claude_usage.zsh` / `claude_usage.ps1`.
- PS5 ASCII fallbacks replace the purple circle (`🟣`) with `[P]` (other colors same as Copilot).
- The PowerShell script uses global guards (`$global:_ClaudeSeeded`, `$global:_ClaudePromptInstalled`).
- Weekly budget is configurable via `_CLAUDE_WEEKLY_BUDGET` (Zsh) / `$global:_ClaudeWeeklyBudget` (PS) or the `CLAUDE_WEEKLY_BUDGET` environment variable.
- Claude Code's project key encoding: all non-alphanumeric characters (including `/`, `_`, `.`) become `-`. This is derived empirically — there is no public spec.

## Development notes

- Keep the embedded Python logic identical between `copilot_usage.zsh` and `copilot_usage.ps1`. When changing the computation, update both and update `tests/compute_helper.py` to match.
- Keep the embedded Python logic identical between `claude_usage.zsh`, `claude_usage.ps1`, `claude_check_usage.sh`, and `claude_check_usage.ps1`. The check scripts contain a superset of the prompt scripts' logic (extra breakdown fields).
- Do not introduce a shared Python file dependency — the scripts are designed to be self-contained single-file sources.
- CI runs on Ubuntu (Python + Zsh + PS7) and Windows (PS7 + PS5).
