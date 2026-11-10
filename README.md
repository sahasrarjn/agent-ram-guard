# agent-ram-guard

A hook for [Claude Code](https://docs.claude.com/en/docs/claude-code) and [Codex](https://github.com/openai/codex) that keeps parallel coding agents from running a Mac out of memory.

When several agents share one machine, each one starts its own dev server, test run or container, and nobody stops them. RAM fills up, swap grows, and everything slows down. This hook makes the agents notice:

- **Before** a memory-heavy shell command (`pytest`, `next dev`, `docker compose up`, `tsc`, `uvicorn`, ...), it checks RAM. If memory is critical it waits up to 2 minutes for it to drop, then denies the command and tells the agent to stop the processes it started itself.
- **After** any shell command (at most once every 5 minutes per session), it logs a sample and, if RAM or swap is high, warns the agent with the top processes by memory, tagged with the git worktree they belong to.

Claude Code and Codex use the same hook input and output format, so one script serves both.

macOS only (it reads `vm_stat`, `sysctl` and `ps`). Needs `jq`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/sahasrarjn/agent-ram-guard/main/install.sh | bash
```

The installer copies `ram-guard.sh` to `~/.local/bin/` and registers the hooks for each tool it finds:

- **Claude Code** (`~/.claude` exists): adds `PreToolUse` and `PostToolUse` Bash hooks to `~/.claude/settings.json`.
- **Codex** (`~/.codex` exists): appends the same hooks to `~/.codex/config.toml`. Then open `codex` and run `/hooks` to review and trust them, because Codex skips hooks you haven't trusted.

It backs up each file it changes (`*.bak-ram-guard`) and does nothing to a tool that's already configured, so re-running is safe.

### Manual setup

Claude Code, in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/.local/bin/ram-guard.sh pre", "timeout": 150, "statusMessage": "Checking RAM..." }] }
    ],
    "PostToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/.local/bin/ram-guard.sh post", "timeout": 10 }] }
    ]
  }
}
```

Codex, in `~/.codex/config.toml` (use the absolute path), then `/hooks` in Codex to trust:

```toml
[[hooks.PreToolUse]]
matcher = "Bash"
[[hooks.PreToolUse.hooks]]
type = "command"
command = "/Users/<you>/.local/bin/ram-guard.sh pre"
timeout = 150
statusMessage = "Checking RAM..."

[[hooks.PostToolUse]]
matcher = "Bash"
[[hooks.PostToolUse.hooks]]
type = "command"
command = "/Users/<you>/.local/bin/ram-guard.sh post"
timeout = 10
```

Keep the `pre` timeout above `RAM_WAIT_SECS` so the hook can finish waiting.

### Tell the agents the rules (optional)

Add to `~/.claude/CLAUDE.md` and/or `~/.codex/AGENTS.md`:

```markdown
# RAM

- Every process you start (dev servers, test runs, containers, browsers) is yours to stop. Note its PID and stop it when you are done.
- Never kill a process you did not start.
- Before starting something heavy, run `~/.local/bin/ram-guard.sh status`. If RAM is at or above 90%, close your own idle processes first.
```

## Manual use

```bash
~/.local/bin/ram-guard.sh status   # used %, swap, top 8 processes
~/.local/bin/ram-guard.sh top      # top 10 processes
```

Samples (timestamp, used %, swap GB) are appended to `~/.local/state/ram-guard/ram-log.tsv`, capped at a few thousand lines.

## How it measures

"Used %" matches Activity Monitor's Memory Used: app memory (anonymous minus purgeable) + wired + compressed, over physical RAM. Memory is **critical** when used % reaches the block threshold, or when swap is nearly full while used % is already high.

## Configuration

Set these as environment variables (for Claude Code, the `env` block of `settings.json` works):

| Variable | Default | Meaning |
| --- | --- | --- |
| `RAM_WARN_USED_PCT` | 90 | Post-command warning threshold (used %) |
| `RAM_BLOCK_USED_PCT` | 95 | Block heavy commands at this used % |
| `RAM_WAIT_SECS` | 120 | How long `pre` waits for RAM to drop before denying |
| `RAM_WARN_SWAP_GB` | 5 | Warn when swap reaches this many GB |
| `RAM_BLOCK_SWAP_GB` | 7 | Block when swap reaches this many GB... |
| `RAM_SWAP_BLOCK_MIN_USED_PCT` | 85 | ...and used % is at least this |
| `RAM_GUARD_LOG` | `~/.local/state/ram-guard/ram-log.tsv` | Where samples are logged |

Which commands count as heavy is the `HEAVY` regex near the top of the script. Commands that only inspect or stop things (`grep`, `cat`, `git`, `kill`, `docker stop`, ...) are never held. Edit the regex to fit your stack.

## Uninstall

Remove the `ram-guard.sh` entries from `~/.claude/settings.json` and `~/.codex/config.toml`, then `rm ~/.local/bin/ram-guard.sh`.

## License

MIT
