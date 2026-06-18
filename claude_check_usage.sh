#!/usr/bin/env bash
# claude_check_usage.sh — standalone Claude usage report (no shell sourcing required)
# Usage:  ./claude_check_usage.sh [--cwd <dir>] [--budget <usd>] [--days <n>]
#
# Reads from ~/.claude/projects/ and prints a /usage-style summary.
# Requirements: python3

set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
CWD="${PWD}"
WEEKLY_BUDGET="${CLAUDE_WEEKLY_BUDGET:-50}"
DAYS=7

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)     CWD="$2";            shift 2 ;;
    --budget)  WEEKLY_BUDGET="$2";  shift 2 ;;
    --days)    DAYS="$2";           shift 2 ;;
    *)         echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

python3 - "$CLAUDE_DIR" "$CWD" "$WEEKLY_BUDGET" "$DAYS" <<'PYEOF'
import sys, json, os, glob
from datetime import datetime

claude_dir    = sys.argv[1]
cwd           = sys.argv[2]
weekly_budget = float(sys.argv[3])
days          = int(sys.argv[4])

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

# ── session stats ────────────────────────────────────────────────────────────
import re as _re
project_key = _re.sub(r'[^a-zA-Z0-9]', '-', cwd)
project_dir = os.path.join(claude_dir, 'projects', project_key)

session_ctx     = 0
session_in      = 0
session_out     = 0
session_cr      = 0
session_cw      = 0
session_cost    = 0.0
session_model   = ''
session_file    = None
session_msgs    = 0

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
                        session_msgs += 1
                        session_cost += msg_cost(usage, model)
                        session_in   += usage.get('input_tokens', 0)
                        session_out  += usage.get('output_tokens', 0)
                        session_cr   += usage.get('cache_read_input_tokens', 0)
                        session_cw   += usage.get('cache_creation_input_tokens', 0)
                        last_inp      = usage.get('input_tokens', 0)
                        last_cr       = usage.get('cache_read_input_tokens', 0)
                        if model:
                            session_model = model
                except Exception:
                    pass
        session_ctx = last_inp + last_cr

# ── period stats (default: last 7 days) ─────────────────────────────────────
cutoff    = datetime.now().timestamp() - days * 86400
all_jsonl = glob.glob(os.path.join(claude_dir, 'projects', '*', '*.jsonl'))

period_cost    = 0.0
period_in      = 0
period_out     = 0
period_cr      = 0
period_cw      = 0
period_msgs    = 0
model_costs    = {}

for fpath in all_jsonl:
    if os.path.getmtime(fpath) < cutoff:
        continue
    try:
        with open(fpath, encoding='utf-8', errors='replace') as fh:
            for line in fh:
                try:
                    msg   = json.loads(line)
                    usage = msg.get('message', {}).get('usage')
                    model = msg.get('message', {}).get('model', '') or 'unknown'
                    if usage:
                        c = msg_cost(usage, model)
                        period_cost += c
                        period_in   += usage.get('input_tokens', 0)
                        period_out  += usage.get('output_tokens', 0)
                        period_cr   += usage.get('cache_read_input_tokens', 0)
                        period_cw   += usage.get('cache_creation_input_tokens', 0)
                        period_msgs += 1
                        model_costs[model] = model_costs.get(model, 0.0) + c
                except Exception:
                    pass
    except Exception:
        pass

CONTEXT_WINDOW = 1_000_000
sess_pct = session_ctx / CONTEXT_WINDOW * 100
week_pct = (period_cost / weekly_budget * 100) if weekly_budget > 0 else 0.0

now_str = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

print(f"Claude Usage Report — {now_str}")
print(f"{'=' * 50}")
print()
print("Session")
print(f"  Context window : {session_ctx:>12,} / {CONTEXT_WINDOW:,}  ({sess_pct:.1f}%)")
print(f"  Input tokens   : {session_in:>12,}")
print(f"  Output tokens  : {session_out:>12,}")
print(f"  Cache read     : {session_cr:>12,}")
print(f"  Cache write    : {session_cw:>12,}")
print(f"  API calls      : {session_msgs:>12,}")
print(f"  Estimated cost : ${session_cost:.4f}")
print(f"  Model          : {session_model or 'unknown'}")
print(f"  Project dir    : {cwd}")
print()
print(f"{days}-Day Period")
print(f"  Input tokens   : {period_in:>12,}")
print(f"  Output tokens  : {period_out:>12,}")
print(f"  Cache read     : {period_cr:>12,}")
print(f"  Cache write    : {period_cw:>12,}")
print(f"  API calls      : {period_msgs:>12,}")
print(f"  Estimated cost : ${period_cost:.2f}")

if model_costs:
    print()
    print("  Cost by model:")
    for m, c in sorted(model_costs.items(), key=lambda x: -x[1]):
        print(f"    {m:<30} ${c:.2f}")

print()
print("Budget")
print(f"  Weekly budget  : ${weekly_budget:.2f}")
print(f"  Period used    : {week_pct:.1f}%  (${period_cost:.2f} / ${weekly_budget:.2f})")
PYEOF
