#!/bin/bash
# Tests for ram-guard.sh and install.sh. macOS only (the script reads vm_stat). Run: make test
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

readonly SCRIPT=$PWD/plugins/ram-guard/scripts/ram-guard.sh
failures=0
TMPDIR=$(mktemp -d)
export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# Runs a hook with thresholds forced so every heavy command is denied and every post hook warns.
forced() { RAM_BLOCK_USED_PCT=0 RAM_WARN_USED_PCT=0 RAM_WAIT_SECS=0 "$SCRIPT" "$@"; }
claude_payload() { jq -nc --arg c "$1" '{session_id: "t", tool_input: {command: $c}}'; }
is_held() { forced pre <<<"$(claude_payload "$1")" | grep -q '"deny"'; }

echo "heavy commands"
while IFS= read -r cmd; do
  check "held: $cmd" "is_held '$cmd'"
done <<'EOF'
npm test
npm start
npm run dev
pnpm run dev
pnpm dev
yarn start
bun test
npx vitest run
npx playwright test
next dev
turbo run build
nx serve app
webpack --watch
tsc -p .
pytest -q
uv run pytest
python -m pytest tests
python train.py --epochs 3
torchrun --nproc_per_node=4 train.py
jupyter lab
ollama run llama3
uvicorn app:app
docker compose up
docker build .
go test ./...
cargo test
mvn test
gradle build
./gradlew assembleDebug
dotnet test
swift build
bazel test //...
flutter run
bundle exec rspec
rails server
php artisan serve
make
make test
cd web && npm run dev
ls && pytest
EOF
while IFS= read -r cmd; do
  check "passes: $cmd" "! is_held '$cmd'"
done <<'EOF'
ls -la
git status
grep -r pytest .
cat package.json
tsc --version
python --version
python script.py
echo npm test
docker ps
kill 1234
EOF
check "RAM_GUARD_HEAVY_EXTRA adds patterns" "RAM_GUARD_HEAVY_EXTRA='my-server' is_held 'my-server --port 3000'"
check "RAM_GUARD_HEAVY replaces the list" "! RAM_GUARD_HEAVY='my-server' is_held pytest"

echo "hook dialects"
check "claude deny" "forced pre <<<'$(claude_payload pytest)' | jq -e '.hookSpecificOutput.permissionDecision == \"deny\"' >/dev/null"
check "claude pass is empty" "[ -z \"\$(forced pre <<<'$(claude_payload ls)')\" ]"
check "claude warn" "forced post <<<'{\"session_id\":\"w1\"}' | jq -e '.hookSpecificOutput.hookEventName == \"PostToolUse\"' >/dev/null"
check "post warns once per session window" "[ -z \"\$(forced post <<<'{\"session_id\":\"w1\"}')\" ]"
check "claude session rules" "forced session </dev/null | jq -e '.hookSpecificOutput.additionalContext | startswith(\"RAM rules\")' >/dev/null"
check "cursor deny" "forced pre cursor <<<'{\"command\":\"pytest\"}' | jq -e '.permission == \"deny\" and (.agent_message | length > 0)' >/dev/null"
check "cursor pass is {}" "[ \"\$(forced pre cursor <<<'{\"command\":\"ls\"}')\" = '{}' ]"
check "cursor warn" "forced post cursor <<<'{\"conversation_id\":\"w2\"}' | jq -e '.additional_context | startswith(\"RAM warning\")' >/dev/null"
check "gemini deny" "forced pre gemini <<<'$(claude_payload pytest)' | jq -e '.decision == \"deny\"' >/dev/null"
check "gemini warn" "forced post gemini <<<'{\"session_id\":\"w3\"}' | jq -e '.hookSpecificOutput.hookEventName == \"AfterTool\"' >/dev/null"
check "antigravity deny" "forced pre antigravity <<<'{\"toolCall\":{\"args\":{\"CommandLine\":\"pytest\"}}}' | jq -e '.decision == \"deny\"' >/dev/null"
check "antigravity pass is allow" "forced pre antigravity <<<'{\"toolCall\":{\"args\":{\"CommandLine\":\"ls\"}}}' | jq -e '.decision == \"allow\"' >/dev/null"
check "antigravity warn is a system message" "forced post antigravity <<<'{\"conversationId\":\"w4\"}' | jq -e '.injectSteps[0].systemMessage.systemMessage | startswith(\"RAM warning\")' >/dev/null"
check "no warning below threshold" "[ -z \"\$(RAM_WARN_USED_PCT=101 RAM_WARN_SWAP_GB=9999 '$SCRIPT' post <<<'{\"session_id\":\"w5\"}')\" ]"

echo "configs"
for tool in claude cursor gemini antigravity; do
  check "$tool config is valid JSON" "'$SCRIPT' config $tool /x/ram-guard.sh | jq -e . >/dev/null"
done
check "codex config is valid TOML" "'$SCRIPT' config codex /x/ram-guard.sh | python3 -c 'import sys, tomllib; tomllib.loads(sys.stdin.read())'"
check "unknown tool is rejected" "! '$SCRIPT' config nope /x 2>/dev/null"
check "README rules match the script" "grep -qF -- \"\$('$SCRIPT' rules | sed -n 2p)\" README.md"

echo "installer"
fake_home() {
  local home
  home=$(mktemp -d "$TMPDIR/home.XXXX")
  mkdir -p "$home/.claude" "$home/.codex" "$home/.cursor" "$home/.gemini/antigravity-cli"
  echo "$home"
}
home=$(fake_home)
echo '{"version":1,"hooks":{"stop":[{"command":"existing"}]}}' >"$home/.cursor/hooks.json"
HOME=$home ./install.sh >/dev/null 2>&1
check "installs into every tool" "grep -q ram-guard.sh '$home/.claude/settings.json' '$home/.codex/config.toml' '$home/.cursor/hooks.json' '$home/.gemini/config/hooks.json'"
check "keeps existing Cursor hooks" "jq -e '.hooks.stop[0].command == \"existing\" and (.hooks.beforeShellExecution | length == 1)' '$home/.cursor/hooks.json' >/dev/null"
check "codex config parses" "python3 -c 'import tomllib; tomllib.load(open(\"$home/.codex/config.toml\", \"rb\"))'"
HOME=$home ./install.sh >/dev/null 2>&1
check "re-running adds nothing" "[ \"\$(jq '.hooks.PreToolUse | length' '$home/.claude/settings.json')\" = 1 ]"
home=$(fake_home)
HOME=$home ./install.sh cursor >/dev/null 2>&1
check "named tools only" "[ ! -f '$home/.claude/settings.json' ] && grep -q ram-guard.sh '$home/.cursor/hooks.json'"
check "unknown tool is rejected" "! HOME='$home' ./install.sh nope >/dev/null 2>&1"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures failed" && exit 1; fi
