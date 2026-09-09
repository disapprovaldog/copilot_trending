#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_SCRIPT="$SCRIPT_DIR/claude_usage.zsh"

if [[ ! -f "$CLAUDE_SCRIPT" ]]; then
  echo "Missing $CLAUDE_SCRIPT" >&2
  exit 1
fi

ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
STARSHIP_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
STARSHIP_TOML="$STARSHIP_DIR/starship.toml"

mkdir -p "$STARSHIP_DIR"
touch "$ZSHRC" "$STARSHIP_TOML"

SOURCE_LINE="source $CLAUDE_SCRIPT"

upsert_zshrc_line() {
  local file="$1"
  local line="$2"

  if grep -Fqx "$line" "$file"; then
    echo "zshrc already configured"
    return 0
  fi

  if grep -Eq '^[[:space:]]*source .*/claude_usage\.zsh$' "$file"; then
    awk -v replacement="$line" '
      BEGIN { replaced = 0 }
      /^[[:space:]]*source .*claude_usage\.zsh$/ && !replaced {
        print replacement
        replaced = 1
        next
      }
      { print }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    echo "Updated source line in $file"
    return 0
  fi

  {
    echo
    echo "# Claude usage prompt"
    echo "$line"
  } >> "$file"
  echo "Added source line to $file"
}

upsert_zshrc_line "$ZSHRC" "$SOURCE_LINE"

START_MARKER="# >>> claude_usage_start >>>"
END_MARKER="# <<< claude_usage_end <<<"

upsert_managed_block() {
  local file="$1"
  local start_marker="$2"
  local end_marker="$3"
  local block="$4"
  local block_file
  local tmp_file
  local status=0
  block_file="$(mktemp)"
  tmp_file="$(mktemp)"

  printf '%s\n' "$block" > "$block_file"

  if awk -v start="$start_marker" -v end="$end_marker" -v block_file="$block_file" '
    BEGIN {
      while ((getline line < block_file) > 0) {
        lines[++n] = line
      }
      close(block_file)
      in_block = 0
      replaced = 0
    }
    $0 == start && !replaced {
      print start
      for (i = 1; i <= n; i++) print lines[i]
      replaced = 1
      in_block = 1
      next
    }
    in_block {
      if ($0 == end) {
        print end
        in_block = 0
      }
      next
    }
    { print }
    END {
      if (!replaced) {
        if (NR > 0) print ""
        print start
        for (i = 1; i <= n; i++) print lines[i]
        print end
      } else if (in_block) {
        print end
      }
    }
  ' "$file" > "$tmp_file"; then
    mv "$tmp_file" "$file"
    status=$?
  else
    status=$?
  fi

  rm -f "$block_file" "$tmp_file"
  return "$status"
}

STARSHIP_BLOCK='[custom.claude]
command = "cat ~/.cache/claude_usage/prompt.txt 2>/dev/null"
when    = "test -f ~/.cache/claude_usage/prompt.txt"
shell   = ["sh"]
format  = "[$output]($style) "
style   = "bold purple"'

upsert_managed_block "$STARSHIP_TOML" "$START_MARKER" "$END_MARKER" "$STARSHIP_BLOCK"
echo "Updated custom.claude block in $STARSHIP_TOML"

if command -v zsh >/dev/null 2>&1; then
  if zsh -fc "source '$CLAUDE_SCRIPT' && claude_usage_update" >/dev/null 2>&1; then
    echo "Refreshed Claude usage cache"
  else
    echo "Could not refresh Claude usage cache right now"
  fi
else
  echo "zsh not found — skipping cache refresh"
fi

echo
echo "Done. Reload your shell with: exec zsh"
