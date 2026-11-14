// pi extension: runs the shared ram-guard.sh with Claude Code style hook payloads and maps the results onto pi events.
import { spawn } from "node:child_process";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "plugins", "ram-guard", "scripts", "ram-guard.sh");

function runGuard(mode: string, payload: object): Promise<any> {
  return new Promise((resolve) => {
    const child = spawn(SCRIPT, [mode], { stdio: ["pipe", "pipe", "ignore"] });
    let out = "";
    child.stdout.on("data", (d) => (out += d));
    child.on("error", () => resolve(undefined)); // never block the agent because the guard itself broke
    child.on("close", () => {
      try {
        resolve(out.trim() ? JSON.parse(out) : undefined);
      } catch {
        resolve(undefined);
      }
    });
    child.stdin.end(JSON.stringify(payload));
  });
}

export default function (pi: ExtensionAPI) {
  let sessionId = `pi-${process.pid}-${Date.now()}`;
  let rules: string | undefined;

  pi.on("session_start", async () => {
    rules = (await runGuard("session", {}))?.hookSpecificOutput?.additionalContext;
  });

  pi.on("before_agent_start", async (event) => {
    if (!rules) return;
    return { systemPrompt: `${event.systemPrompt}\n\n${rules}\n` };
  });

  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;
    const res = await runGuard("pre", { session_id: sessionId, tool_input: { command: event.input.command } });
    const out = res?.hookSpecificOutput;
    if (out?.permissionDecision === "deny") return { block: true, reason: out.permissionDecisionReason };
  });

  pi.on("tool_result", async (event) => {
    if (event.toolName !== "bash") return;
    const warning = (await runGuard("post", { session_id: sessionId, tool_input: event.input }))?.hookSpecificOutput?.additionalContext;
    if (!warning) return;
    return { content: [...event.content, { type: "text", text: `\n\n${warning}` }] };
  });
}
