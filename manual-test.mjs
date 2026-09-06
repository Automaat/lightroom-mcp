#!/usr/bin/env node
// DEV-ONLY: Direct TCP probe for validating plugin dispatch without a full MCP
// client. Connects raw sockets to the plugin's request (:58763) and response
// (:58764) ports, sends one action, prints the reply, then exits.
//
// This script bypasses the MCP server entirely — it does NOT exercise MCP
// transport, tool schemas, or server-side validation. Use it to confirm the
// Lightroom plugin is reachable and a given handler works end-to-end.
//
// Prerequisites:
//   - Lightroom Classic running with LightroomMCP plugin loaded
//   - Plugin token written to TOKEN_PATH (created when Start Server is clicked)
//
// Env overrides (must match plugin Plug-in Manager settings):
//   LIGHTROOM_MCP_REQUEST_PORT   default 58763
//   LIGHTROOM_MCP_RESPONSE_PORT  default 58764
//
// Env overrides (probe/server reader only — no matching Plug-in Manager setting):
//   LIGHTROOM_MCP_TOKEN_PATH     default ~/.config/lightroom-mcp/token
//
// Usage: node manual-test.mjs [action] [json-params]
//   node manual-test.mjs list_collections
//   node manual-test.mjs search_photos '{"rating":5}'

import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";

const REQUEST_PORT = Number(process.env.LIGHTROOM_MCP_REQUEST_PORT ?? 58763);
const RESPONSE_PORT = Number(process.env.LIGHTROOM_MCP_RESPONSE_PORT ?? 58764);
const TOKEN_PATH =
  process.env.LIGHTROOM_MCP_TOKEN_PATH ??
  path.join(os.homedir(), ".config", "lightroom-mcp", "token");
const TIMEOUT_MS = 30_000;

const action = process.argv[2] ?? "list_collections";
const params = process.argv[3] ? JSON.parse(process.argv[3]) : {};
const id = `manual_${Date.now()}`;

let token;
try {
  token = fs.readFileSync(TOKEN_PATH, "utf8").trim();
} catch (err) {
  console.error(`token read failed at ${TOKEN_PATH}: ${err.message}`);
  console.error("start the plugin in Lightroom first");
  process.exit(1);
}
if (!token) {
  console.error(`token file ${TOKEN_PATH} is empty`);
  process.exit(1);
}

function connect(port, label) {
  return new Promise((resolve, reject) => {
    const sock = new net.Socket();
    sock.setEncoding("utf8");
    sock.once("error", reject);
    sock.once("connect", () => {
      sock.removeAllListeners("error");
      console.log(`[${label}] connected :${port}`);
      resolve(sock);
    });
    sock.connect(port, "127.0.0.1");
  });
}

const RESPONSE_CONNECT_SETTLE_MS = 200;
const RESPONSE_RECONNECT_DELAY_MS = 500;
const CONNECT_RETRY_DELAY_MS = 500;
const CONNECT_RETRY_ATTEMPTS = 20;

// The plugin rebinds a listener after a client disconnects, and the port is
// briefly refused during that window. The MCP server rides it out by retrying,
// so back-to-back probe runs need the same patience.
async function connectWithRetry(port, label) {
  for (let attempt = 1; ; attempt++) {
    try {
      return await connect(port, label);
    } catch (err) {
      if (attempt >= CONNECT_RETRY_ATTEMPTS) throw err;
      console.log(`[${label}] connect failed (${err.message}), retrying`);
      await new Promise((resolve) => setTimeout(resolve, CONNECT_RETRY_DELAY_MS));
    }
  }
}

const reqSock = await connectWithRetry(REQUEST_PORT, "request");
await new Promise((resolve) => setTimeout(resolve, RESPONSE_CONNECT_SETTLE_MS));

let buf = "";
let respSock = null;

let signalConnected;
const responseConnected = new Promise((resolve) => {
  signalConnected = resolve;
});

const responsePromise = new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error("timeout waiting for response")), TIMEOUT_MS);
  let settled = false;

  const attachResponseSocket = (sock) => {
    respSock = sock;
    signalConnected();
    sock.on("data", (chunk) => {
      buf += chunk;
      let idx;
      while ((idx = buf.indexOf("\n")) !== -1) {
        const line = buf.slice(0, idx).trim();
        buf = buf.slice(idx + 1);
        if (!line) continue;
        const resp = JSON.parse(line);
        if (resp.id === id) {
          settled = true;
          clearTimeout(timer);
          resolve(resp);
        }
      }
    });
    sock.on("close", () => {
      if (settled) return;
      buf = "";
      console.log("[response] dropped by plugin rebind, reconnecting");
      setTimeout(reconnectResponseSocket, RESPONSE_RECONNECT_DELAY_MS);
    });
  };

  function reconnectResponseSocket() {
    if (settled) return;
    connectWithRetry(RESPONSE_PORT, "response").then(attachResponseSocket, (err) => {
      if (settled) return;
      console.log(`[response] connect failed (${err.message}), retrying`);
      setTimeout(reconnectResponseSocket, RESPONSE_RECONNECT_DELAY_MS);
    });
  }

  reconnectResponseSocket();
});

await responseConnected;

const payload = JSON.stringify({ hello: token, id, action, params });
console.log(`>>> ${payload}`);
reqSock.write(payload + "\n");

const resp = await responsePromise;
console.log("<<<", JSON.stringify(resp, null, 2));

reqSock.destroy();
respSock?.destroy();
