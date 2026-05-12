#!/usr/bin/env bash
# claude-statusline installer
# Installs a rich status line for Claude Code with context bar,
# effort/thinking indicators, and 5h/7d rate limit usage + reset times.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/viniciusragazzi/claude-statusline/main/install.sh | bash
#   # or clone the repo and run ./install.sh

set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"
SETTINGS="$CLAUDE_DIR/settings.json"
SCRIPT_DEST="$SCRIPTS_DIR/statusline.sh"
RAW_URL="https://raw.githubusercontent.com/viniciusragazzi/claude-statusline/main/statusline.sh"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
red() { printf '\033[0;31m%s\033[0m\n' "$1" >&2; }
dim() { printf '\033[2m%s\033[0m\n' "$1"; }

bold "claude-statusline installer"
echo

if ! command -v jq >/dev/null 2>&1; then
  red "missing dependency: jq"
  echo "install with: apt install jq  /  brew install jq"
  exit 1
fi

if [ ! -d "$CLAUDE_DIR" ]; then
  red "Claude Code config dir not found: $CLAUDE_DIR"
  echo "is Claude Code installed and run at least once?"
  exit 1
fi

mkdir -p "$SCRIPTS_DIR"

echo "→ downloading statusline.sh"
if [ -f "./statusline.sh" ]; then
  cp ./statusline.sh "$SCRIPT_DEST"
  dim "  (used local copy)"
else
  curl -fsSL "$RAW_URL" -o "$SCRIPT_DEST"
fi
chmod +x "$SCRIPT_DEST"
green "✓ installed to $SCRIPT_DEST"

echo "→ updating $SETTINGS"
if [ -f "$SETTINGS" ]; then
  BACKUP="$SETTINGS.bak.$(date +%s)"
  cp "$SETTINGS" "$BACKUP"
  dim "  backup saved to $BACKUP"
  TMP=$(mktemp)
  jq --arg cmd "bash $SCRIPT_DEST" \
    '.statusLine = {type: "command", command: $cmd}' \
    "$SETTINGS" > "$TMP"
  mv "$TMP" "$SETTINGS"
else
  cat > "$SETTINGS" <<EOF
{
  "statusLine": {
    "type": "command",
    "command": "bash $SCRIPT_DEST"
  }
}
EOF
fi
green "✓ statusLine configured"

echo
bold "done."
echo "restart Claude Code or run any prompt to see the new status line."
