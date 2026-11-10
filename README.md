# claude-code-ram-guard

A [Claude Code](https://docs.claude.com/en/docs/claude-code) hook that keeps parallel agents from running a Mac out of memory.

When several agents share one machine, each one starts its own dev server, test run or container, and nobody stops them. RAM fills up, swap grows, and everything slows down. This hook makes the agents notice:

- **Before** a memory-heavy Bash command (`pytest`, `next dev`, `docker compose up`, `tsc`, `uvicorn`, ...), it checks RAM. If memory is critical it waits up to 2 minutes for it to drop, then denies the command and tells the agent to stop the processes it started itself.
- **After** any Bash command (at most once every 5 minutes per session), it logs a sample and, if RAM or swap is high, warns the agent with the top processes by memory, tagged with the worktree they belong to.

macOS only (it reads `vm_stat`, `sysctl` and `ps`). Needs `jq`.

## Install

```bash
mkdir -p ~/.claude/hooks
curl -fsSL https://raw.githubusercontent.com/sahasrarjn/claude-code-ram-guard/main/ram-guard.sh -o ~/.claude/hooks/ram-guard.sh
chmod +x ~/.claude/hooks/ram-guard.sh
```

Add the hooks to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/ram-guard.sh pre",
            "timeout": 150,
            "statusMessage": "Checking RAM..."
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/ram-guard.sh post",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

Keep the `pre` timeout above `RAM_WAIT_SECS` so the hook can finish waiting.

Optionally, tell agents the rules in `~/.claude/CLAUDE.md`:

```markdown
# RAM

- Every process you start (dev servers, test runs, containers, browsers) is yours to stop. Note its PID and stop it when you are done.
- Never kill a process you did not start.
- Before starting something heavy, run `~/.claude/hooks/ram-guard.sh status`. If RAM is at or above 90%, close your own idle processes first.
```

## Manual use

```bash
~/.claude/hooks/ram-guard.sh status   # used %, swap, top 8 processes
~/.claude/hooks/ram-guard.sh top      # top 10 processes
```

Samples are appended to `~/.claude/ram-log.tsv` (timestamp, used %, swap GB), capped at a few thousand lines.

## How it measures

"Used %" matches Activity Monitor's Memory Used: app memory (anonymous minus purgeable) + wired + compressed, over physical RAM. Memory is **critical** when used % reaches the block threshold, or when swap is nearly full while used % is already high.

## Configuration

Set these as environment variables (for example in the `env` block of `settings.json`):

| Variable | Default | Meaning |
| --- | --- | --- |
| `RAM_WARN_USED_PCT` | 90 | Post-command warning threshold (used %) |
| `RAM_BLOCK_USED_PCT` | 95 | Block heavy commands at this used % |
| `RAM_WAIT_SECS` | 120 | How long `pre` waits for RAM to drop before denying |
| `RAM_WARN_SWAP_GB` | 5 | Warn when swap reaches this many GB |
| `RAM_BLOCK_SWAP_GB` | 7 | Block when swap reaches this many GB... |
| `RAM_SWAP_BLOCK_MIN_USED_PCT` | 85 | ...and used % is at least this |

Which commands count as heavy is the `HEAVY` regex near the top of the script. Commands that only inspect or stop things (`grep`, `cat`, `git`, `kill`, `docker stop`, ...) are never held. Edit the regex to fit your stack.

## License

MIT
