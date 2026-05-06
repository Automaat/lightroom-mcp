#!/usr/bin/env node

import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { PluginSocket } from "./plugin-socket.js";
import { Dispatcher } from "./dispatcher.js";
import { readToken, tokenFilePath } from "./token.js";
import { requestPort, responsePort } from "./ports.js";
import { createMcpServer } from "./create-server.js";

const REQUEST_TIMEOUT_MS = 30_000;

let REQUEST_PORT: number;
let RESPONSE_PORT: number;
try {
  REQUEST_PORT = requestPort();
  RESPONSE_PORT = responsePort();
  readToken();
} catch (err) {
  console.error((err as Error).message);
  process.exit(1);
}

const requestSocket = new PluginSocket({
  port: REQUEST_PORT,
  label: "request",
});
const dispatcher = new Dispatcher({
  send: (line) => requestSocket.send(line),
  // Re-read on every call so a token rotation by the plugin (e.g. server
  // restart in Plug-in Manager) is picked up without bouncing this process.
  getToken: () => readToken(),
  timeoutMs: REQUEST_TIMEOUT_MS,
});
const responseSocket = new PluginSocket({
  port: RESPONSE_PORT,
  label: "response",
  onLine: (line) => dispatcher.handleResponseLine(line),
});
requestSocket.connect();
responseSocket.connect();

const server = createMcpServer({
  dispatcher,
  isReady: () => requestSocket.isConnected() && responseSocket.isConnected(),
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Lightroom MCP server running on stdio");
  console.error(`Connecting to plugin: request :${REQUEST_PORT}, response :${RESPONSE_PORT}`);
  console.error(`Token file: ${tokenFilePath()}`);
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
