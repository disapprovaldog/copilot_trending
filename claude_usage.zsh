# claude_usage.zsh — Claude API usage tracking + Starship prompt
# Source in ~/.zshrc:  source /path/to/claude_usage.zsh
#
# Reads usage data from local Claude Code history (~/.claude/projects/).
# No external API calls required — all computation is local.
#
# Prompt format:  {icon} {sess%}/{wk%}/${wk_cost}/${budget}
#   sess%    — current session context window usage
#   wk%      — week-to-date spend as % of configured budget
#   wk_cost  — estimated week-to-date API cost
#   budget   — weekly budget ceiling (set _CLAUDE_WEEKLY_BUDGET)
#
# Requirements: python3
#
# ─── Starship setup ────────────────────────────────────────────────────────
# Add to ~/.config/starship.toml:
#
# [custom.claude]
# command = "cat ~/.cache/claude_usage/prompt.txt 2>/dev/null"
# when    = "test -f ~/.cache/claude_usage/prompt.txt"
# shell   = ["sh"]
# format  = "[$output]($style) "
# style   = "bold purple"
# ───────────────────────────────────────────────────────────────────────────

_CLAUDE_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude_usage"
_CLAUDE_CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
_CLAUDE_REFRESH_SECS=300   # re-compute every 5 minutes
_CLAUDE_WEEKLY_BUDGET="${CLAUDE_WEEKLY_BUDGET:-50}"  # USD

# ── internal: read local history + compute metrics, write cache files ────
_claude_usage_fetch() {
  local cache_dir="$_CLAUDE_CACHE_DIR"
  mkdir -p "$cache_dir"

  printf '%s\n' "$PWD" > "$cache_dir/cwd"

  python3 - "$_CLAUDE_CLAUDE_DIR" "$PWD" "$cache_dir" "$_CLAUDE_WEEKLY_BUDGET" <<'PYEOF'
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
import re as _re
project_key = _re.sub(r'[^a-zA-Z0-9]', '-', cwd)
project_dir = os.path.join(claude_dir, 'projects', project_key)

session_ctx   = 0      # last context size (input + cache_read of last API call)
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

if   sess_pct < 50: icon = "🟣"
elif sess_pct < 75: icon = "🟡"
elif sess_pct < 90: icon = "🟠"
else:               icon = "🔴"

prompt = (f"{icon} {sess_pct:.0f}%%/{week_pct:.0f}%%/"
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

with open(os.path.join(cache_dir, "prompt.txt"), "w") as fh:
    fh.write(prompt.replace('%', '%%'))  # zsh prompt expansion renders %% as %
with open(os.path.join(cache_dir, "detail.txt"), "w") as fh:
    fh.write("\n".join(detail_lines) + "\n")
PYEOF

  date +%s > "$_CLAUDE_CACHE_DIR/last_fetch"
}

# ── public: human-readable summary ──────────────────────────────────────
claude_usage_info() {
  local detail="$_CLAUDE_CACHE_DIR/detail.txt"
  if [[ ! -f "$detail" ]]; then
    print "No cached data yet — run: claude_usage_update"
    return 1
  fi
  cat "$detail"
  printf '\nCached: %s\n' \
    "$(date -r "$(< "$_CLAUDE_CACHE_DIR/last_fetch")" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
       || date -d "@$(< "$_CLAUDE_CACHE_DIR/last_fetch")" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
       || cat "$_CLAUDE_CACHE_DIR/last_fetch")"
}

# ── public: force a synchronous refresh ─────────────────────────────────
claude_usage_update() {
  print "Computing Claude usage…"
  if _claude_usage_fetch; then
    local prompt_str
    prompt_str="$(< "$_CLAUDE_CACHE_DIR/prompt.txt")"
    print "${prompt_str//\%\%/%}"
  fi
}

# ── internal: precmd hook — async refresh when cache is stale ───────────
_claude_usage_precmd() {
  local last_fetch=0
  [[ -f "$_CLAUDE_CACHE_DIR/last_fetch" ]] && last_fetch=$(< "$_CLAUDE_CACHE_DIR/last_fetch")
  if (( $(date +%s) - last_fetch > _CLAUDE_REFRESH_SECS )); then
    ( _claude_usage_fetch &>/dev/null & )
  fi
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _claude_usage_precmd
