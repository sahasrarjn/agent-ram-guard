#!/bin/bash
# Installs ram-guard.sh to ~/.local/bin and registers its hooks in each coding agent's global config.
#   install.sh                       every supported tool it finds
#   install.sh cursor antigravity    only these (claude, codex, cursor, antigravity)
# Safe to re-run: the script is refreshed, and a config that already references ram-guard.sh is left alone.
# The hook configs come from `ram-guard.sh config <tool>`, the same source the plugin files are built from.
set -euo pipefail

readonly SRC_URL=https://raw.githubusercontent.com/sahasrarjn/agent-ram-guard/main/plugins/ram-guard/scripts/ram-guard.sh
readonly DEST="$HOME/.local/bin/ram-guard.sh"
readonly ALL_TOOLS=(claude codex cursor antigravity)

config_file() {
  case $1 in
    claude) echo "$HOME/.claude/settings.json" ;;
    codex) echo "$HOME/.codex/config.toml" ;;
    cursor) echo "$HOME/.cursor/hooks.json" ;;
    antigravity) echo "$HOME/.gemini/config/hooks.json" ;;
  esac
}

is_installed() {
  case $1 in
    antigravity) [ -d "$HOME/.gemini/antigravity" ] || [ -d "$HOME/.gemini/antigravity-cli" ] || command -v agy >/dev/null ;;
    *) [ -d "$HOME/.$1" ] ;;
  esac
}

after_note() {
  case $1 in
    codex) echo "  Open codex and run /hooks to trust the new hooks; untrusted hooks are skipped." ;;
    cursor | claude) echo "  Restart open sessions to pick the hooks up." ;;
  esac
}

install_script() {
  local here
  mkdir -p "$(dirname "$DEST")"
  here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
  if [ -n "$here" ] && [ -f "$here/plugins/ram-guard/scripts/ram-guard.sh" ]; then
    cp "$here/plugins/ram-guard/scripts/ram-guard.sh" "$DEST"
  else
    curl -fsSL "$SRC_URL" -o "$DEST"
  fi
  chmod +x "$DEST"
  echo "Installed $DEST"
}

# Deep-merges the tool's hooks into its JSON config, appending to existing hook lists.
merge_json() {
  local file=$1 tool=$2
  jq --argjson new "$("$DEST" config "$tool" "$DEST")" '
    def merge($a; $b):
      if ($a | type) == "object" and ($b | type) == "object" then
        reduce ($b | keys_unsorted[]) as $k ($a; .[$k] = merge($a[$k]; $b[$k]))
      elif ($a | type) == "array" and ($b | type) == "array" then $a + $b
      elif $a == null then $b
      else $a end;
    merge(.; $new)' "$file.bak-ram-guard" >"$file"
}

register() {
  local tool=$1 file
  file=$(config_file "$tool")
  mkdir -p "$(dirname "$file")"
  if [ ! -f "$file" ]; then
    if [ "$tool" = codex ]; then touch "$file"; else echo '{}' >"$file"; fi
  fi
  if grep -q 'ram-guard.sh' "$file"; then
    echo "$tool: already configured in $file"
    return
  fi
  cp "$file" "$file.bak-ram-guard"
  if [ "$tool" = codex ]; then "$DEST" config codex "$DEST" >>"$file"; else merge_json "$file" "$tool"; fi
  echo "$tool: hooks added to $file (backup at $file.bak-ram-guard)"
  after_note "$tool"
}

main() {
  local tools=("$@") tool registered=0
  [ ${#tools[@]} -gt 0 ] || tools=("${ALL_TOOLS[@]}")
  for tool in "${tools[@]}"; do
    [[ " ${ALL_TOOLS[*]} " == *" $tool "* ]] || { echo "Unknown tool: $tool (use ${ALL_TOOLS[*]})" >&2; exit 1; }
  done
  [ "$(uname)" = Darwin ] || { echo "ram-guard supports macOS only." >&2; exit 1; }
  command -v jq >/dev/null || { echo "ram-guard needs jq (brew install jq)." >&2; exit 1; }

  install_script
  for tool in "${tools[@]}"; do
    is_installed "$tool" || continue
    register "$tool"
    registered=1
  done
  [ "$registered" = 1 ] || echo "Found none of: ${tools[*]}. The script is installed but no hooks were registered."
  "$DEST" status | head -1
}

main "$@"
