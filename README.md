# agent-ram-guard

A hook for coding agents ([Claude Code](https://docs.claude.com/en/docs/claude-code), [Codex](https://github.com/openai/codex), [Cursor](https://cursor.com), [Antigravity](https://antigravity.google), [Gemini CLI](https://geminicli.com) and [pi](https://pi.dev)) that keeps parallel agents from running a Mac out of memory.

When several agents share one machine, each one starts its own dev server, test run or container, and nobody stops them. RAM fills up, swap grows, and everything slows down. This hook makes the agents notice:

- **Before** a memory-heavy shell command (`pytest`, `next dev`, `docker compose up`, `tsc`, `uvicorn`, ...), it checks RAM. If memory is critical it waits up to 2 minutes for it to drop, then denies the command and tells the agent to stop the processes it started itself.
- **After** any shell command (at most once every 5 minutes per session), it logs a sample and, if RAM or swap is high, warns the agent with the top processes by memory, tagged with the git worktree they belong to.

One shell script does the work for every tool; each tool gets a thin hook config that tells the script which output format to speak. macOS only (it reads `vm_stat`, `sysctl` and `ps`). Needs `jq`.

| Tool | Install | Blocks heavy commands | Warns after commands | RAM rules at session start |
| --- | --- | --- | --- | --- |
| Claude Code | plugin | yes | yes | yes |
| Codex | plugin | yes | yes | yes |
| pi | `pi install` | yes | yes (appended to the bash result) | yes (system prompt) |
| Gemini CLI | extension | yes | yes | yes |
| Cursor | `install.sh` | yes (`beforeShellExecution`) | yes (`postToolUse`) | yes |
| Antigravity (app, IDE, CLI) | `install.sh` | yes (`run_command`) | yes, before the next model call | yes |

## Install as a plugin

One plugin works in both tools. It registers the hooks and, at the start of each session, gives the agent the RAM rules below, so there is nothing to add to `CLAUDE.md` or `AGENTS.md`.

Claude Code:

```bash
claude plugin marketplace add sahasrarjn/agent-ram-guard
claude plugin install ram-guard@agent-ram-guard
```

Codex:

```bash
codex plugin marketplace add sahasrarjn/agent-ram-guard
codex plugin add ram-guard@agent-ram-guard
```

pi:

```bash
pi install git:github.com/sahasrarjn/agent-ram-guard
```

Gemini CLI:

```bash
gemini extensions install https://github.com/sahasrarjn/agent-ram-guard
```

Cursor and Antigravity have no plugin install from a repo yet, so use the installer below. It finds them on its own.

Then:

- Restart open Claude Code sessions; new ones pick the plugin up.
- **Codex skips plugin hooks until you trust them.** Start `codex`, and pick "Trust all and continue" when it says the hooks need review (or run `/hooks`). Nobody can do this step for you.
- If you set ram-guard up earlier with `install.sh` or by hand, remove those hook entries (see Uninstall), or every command is checked twice.

To update later: `claude plugin marketplace update agent-ram-guard`, or `codex plugin marketplace upgrade agent-ram-guard`. Codex asks you to trust the hooks again when they change.

The RAM rules each session gets:

```markdown
- Every process you start (dev servers, test runs, containers, browsers) is yours to stop. Note its PID and stop it when you are done.
- Never kill a process you did not start.
- Before starting something heavy, run `ram-guard.sh status`. If RAM is at or above 90%, close your own idle processes first.
```

## Install without the plugin

`install.sh` copies the script to `~/.local/bin/` and adds the hooks to your global config instead. Use it if you would rather not use plugins.

```bash
curl -fsSL https://raw.githubusercontent.com/sahasrarjn/agent-ram-guard/main/install.sh | bash
```

It registers the hooks for each tool it finds: Claude Code (`~/.claude/settings.json`), Codex (`~/.codex/config.toml`), Cursor (`~/.cursor/hooks.json`) and Antigravity (`~/.gemini/config/hooks.json`, shared by the app, IDE and CLI). It backs up each file it changes (`*.bak-ram-guard`) and leaves a tool alone if it already references `ram-guard.sh`, so re-running is safe. Cursor and Antigravity get the RAM rules from a session-start hook. For Claude Code and Codex the installer does not add them: copy them into `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` under a `# RAM` heading, with the path `~/.local/bin/ram-guard.sh`.

If Cursor is set to load third-party (Claude Code) hooks, it would also run the Claude Code entries; in that case keep only one of them.

### Manual setup

Claude Code, in `~/.claude/settings.json` (merge into any existing `hooks` block):

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

Codex, in `~/.codex/config.toml`, with the absolute path to the script, then trust them with `/hooks`:

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

Cursor, in `~/.cursor/hooks.json`:

```json
{
  "version": 1,
  "hooks": {
    "sessionStart": [{ "command": "~/.local/bin/ram-guard.sh session cursor", "timeout": 10 }],
    "beforeShellExecution": [{ "command": "~/.local/bin/ram-guard.sh pre cursor", "timeout": 150 }],
    "postToolUse": [{ "matcher": "Shell", "command": "~/.local/bin/ram-guard.sh post cursor", "timeout": 10 }]
  }
}
```

Antigravity, in `~/.gemini/config/hooks.json` (its `PostToolUse` hooks cannot talk to the agent, so the warning runs on `PreInvocation`, throttled the same way):

```json
{
  "ram-guard": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "/Users/<you>/.local/bin/ram-guard.sh session antigravity", "timeout": 10 }] }],
    "PreToolUse": [{ "matcher": "run_command", "hooks": [{ "type": "command", "command": "/Users/<you>/.local/bin/ram-guard.sh pre antigravity", "timeout": 150 }] }],
    "PreInvocation": [{ "hooks": [{ "type": "command", "command": "/Users/<you>/.local/bin/ram-guard.sh post antigravity", "timeout": 10 }] }]
  }
}
```

Any other tool with command hooks: call `ram-guard.sh pre|post|session <format>`, where format is `claude` (default, also Codex), `cursor`, `gemini` or `antigravity`. The script reads the command from `tool_input.command`, `command` or `toolCall.args.CommandLine`.

In every tool, keep the `pre` timeout above `RAM_WAIT_SECS` so the hook can finish waiting.

## Manual use

```bash
ram-guard.sh status   # used %, swap, top 8 processes
ram-guard.sh top      # top 10 processes
```

With the plugin, the script lives in the tool's plugin cache; ask the agent for the path, since its RAM rules name it. With `install.sh`, it is `~/.local/bin/ram-guard.sh`.

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

Which commands count as heavy is the `HEAVY` regex near the top of `plugins/ram-guard/scripts/ram-guard.sh`. Commands that only inspect or stop things (`grep`, `cat`, `git`, `kill`, `docker stop`, ...) are never held. Edit the regex to fit your stack.

## Uninstall

Plugin: `claude plugin uninstall ram-guard@agent-ram-guard`, `codex plugin remove ram-guard@agent-ram-guard`, `pi remove git:github.com/sahasrarjn/agent-ram-guard`, `gemini extensions uninstall agent-ram-guard`.

`install.sh` or manual setup: remove the `ram-guard.sh` entries from `~/.claude/settings.json`, `~/.codex/config.toml` and `~/.cursor/hooks.json`, the `ram-guard` key from `~/.gemini/config/hooks.json`, delete the `# RAM` section from `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`, then `rm ~/.local/bin/ram-guard.sh`.

## License

MIT
