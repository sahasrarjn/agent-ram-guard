#!/bin/bash
# RAM guard for coding-agent hooks on macOS.
#   ram-guard.sh pre [harness]      before a shell command: hold or deny memory-heavy commands while RAM is critical
#   ram-guard.sh post [harness]     after a shell command: throttled warning + log, tells agents to close their own processes
#   ram-guard.sh session [harness]  session start: injects the RAM rules for the agent
#   ram-guard.sh status | top       manual inspection
# harness picks the hook output format: claude (default; also Codex and pi), cursor, gemini, antigravity.
# For antigravity, register `post` on PreInvocation: its PostToolUse hooks cannot add context.
# Thresholds are "used %" as Activity Monitor counts it (app + wired + compressed).
WARN=${RAM_WARN_USED_PCT:-90}
BLOCK=${RAM_BLOCK_USED_PCT:-95}
WAIT_SECS=${RAM_WAIT_SECS:-120}
SWAP_WARN=${RAM_WARN_SWAP_GB:-5}
SWAP_BLOCK=${RAM_BLOCK_SWAP_GB:-7}
SWAP_FLOOR_PCT=${RAM_SWAP_BLOCK_MIN_USED_PCT:-85}
LOG=${RAM_GUARD_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/ram-guard/ram-log.tsv}
HEAVY='(^|[;&| ]|xargs )(next (dev|build)|bun (run )?(dev|build|test)|npm run (dev|build|test)|yarn (dev|build|test)|pnpm (dev|build|test)|vite|tsc|jest|mypy|next start|make (dev|test|run)|uvicorn|pytest|python[0-9.]* -m (pytest|uvicorn)|docker([ -]compose)? (up|run)|scripts/dev|playwright|xcodebuild|cargo build|gradlew)'

used_pct() {
  local vm total
  vm=$(vm_stat)
  total=$(sysctl -n hw.memsize)
  awk -v total="$total" '
    /page size of/ { gsub(/[^0-9]/, "", $8); ps = $8 }
    /^Anonymous pages/ { a = $3 + 0 }
    /^Pages purgeable/ { p = $3 + 0 }
    /^Pages wired down/ { w = $4 + 0 }
    /^Pages occupied by compressor/ { c = $5 + 0 }
    END { printf "%d", ((a - p + w + c) * ps) * 100 / total }' <<<"$vm"
}

swap_gb() { sysctl -n vm.swapusage | awk '{gsub("M","",$6); printf "%.1f", $6/1024}'; }

swap_ge() { awk -v a="$(swap_gb)" -v b="$1" 'BEGIN { exit !(a >= b) }'; }

# Critical when used% hits the limit, or swap is nearly full while used% is already high.
critical() {
  local used=$1
  [ "$used" -ge "$BLOCK" ] && return 0
  [ "$used" -ge "$SWAP_FLOOR_PCT" ] && swap_ge "$SWAP_BLOCK" && return 0
  return 1
}

is_heavy() {
  local seg
  while IFS= read -r seg; do
    [[ $seg =~ ^[[:space:]]*(grep|rg|cat|echo|ls|git|kill|pkill|docker\ (stop|rm|ps))([[:space:]]|$) ]] && continue
    [[ $seg =~ $HEAVY ]] && return 0
  done < <(sed -E 's/&&|\|\||[;|]/\
/g' <<<"$1")
  return 1
}

top_procs() {
  ps -axo rss=,pid=,command= | sort -nr | head -${1:-6} | awk '{
    rss = $1 / 1024; pid = $2; $1 = ""; $2 = ""; cmd = $0
    if (match(cmd, /worktrees\/[^\/]+/)) wt = substr(cmd, RSTART + 10, RLENGTH - 10); else wt = ""
    gsub(/^ +/, "", cmd); cmd = substr(cmd, 1, 70)
    printf "  %5.0f MB  pid %-6s %s%s\n", rss, pid, cmd, (wt ? "  [worktree " wt "]" : "")
  }'
}

log_sample() {
  mkdir -p "$(dirname "$LOG")"
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$(swap_gb)" >>"$LOG"
  if [ "$(wc -l <"$LOG")" -gt 5000 ]; then tail -n 2000 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"; fi
}

mode=${1:-status}
fmt=${2:-claude}
input=""
case $mode in pre|post|session) [ -t 0 ] || input=$(cat) ;; esac

# The shell command, from Claude Code/Codex/Gemini (tool_input.command), Cursor (command) or Antigravity (toolCall.args.CommandLine).
command_of() { jq -r '.tool_input.command // .command // .toolCall.args.CommandLine // ""' <<<"$input" 2>/dev/null; }
session_of() { jq -r '.session_id // .conversation_id // .conversationId // "x"' <<<"$input" 2>/dev/null; }

# Tell the agent something: $1 = session|post, $2 = text.
emit_context() {
  case $fmt in
    cursor) jq -n --arg m "$2" '{additional_context:$m}' ;;
    gemini)
      local ev=AfterTool; [ "$1" = session ] && ev=SessionStart
      jq -n --arg e "$ev" --arg m "$2" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$m}}' ;;
    antigravity) jq -n --arg m "$2" '{injectSteps:[{systemMessage:{systemMessage:$m}}]}' ;;
    *)
      local ev=PostToolUse; [ "$1" = session ] && ev=SessionStart
      jq -n --arg e "$ev" --arg m "$2" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$m}}' ;;
  esac
}

# Nothing to say. Cursor and Antigravity expect a JSON object from every hook; the others accept empty output.
# Antigravity's PreToolUse treats a missing or empty decision as deny. "allow" only means this hook does not
# object: the user's own ask/deny permission rules still apply (checked against agy 1.5.8).
emit_none() {
  case $fmt in
    antigravity) [ "$mode" = pre ] && echo '{"decision":"allow"}' || echo '{}' ;;
    cursor) echo '{}' ;;
  esac
}

emit_deny() {
  case $fmt in
    cursor) jq -n --arg r "$1" '{permission:"deny",user_message:"ram-guard: RAM is critical, heavy command held back.",agent_message:$r}' ;;
    gemini|antigravity) jq -n --arg r "$1" '{decision:"deny",reason:$r}' ;;
    *) jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' ;;
  esac
}

case $mode in
  status) echo "RAM used $(used_pct)%, swap $(swap_gb) GB"; top_procs 8 ;;
  session)
    self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
    rules="RAM rules (ram-guard): Every process you start (dev servers, test runs, containers, browsers) is yours to stop. Note its PID and stop it when you are done. Never kill a process you did not start. Before starting something heavy, run \`\"$self\" status\`; if RAM is at or above ${WARN}%, close your own idle processes first."
    emit_context session "$rules"
    ;;
  top) top_procs 10 ;;

  pre)
    cmd=$(command_of)
    is_heavy "$cmd" || { emit_none; exit 0; }
    used=$(used_pct)
    waited=0
    while critical "$used" && [ "$waited" -lt "$WAIT_SECS" ]; do
      step=$((8 + RANDOM % 5)); sleep "$step"; waited=$((waited + step)); used=$(used_pct)
    done
    if critical "$used"; then
      reason="RAM is at ${used}% used, swap $(swap_gb) GB (limits ${BLOCK}% used, or ${SWAP_BLOCK} GB swap above ${SWAP_FLOOR_PCT}%) after waiting ${waited}s, so this memory-heavy command was not started. Stop dev servers and test runs you started yourself (check your own PIDs), do not kill other agents' processes, then retry. Top processes:
$(top_procs 6)"
      emit_deny "$reason"
    else
      emit_none
    fi
    ;;

  post)
    sid=$(session_of | tr -cd 'A-Za-z0-9_-')
    stamp="${TMPDIR:-/tmp}/ram-guard-$sid"
    now=$(date +%s)
    [ -f "$stamp" ] && [ $((now - $(stat -f %m "$stamp"))) -lt 300 ] && { emit_none; exit 0; }
    touch "$stamp"
    used=$(used_pct)
    log_sample "$used"
    [ "$used" -ge "$WARN" ] || swap_ge "$SWAP_WARN" || { emit_none; exit 0; }
    msg="RAM warning: ${used}% used, swap $(swap_gb) GB. Stop dev servers, test runs and containers YOU started that you no longer need, and do not start new heavy processes until it drops below ${WARN}%. Do not kill processes you did not start. Top processes:
$(top_procs 6)"
    emit_context post "$msg"
    ;;
esac
exit 0
