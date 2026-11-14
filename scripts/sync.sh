#!/bin/bash
# Regenerates every file derived from a single source:
#   package.json        name, version and description for all manifests
#   ram-guard.sh config the hook files shipped with the Claude Code/Codex plugin and the Gemini extension
# Run `make sync` after changing either; `make check` fails if anything is out of date.
set -euo pipefail
cd "$(dirname "$0")/.."

readonly SCRIPT=plugins/ram-guard/scripts/ram-guard.sh
version=$(jq -r .version package.json)
description=$(jq -r .description package.json)

# jq in place: write_json <file> <jq args...>
write_json() {
  local file=$1
  shift
  jq "$@" "$file" >"$file.tmp" && mv "$file.tmp" "$file"
}

"$SCRIPT" config claude '"${CLAUDE_PLUGIN_ROOT}/scripts/ram-guard.sh"' >plugins/ram-guard/hooks/hooks.json
"$SCRIPT" config gemini '"${extensionPath}/plugins/ram-guard/scripts/ram-guard.sh"' >hooks/hooks.json

for manifest in plugins/ram-guard/.claude-plugin/plugin.json gemini-extension.json; do
  write_json "$manifest" --arg v "$version" --arg d "$description" '.version = $v | .description = $d'
done
write_json .claude-plugin/marketplace.json --arg d "$description" '.plugins[0].description = $d'
