#!/usr/bin/env node

import path from "node:path";
import { fileURLToPath } from "node:url";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { PluginSocket } from "./plugin-socket.js";
import { Dispatcher } from "./dispatcher.js";
import { readToken, tokenFilePath } from "./token.js";
import { requestPort, responsePort } from "./ports.js";
import { createMcpServer } from "./create-server.js";
import { NOT_CONNECTED_MESSAGE } from "./tool-handler.js";
import { parseCli, helpText } from "./cli.js";
import { VERSION } from "./version.js";
import { startHeartbeat, probePlugin } from "./heartbeat.js";
import { PluginLiveness, SHADOW_BRIDGE_MESSAGE } from "./plugin-liveness.js";
import { waitUntil } from "./wait-until.js";
import { acquireInstanceLock } from "./instance-lock.js";
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
// Keep this interval in sync with HEARTBEAT_INTERVAL_SECONDS in
// PluginInfoProvider.lua. See heartbeat.ts for what this drives.
const HEARTBEAT_INTERVAL_MS = 30_000;
const PING_TIMEOUT_MS = 10_000;
const RESPONSE_CONNECT_SETTLE_MS = 200;
// Short enough that a tool call waiting on the verdict is not left hanging,
// generous enough for a busy-but-healthy plugin: a ping is a no-op dispatch
// that answered in single-digit milliseconds even mid-export.
const PROBE_TIMEOUT_MS = 5_000;
const PROBE_RECOVERY_INTERVAL_MS = 5_000;
// A client that calls a tool immediately after initialize would otherwise be
// told "plugin not connected" while the sockets are still coming up, which is
// a lie about a perfectly healthy Lightroom. Wait out the connect instead.
const STARTUP_GRACE_MS = 3_000;
const CONNECT_POLL_MS = 50;
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

  try {
    acquireInstanceLock(REQUEST_PORT, RESPONSE_PORT);
  } catch (err) {
    console.error((err as Error).message);
    process.exit(1);
  }

  ensurePluginInstalled(here, (m) => console.error(m));

  let requestSocket: PluginSocket;
  let responseSocket: PluginSocket | null = null;
  let responseConnectTimer: NodeJS.Timeout | null = null;
  const dispatcher = new Dispatcher({
    send: (line) => requestSocket.send(line),
    getToken: () => readToken(),
    timeoutMs: REQUEST_TIMEOUT_MS,
    actionTimeoutsMs: ACTION_TIMEOUTS_MS,
  });
  const liveness = new PluginLiveness();
  let recoveryTimer: NodeJS.Timeout | null = null;
  const probeOnConnect = () => {
    liveness.beginProbe();
    void probePlugin(dispatcher, PROBE_TIMEOUT_MS).then((answered) => {
      if (answered) {
        liveness.markResponsive();
        if (recoveryTimer) {
          clearInterval(recoveryTimer);
          recoveryTimer = null;
        }
        return;
      }
      liveness.markUnresponsive();
      console.error(`[plugin] ${SHADOW_BRIDGE_MESSAGE}`);
      // Re-probe faster than the 30s heartbeat so the bridge recovers promptly
      // once the process holding the plugin goes away.
      if (!recoveryTimer) {
        recoveryTimer = setInterval(() => probeOnConnect(), PROBE_RECOVERY_INTERVAL_MS);
      }
    });
  };
  const startResponseSocket = () => {
    if (responseSocket || !requestSocket.isConnected()) return;
    responseSocket = new PluginSocket({
      port: RESPONSE_PORT,
      label: "response",
      onLine: (line) => dispatcher.handleResponseLine(line),
      onConnect: () => probeOnConnect(),
    });
    responseSocket.connect();
  };
  const stopResponseSocket = () => {
    liveness.reset();
    if (responseConnectTimer) {
      clearTimeout(responseConnectTimer);
      responseConnectTimer = null;
    }
    responseSocket?.stop();
    responseSocket = null;
  };
  requestSocket = new PluginSocket({
    port: REQUEST_PORT,
    label: "request",
    onConnect: () => {
      if (responseConnectTimer) clearTimeout(responseConnectTimer);
      responseConnectTimer = setTimeout(() => {
        responseConnectTimer = null;
        startResponseSocket();
      }, RESPONSE_CONNECT_SETTLE_MS);
    },
    onDisconnect: () => {
      stopResponseSocket();
    },
  });
  requestSocket.connect();

  const socketsConnected = () =>
    requestSocket.isConnected() && (responseSocket?.isConnected() ?? false);

  startHeartbeat(
    dispatcher,
    HEARTBEAT_INTERVAL_MS,
    (err) => {
      console.error(`[heartbeat] ping failed: ${err.message}`);
      // A ping that fails because the socket is down is an ordinary disconnect,
      // not a second bridge holding the plugin. Only diagnose the latter while
      // the connection is actually up, or a stopped plugin gets blamed on a
      // process that does not exist.
      if (!socketsConnected()) {
        liveness.reset();
        return;
      }
      liveness.markUnresponsive();
      console.error(`[plugin] ${SHADOW_BRIDGE_MESSAGE}`);
    },
    () => liveness.markResponsive(),
  );

  const server = createMcpServer({
    dispatcher,
    isReady: () => socketsConnected() && liveness.isUsable(),
    notReadyMessage: () => (socketsConnected() ? SHADOW_BRIDGE_MESSAGE : NOT_CONNECTED_MESSAGE),
    settleReadiness: async () => {
      await waitUntil(socketsConnected, STARTUP_GRACE_MS, CONNECT_POLL_MS);
      await liveness.settled();
    },
  });

  const transport = new StdioServerTransport();
  await server.connect(transport);

  // Exit when the MCP client goes away. Signal handlers never fire when the
  // parent dies without signaling (typical on Windows), and the live plugin
  // sockets plus the heartbeat interval keep the event loop alive — the
  // orphaned bridge then holds both the single-client plugin connection and
  // the instance lock, so every future bridge instance fails with "Another
  // Lightroom MCP bridge is already running". Stdin EOF is the one reliable
  // cross-platform signal that the client is gone.
  const exitOnClientGone = (reason: string) => () => {
    console.error(`Shutting down: ${reason}`);
    process.exit(0);
  };
  process.stdin.once("end", exitOnClientGone("stdin ended (client exited)"));
  process.stdin.once("close", exitOnClientGone("stdin closed (client exited)"));

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
