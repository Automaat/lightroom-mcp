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
import { VERSION } from "./version.js";
import {
  ensurePluginInstalled,
  findBundledPlugin,
  installPlugin,
  lightroomModulesDir,
} from "./install-plugin.js";

const REQUEST_TIMEOUT_MS = 30_000;
// Batch export/import render files and can run for minutes; the default
// timeout would report a spurious failure mid-export. See issue #128.
const LONG_RUNNING_TIMEOUT_MS = 300_000;
// Heartbeat: ping the plugin on this interval so it can tell a healthy-but-
// idle session apart from a genuinely dead connection (issue #134 follow-up,
// PR #151 review) instead of relying on a long fixed idle timer. The plugin
// derives liveness from any inbound message -- ping included -- via its
// existing lastRequestTime tracking, so this side doesn't need to react to a
// missed pong itself; a failed/timed-out ping is only logged for visibility.
// Keep this interval in sync with HEARTBEAT_INTERVAL_SECONDS in
// PluginInfoProvider.lua.
const HEARTBEAT_INTERVAL_MS = 30_000;
const PING_TIMEOUT_MS = 10_000;
const ACTION_TIMEOUTS_MS: Record<string, number> = {
  export_photos: LONG_RUNNING_TIMEOUT_MS,
  import_photos: LONG_RUNNING_TIMEOUT_MS,
  ping: PING_TIMEOUT_MS,
};

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
    process.stdout.write(VERSION + "\n");
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
    actionTimeoutsMs: ACTION_TIMEOUTS_MS,
  });
  const responseSocket = new PluginSocket({
    port: RESPONSE_PORT,
    label: "response",
    onLine: (line) => dispatcher.handleResponseLine(line),
  });
  requestSocket.connect();
  responseSocket.connect();

  // Fire-and-forget heartbeat. dispatcher.call() rejects on its own if the
  // request socket is currently disconnected, so this is safe to run
  // unconditionally regardless of connection state.
  setInterval(() => {
    dispatcher.call("ping", {}).catch((err: Error) => {
      console.error(`[heartbeat] ping failed: ${err.message}`);
    });
  }, HEARTBEAT_INTERVAL_MS);

  const server = createMcpServer({
    dispatcher,
    isReady: () => requestSocket.isConnected() && responseSocket.isConnected(),
  });

  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(`Lightroom MCP server v${VERSION} running on stdio`);
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
