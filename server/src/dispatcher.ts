export interface PluginResponse {
  id: string;
  result?: unknown;
  error?: string;
}

interface PendingResponse {
  resolve: (resp: PluginResponse) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
}

export interface DispatcherOptions {
  send: (line: string) => boolean;
  getToken: () => string;
  timeoutMs?: number;
  /**
   * Per-action timeout overrides (ms), keyed by action name. Long-running
   * actions like batch export/import need far more than the default before a
   * healthy plugin can reply; with too short a timeout the call reports a
   * false failure, and the plugin's eventual (correct) response arrives after
   * the pending entry is gone, so it is dropped as an unknown id. Actions
   * absent here -- or mapped to a non-positive value -- use `timeoutMs`.
   */
  actionTimeoutsMs?: Record<string, number>;
  log?: (msg: string) => void;
}

export class Dispatcher {
  private pending = new Map<string, PendingResponse>();
  private idCounter = 0;
  private readonly timeoutMs: number;
  private readonly actionTimeoutsMs: Record<string, number>;
  private readonly send: (line: string) => boolean;
  private readonly getToken: () => string;
  private readonly log: (msg: string) => void;

  constructor(opts: DispatcherOptions) {
    this.send = opts.send;
    this.getToken = opts.getToken;
    this.timeoutMs = opts.timeoutMs ?? 30_000;
    this.actionTimeoutsMs = opts.actionTimeoutsMs ?? {};
    this.log = opts.log ?? ((msg: string) => console.error(msg));
  }

  handleResponseLine(line: string): void {
    let resp: PluginResponse;
    try {
      resp = JSON.parse(line) as PluginResponse;
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      this.log(`Bad JSON from plugin (${msg}): ${line}`);
      return;
    }
    const p = this.pending.get(resp.id);
    if (!p) {
      this.log(`Response for unknown id: ${resp.id}`);
      return;
    }
    clearTimeout(p.timer);
    this.pending.delete(resp.id);
    p.resolve(resp);
  }

  async call(action: string, params: unknown): Promise<PluginResponse> {
    const id = `req_${Date.now()}_${this.idCounter++}`;
    // A non-positive override means "no override": `0` would otherwise arm a
    // 0 ms timer that rejects on the next tick.
    const override = this.actionTimeoutsMs[action];
    const timeoutMs = override !== undefined && override > 0 ? override : this.timeoutMs;

    const responsePromise = new Promise<PluginResponse>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Plugin response timeout (${timeoutMs / 1000}s)`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
    });

    const cleanup = () => {
      const p = this.pending.get(id);
      if (p) clearTimeout(p.timer);
      this.pending.delete(id);
    };

    let payload: string;
    try {
      payload = JSON.stringify({ hello: this.getToken(), id, action, params: params ?? {} });
    } catch (err) {
      cleanup();
      throw err;
    }

    if (!this.send(payload)) {
      cleanup();
      throw new Error("Failed to send request to plugin (socket dropped)");
    }

    return responsePromise;
  }

  pendingCount(): number {
    return this.pending.size;
  }
}
