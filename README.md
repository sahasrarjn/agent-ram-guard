# agent-ram-guard

Keeps parallel coding agents from running a Mac out of memory. Works with [Claude Code](https://docs.claude.com/en/docs/claude-code), [Codex](https://github.com/openai/codex), [Cursor](https://cursor.com), [Antigravity](https://antigravity.google), [pi](https://pi.dev) and [Gemini CLI](https://geminicli.com).

When several agents share one machine, each one starts its own dev server, test run or container, and nobody stops them. RAM fills up, swap grows, and everything slows down. ram-guard hooks into each agent's shell commands so the agents notice:

- **Session start:** the agent gets three RAM rules. It must stop every process it starts, never kill a process it did not start, and check RAM before starting anything heavy.
- **Before** a memory-heavy shell command (`pytest`, `next dev`, `docker compose up`, `tsc`, `uvicorn`, ...): if RAM is critical (95% used by default), it waits up to 2 minutes for it to drop, then denies the command. The denial tells the agent to stop the processes it started itself.
- **After** a shell command (at most once every 5 minutes per session): it logs a sample and, if RAM is at or above 90% or swap is high, warns the agent with the top processes by memory, tagged with the git worktree each belongs to.

One shell script does the work for every tool. Each tool gets a small hook config that tells the script which output format to use. Requires macOS (it reads `vm_stat`, `sysctl` and `ps`) and `jq` (`brew install jq`).

## Install

| Tool | Install with | Blocks heavy commands | Warns | RAM rules |
| --- | --- | --- | --- | --- |
| Claude Code | plugin | yes | after the command | session start |
| Codex | plugin | yes | after the command | session start |
| Cursor | `install.sh` | yes | after the command | session start |
| Antigravity (app, IDE, CLI) | `install.sh` | yes | before the next model call | session start |
| pi | `pi install` | yes | appended to the bash result | system prompt |
| Gemini CLI | extension | yes | after the command | session start |

### Claude Code and Codex: plugin

```bash
claude plugin marketplace add sahasrarjn/agent-ram-guard
claude plugin install ram-guard@agent-ram-guard

codex plugin marketplace add sahasrarjn/agent-ram-guard
codex plugin add ram-guard@agent-ram-guard
```

- Restart open sessions; new ones pick the plugin up.
- **Codex skips plugin hooks until you trust them.** Start `codex` and pick "Trust all and continue" when it says the hooks need review (or run `/hooks`). Nobody can do this step for you.
- Update later with `claude plugin marketplace update agent-ram-guard` or `codex plugin marketplace upgrade agent-ram-guard`. Codex asks you to trust the hooks again when they change.

### Cursor and Antigravity: installer

Neither can install hooks from a repo yet, so the installer writes them into your global config:

```bash
curl -fsSL https://raw.githubusercontent.com/sahasrarjn/agent-ram-guard/main/install.sh | bash -s -- cursor antigravity
```

Name the tools you want, or leave the list empty (`| bash`) to set up every tool it finds (Claude Code, Codex, Cursor, Antigravity). If you already use the Claude Code or Codex plugin, name only `cursor antigravity`, or every command is checked twice.

The installer copies the script to `~/.local/bin/ram-guard.sh` and registers the hooks in:

| Tool | File |
| --- | --- |
| Claude Code | `~/.claude/settings.json` |
| Codex | `~/.codex/config.toml` (then trust them with `/hooks`) |
| Cursor | `~/.cursor/hooks.json` (restart Cursor) |
| Antigravity | `~/.gemini/config/hooks.json`, shared by the app, IDE and CLI |

It backs up each file it changes (`*.bak-ram-guard`) and skips a tool that already references `ram-guard.sh`, so you can re-run it safely. Re-run it to update the script.

If Cursor is set to load third-party (Claude Code) hooks, it also runs your Claude Code entries, so keep only one of the two.

### pi

```bash
pi install git:github.com/sahasrarjn/agent-ram-guard
```

The extension runs the same script: it blocks heavy `bash` calls, appends the warning to the bash result and adds the RAM rules to the system prompt.

### Gemini CLI

```bash
gemini extensions install https://github.com/sahasrarjn/agent-ram-guard
```

Google moved free-tier Gemini CLI users to Antigravity in June 2026; this is for accounts that still run it.

### The RAM rules

Every install method gives the agent these rules at the start of a session (with the real script path), so there is nothing to add to `CLAUDE.md`, `AGENTS.md` or `GEMINI.md`:

```markdown
- Every process you start (dev servers, test runs, containers, browsers) is yours to stop. Note its PID and stop it when you are done.
- Never kill a process you did not start.
- Before starting something heavy, run `ram-guard.sh status`. If RAM is at or above 90%, close your own idle processes first.
```

## Manual setup

To edit config files yourself, print the exact hooks for a tool and merge them in:

```bash
ram-guard.sh config claude    # also: codex (TOML), cursor, gemini, antigravity
```

Pass the script path as a second argument if it is not where the command runs from, e.g. `ram-guard.sh config codex ~/.local/bin/ram-guard.sh`. Codex needs an absolute path. This is the same output the installer merges and the plugin's hook files are generated from.

A few details worth knowing:

- Keep the `pre` hook's timeout above `RAM_WAIT_SECS` so it can finish waiting. The generated configs use `RAM_WAIT_SECS + 30`.
- Antigravity's `PostToolUse` hooks cannot talk to the agent, so the warning runs on `PreInvocation` instead.
- Antigravity blocks the tool call when a `PreToolUse` hook fails, so make sure `jq` is installed.

For any other tool with command hooks, call `ram-guard.sh pre|post|session <format>`, where format is `claude` (default, also Codex), `cursor`, `gemini` or `antigravity`. The script reads the command from `tool_input.command`, `command` or `toolCall.args.CommandLine`.

## Manual use

```bash
ram-guard.sh status   # used %, swap, top 8 processes
ram-guard.sh top      # top 10 processes
ram-guard.sh rules    # the RAM rules agents get at session start
```

With the plugin, the script lives in the tool's plugin cache; ask the agent for the path, since its RAM rules name it. With `install.sh`, it is `~/.local/bin/ram-guard.sh`.

Samples (timestamp, used %, swap GB) are appended to `~/.local/state/ram-guard/ram-log.tsv`, capped at a few thousand lines.

## How it measures

"Used %" matches Activity Monitor's Memory Used: app memory (anonymous minus purgeable) + wired + compressed, over physical RAM. Memory is **critical** when used % reaches the block threshold, or when swap is nearly full while used % is already high.

## Configuration

Set these as environment variables in the environment your agent runs in (for Claude Code, the `env` block of `settings.json` works):

| Variable | Default | Meaning |
| --- | --- | --- |
| `RAM_WARN_USED_PCT` | 90 | Post-command warning threshold (used %) |
| `RAM_BLOCK_USED_PCT` | 95 | Block heavy commands at this used % |
| `RAM_WAIT_SECS` | 120 | How long `pre` waits for RAM to drop before denying |
| `RAM_WARN_SWAP_GB` | 5 | Warn when swap reaches this many GB |
| `RAM_BLOCK_SWAP_GB` | 7 | Block when swap reaches this many GB... |
| `RAM_SWAP_BLOCK_MIN_USED_PCT` | 85 | ...and used % is at least this |
| `RAM_GUARD_LOG` | `~/.local/state/ram-guard/ram-log.tsv` | Where samples are logged |
| `RAM_GUARD_HEAVY_EXTRA` | (none) | Extra heavy-command patterns |
| `RAM_GUARD_HEAVY` | (built-in list) | Replaces the heavy-command patterns |

### Which commands are heavy

The default list covers the common dev, test, build and serve commands across ecosystems: JavaScript package managers and tools (`npm test`, `pnpm dev`, `next`, `vite`, `jest`, `playwright`, `turbo`, `nx`, `webpack`, `tsc`), Python (`pytest`, `uvicorn`, `gunicorn`, `jupyter`, scripts named like `train*.py`, `torchrun`), containers (`docker compose up`, `docker build`), Go, Rust, JVM (`mvn`, `gradle`, `./gradlew`), .NET, Swift/Xcode, Bazel, Flutter, Ruby, PHP, Elixir, `make` and local LLM servers (`ollama`, `vllm`). The exact patterns are `DEFAULT_HEAVY` at the top of `ram-guard.sh`.

It cannot know your own commands. Add them with a regex (extended syntax, matched where a word starts):

```bash
export RAM_GUARD_HEAVY_EXTRA='python .*etl\.py|my-server|bin/worker'
```

or replace the whole list with `RAM_GUARD_HEAVY`. Commands that only inspect or stop things (`ls`, `cat`, `grep`, `git`, `kill`, `docker ps`, ...) and anything run with `--version` or `--help` are never held.

Only the hold-and-deny step depends on this list. The session rules and the post-command warning apply to every shell command.

## Uninstall

Plugin: `claude plugin uninstall ram-guard@agent-ram-guard`, `codex plugin remove ram-guard@agent-ram-guard`, `pi remove git:github.com/sahasrarjn/agent-ram-guard`, `gemini extensions uninstall agent-ram-guard`.

`install.sh` or manual setup: remove the `ram-guard.sh` entries from `~/.claude/settings.json`, `~/.codex/config.toml` and `~/.cursor/hooks.json`, and the `ram-guard` key from `~/.gemini/config/hooks.json`, then `rm ~/.local/bin/ram-guard.sh`. Older versions of these instructions had you paste the RAM rules into `~/.claude/CLAUDE.md` or `~/.codex/AGENTS.md`; delete that `# RAM` section too.

## Development

- `plugins/ram-guard/scripts/ram-guard.sh` is the only place behavior and hook configs are defined.
- `package.json` holds the name, version and description. `make sync` copies them into the other manifests and regenerates the plugin and Gemini hook files from `ram-guard.sh config`. Do not edit those generated files by hand.
- `make lint` runs shellcheck, `make test` runs `tests/test.sh` (heavy-command cases, every hook format, configs, the installer in a temporary home), and `make check` fails if generated files are stale. CI runs all three on macOS.

## License

MIT
