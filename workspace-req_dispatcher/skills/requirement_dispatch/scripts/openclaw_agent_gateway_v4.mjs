#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { pathToFileURL } from "node:url";

const PROTOCOL_VERSION = 4;
const CLIENT_ID = "cli";
const CLIENT_MODE = "cli";
const CLIENT_VERSION = "2026.6.1";
const CLIENT_DISPLAY_NAME = "req-dispatcher-reply-adapter";
const ROLE = "operator";
const SCOPES = ["operator.write"];
const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
const ED25519_PKCS8_PRIVATE_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");

export class GatewayV4Error extends Error {
  constructor(message, exitCode = 69) {
    super(message);
    this.name = "GatewayV4Error";
    this.exitCode = exitCode;
  }
}

function fail(message, exitCode = 69) {
  throw new GatewayV4Error(message, exitCode);
}

function base64UrlDecode(value) {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  return Buffer.from(normalized + "=".repeat((4 - (normalized.length % 4)) % 4), "base64");
}

function pemEncode(label, der) {
  const body = der.toString("base64").match(/.{1,64}/g)?.join("\n") ?? "";
  return `-----BEGIN ${label}-----\n${body}\n-----END ${label}-----\n`;
}

function rawPublicKey(publicKeyPem) {
  const der = crypto.createPublicKey(publicKeyPem).export({ type: "spki", format: "der" });
  if (der.length !== ED25519_SPKI_PREFIX.length + 32
      || !der.subarray(0, ED25519_SPKI_PREFIX.length).equals(ED25519_SPKI_PREFIX)) {
    fail("OpenClaw device identity does not contain an Ed25519 public key", 68);
  }
  return der.subarray(ED25519_SPKI_PREFIX.length);
}

function normalizeIdentity(parsed) {
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  if (parsed.version === 1
      && typeof parsed.deviceId === "string"
      && typeof parsed.publicKeyPem === "string"
      && typeof parsed.privateKeyPem === "string") {
    return {
      deviceId: parsed.deviceId,
      publicKeyPem: parsed.publicKeyPem,
      privateKeyPem: parsed.privateKeyPem,
    };
  }
  if (!("version" in parsed)
      && typeof parsed.deviceId === "string"
      && typeof parsed.publicKey === "string"
      && typeof parsed.privateKey === "string") {
    const publicKey = base64UrlDecode(parsed.publicKey);
    const privateKey = base64UrlDecode(parsed.privateKey);
    if (publicKey.length !== 32 || privateKey.length !== 32) return null;
    return {
      deviceId: parsed.deviceId,
      publicKeyPem: pemEncode("PUBLIC KEY", Buffer.concat([ED25519_SPKI_PREFIX, publicKey])),
      privateKeyPem: pemEncode("PRIVATE KEY", Buffer.concat([ED25519_PKCS8_PRIVATE_PREFIX, privateKey])),
    };
  }
  return null;
}

export function loadOpenClawDeviceIdentity(stateDir) {
  if (typeof stateDir !== "string" || !path.isAbsolute(stateDir)) {
    fail("OpenClaw state directory must be an absolute path", 64);
  }
  const identityPath = path.join(stateDir, "identity", "device.json");
  let stat;
  let parsed;
  try {
    stat = fs.lstatSync(identityPath);
    if (!stat.isFile() || stat.isSymbolicLink()) {
      fail("OpenClaw device identity must be a regular file", 68);
    }
    if ((stat.mode & 0o077) !== 0) {
      fail("OpenClaw device identity permissions must not allow group or other access", 68);
    }
    if (typeof process.getuid === "function" && stat.uid !== process.getuid()) {
      fail("OpenClaw device identity must be owned by the current user", 68);
    }
    parsed = JSON.parse(fs.readFileSync(identityPath, "utf8"));
  } catch (error) {
    if (error instanceof GatewayV4Error) throw error;
    fail("unable to read the existing OpenClaw device identity", 68);
  }
  const identity = normalizeIdentity(parsed);
  if (!identity) fail("existing OpenClaw device identity has an unsupported shape", 68);

  try {
    const publicKey = rawPublicKey(identity.publicKeyPem);
    const derivedId = crypto.createHash("sha256").update(publicKey).digest("hex");
    const selfCheck = Buffer.from("openclaw-device-identity-self-check", "utf8");
    const signature = crypto.sign(null, selfCheck, crypto.createPrivateKey(identity.privateKeyPem));
    if (derivedId !== identity.deviceId
        || !crypto.verify(null, selfCheck, crypto.createPublicKey(identity.publicKeyPem), signature)) {
      fail("existing OpenClaw device identity failed validation", 68);
    }
  } catch (error) {
    if (error instanceof GatewayV4Error) throw error;
    fail("existing OpenClaw device identity failed validation", 68);
  }
  return identity;
}

function normalizedDeviceMetadata(value) {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

export function buildDeviceAuthPayloadV3({
  deviceId,
  token,
  nonce,
  signedAtMs,
  platform,
  deviceFamily = "",
}) {
  return [
    "v3",
    deviceId,
    CLIENT_ID,
    CLIENT_MODE,
    ROLE,
    SCOPES.join(","),
    String(signedAtMs),
    token,
    nonce,
    normalizedDeviceMetadata(platform),
    normalizedDeviceMetadata(deviceFamily),
  ].join("|");
}

export function buildConnectParams({ identity, token, nonce, signedAtMs, instanceId, platform }) {
  const payload = buildDeviceAuthPayloadV3({
    deviceId: identity.deviceId,
    token,
    nonce,
    signedAtMs,
    platform,
  });
  const signature = crypto.sign(
    null,
    Buffer.from(payload, "utf8"),
    crypto.createPrivateKey(identity.privateKeyPem),
  ).toString("base64url");
  return {
    minProtocol: PROTOCOL_VERSION,
    maxProtocol: PROTOCOL_VERSION,
    client: {
      id: CLIENT_ID,
      displayName: CLIENT_DISPLAY_NAME,
      version: CLIENT_VERSION,
      platform,
      mode: CLIENT_MODE,
      instanceId,
    },
    caps: [],
    auth: { token },
    role: ROLE,
    scopes: [...SCOPES],
    device: {
      id: identity.deviceId,
      publicKey: rawPublicKey(identity.publicKeyPem).toString("base64url"),
      signature,
      signedAt: signedAtMs,
      nonce,
    },
  };
}

function stripIpv6Brackets(hostname) {
  return hostname.startsWith("[") && hostname.endsWith("]")
    ? hostname.slice(1, -1) : hostname;
}

function isLoopbackHost(hostname) {
  const host = stripIpv6Brackets(hostname).toLowerCase();
  if (host === "localhost" || host.endsWith(".localhost") || host === "::1") return true;
  if (net.isIP(host) !== 4) return false;
  return Number(host.split(".")[0]) === 127;
}

function isPrivateOrLoopbackHost(hostname) {
  const host = stripIpv6Brackets(hostname).toLowerCase();
  if (isLoopbackHost(host)) return true;
  const family = net.isIP(host);
  if (family === 4) {
    const octets = host.split(".").map(Number);
    return octets[0] === 10
      || octets[0] === 127
      || (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31)
      || (octets[0] === 192 && octets[1] === 168);
  }
  if (family === 6) {
    return host === "::1"
      || host.startsWith("fc")
      || host.startsWith("fd")
      || /^fe[89ab]/.test(host);
  }
  return false;
}

export function validateGatewayUrl(rawUrl, allowInsecurePrivateWs) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    fail("OPENCLAW_GATEWAY_URL must be a valid WebSocket URL", 64);
  }
  if (url.protocol !== "ws:" && url.protocol !== "wss:") {
    fail("OPENCLAW_GATEWAY_URL must use ws:// or wss://", 64);
  }
  if (url.username || url.password) {
    fail("OPENCLAW_GATEWAY_URL must not contain credentials", 64);
  }
  if (url.search || url.hash) {
    fail("OPENCLAW_GATEWAY_URL must not contain a query or fragment", 64);
  }
  if (url.protocol === "ws:") {
    if (!isPrivateOrLoopbackHost(url.hostname)) {
      fail("plaintext ws:// is restricted to loopback or private-network addresses", 64);
    }
    if (!isLoopbackHost(url.hostname) && allowInsecurePrivateWs !== "1") {
      fail("plaintext private-network ws:// requires OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=1", 64);
    }
  }
  return url.toString();
}

function safeErrorLabel(error) {
  const code = typeof error?.code === "string" ? error.code : "UNKNOWN";
  const details = error?.details && typeof error.details === "object" ? error.details : {};
  const detailCode = typeof details.code === "string" ? details.code : "UNKNOWN";
  const requestId = typeof details.requestId === "string" ? ` requestId=${details.requestId}` : "";
  const expected = Number.isInteger(details.expectedProtocol)
    ? ` expectedProtocol=${details.expectedProtocol}` : "";
  return `code=${code} detail=${detailCode}${requestId}${expected}`;
}

async function messageDataToText(data) {
  if (typeof data === "string") return data;
  if (Buffer.isBuffer(data)) return data.toString("utf8");
  if (data instanceof ArrayBuffer) return Buffer.from(data).toString("utf8");
  if (ArrayBuffer.isView(data)) {
    return Buffer.from(data.buffer, data.byteOffset, data.byteLength).toString("utf8");
  }
  if (data && typeof data.text === "function") return data.text();
  fail("Gateway returned an unsupported WebSocket message type", 69);
}

export async function callAgentViaGatewayV4({
  url,
  token,
  identity,
  request,
  createWebSocket = (target) => new globalThis.WebSocket(target),
  timeoutMs = Math.max(10_000, (request.timeout_seconds + 30) * 1_000),
  now = () => Date.now(),
  randomId = () => crypto.randomUUID(),
  platform = process.platform,
}) {
  if (typeof createWebSocket !== "function") fail("WebSocket support is unavailable", 68);

  return new Promise((resolve, reject) => {
    let socket;
    let settled = false;
    let connectRequestId = null;
    let agentRequestId = null;
    let connectSent = false;

    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(overallTimer);
      clearTimeout(challengeTimer);
      try {
        socket?.close(1000, "complete");
      } catch {}
      if (error) reject(error);
      else resolve(value);
    };

    const overallTimer = setTimeout(() => {
      finish(new GatewayV4Error("Gateway protocol 4 agent request timed out", 69));
    }, timeoutMs);
    const challengeTimer = setTimeout(() => {
      finish(new GatewayV4Error("Gateway protocol 4 connect.challenge timed out", 69));
    }, Math.min(timeoutMs, 10_000));

    try {
      socket = createWebSocket(url);
    } catch {
      finish(new GatewayV4Error("unable to open the Gateway WebSocket", 69));
      return;
    }
    if (!socket || typeof socket.addEventListener !== "function"
        || typeof socket.send !== "function") {
      finish(new GatewayV4Error("WebSocket implementation is incompatible", 68));
      return;
    }
    const sendFrame = (frame) => {
      try {
        socket.send(JSON.stringify(frame));
        return true;
      } catch {
        finish(new GatewayV4Error("unable to send a Gateway WebSocket frame", 69));
        return false;
      }
    };

    socket.addEventListener("error", () => {
      finish(new GatewayV4Error("Gateway WebSocket transport failed", 69));
    });
    socket.addEventListener("close", (event) => {
      if (settled) return;
      const closeCode = Number.isInteger(event?.code) ? event.code : 1006;
      finish(new GatewayV4Error(`Gateway WebSocket closed before completion code=${closeCode}`, 69));
    });
    socket.addEventListener("message", async (event) => {
      if (settled) return;
      let frame;
      try {
        frame = JSON.parse(await messageDataToText(event.data));
      } catch (error) {
        if (error instanceof GatewayV4Error) finish(error);
        else finish(new GatewayV4Error("Gateway returned invalid JSON", 69));
        return;
      }

      if (frame?.type === "event" && frame.event === "connect.challenge") {
        const nonce = typeof frame.payload?.nonce === "string" ? frame.payload.nonce.trim() : "";
        if (!nonce) {
          finish(new GatewayV4Error("Gateway connect.challenge did not contain a nonce", 69));
          return;
        }
        if (connectSent) return;
        connectSent = true;
        clearTimeout(challengeTimer);
        connectRequestId = randomId();
        const signedAtMs = now();
        let params;
        try {
          params = buildConnectParams({
            identity,
            token,
            nonce,
            signedAtMs,
            instanceId: randomId(),
            platform,
          });
        } catch (error) {
          finish(error instanceof GatewayV4Error
            ? error : new GatewayV4Error("unable to sign the Gateway connect request", 68));
          return;
        }
        sendFrame({
          type: "req",
          id: connectRequestId,
          method: "connect",
          params,
        });
        return;
      }

      if (frame?.type !== "res" || typeof frame.id !== "string") return;
      if (frame.id === connectRequestId) {
        if (frame.ok !== true) {
          finish(new GatewayV4Error(`Gateway connect rejected ${safeErrorLabel(frame.error)}`, 69));
          return;
        }
        if (frame.payload?.type !== "hello-ok" || frame.payload.protocol !== PROTOCOL_VERSION) {
          finish(new GatewayV4Error("Gateway returned an incompatible hello response", 69));
          return;
        }
        if (!Array.isArray(frame.payload.auth?.scopes)
            || !frame.payload.auth.scopes.includes("operator.write")) {
          finish(new GatewayV4Error("Gateway did not grant operator.write to the paired device", 69));
          return;
        }
        agentRequestId = randomId();
        sendFrame({
          type: "req",
          id: agentRequestId,
          method: "agent",
          params: {
            message: request.message,
            agentId: request.target_agent,
            sessionKey: request.session_key,
            timeout: request.timeout_seconds,
            idempotencyKey: request.run_id,
          },
        });
        return;
      }

      if (frame.id === agentRequestId) {
        if (frame.ok !== true) {
          finish(new GatewayV4Error(`Gateway agent request rejected ${safeErrorLabel(frame.error)}`, 69));
          return;
        }
        if (frame.payload?.status === "accepted") return;
        if (frame.payload?.status !== "ok") {
          const status = typeof frame.payload?.status === "string"
            ? frame.payload.status : "UNKNOWN";
          finish(new GatewayV4Error(`Gateway agent request ended without success status=${status}`, 69));
          return;
        }
        finish(null, frame.payload);
      }
    });
  });
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

export function validateAdapterRequest(request) {
  const expectedKeys = [
    "message",
    "openclaw_state_dir",
    "run_id",
    "session_key",
    "target_agent",
    "timeout_seconds",
  ];
  if (!request || typeof request !== "object" || Array.isArray(request)
      || JSON.stringify(Object.keys(request).sort()) !== JSON.stringify(expectedKeys)) {
    fail("request has an invalid shape", 64);
  }
  for (const key of ["message", "openclaw_state_dir", "run_id", "session_key", "target_agent"]) {
    if (typeof request[key] !== "string" || request[key].length === 0) {
      fail(`request field ${key} is invalid`, 64);
    }
  }
  if (!/^[A-Za-z0-9_-]+$/.test(request.target_agent)) {
    fail("request target agent is invalid", 64);
  }
  if (!Number.isSafeInteger(request.timeout_seconds) || request.timeout_seconds <= 0) {
    fail("request timeout is invalid", 64);
  }
  const sessionPrefix = `agent:${request.target_agent}:`;
  if (!request.session_key.startsWith(sessionPrefix)
      || request.session_key.length === sessionPrefix.length) {
    fail("session key does not belong to target agent", 65);
  }
  return request;
}

function renderResponse(response) {
  const payloads = response?.result?.payloads;
  if (Array.isArray(payloads) && payloads.length > 0) {
    const lines = [];
    for (const payload of payloads) {
      if (typeof payload?.text === "string" && payload.text.length > 0) {
        lines.push(payload.text.trimEnd());
      }
      const media = Array.isArray(payload?.mediaUrls)
        ? payload.mediaUrls : (typeof payload?.mediaUrl === "string" ? [payload.mediaUrl] : []);
      for (const item of media) lines.push(`MEDIA:${item}`);
    }
    return lines.join("\n");
  }
  return typeof response?.summary === "string" ? response.summary : "";
}

export async function main() {
  if (typeof globalThis.WebSocket !== "function") {
    fail("Node.js WebSocket support is unavailable", 68);
  }
  let request;
  try {
    request = validateAdapterRequest(JSON.parse(await readStdin()));
  } catch (error) {
    if (error instanceof GatewayV4Error) throw error;
    fail("request must be one JSON object", 64);
  }

  const rawUrl = process.env.OPENCLAW_GATEWAY_URL?.trim();
  const token = process.env.OPENCLAW_GATEWAY_TOKEN?.trim();
  if (typeof rawUrl !== "string" || rawUrl.length === 0) {
    fail("OPENCLAW_GATEWAY_URL is required", 64);
  }
  if (typeof token !== "string" || token.length === 0) {
    fail("OPENCLAW_GATEWAY_TOKEN is required", 64);
  }
  const url = validateGatewayUrl(rawUrl, process.env.OPENCLAW_ALLOW_INSECURE_PRIVATE_WS);
  const identity = loadOpenClawDeviceIdentity(request.openclaw_state_dir);
  const response = await callAgentViaGatewayV4({ url, token, identity, request });
  process.stdout.write(renderResponse(response));
}

const isMain = process.argv[1]
  && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;
if (isMain) {
  main().catch((error) => {
    const safeError = error instanceof GatewayV4Error
      ? error : new GatewayV4Error("unexpected Gateway protocol 4 adapter failure", 69);
    process.stderr.write(`openclaw_agent_gateway_v4: ${safeError.message}\n`);
    process.exitCode = safeError.exitCode;
  });
}
