// Integration repro for issue #110: response socket rebind cycle drops
// the first dispatch on Windows. Drives the real PluginSocket + Dispatcher
// against a Node fake plugin that mimics the Lua plugin's close+rebind
// behavior on each new request-side connect.
//
// The bug is fundamentally about TCP listener lifecycle on the host OS — we
// run the test unmodified on ubuntu/macos/windows in CI so any Windows-only
// race shows up as a deterministic test failure rather than a user report.

import { describe, it, expect, afterEach } from "@jest/globals";
import { PluginSocket } from "../src/plugin-socket.js";
import { Dispatcher } from "../src/dispatcher.js";
import { FakePlugin, freePort } from "./helpers/fake-plugin.js";

interface Harness {
  plugin: FakePlugin;
  request: PluginSocket;
  response: PluginSocket;
  dispatcher: Dispatcher;
}

const TOKEN = "rebind-test-token";

async function waitFor(
  check: () => boolean,
  timeoutMs: number,
  label: string,
): Promise<void> {
  const start = Date.now();
  while (!check()) {
    if (Date.now() - start > timeoutMs) {
      throw new Error(`waitFor(${label}) timed out after ${timeoutMs}ms`);
    }
    await new Promise((r) => setTimeout(r, 25));
  }
}

async function startHarness(options?: {
  rebindDelayMs?: number;
  exclusivePort?: boolean;
  handler?: (action: string, params: unknown) => unknown | Promise<unknown>;
  dispatcherTimeoutMs?: number;
}): Promise<Harness> {
  const [requestPort, responsePort] = await Promise.all([freePort(), freePort()]);
  const plugin = new FakePlugin({
    requestPort,
    responsePort,
    token: TOKEN,
    rebindDelayMs: options?.rebindDelayMs ?? 0,
    exclusivePort: options?.exclusivePort ?? false,
    handler:
      options?.handler ??
      ((action: string) => ({ echoed: action, count: 0, has_more: false })),
  });
  await plugin.start();

  const request = new PluginSocket({
    port: requestPort,
    label: "request",
    reconnectDelayMs: 50,
    log: () => {},
  });
  const response = new PluginSocket({
    port: responsePort,
    label: "response",
    reconnectDelayMs: 50,
    log: () => {},
    onLine: (line) => dispatcher.handleResponseLine(line),
  });
  const dispatcher = new Dispatcher({
    send: (line) => request.send(line),
    getToken: () => TOKEN,
    timeoutMs: options?.dispatcherTimeoutMs ?? 5_000,
    log: () => {},
  });

  request.connect();
  response.connect();

  await waitFor(
    () => request.isConnected() && response.isConnected(),
    3_000,
    "both sockets connected",
  );

  return { plugin, request, response, dispatcher };
}

async function teardown(h: Harness | null): Promise<void> {
  if (!h) return;
  h.request.stop();
  h.response.stop();
  await h.plugin.stop();
}

describe("plugin rebind cycle (issue #110)", () => {
  let harness: Harness | null = null;

  afterEach(async () => {
    await teardown(harness);
    harness = null;
  });

  it(
    "delivers first response despite forced rebind on request connect",
    async () => {
      harness = await startHarness();
      // After startHarness resolves, the fake plugin has already triggered a
      // rebind from the request-connect handler. The server's response socket
      // must reconnect to the freshly-bound listener before this call returns.
      const resp = await harness.dispatcher.call("list_collections", { limit: 5 });
      expect(resp.error).toBeUndefined();
      expect(resp.result).toEqual({
        echoed: "list_collections",
        count: 0,
        has_more: false,
      });
    },
    20_000,
  );

  it(
    "delivers many sequential responses across the post-rebind connection",
    async () => {
      harness = await startHarness();
      for (let i = 0; i < 5; i++) {
        const resp = await harness.dispatcher.call("ping", { i });
        expect(resp.error).toBeUndefined();
        expect((resp.result as { echoed: string }).echoed).toBe("ping");
      }
    },
    20_000,
  );

  it(
    "survives a 200 ms close/re-listen gap on the response port",
    async () => {
      // Forces the fake plugin to wait 200 ms between closing the response
      // listener and rebinding to the same port. On Windows the kernel may
      // hold the listen socket in a closing state across this window —
      // exposes any race in the server's reconnect path.
      harness = await startHarness({ rebindDelayMs: 200 });
      const resp = await harness.dispatcher.call("list_collections", {});
      expect(resp.error).toBeUndefined();
    },
    20_000,
  );

  it(
    "survives close/rebind on the same port with SO_REUSEADDR disabled",
    async () => {
      // Listening with `exclusive: true` turns off SO_REUSEADDR. On Windows
      // this is the closest match for SO_EXCLUSIVEADDRUSE — a closed listener's
      // port can stay in TIME_WAIT and reject an immediate rebind. If LrSocket
      // on Windows behaves this way, the response port would intermittently
      // fail to rebind and sendConnected would stay false. We test that the
      // rebind+reconnect cycle still delivers a response even in this mode.
      harness = await startHarness({ exclusivePort: true });
      const resp = await harness.dispatcher.call("list_collections", {});
      expect(resp.error).toBeUndefined();
    },
    20_000,
  );

  it(
    "delivers responses across 50 sequential rebind cycles",
    async () => {
      // Stress: each iteration triggers a response-port rebind, then issues
      // a dispatch. Any timing race in the close+rebind+reconnect cycle has
      // 50 chances to fire. Mirrors what happens under sustained churn (e.g.
      // MCP client restart loops the reporter described in issue #110).
      harness = await startHarness();
      for (let i = 0; i < 50; i++) {
        await harness.plugin.triggerRebind();
        const resp = await harness.dispatcher.call("stress", { i });
        expect(resp.error).toBeUndefined();
        expect((resp.result as { echoed: string }).echoed).toBe("stress");
      }
    },
    60_000,
  );

  it(
    "delivers responses across 50 rebind cycles with SO_REUSEADDR disabled",
    async () => {
      // Same stress as above but with `exclusive: true`. On Windows, repeated
      // rapid bind/close on the same port without SO_REUSEADDR is the
      // pathological case for TIME_WAIT collisions.
      harness = await startHarness({ exclusivePort: true });
      for (let i = 0; i < 50; i++) {
        await harness.plugin.triggerRebind();
        const resp = await harness.dispatcher.call("stress_excl", { i });
        expect(resp.error).toBeUndefined();
      }
    },
    60_000,
  );
});
