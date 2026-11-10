#!/usr/bin/env node
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const event = process.argv[2] || "";
let raw = "";
for await (const chunk of process.stdin) raw += chunk;
let input = {};
try {
  input = JSON.parse(raw || "{}");
} catch {
  input = {};
}

const sessionId = String(input.session_id || "unknown");
const key = createHash("sha256").update(sessionId).digest("hex");
const stateDir = join(process.env.KIMI_CODE_HOME || join(homedir(), ".kimi-code"), "tessaridb-agent-memory");
const pendingPath = join(stateDir, `${key}.json`);

function save(context) {
  mkdirSync(stateDir, { recursive: true, mode: 0o700 });
  chmodSync(stateDir, 0o700);
  writeFileSync(pendingPath, JSON.stringify({ context }), { mode: 0o600 });
  chmodSync(pendingPath, 0o600);
}

function saveNotice(reason) {
  save(`TessariDB Agent Memory: ${reason}\nCall \`status\` with width \`me\` when the memory is reachable. Call \`session_start\` only when a refusal says the connection has no session.`);
}

if (event === "PostCompact") {
  const token = process.env.TESSARI_AM_TOKEN;
  if (!token) {
    saveNotice("the recovery status was not requested because TESSARI_AM_TOKEN is not set. Set it before starting Kimi to enable automatic recovery.");
    process.exit(0);
  }

  const endpoint = (process.env.TESSARI_AM_ENDPOINT || "http://127.0.0.1:39142").replace(/\/$/, "").replace(/\/mcp$/, "");
  const headers = {
    "content-type": "application/json",
    authorization: `Bearer ${token}`,
  };
  if (process.env.TESSARI_AM_SESSION) headers["x-tessari-session"] = process.env.TESSARI_AM_SESSION;

  try {
    const response = await fetch(`${endpoint}/v1/calls`, {
      method: "POST",
      headers,
      body: JSON.stringify({ method: "status", input: { width: "me" } }),
      signal: AbortSignal.timeout(2000),
    });
    if (!response.ok) {
      saveNotice(`the recovery status request returned HTTP ${response.status}.`);
      process.exit(0);
    }
    const status = await response.json();
    save(`TessariDB Agent Memory — status (width=me)\n\n${JSON.stringify(status, null, 2)}\n\nContinue the same memory session. Call \`session_start\` only when a refusal says the connection has no session.`);
  } catch {
    saveNotice("the recovery status request could not reach the memory service.");
  }
  process.exit(0);
}

if (event === "UserPromptSubmit") {
  if (!existsSync(pendingPath)) process.exit(0);
  try {
    const pending = JSON.parse(readFileSync(pendingPath, "utf8"));
    unlinkSync(pendingPath);
    if (pending.context) process.stdout.write(pending.context);
  } catch {
    process.stdout.write("TessariDB Agent Memory: the saved recovery status could not be read. Call `status` with width `me`.");
  }
  process.exit(0);
}
