#!/bin/bash
# ram-guard: keeps parallel coding agents from running a Mac out of RAM.
#
#   ram-guard.sh pre|post|session [format]   hook entry points (stdin: the tool's hook payload)
#   ram-guard.sh config <tool> [script]      print the hook config for a tool
#   ram-guard.sh status | top | rules        manual use
#
# format is the hook output dialect: claude (default; also Codex and pi), cursor, gemini, antigravity.
# tool is one of: claude, codex, cursor, gemini, antigravity.
#
# Hooks must never break the agent: this script does not use `set -e`, and when it has nothing to say
# it answers with the format's no-op. Antigravity treats a failed PreToolUse hook as a denial.
set -uo pipefail

readonly WARN_PCT=${RAM_WARN_USED_PCT:-90}
readonly BLOCK_PCT=${RAM_BLOCK_USED_PCT:-95}
readonly WAIT_SECS=${RAM_WAIT_SECS:-120}
readonly SWAP_WARN_GB=${RAM_WARN_SWAP_GB:-5}
readonly SWAP_BLOCK_GB=${RAM_BLOCK_SWAP_GB:-7}
readonly SWAP_BLOCK_MIN_PCT=${RAM_SWAP_BLOCK_MIN_USED_PCT:-85}
readonly LOG=${RAM_GUARD_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/ram-guard/ram-log.tsv}
readonly WARN_EVERY_SECS=300
readonly PRE_TIMEOUT_SECS=$((WAIT_SECS + 30)) # hook timeout must outlast the wait
readonly HOOK_TIMEOUT_SECS=10
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
readonly SELF

# Memory-heavy commands, one tool family per line. A command matches when one of these starts a word
# (after a space, a separator, `./` or a path). Extend with RAM_GUARD_HEAVY_EXTRA, replace with RAM_GUARD_HEAVY.
readonly DEFAULT_HEAVY=(
  '(npm|pnpm|yarn|bun)( run)? (dev|start|serve|test|build|watch|e2e|storybook)'
  'npm (t|start)|bun test'
  'next (dev|build|start)|vite|vitest|jest|playwright|cypress (run|open)|webpack|tsc|turbo (run|dev|build|test)|nx (serve|build|test|run)|storybook'
  'pytest|tox|nox|mypy|uvicorn|gunicorn|celery|streamlit run|flask run|manage\.py (runserver|test)'
  'python[0-9.]* -m (pytest|uvicorn|torch\.distributed\.run)|python[0-9.]* [^ ]*(train|finetune|fine_tune|serve)[^ ]*\.py'
  'torchrun|accelerate launch|deepspeed|jupyter|ipython|ollama (run|serve)|llama-server|vllm serve'
  'docker( |-)compose (up|run|build)|docker (run|build)|podman (run|build)|minikube start|kind create'
  'go (test|build|run)|cargo (build|test|run|bench|nextest)|swift (build|test|run)|xcodebuild'
  'mvn|gradle|gradlew|sbt|dotnet (build|test|run|watch)|bazel(isk)? (build|test|run)|flutter (run|test|build)'
  'rspec|rails (s|server|test)|php artisan (serve|test)|phpunit|mix (test|phx\.server)'
  'make|scripts/dev'
)
# Segments that start with these only inspect or stop things, so they are never held.
readonly SAFE_FIRST_WORD='grep|rg|cat|echo|ls|head|tail|less|wc|which|man|git|kill|pkill|docker (stop|rm|ps|logs)'
readonly SAFE_FLAG='--version|--help|-V'

readonly RULES="RAM rules (ram-guard):
- Every process you start (dev servers, test runs, containers, browsers) is yours to stop. Note its PID and stop it when you are done.
- Never kill a process you did not start.
- Before starting something heavy, run \`\"$SELF\" status\`. If RAM is at or above ${WARN_PCT}%, close your own idle processes first."

# --- memory ---------------------------------------------------------------------------------------

# "Used %" as Activity Monitor counts it: app memory (anonymous - purgeable) + wired + compressed.
used_pct() {
  vm_stat | awk -v total="$(sysctl -n hw.memsize)" '
    /page size of/ { gsub(/[^0-9]/, "", $8); ps = $8 }
    /^Anonymous pages/ { a = $3 + 0 }
    /^Pages purgeable/ { p = $3 + 0 }
    /^Pages wired down/ { w = $4 + 0 }
    /^Pages occupied by compressor/ { c = $5 + 0 }
    END { printf "%d", ((a - p + w + c) * ps) * 100 / total }'
}

swap_gb() { sysctl -n vm.swapusage | awk '{ gsub("M", "", $6); printf "%.1f", $6 / 1024 }'; }

swap_at_least() { awk -v a="$(swap_gb)" -v b="$1" 'BEGIN { exit !(a >= b) }'; }

# Critical: used % at the block limit, or swap nearly full while used % is already high.
critical() {
  [ "$1" -ge "$BLOCK_PCT" ] || { [ "$1" -ge "$SWAP_BLOCK_MIN_PCT" ] && swap_at_least "$SWAP_BLOCK_GB"; }
}

top_procs() {
  ps -axo rss=,pid=,command= | sort -nr | head -"${1:-6}" | awk '{
    rss = $1 / 1024; pid = $2; $1 = ""; $2 = ""; cmd = $0
    wt = match(cmd, /worktrees\/[^\/]+/) ? substr(cmd, RSTART + 10, RLENGTH - 10) : ""
    gsub(/^ +/, "", cmd)
    printf "  %5.0f MB  pid %-6s %s%s\n", rss, pid, substr(cmd, 1, 70), (wt ? "  [worktree " wt "]" : "")
  }'
}

log_sample() {
  mkdir -p "$(dirname "$LOG")"
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$(swap_gb)" >>"$LOG"
  if [ "$(wc -l <"$LOG")" -gt 5000 ]; then tail -n 2000 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"; fi
}

# --- commands -------------------------------------------------------------------------------------

heavy_regex() {
  local patterns=("${DEFAULT_HEAVY[@]}")
  [ -n "${RAM_GUARD_HEAVY:-}" ] && patterns=("$RAM_GUARD_HEAVY")
  [ -n "${RAM_GUARD_HEAVY_EXTRA:-}" ] && patterns+=("$RAM_GUARD_HEAVY_EXTRA")
  local IFS='|'
  printf '(^|[;&|( /]|xargs )(%s)([[:space:]]|$)' "${patterns[*]}"
}

# True if any segment of a compound command (split on ; | && ||) is memory-heavy.
is_heavy() {
  local seg heavy
  heavy=$(heavy_regex)
  while IFS= read -r seg; do
    [[ $seg =~ ^[[:space:]]*($SAFE_FIRST_WORD)([[:space:]]|$) ]] && continue
    [[ $seg =~ [[:space:]]($SAFE_FLAG)([[:space:]]|$) ]] && continue
    [[ $seg =~ $heavy ]] && return 0
  done < <(awk '{ gsub(/&&|\|\||[;|]/, "\n"); print }' <<<"$1")
  return 1
}

# --- hook dialects --------------------------------------------------------------------------------

# Field names differ per tool: Claude Code/Codex/Gemini (tool_input.command), Cursor (command),
# Antigravity (toolCall.args.CommandLine).
payload_command() { jq -r '.tool_input.command // .command // .toolCall.args.CommandLine // ""' 2>/dev/null; }
payload_session() { jq -r '.session_id // .conversation_id // .conversationId // "x"' 2>/dev/null | tr -cd 'A-Za-z0-9_-'; }

# respond <format> <kind> [text]
#   kind: deny | pass (pre-hook no-op) | session | warn | none (other no-op)
# Prints nothing when the format wants no output. Antigravity reads a missing PreToolUse decision as
# deny, and its "allow" does not override the user's own ask/deny rules (checked against agy 1.5.8).
respond() {
  jq -n --arg fmt "$1" --arg kind "$2" --arg text "${3:-}" '
    def context($event): {hookSpecificOutput: {hookEventName: $event, additionalContext: $text}};
    def system_step: {injectSteps: [{systemMessage: {systemMessage: $text}}]};
    {
      claude: {deny: {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $text}},
               session: context("SessionStart"), warn: context("PostToolUse"), pass: null, none: null},
      gemini: {deny: {decision: "deny", reason: $text},
               session: context("SessionStart"), warn: context("AfterTool"), pass: null, none: null},
      cursor: {deny: {permission: "deny", user_message: "ram-guard: RAM is critical, heavy command held back.", agent_message: $text},
               session: {additional_context: $text}, warn: {additional_context: $text}, pass: {}, none: {}},
      antigravity: {deny: {decision: "deny", reason: $text},
                    session: system_step, warn: system_step, pass: {decision: "allow"}, none: {}}
    }[$fmt][$kind] // empty'
}

# config <tool> <script>: the hook config for a tool, as merged into its config file (Codex: TOML).
config() {
  local tool=$1 script=$2
  jq -n --arg tool "$tool" --arg script "$script" --argjson pre "$PRE_TIMEOUT_SECS" --argjson short "$HOOK_TIMEOUT_SECS" '
    def fmt: if $tool == "claude" or $tool == "codex" then "" else " " + $tool end;
    def hook($mode; $timeout): {type: "command", command: "\($script) \($mode)\(fmt)", timeout: $timeout};
    def claude: {hooks: {
      SessionStart: [{hooks: [hook("session"; $short)]}],
      PreToolUse: [{matcher: "Bash", hooks: [hook("pre"; $pre) + {statusMessage: "Checking RAM..."}]}],
      PostToolUse: [{matcher: "Bash", hooks: [hook("post"; $short)]}]}};
    {
      claude: claude,
      codex: claude,
      gemini: {hooks: {
        SessionStart: [{hooks: [hook("session"; $short * 1000) + {name: "ram-guard-session"}]}],
        BeforeTool: [{matcher: "run_shell_command", hooks: [hook("pre"; $pre * 1000) + {name: "ram-guard-pre"}]}],
        AfterTool: [{matcher: "run_shell_command", hooks: [hook("post"; $short * 1000) + {name: "ram-guard-post"}]}]}},
      cursor: {version: 1, hooks: {
        sessionStart: [hook("session"; $short)],
        beforeShellExecution: [hook("pre"; $pre)],
        postToolUse: [hook("post"; $short) + {matcher: "Shell"}]}},
      # PostToolUse cannot reach the agent in Antigravity, so the warning runs before the next model call.
      # SessionStart and PreInvocation take flat handler lists.
      antigravity: {"ram-guard": {
        SessionStart: [hook("session"; $short)],
        PreToolUse: [{matcher: "run_command", hooks: [hook("pre"; $pre)]}],
        PreInvocation: [hook("post"; $short)]}}
    }[$tool] // error("unknown tool: \($tool)")' |
    if [ "$tool" = codex ]; then to_toml; else cat; fi
}

# Codex keeps hooks in config.toml as [[hooks.<Event>]] tables.
to_toml() {
  jq -r '.hooks | to_entries[] | .key as $event | .value[] |
    "\n[[hooks.\($event)]]" + (if .matcher then "\nmatcher = \(.matcher | tojson)" else "" end) +
    ([.hooks[] | "\n[[hooks.\($event).hooks]]" + ([to_entries[] | "\n\(.key) = \(.value | tojson)"] | join(""))] | join(""))'
}

# --- hook modes -----------------------------------------------------------------------------------

hook_pre() {
  local fmt=$1 input=$2 used waited=0 step
  is_heavy "$(payload_command <<<"$input")" || { respond "$fmt" pass; return; }
  used=$(used_pct)
  while critical "$used" && [ "$waited" -lt "$WAIT_SECS" ]; do
    step=$((8 + RANDOM % 5))
    sleep "$step"
    waited=$((waited + step))
    used=$(used_pct)
  done
  if ! critical "$used"; then respond "$fmt" pass; return; fi
  respond "$fmt" deny "RAM is at ${used}% used, swap $(swap_gb) GB (limits ${BLOCK_PCT}% used, or ${SWAP_BLOCK_GB} GB swap above ${SWAP_BLOCK_MIN_PCT}%) after waiting ${waited}s, so this memory-heavy command was not started. Stop dev servers and test runs you started yourself (check your own PIDs), do not kill other agents' processes, then retry. Top processes:
$(top_procs 6)"
}

# At most one sample and warning per session every WARN_EVERY_SECS.
hook_post() {
  local fmt=$1 input=$2 stamp used
  stamp="${TMPDIR:-/tmp}/ram-guard-$(payload_session <<<"$input")"
  if [ -f "$stamp" ] && [ $(($(date +%s) - $(stat -f %m "$stamp"))) -lt "$WARN_EVERY_SECS" ]; then
    respond "$fmt" none
    return
  fi
  touch "$stamp"
  used=$(used_pct)
  log_sample "$used"
  if [ "$used" -lt "$WARN_PCT" ] && ! swap_at_least "$SWAP_WARN_GB"; then respond "$fmt" none; return; fi
  respond "$fmt" warn "RAM warning: ${used}% used, swap $(swap_gb) GB. Stop dev servers, test runs and containers YOU started that you no longer need, and do not start new heavy processes until it drops below ${WARN_PCT}%. Do not kill processes you did not start. Top processes:
$(top_procs 6)"
}

main() {
  local mode=${1:-status} input=""
  case $mode in pre | post | session) [ -t 0 ] || input=$(cat) ;; esac
  case $mode in
    pre) hook_pre "${2:-claude}" "$input" ;;
    post) hook_post "${2:-claude}" "$input" ;;
    session) respond "${2:-claude}" session "$RULES" ;;
    config) config "${2:?usage: ram-guard.sh config <tool> [script]}" "${3:-$SELF}" ;;
    rules) echo "$RULES" ;;
    status) echo "RAM used $(used_pct)%, swap $(swap_gb) GB" && top_procs 8 ;;
    top) top_procs 10 ;;
    *) echo "usage: ram-guard.sh pre|post|session [format] | config <tool> [script] | status | top | rules" >&2 && return 2 ;;
  esac
}

main "$@"
