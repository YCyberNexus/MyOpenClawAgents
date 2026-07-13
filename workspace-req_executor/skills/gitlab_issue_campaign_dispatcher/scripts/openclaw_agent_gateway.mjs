import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

function fail(message, code = 1) { process.stderr.write(`openclaw_agent_gateway: ${message}\n`); process.exit(code); }
async function readStdin() { const chunks = []; for await (const chunk of process.stdin) chunks.push(chunk); return Buffer.concat(chunks).toString("utf8"); }
function findPackageRoot(binPath) {
  let current;
  try { current = fs.realpathSync(binPath); } catch { fail("unable to resolve the OpenClaw executable", 68); }
  current = path.dirname(current);
  for (let i = 0; i < 8; i += 1) {
    const manifest = path.join(current, "package.json");
    if (fs.existsSync(manifest)) {
      try { if (JSON.parse(fs.readFileSync(manifest, "utf8")).name === "openclaw") return current; }
      catch { fail("invalid OpenClaw package manifest", 68); }
    }
    const parent = path.dirname(current); if (parent === current) break; current = parent;
  }
  fail("unable to locate the installed OpenClaw package", 68);
}
async function loadCallGateway(packageRoot) {
  const dist = path.join(packageRoot, "dist");
  let candidates;
  try { candidates = fs.readdirSync(dist).filter((name) => /^call-.*\.js$/.test(name)).sort(); }
  catch { fail("unable to inspect the installed OpenClaw runtime", 68); }
  for (const name of candidates) {
    const file = path.join(dist, name); const source = fs.readFileSync(file, "utf8");
    if (!source.includes("function callGateway(")) continue;
    const alias = source.match(/callGateway as ([A-Za-z_$][A-Za-z0-9_$]*)/)?.[1]
      ?? (source.match(/export\s*\{[^}]*\b(callGateway)\b[^}]*\}/s)?.[1]);
    const namespace = await import(pathToFileURL(file).href);
    if (alias && typeof namespace[alias] === "function") return namespace[alias];
    for (const value of Object.values(namespace)) if (typeof value === "function" && value.name === "callGateway") return value;
  }
  fail("installed OpenClaw runtime does not expose the Gateway caller", 68);
}
let request;
try { request = JSON.parse(await readStdin()); } catch { fail("request must be one JSON object", 64); }
const expectedKeys = ["message", "openclaw_bin_path", "run_id", "session_key", "target_agent", "timeout_seconds"];
if (!request || typeof request !== "object" || Array.isArray(request) || JSON.stringify(Object.keys(request).sort()) !== JSON.stringify(expectedKeys)) fail("request has an invalid shape", 64);
for (const key of ["message", "openclaw_bin_path", "run_id", "session_key", "target_agent"]) if (typeof request[key] !== "string" || request[key].length === 0) fail(`request field ${key} is invalid`, 64);
if (!Number.isSafeInteger(request.timeout_seconds) || request.timeout_seconds <= 0) fail("request timeout is invalid", 64);
if (!request.session_key.startsWith(`agent:${request.target_agent}:`)) fail("session key does not belong to target agent", 65);
const callGateway = await loadCallGateway(findPackageRoot(request.openclaw_bin_path));
let response;
try {
  response = await callGateway({method:"agent",params:{message:request.message,agentId:request.target_agent,sessionKey:request.session_key,timeout:request.timeout_seconds,idempotencyKey:request.run_id},expectFinal:true,timeoutMs:Math.max(10000,(request.timeout_seconds+30)*1000),clientName:"cli",mode:"cli"});
} catch (error) {
  const kind = error && typeof error === "object" && error.constructor?.name ? error.constructor.name : "GatewayError";
  fail(`local Gateway request failed (${kind})`, 69);
}
const payloads = response?.result?.payloads;
if (Array.isArray(payloads) && payloads.length > 0) {
  const lines = [];
  for (const payload of payloads) {
    if (typeof payload?.text === "string" && payload.text.length > 0) lines.push(payload.text.trimEnd());
    const media = Array.isArray(payload?.mediaUrls) ? payload.mediaUrls : (typeof payload?.mediaUrl === "string" ? [payload.mediaUrl] : []);
    for (const item of media) lines.push(`MEDIA:${item}`);
  }
  process.stdout.write(lines.join("\n"));
} else if (typeof response?.summary === "string") process.stdout.write(response.summary);
