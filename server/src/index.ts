#!/usr/bin/env node

import path from "node:path";
import { fileURLToPath } from "node:url";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { PluginSocket } from "./plugin-socket.js";
import { Dispatcher } from "./dispatcher.js";
import { readToken, tokenFilePath } from "./token.js";
import { requestPort, responsePort } from "./ports.js";
import { createMcpServer } from "./create-server.js";
import { parseCli, helpText } from "./cli.js";
import {
  ensurePluginInstalled,
  findBundledPlugin,
  installPlugin,
  lightroomModulesDir,
} from "./install-plugin.js";

const REQUEST_TIMEOUT_MS = 30_000;
const PKG_VERSION = "0.2.0";

const here = path.dirname(fileURLToPath(import.meta.url));

async function main() {
  let cli;
  try {
    cli = parseCli(process.argv);
  } catch (err) {
    console.error((err as Error).message);
    process.exit(2);
  }

  if (cli.command === "help") {
    process.stdout.write(helpText());
    return;
  }
  if (cli.command === "version") {
    process.stdout.write(PKG_VERSION + "\n");
    return;
  }
  if (cli.command === "install-plugin") {
    runInstallPlugin();
    return;
  }

  let REQUEST_PORT: number;
  let RESPONSE_PORT: number;
  try {
    REQUEST_PORT = requestPort();
    RESPONSE_PORT = responsePort();
  } catch (err) {
    console.error((err as Error).message);
    process.exit(1);
  }

  ensurePluginInstalled(here, (m) => console.error(m));

  const requestSocket = new PluginSocket({ port: REQUEST_PORT, label: "request" });
  const dispatcher = new Dispatcher({
    send: (line) => requestSocket.send(line),
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

  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(`Lightroom MCP server v${PKG_VERSION} running on stdio`);
  console.error(`Connecting to plugin: request :${REQUEST_PORT}, response :${RESPONSE_PORT}`);
  console.error(`Token file: ${tokenFilePath()}`);
}

function runInstallPlugin(): void {
  const source = findBundledPlugin(here);
  if (!source) {
    console.error("Could not locate bundled LightroomMCP.lrplugin folder near this binary.");
    console.error("If you cloned the repo, run from the repo root or pass a path explicitly.");
    process.exit(1);
  }
  const dest = lightroomModulesDir();
  try {
    const result = installPlugin({ source, destDir: dest });
    if (result.status === "installed") {
      console.error(`Installed plugin: ${result.destination}`);
      console.error(`Restart Lightroom Classic to load it.`);
    } else if (result.status === "already-present") {
      console.error(`Plugin already present at ${result.destination}`);
    } else {
      console.error(`Skipped: ${result.reason ?? "unknown reason"}`);
      process.exit(1);
    }
  } catch (err) {
    console.error(`Install failed: ${(err as Error).message}`);
    process.exit(1);
  }
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
