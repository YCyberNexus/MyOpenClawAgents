import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  captureSessionCursor,
  extractLastExecToolJson,
  extractUniqueJsonObject,
} from "../scripts/openclaw_strict_json_receipt.mjs";

const TEST_ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "openclaw-strict-receipt-"));
const STATE_DIR = path.join(TEST_ROOT, "state");
const TARGET_AGENT = "req_executor";
const SESSION_KEY = "agent:req_executor:main";
const SESSION_ID = "strict-session-1";
const SESSIONS_DIR = path.join(STATE_DIR, "agents", TARGET_AGENT, "sessions");
const TRANSCRIPT = path.join(SESSIONS_DIR, `${SESSION_ID}.jsonl`);
const TEST_DIR = path.dirname(fileURLToPath(import.meta.url));
const GATEWAY_HELPER = path.resolve(TEST_DIR, "../scripts/openclaw_agent_gateway.mjs");

function transcriptEntry(message) {
  return `${JSON.stringify({ type: "message", message })}\n`;
}

function appendMessage(message) {
  fs.appendFileSync(TRANSCRIPT, transcriptEntry(message));
}

function execResult(text, isError = false) {
  return {
    role: "toolResult",
    toolName: "exec",
    isError,
    content: [{ type: "text", text }],
  };
}

fs.mkdirSync(SESSIONS_DIR, { recursive: true, mode: 0o700 });
fs.writeFileSync(
  path.join(SESSIONS_DIR, "sessions.json"),
  `${JSON.stringify({ [SESSION_KEY]: { sessionId: SESSION_ID } })}\n`,
  { mode: 0o600 },
);
fs.writeFileSync(
  TRANSCRIPT,
  transcriptEntry(execResult('{"status":"stale","value":1}')),
  { mode: 0o600 },
);

assert.deepEqual(
  extractUniqueJsonObject("log\n```json\n{\n  \"status\": \"success\",\n  \"value\": 2\n}\n```"),
  { status: "success", value: 2 },
);
assert.equal(
  extractUniqueJsonObject('{"status":"one"}\n{"status":"two"}'),
  null,
);

const cursor = captureSessionCursor({
  stateDir: STATE_DIR,
  targetAgent: TARGET_AGENT,
  sessionKey: SESSION_KEY,
});
appendMessage({ role: "user", content: [{ type: "text", text: "run" }] });
appendMessage(execResult('{"status":"failed-tool"}', true));
appendMessage(execResult('{"status":"ambiguous"}\n{"status":"other"}'));
appendMessage(execResult('wrapper log\n{"status":"success","value":7}'));
appendMessage({
  role: "assistant",
  content: [{ type: "text", text: "执行成功，已经处理完毕。" }],
});
assert.equal(
  extractLastExecToolJson({
    stateDir: STATE_DIR,
    targetAgent: TARGET_AGENT,
    sessionKey: SESSION_KEY,
    cursor,
  }),
  '{"status":"success","value":7}',
);

const noReceiptCursor = captureSessionCursor({
  stateDir: STATE_DIR,
  targetAgent: TARGET_AGENT,
  sessionKey: SESSION_KEY,
});
appendMessage({ role: "assistant", content: [{ type: "text", text: "only prose" }] });
assert.equal(
  extractLastExecToolJson({
    stateDir: STATE_DIR,
    targetAgent: TARGET_AGENT,
    sessionKey: SESSION_KEY,
    cursor: noReceiptCursor,
  }),
  null,
);

const PACKAGE_ROOT = path.join(TEST_ROOT, "fake-openclaw");
const BIN_DIR = path.join(PACKAGE_ROOT, "bin");
const DIST_DIR = path.join(PACKAGE_ROOT, "dist");
const OPENCLAW_BIN = path.join(BIN_DIR, "openclaw");
fs.mkdirSync(BIN_DIR, { recursive: true, mode: 0o700 });
fs.mkdirSync(DIST_DIR, { recursive: true, mode: 0o700 });
fs.writeFileSync(
  path.join(PACKAGE_ROOT, "package.json"),
  '{"name":"openclaw","type":"module"}\n',
  { mode: 0o600 },
);
fs.writeFileSync(OPENCLAW_BIN, "#!/usr/bin/env bash\nexit 0\n", { mode: 0o700 });
fs.writeFileSync(
  path.join(DIST_DIR, "call-fake.js"),
  `import fs from "node:fs";
export async function callGateway() {
  const appendTurn = () => {
    if (process.env.FAKE_SKIP_RECEIPT !== "1") {
      const tool = {type:"message",message:{role:"toolResult",toolName:"exec",isError:false,content:[{type:"text",text:"wrapper output\\n{\\"status\\":\\"success\\",\\"receipt_id\\":\\"r-1\\"}"}]}};
      fs.appendFileSync(process.env.FAKE_TRANSCRIPT, JSON.stringify(tool) + "\\n");
    }
    const assistant = {type:"message",message:{role:"assistant",content:[{type:"text",text:"已完成，但这是模型散文。"}]}};
    fs.appendFileSync(process.env.FAKE_TRANSCRIPT, JSON.stringify(assistant) + "\\n");
  };
  if (process.env.FAKE_DELAY_RECEIPT === "1") setTimeout(appendTurn, 50);
  else appendTurn();
  return {result:{payloads:[{text:"已完成，但这是模型散文。"}]}};
}
`,
  { mode: 0o600 },
);

function runGateway(strict, skipReceipt = false, delayReceipt = false) {
  return spawnSync(process.execPath, [GATEWAY_HELPER], {
    input: JSON.stringify({
      message: "structured request",
      openclaw_bin_path: OPENCLAW_BIN,
      openclaw_state_dir: STATE_DIR,
      run_id: `strict-${strict}-${skipReceipt}`,
      session_key: SESSION_KEY,
      strict_json_receipt: strict,
      target_agent: TARGET_AGENT,
      timeout_seconds: 30,
    }),
    encoding: "utf8",
    timeout: 5_000,
    env: {
      ...process.env,
      FAKE_TRANSCRIPT: TRANSCRIPT,
      FAKE_SKIP_RECEIPT: skipReceipt ? "1" : "0",
      FAKE_DELAY_RECEIPT: delayReceipt ? "1" : "0",
    },
  });
}

const strictResult = runGateway(true);
assert.equal(strictResult.status, 0, strictResult.stderr);
assert.equal(strictResult.stdout, '{"status":"success","receipt_id":"r-1"}');
assert.equal(strictResult.stdout.includes("已完成"), false);

const delayedResult = runGateway(true, false, true);
assert.equal(delayedResult.status, 0, delayedResult.stderr);
assert.equal(delayedResult.stdout, '{"status":"success","receipt_id":"r-1"}');

const missingResult = runGateway(true, true);
assert.equal(missingResult.status, 70);
assert.equal(missingResult.stdout, "");
assert.match(missingResult.stderr, /strict JSON receipt was not emitted/);

const proseResult = runGateway(false, true);
assert.equal(proseResult.status, 0, proseResult.stderr);
assert.equal(proseResult.stdout, "已完成，但这是模型散文。");

process.stdout.write("ok strict JSON receipt is extracted from the current exec transcript delta\n");
