#!/usr/bin/env node
// Direct TCP probe that mimics what the MCP server does. Use to verify the plugin
// is wired correctly without spinning up a full MCP client.
//
// Usage: node manual-test.mjs [action] [json-params]
//   node manual-test.mjs list_collections
//   node manual-test.mjs search_photos '{"rating":5}'

import net from "node:net";

const REQUEST_PORT = 58763;
const RESPONSE_PORT = 58764;
const TIMEOUT_MS = 30_000;

const action = process.argv[2] ?? "list_collections";
const params = process.argv[3] ? JSON.parse(process.argv[3]) : {};
const id = `manual_${Date.now()}`;

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

const [reqSock, respSock] = await Promise.all([
  connect(REQUEST_PORT, "request"),
  connect(RESPONSE_PORT, "response"),
]);

let buf = "";
const responsePromise = new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error("timeout waiting for response")), TIMEOUT_MS);
  respSock.on("data", (chunk) => {
    buf += chunk;
    let idx;
    while ((idx = buf.indexOf("\n")) !== -1) {
      const line = buf.slice(0, idx).trim();
      buf = buf.slice(idx + 1);
      if (!line) continue;
      const resp = JSON.parse(line);
      if (resp.id === id) {
        clearTimeout(timer);
        resolve(resp);
      }
    }
  });
  respSock.on("close", () => reject(new Error("response socket closed")));
});

const payload = JSON.stringify({ id, action, params });
console.log(`>>> ${payload}`);
reqSock.write(payload + "\n");

const resp = await responsePromise;
console.log("<<<", JSON.stringify(resp, null, 2));

reqSock.destroy();
respSock.destroy();
