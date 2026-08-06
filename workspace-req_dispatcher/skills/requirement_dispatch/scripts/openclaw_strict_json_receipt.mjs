import fs from "node:fs";
import path from "node:path";

const MAX_REGISTRY_BYTES = 8 * 1024 * 1024;
const MAX_TURN_BYTES = 32 * 1024 * 1024;

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (isPlainObject(value)) {
    return `{${Object.keys(value).sort().map((key) => (
      `${JSON.stringify(key)}:${canonicalJson(value[key])}`
    )).join(",")}}`;
  }
  return JSON.stringify(value);
}

function parseObject(text) {
  try {
    const value = JSON.parse(text.trim());
    return isPlainObject(value) ? value : null;
  } catch {
    return null;
  }
}

export function extractUniqueJsonObject(text) {
  if (typeof text !== "string" || text.length === 0) return null;
  const objects = [];
  const lines = text.split(/\r?\n/);

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("{") || !trimmed.endsWith("}")) continue;
    const value = parseObject(trimmed);
    if (value) objects.push(value);
  }

  let insideFence = false;
  let fenceBody = [];
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith("```")) {
      if (insideFence) {
        const value = parseObject(fenceBody.join("\n"));
        if (value) objects.push(value);
        insideFence = false;
        fenceBody = [];
      } else {
        insideFence = true;
        fenceBody = [];
      }
    } else if (insideFence) {
      fenceBody.push(line);
    }
  }

  const unique = new Map();
  for (const value of objects) unique.set(canonicalJson(value), value);
  return unique.size === 1 ? unique.values().next().value : null;
}

function ownedRegularFile(filePath) {
  const stat = fs.lstatSync(filePath);
  if (!stat.isFile() || stat.isSymbolicLink()) return null;
  if (typeof process.getuid === "function" && stat.uid !== process.getuid()) return null;
  return stat;
}

function resolveSessionsDirectory(stateDir, targetAgent) {
  if (typeof stateDir !== "string" || !path.isAbsolute(stateDir)) return null;
  if (!/^[A-Za-z0-9_-]+$/.test(targetAgent)) return null;

  const stateStat = fs.lstatSync(stateDir);
  if (!stateStat.isDirectory() || stateStat.isSymbolicLink()) return null;
  const stateReal = fs.realpathSync(stateDir);
  const sessionsPath = path.join(stateReal, "agents", targetAgent, "sessions");
  const sessionsStat = fs.lstatSync(sessionsPath);
  if (!sessionsStat.isDirectory() || sessionsStat.isSymbolicLink()) return null;
  const sessionsReal = fs.realpathSync(sessionsPath);
  const relative = path.relative(stateReal, sessionsReal);
  if (relative.startsWith("..") || path.isAbsolute(relative)) return null;
  return sessionsReal;
}

function resolveTranscript(stateDir, targetAgent, sessionKey) {
  const sessionsDir = resolveSessionsDirectory(stateDir, targetAgent);
  if (!sessionsDir) return null;
  const registryPath = path.join(sessionsDir, "sessions.json");
  const registryStat = ownedRegularFile(registryPath);
  if (!registryStat || registryStat.size > MAX_REGISTRY_BYTES) return null;

  const registry = JSON.parse(fs.readFileSync(registryPath, "utf8"));
  if (!isPlainObject(registry) || !isPlainObject(registry[sessionKey])) return {
    sessionsDir,
    sessionId: null,
    transcriptPath: null,
  };

  const entry = registry[sessionKey];
  const sessionId = entry.sessionId;
  if (typeof sessionId !== "string"
      || !/^[A-Za-z0-9._-]{1,128}$/.test(sessionId)
      || sessionId === "." || sessionId === "..") return null;
  const transcriptPath = path.join(sessionsDir, `${sessionId}.jsonl`);
  if (entry.sessionFile !== undefined && entry.sessionFile !== null
      && path.resolve(entry.sessionFile) !== transcriptPath) return null;
  return { sessionsDir, sessionId, transcriptPath };
}

function transcriptEndsWithNewline(filePath, size) {
  if (size === 0) return true;
  const descriptor = fs.openSync(filePath, "r");
  try {
    const byte = Buffer.alloc(1);
    return fs.readSync(descriptor, byte, 0, 1, size - 1) === 1 && byte[0] === 10;
  } finally {
    fs.closeSync(descriptor);
  }
}

export function captureSessionCursor({ stateDir, targetAgent, sessionKey }) {
  try {
    const resolved = resolveTranscript(stateDir, targetAgent, sessionKey);
    if (!resolved) return { usable: false };
    if (!resolved.transcriptPath || !fs.existsSync(resolved.transcriptPath)) {
      return {
        usable: true,
        sessionId: resolved.sessionId,
        offset: 0,
        device: null,
        inode: null,
      };
    }
    const stat = ownedRegularFile(resolved.transcriptPath);
    if (!stat || !transcriptEndsWithNewline(resolved.transcriptPath, stat.size)) {
      return { usable: false };
    }
    return {
      usable: true,
      sessionId: resolved.sessionId,
      offset: stat.size,
      device: String(stat.dev),
      inode: String(stat.ino),
    };
  } catch {
    return { usable: false };
  }
}

function readTranscriptDelta(filePath, offset, expectedDevice, expectedInode) {
  const stat = ownedRegularFile(filePath);
  if (!stat || stat.size < offset || stat.size - offset > MAX_TURN_BYTES) return null;
  if (expectedDevice !== null
      && (String(stat.dev) !== expectedDevice || String(stat.ino) !== expectedInode)) return null;

  const length = stat.size - offset;
  if (length === 0) return "";
  const descriptor = fs.openSync(filePath, "r");
  try {
    const buffer = Buffer.alloc(length);
    const read = fs.readSync(descriptor, buffer, 0, length, offset);
    if (read !== length) return null;
    return buffer.toString("utf8");
  } finally {
    fs.closeSync(descriptor);
  }
}

export function extractLastExecToolJson({
  stateDir,
  targetAgent,
  sessionKey,
  cursor,
}) {
  try {
    if (!cursor || cursor.usable !== true) return null;
    const resolved = resolveTranscript(stateDir, targetAgent, sessionKey);
    if (!resolved?.transcriptPath || !fs.existsSync(resolved.transcriptPath)) return null;
    if (cursor.sessionId !== null && resolved.sessionId !== cursor.sessionId) return null;
    const delta = readTranscriptDelta(
      resolved.transcriptPath,
      cursor.offset,
      cursor.device,
      cursor.inode,
    );
    if (delta === null) return null;

    let last = null;
    for (const line of delta.split("\n")) {
      if (line.trim() === "") continue;
      const entry = JSON.parse(line);
      const message = entry?.type === "message" ? entry.message : null;
      if (message?.role !== "toolResult" || message.toolName !== "exec"
          || message.isError === true || !Array.isArray(message.content)) continue;
      const text = message.content
        .filter((block) => block?.type === "text" && typeof block.text === "string")
        .map((block) => block.text)
        .join("\n");
      const candidate = extractUniqueJsonObject(text);
      if (candidate) last = candidate;
    }
    return last === null ? null : JSON.stringify(last);
  } catch {
    return null;
  }
}

export async function waitForLastExecToolJson(options, attempts = 6, delayMs = 25) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const receipt = extractLastExecToolJson(options);
    if (receipt !== null) return receipt;
    if (attempt + 1 < attempts) {
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
  return null;
}
