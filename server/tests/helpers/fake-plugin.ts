// Node-side mimic of the Lua plugin's LrSocket dual-port state machine.
// Goal: exercise the close+rebind-on-each-request-connect dance against the
// real PluginSocket/Dispatcher, on every OS the CI matrix runs on, so we can
// surface Windows-only TCP lifecycle races (issue #110) without Lightroom.
//
// Mirrors plugin/LightroomMCP.lrplugin/PluginInfoProvider.lua:
//   - request port: TCP server, single client accepted at a time
//   - response port: TCP server, single client accepted at a time
//   - each new request-side client connect schedules a response-side rebind
//   - sendConnected gates the response send; if false at handler completion,
//     wait up to sendWaitMs, then drop with a "send socket disconnected" log
//   - dispatch runs after token check; response carries the request id

import net from "node:net";

export interface FakePluginOptions {
  requestPort: number;
  responsePort: number;
  token: string;
  handler: (action: string, params: unknown) => unknown | Promise<unknown>;
  // Sleep between close and re-listen. The real plugin runs the close+bind
  // back-to-back in the monitor loop tick. Configurable so we can stress
  // the kernel port-reuse window.
  rebindDelayMs?: number;
  // Max wait inside "sendResponse" for sendConnected to become true.
  sendWaitMs?: number;
  // If true, listen() runs with `exclusive: true` which disables SO_REUSEADDR.
  // On Windows this surfaces TIME_WAIT collisions during close+rebind on the
  // same port — closest Node knob we have to LrSocket's Win32 socket
  // semantics. Default false (Node's normal behavior).
  exclusivePort?: boolean;
  log?: (msg: string) => void;
}

export interface FakePluginEvent {
  ts: number;
  kind: string;
  detail?: string;
}

export class FakePlugin {
  private readonly host = "127.0.0.1";
  private readonly opts: Required<Omit<FakePluginOptions, "log" | "exclusivePort">> & {
    log: (msg: string) => void;
    exclusivePort: boolean;
  };

  private requestServer: net.Server | null = null;
  private responseServer: net.Server | null = null;
  private requestClient: net.Socket | null = null;
  private responseClient: net.Socket | null = null;
  private requestBuf = "";
  private sendConnected = false;
  // Bumped on every rebind. Pending rebind tasks compare against this so
  // a stale rebind initiated for an old session does not race with a fresh
  // one. Mirrors the responseGen / isLive guard in the Lua plugin.
  private responseGen = 0;
  private stopped = false;
  public readonly events: FakePluginEvent[] = [];

  constructor(opts: FakePluginOptions) {
    this.opts = {
      requestPort: opts.requestPort,
      responsePort: opts.responsePort,
      token: opts.token,
      handler: opts.handler,
      rebindDelayMs: opts.rebindDelayMs ?? 0,
      sendWaitMs: opts.sendWaitMs ?? 25_000,
      exclusivePort: opts.exclusivePort ?? false,
      log: opts.log ?? (() => {}),
    };
  }

  private event(kind: string, detail?: string): void {
    const evt = { ts: Date.now(), kind, detail };
    this.events.push(evt);
    this.opts.log(`[fake] ${kind}${detail ? ` ${detail}` : ""}`);
  }

  async start(): Promise<void> {
    this.responseServer = await this.bindResponse();
    this.requestServer = await this.bindRequest();
  }

  private bindResponse(): Promise<net.Server> {
    this.responseGen++;
    const myGen = this.responseGen;
    const srv = net.createServer({ allowHalfOpen: false }, (client) => {
      if (this.responseGen !== myGen) {
        // Stale listener accepted a connection between close() returning and
        // the kernel actually retiring the listen socket. Drop it.
        this.event("response_stale_accept");
        client.destroy();
        return;
      }
      this.responseClient = client;
      this.sendConnected = true;
      this.event("response_connected");
      client.on("close", () => {
        if (this.responseClient === client) {
          this.responseClient = null;
          this.sendConnected = false;
          this.event("response_client_closed");
        }
      });
      client.on("error", () => {
        // swallow — close handler covers cleanup
      });
    });
    return new Promise((resolve, reject) => {
      srv.once("error", reject);
      srv.listen(
        {
          port: this.opts.responsePort,
          host: this.host,
          exclusive: this.opts.exclusivePort,
        },
        () => {
          srv.off("error", reject);
          this.event("response_bound", `gen=${myGen}`);
          resolve(srv);
        },
      );
    });
  }

  // Externally-triggered rebind for stress tests. Mirrors what happens
  // internally when a new request-side client connects, but lets a test
  // drive many rebind cycles against the same long-lived connection.
  async triggerRebind(): Promise<void> {
    await this.rebindResponse();
  }

  private async rebindResponse(): Promise<void> {
    if (this.stopped) return;
    const old = this.responseServer;
    const oldClient = this.responseClient;
    this.responseClient = null;
    this.sendConnected = false;
    if (oldClient) oldClient.destroy();
    if (old) {
      await new Promise<void>((resolve) => old.close(() => resolve()));
    }
    if (this.opts.rebindDelayMs > 0) {
      await new Promise((r) => setTimeout(r, this.opts.rebindDelayMs));
    }
    if (this.stopped) return;
    this.responseServer = await this.bindResponse();
    this.event("response_rebound");
  }

  private bindRequest(): Promise<net.Server> {
    const srv = net.createServer((client) => {
      if (this.requestClient) {
        // Plugin only accepts one request client at a time.
        this.event("request_extra_rejected");
        client.destroy();
        return;
      }
      this.requestClient = client;
      this.requestBuf = "";
      client.setEncoding("utf8");
      this.event("request_connected");
      // Mirror Lua plugin: every new request-side client triggers a
      // response-side rebind. This is the load-bearing fragile move that
      // issue #110 stress-tests on Windows.
      void this.rebindResponse();

      client.on("data", (chunk: string) => {
        this.requestBuf += chunk;
        let idx: number;
        while ((idx = this.requestBuf.indexOf("\n")) !== -1) {
          const line = this.requestBuf.slice(0, idx);
          this.requestBuf = this.requestBuf.slice(idx + 1);
          if (line.trim()) void this.handleMessage(line);
        }
      });
      client.on("close", () => {
        if (this.requestClient === client) {
          this.requestClient = null;
          this.event("request_client_closed");
        }
      });
      client.on("error", () => {
        // swallow
      });
    });
    return new Promise((resolve, reject) => {
      srv.once("error", reject);
      srv.listen(
        {
          port: this.opts.requestPort,
          host: this.host,
          exclusive: this.opts.exclusivePort,
        },
        () => {
          srv.off("error", reject);
          this.event("request_bound");
          resolve(srv);
        },
      );
    });
  }

  private async handleMessage(line: string): Promise<void> {
    let req: { hello?: string; id?: string; action?: string; params?: unknown };
    try {
      req = JSON.parse(line) as { hello?: string; id?: string; action?: string; params?: unknown };
    } catch {
      this.event("bad_json");
      return;
    }
    if (req.hello !== this.opts.token) {
      this.event("auth_fail", req.id ?? "");
      return;
    }
    if (typeof req.id !== "string" || typeof req.action !== "string") {
      return;
    }

    let result: unknown;
    let error: string | undefined;
    try {
      result = await this.opts.handler(req.action, req.params);
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    }

    await this.sendResponse(req.id, { id: req.id, result, error });
  }

  private async sendResponse(id: string, payload: object): Promise<void> {
    const deadline = Date.now() + this.opts.sendWaitMs;
    while (!this.sendConnected && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 50));
    }
    if (!this.sendConnected || !this.responseClient) {
      this.event(
        "drop_response",
        `id=${id} waited=${this.opts.sendWaitMs}ms`,
      );
      return;
    }
    this.responseClient.write(JSON.stringify(payload) + "\n");
    this.event("response_sent", `id=${id}`);
  }

  async stop(): Promise<void> {
    this.stopped = true;
    this.responseClient?.destroy();
    this.requestClient?.destroy();
    await Promise.all([
      this.responseServer
        ? new Promise<void>((r) => this.responseServer!.close(() => r()))
        : Promise.resolve(),
      this.requestServer
        ? new Promise<void>((r) => this.requestServer!.close(() => r()))
        : Promise.resolve(),
    ]);
    this.responseServer = null;
    this.requestServer = null;
  }
}

export function freePort(): Promise<number> {
  return new Promise((resolve) => {
    const srv = net.createServer();
    srv.listen(0, () => {
      const addr = srv.address();
      const port = typeof addr === "object" && addr ? addr.port : 0;
      srv.close(() => resolve(port));
    });
  });
}
