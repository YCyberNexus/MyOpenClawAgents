import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { once } from "node:events";
import { spawn } from "node:child_process";
import {
  callAgentViaGatewayV4,
  validateGatewayUrl,
} from "../scripts/openclaw_agent_gateway_v4.mjs";

const TEST_ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "openclaw-gateway-v4-test-"));
const STATE_DIR = path.join(TEST_ROOT, "state");
const HELPER = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "../scripts/openclaw_agent_gateway_v4.mjs",
);
const TOKEN = "gateway-token-v4-secret";
const MESSAGE = "task result with callback nonce-v4-secret";
const NONCE = "challenge-nonce-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

function createIdentity() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync("ed25519");
  const publicKeyPem = publicKey.export({ type: "spki", format: "pem" });
  const privateKeyPem = privateKey.export({ type: "pkcs8", format: "pem" });
  const publicKeyDer = publicKey.export({ type: "spki", format: "der" });
  const publicKeyRaw = publicKeyDer.subarray(SPKI_PREFIX.length);
  const identity = {
    version: 1,
    deviceId: crypto.createHash("sha256").update(publicKeyRaw).digest("hex"),
    publicKeyPem,
    privateKeyPem,
    createdAtMs: Date.now(),
  };
  fs.mkdirSync(path.join(STATE_DIR, "identity"), { recursive: true, mode: 0o700 });
  fs.writeFileSync(
    path.join(STATE_DIR, "identity", "device.json"),
    `${JSON.stringify(identity)}\n`,
    { mode: 0o600 },
  );
  return identity;
}

const IDENTITY = createIdentity();

function encodeServerFrame(opcode, payload = Buffer.alloc(0)) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  let header;
  if (body.length < 126) {
    header = Buffer.from([0x80 | opcode, body.length]);
  } else if (body.length <= 0xffff) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(body.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(body.length), 2);
  }
  return Buffer.concat([header, body]);
}

function attachFrameReader(socket, onText) {
  let buffered = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    buffered = Buffer.concat([buffered, chunk]);
    while (buffered.length >= 2) {
      const opcode = buffered[0] & 0x0f;
      const masked = (buffered[1] & 0x80) !== 0;
      let payloadLength = buffered[1] & 0x7f;
      let offset = 2;
      if (payloadLength === 126) {
        if (buffered.length < 4) return;
        payloadLength = buffered.readUInt16BE(2);
        offset = 4;
      } else if (payloadLength === 127) {
        if (buffered.length < 10) return;
        const wideLength = buffered.readBigUInt64BE(2);
        assert.ok(wideLength <= BigInt(Number.MAX_SAFE_INTEGER));
        payloadLength = Number(wideLength);
        offset = 10;
      }
      const maskLength = masked ? 4 : 0;
      if (buffered.length < offset + maskLength + payloadLength) return;
      const mask = masked ? buffered.subarray(offset, offset + 4) : null;
      offset += maskLength;
      const payload = Buffer.from(buffered.subarray(offset, offset + payloadLength));
      buffered = buffered.subarray(offset + payloadLength);
      if (mask) {
        for (let index = 0; index < payload.length; index += 1) {
          payload[index] ^= mask[index % 4];
        }
      }
      if (opcode === 0x1) {
        Promise.resolve(onText(payload.toString("utf8"))).catch((error) => socket.destroy(error));
      } else if (opcode === 0x8) {
        if (!socket.writableEnded) {
          socket.write(encodeServerFrame(0x8, payload));
          socket.end();
        }
      } else if (opcode === 0x9) {
        socket.write(encodeServerFrame(0x0a, payload));
      }
    }
  });
}

async function startGateway(onFrame) {
  const sockets = new Set();
  const server = http.createServer();
  server.on("upgrade", (request, socket, head) => {
    sockets.add(socket);
    socket.on("error", () => {});
    socket.on("close", () => sockets.delete(socket));
    const websocketKey = request.headers["sec-websocket-key"];
    assert.equal(typeof websocketKey, "string");
    assert.equal(new URL(request.url, "http://127.0.0.1").search, "");
    const accept = crypto.createHash("sha1")
      .update(`${websocketKey}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
      .digest("base64");
    socket.write([
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      `Sec-WebSocket-Accept: ${accept}`,
      "",
      "",
    ].join("\r\n"));
    const connection = {
      send(value) {
        if (!socket.destroyed) socket.write(encodeServerFrame(0x1, JSON.stringify(value)));
      },
      close(code) {
        const payload = Buffer.alloc(2);
        payload.writeUInt16BE(code, 0);
        if (!socket.destroyed) socket.end(encodeServerFrame(0x8, payload));
      },
    };
    attachFrameReader(socket, (raw) => onFrame(JSON.parse(raw), connection));
    if (head.length > 0) socket.emit("data", head);
    connection.send({
      type: "event",
      event: "connect.challenge",
      payload: { nonce: NONCE, ts: Date.now() },
    });
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address === "object");
  return {
    url: `ws://127.0.0.1:${address.port}`,
    async stop() {
      for (const socket of sockets) socket.destroy();
      await new Promise((resolve, reject) => {
        server.close((error) => {
          if (error) reject(error);
          else resolve();
        });
      });
    },
  };
}

function helloOk(id, scopes = ["operator.write"]) {
  return {
    type: "res",
    id,
    ok: true,
    payload: {
      type: "hello-ok",
      protocol: 4,
      server: { version: "2026.6.1", connId: "test-connection" },
      features: { methods: ["agent"], events: [] },
      snapshot: {
        presence: [],
        health: { ok: true, channels: {}, channelOrder: [], channelLabels: {}, heartbeatSeconds: 30, defaultAgentId: "main", agents: [], sessionCount: 0, uptimeMs: 1, pendingSystemEvents: 0, version: "2026.6.1", health: 1 },
        stateVersion: { presence: 1, health: 1 },
        uptimeMs: 1,
      },
      auth: { role: "operator", scopes },
      policy: { maxPayload: 26214400, maxBufferedBytes: 52428800, tickIntervalMs: 30000 },
    },
  };
}

function verifyConnect(frame) {
  assert.equal(frame.type, "req");
  assert.equal(frame.method, "connect");
  assert.equal(frame.params.minProtocol, 4);
  assert.equal(frame.params.maxProtocol, 4);
  assert.equal(frame.params.client.id, "cli");
  assert.equal(frame.params.client.mode, "cli");
  assert.equal(frame.params.client.version, "2026.6.1");
  assert.equal(frame.params.role, "operator");
  assert.deepEqual(frame.params.scopes, ["operator.write"]);
  assert.deepEqual(frame.params.auth, { token: TOKEN });
  assert.equal(frame.params.device.nonce, NONCE);
  assert.equal(frame.params.device.id, IDENTITY.deviceId);

  const rawPublicKey = Buffer.from(frame.params.device.publicKey, "base64url");
  assert.equal(
    crypto.createHash("sha256").update(rawPublicKey).digest("hex"),
    frame.params.device.id,
  );
  const signedPayload = [
    "v3",
    frame.params.device.id,
    frame.params.client.id,
    frame.params.client.mode,
    frame.params.role,
    frame.params.scopes.join(","),
    String(frame.params.device.signedAt),
    TOKEN,
    NONCE,
    frame.params.client.platform.toLowerCase(),
    "",
  ].join("|");
  const publicKey = crypto.createPublicKey({
    key: Buffer.concat([SPKI_PREFIX, rawPublicKey]),
    type: "spki",
    format: "der",
  });
  assert.equal(
    crypto.verify(
      null,
      Buffer.from(signedPayload),
      publicKey,
      Buffer.from(frame.params.device.signature, "base64url"),
    ),
    true,
  );
}

async function runHelper(url) {
  const child = spawn(process.execPath, [HELPER], {
    env: {
      ...process.env,
      OPENCLAW_GATEWAY_URL: url,
      OPENCLAW_GATEWAY_TOKEN: TOKEN,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  child.stdin.end(JSON.stringify({
    openclaw_state_dir: STATE_DIR,
    target_agent: "zhujiaye",
    session_key: "agent:zhujiaye:main",
    message: MESSAGE,
    run_id: "notify-v4-idempotency-1",
    strict_json_receipt: false,
    timeout_seconds: 2,
  }));
  const watchdog = setTimeout(() => child.kill("SIGKILL"), 5_000);
  const [code, signal] = await once(child, "close");
  clearTimeout(watchdog);
  return { code, signal, stdout, stderr };
}

async function testSuccessfulAgentRun() {
  let sawAgent = false;
  const gateway = await startGateway((frame, connection) => {
    if (frame.method === "connect") {
      verifyConnect(frame);
      connection.send(helloOk(frame.id));
      return;
    }
    if (frame.method === "agent") {
      sawAgent = true;
      assert.deepEqual(frame.params, {
        message: MESSAGE,
        agentId: "zhujiaye",
        sessionKey: "agent:zhujiaye:main",
        timeout: 2,
        idempotencyKey: "notify-v4-idempotency-1",
      });
      connection.send({
        type: "res",
        id: frame.id,
        ok: true,
        payload: { runId: "run-1", status: "accepted", acceptedAt: Date.now() },
      });
      setTimeout(() => connection.send({
        type: "res",
        id: frame.id,
        ok: true,
        payload: {
          runId: "run-1",
          status: "ok",
          summary: "completed",
          result: { payloads: [{ text: "final reply" }] },
        },
      }), 30);
    }
  });
  try {
    const result = await runHelper(gateway.url);
    assert.equal(result.code, 0, result.stderr);
    assert.equal(result.signal, null);
    assert.equal(result.stdout, "final reply");
    assert.equal(sawAgent, true);
    assert.equal(result.stderr.includes(TOKEN), false);
    assert.equal(result.stderr.includes(MESSAGE), false);
  } finally {
    await gateway.stop();
  }
}

async function testPairingFailureIsActionableAndSecretSafe() {
  let sawAgent = false;
  const gateway = await startGateway((frame, connection) => {
    if (frame.method === "connect") {
      verifyConnect(frame);
      connection.send({
        type: "res",
        id: frame.id,
        ok: false,
        error: {
          code: "NOT_PAIRED",
          message: "pairing required",
          details: {
            code: "PAIRING_REQUIRED",
            requestId: "pair-request-114-1",
            reason: "not-paired",
          },
        },
      });
      connection.close(1008);
    } else if (frame.method === "agent") {
      sawAgent = true;
    }
  });
  try {
    const result = await runHelper(gateway.url);
    assert.equal(result.code, 69);
    assert.equal(sawAgent, false);
    assert.match(result.stderr, /detail=PAIRING_REQUIRED/);
    assert.match(result.stderr, /requestId=pair-request-114-1/);
    assert.equal(result.stderr.includes(TOKEN), false);
    assert.equal(result.stderr.includes(MESSAGE), false);
  } finally {
    await gateway.stop();
  }
}

async function testProtocolMismatchIsReported() {
  const gateway = await startGateway((frame, connection) => {
    if (frame.method !== "connect") return;
    verifyConnect(frame);
    connection.send({
      type: "res",
      id: frame.id,
      ok: false,
      error: {
        code: "INVALID_REQUEST",
        message: "protocol mismatch",
        details: { code: "PROTOCOL_MISMATCH", expectedProtocol: 4 },
      },
    });
    connection.close(1002);
  });
  try {
    const result = await runHelper(gateway.url);
    assert.equal(result.code, 69);
    assert.match(result.stderr, /detail=PROTOCOL_MISMATCH/);
    assert.match(result.stderr, /expectedProtocol=4/);
    assert.equal(result.stderr.includes(TOKEN), false);
    assert.equal(result.stderr.includes(MESSAGE), false);
  } finally {
    await gateway.stop();
  }
}

async function testAcceptedIsNotFinal() {
  const request = {
    openclaw_state_dir: STATE_DIR,
    target_agent: "zhujiaye",
    session_key: "agent:zhujiaye:main",
    message: MESSAGE,
    run_id: "notify-v4-timeout-1",
    strict_json_receipt: false,
    timeout_seconds: 2,
  };
  const gateway = await startGateway((frame, connection) => {
    if (frame.method === "connect") {
      verifyConnect(frame);
      connection.send(helloOk(frame.id));
    } else if (frame.method === "agent") {
      connection.send({
        type: "res",
        id: frame.id,
        ok: true,
        payload: { runId: "run-timeout", status: "accepted", acceptedAt: Date.now() },
      });
    }
  });
  try {
    await assert.rejects(
      callAgentViaGatewayV4({
        url: gateway.url,
        token: TOKEN,
        identity: IDENTITY,
        request,
        timeoutMs: 150,
      }),
      /agent request timed out/,
    );
  } finally {
    await gateway.stop();
  }
}

async function testTerminalTimeoutIsNotDeliverySuccess() {
  const gateway = await startGateway((frame, connection) => {
    if (frame.method === "connect") {
      verifyConnect(frame);
      connection.send(helloOk(frame.id));
    } else if (frame.method === "agent") {
      connection.send({
        type: "res",
        id: frame.id,
        ok: true,
        payload: { runId: "run-terminal-timeout", status: "accepted", acceptedAt: Date.now() },
      });
      connection.send({
        type: "res",
        id: frame.id,
        ok: true,
        payload: {
          runId: "run-terminal-timeout",
          status: "timeout",
          summary: "aborted",
          stopReason: "timeout",
        },
      });
    }
  });
  try {
    const result = await runHelper(gateway.url);
    assert.equal(result.code, 69);
    assert.match(result.stderr, /ended without success status=timeout/);
    assert.equal(result.stderr.includes(TOKEN), false);
    assert.equal(result.stderr.includes(MESSAGE), false);
  } finally {
    await gateway.stop();
  }
}

function testPlaintextUrlPolicy() {
  assert.throws(
    () => validateGatewayUrl("ws://10.64.5.114:18789", undefined),
    /OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=1/,
  );
  assert.equal(
    validateGatewayUrl("ws://10.64.5.114:18789", "1"),
    "ws://10.64.5.114:18789/",
  );
  assert.throws(
    () => validateGatewayUrl("ws://example.com:18789", "1"),
    /restricted to loopback or private-network addresses/,
  );
  assert.throws(
    () => validateGatewayUrl("wss://gateway.example.com/socket?token=secret", undefined),
    /must not contain a query or fragment/,
  );
}

await testSuccessfulAgentRun();
await testPairingFailureIsActionableAndSecretSafe();
await testProtocolMismatchIsReported();
await testAcceptedIsNotFinal();
await testTerminalTimeoutIsNotDeliverySuccess();
testPlaintextUrlPolicy();

process.stdout.write("ok protocol 4 Gateway adapter\n");
