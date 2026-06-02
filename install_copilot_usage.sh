#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COPILOT_SCRIPT="$SCRIPT_DIR/copilot_usage.zsh"

if [[ ! -f "$COPILOT_SCRIPT" ]]; then
  echo "Missing $COPILOT_SCRIPT" >&2
  exit 1
fi

ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
STARSHIP_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
STARSHIP_TOML="$STARSHIP_DIR/starship.toml"

mkdir -p "$STARSHIP_DIR"
touch "$ZSHRC" "$STARSHIP_TOML"

SOURCE_LINE="source $COPILOT_SCRIPT"

upsert_zshrc_line() {
  local file="$1"
  local line="$2"

  if grep -Fqx "$line" "$file"; then
    echo "zshrc already configured"
    return 0
  fi

  if grep -Eq '^[[:space:]]*source .*/copilot_usage\.zsh$' "$file"; then
    awk -v replacement="$line" '
      BEGIN { replaced = 0 }
      /^[[:space:]]*source .*copilot_usage\.zsh$/ && !replaced {
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
    echo "# Copilot usage prompt"
    echo "$line"
  } >> "$file"
  echo "Added source line to $file"
}

upsert_zshrc_line "$ZSHRC" "$SOURCE_LINE"

START_MARKER="# >>> copilot_usage_start >>>"
END_MARKER="# <<< copilot_usage_end <<<"

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

STARSHIP_BLOCK='[custom.copilot]
command = "cat ~/.cache/copilot_usage/prompt.txt 2>/dev/null"
when    = "test -f ~/.cache/copilot_usage/prompt.txt"
shell   = ["sh"]
format  = "[$output]($style) "
style   = "bold cyan"'

upsert_managed_block "$STARSHIP_TOML" "$START_MARKER" "$END_MARKER" "$STARSHIP_BLOCK"
echo "Updated custom.copilot block in $STARSHIP_TOML"

echo
echo "Done. Reload your shell with: exec zsh"
