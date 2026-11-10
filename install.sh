#!/bin/bash
# Installs ram-guard.sh to ~/.local/bin and registers it as a Bash hook in Claude Code and/or Codex.
# Safe to re-run: a tool that already references ram-guard.sh is left alone.
set -euo pipefail

SRC_URL=https://raw.githubusercontent.com/sahasrarjn/agent-ram-guard/main/plugins/ram-guard/scripts/ram-guard.sh
DEST="$HOME/.local/bin/ram-guard.sh"

[ "$(uname)" = Darwin ] || { echo "ram-guard supports macOS only." >&2; exit 1; }
command -v jq >/dev/null || { echo "ram-guard needs jq (brew install jq)." >&2; exit 1; }

mkdir -p "$(dirname "$DEST")"
here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
if [ -n "$here" ] && [ -f "$here/plugins/ram-guard/scripts/ram-guard.sh" ]; then
  cp "$here/plugins/ram-guard/scripts/ram-guard.sh" "$DEST"
else
  curl -fsSL "$SRC_URL" -o "$DEST"
fi
chmod +x "$DEST"
echo "Installed $DEST"

installed_any=0

if [ -d "$HOME/.claude" ]; then
  installed_any=1
  settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || echo '{}' >"$settings"
  if grep -q 'ram-guard.sh' "$settings"; then
    echo "Claude Code: already configured in $settings"
  else
    cp "$settings" "$settings.bak-ram-guard"
    jq --arg cmd "$DEST" '
      .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{matcher: "Bash", hooks: [{type: "command", command: ($cmd + " pre"), timeout: 150, statusMessage: "Checking RAM..."}]}])
      | .hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{matcher: "Bash", hooks: [{type: "command", command: ($cmd + " post"), timeout: 10}]}])
    ' "$settings.bak-ram-guard" >"$settings"
    echo "Claude Code: hooks added to $settings (backup at $settings.bak-ram-guard)"
  fi
fi

if [ -d "$HOME/.codex" ]; then
  installed_any=1
  config="$HOME/.codex/config.toml"
  touch "$config"
  if grep -q 'ram-guard.sh' "$config"; then
    echo "Codex: already configured in $config"
  else
    cp "$config" "$config.bak-ram-guard"
    cat >>"$config" <<EOF

[[hooks.PreToolUse]]
matcher = "Bash"
[[hooks.PreToolUse.hooks]]
type = "command"
command = "$DEST pre"
timeout = 150
statusMessage = "Checking RAM..."

[[hooks.PostToolUse]]
matcher = "Bash"
[[hooks.PostToolUse.hooks]]
type = "command"
command = "$DEST post"
timeout = 10
EOF
    echo "Codex: hooks added to $config (backup at $config.bak-ram-guard)"
    echo "Codex: open codex and run /hooks to review and trust the new hooks; untrusted hooks are skipped."
  fi
fi

[ "$installed_any" = 1 ] || echo "Found neither ~/.claude nor ~/.codex; the script is installed but no hooks were registered."
"$DEST" status | head -1
