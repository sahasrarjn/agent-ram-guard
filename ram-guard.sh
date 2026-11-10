#!/bin/bash
# RAM guard for Claude Code hooks (macOS).
#   ram-guard.sh pre   PreToolUse(Bash): hold or deny memory-heavy commands while RAM is critical
#   ram-guard.sh post  PostToolUse(Bash): throttled warning + log, tells agents to close their own processes
#   ram-guard.sh status | top   manual inspection
# Thresholds are "used %" as Activity Monitor counts it (app + wired + compressed).
WARN=${RAM_WARN_USED_PCT:-90}
BLOCK=${RAM_BLOCK_USED_PCT:-95}
WAIT_SECS=${RAM_WAIT_SECS:-120}
SWAP_WARN=${RAM_WARN_SWAP_GB:-5}
SWAP_BLOCK=${RAM_BLOCK_SWAP_GB:-7}
SWAP_FLOOR_PCT=${RAM_SWAP_BLOCK_MIN_USED_PCT:-85}
LOG=~/.claude/ram-log.tsv
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
input=""
case $mode in pre|post) input=$(cat) ;; esac

case $mode in
  status) echo "RAM used $(used_pct)%, swap $(swap_gb) GB"; top_procs 8 ;;
  top) top_procs 10 ;;

  pre)
    cmd=$(jq -r '.tool_input.command // ""' <<<"$input")
    is_heavy "$cmd" || exit 0
    used=$(used_pct)
    waited=0
    while critical "$used" && [ "$waited" -lt "$WAIT_SECS" ]; do
      step=$((8 + RANDOM % 5)); sleep "$step"; waited=$((waited + step)); used=$(used_pct)
    done
    if critical "$used"; then
      reason="RAM is at ${used}% used, swap $(swap_gb) GB (limits ${BLOCK}% used, or ${SWAP_BLOCK} GB swap above ${SWAP_FLOOR_PCT}%) after waiting ${waited}s, so this memory-heavy command was not started. Stop dev servers and test runs you started yourself (check your own PIDs), do not kill other agents' processes, then retry. Top processes:
$(top_procs 6)"
      jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    fi
    ;;

  post)
    sid=$(jq -r '.session_id // "x"' <<<"$input")
    stamp="${TMPDIR:-/tmp}/claude-ram-$sid"
    now=$(date +%s)
    [ -f "$stamp" ] && [ $((now - $(stat -f %m "$stamp"))) -lt 300 ] && exit 0
    touch "$stamp"
    used=$(used_pct)
    log_sample "$used"
    [ "$used" -ge "$WARN" ] || swap_ge "$SWAP_WARN" || exit 0
    msg="RAM warning: ${used}% used, swap $(swap_gb) GB. Stop dev servers, test runs and containers YOU started that you no longer need, and do not start new heavy processes until it drops below ${WARN}%. Do not kill processes you did not start. Top processes:
$(top_procs 6)"
    jq -n --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}'
    ;;
esac
exit 0
