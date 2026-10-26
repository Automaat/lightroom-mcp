export interface ToolProgress {
  progress: number;
  total?: number;
  message?: string;
}

export interface CallOptions {
  signal?: AbortSignal;
  onProgress?: (progress: ToolProgress) => void;
}

export interface PluginResponse {
  id: string;
  result?: unknown;
  error?: string;
}

interface PendingResponse {
  resolve: (resp: PluginResponse) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
  onProgress?: (progress: ToolProgress) => void;
  cleanup: () => void;
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
    const event = resp as unknown as { progressFor?: string; progress?: ToolProgress };
    if (event.progressFor && event.progress) {
      this.pending.get(event.progressFor)?.onProgress?.(event.progress);
      return;
    }
    const p = this.pending.get(resp.id);
    if (!p) {
      this.log(`Response for unknown id: ${resp.id}`);
      return;
    }
    clearTimeout(p.timer);
    p.cleanup();
    this.pending.delete(resp.id);
    p.resolve(resp);
  }

  async call(action: string, params: unknown, timeoutOverrideMs?: number, options?: CallOptions): Promise<PluginResponse> {
    const id = `req_${Date.now()}_${this.idCounter++}`;
    // A non-positive override means "no override": `0` would otherwise arm a
    // 0 ms timer that rejects on the next tick.
    const override = timeoutOverrideMs ?? this.actionTimeoutsMs[action];
    const timeoutMs = override !== undefined && override > 0 ? override : this.timeoutMs;

    if (options?.signal?.aborted) throw new Error("Request cancelled");
    const cancel = () => {
      if (this.pending.has(id)) {
        this.send(JSON.stringify({ hello: this.getToken(), action: "cancel", params: { request_id: id } }));
      }
    };
    const responsePromise = new Promise<PluginResponse>((resolve, reject) => {
      const timer = setTimeout(() => {
        options?.signal?.removeEventListener("abort", cancel);
        this.pending.delete(id);
        reject(new Error(`Plugin response timeout (${timeoutMs / 1000}s)`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer, onProgress: options?.onProgress,
        cleanup: () => options?.signal?.removeEventListener("abort", cancel) });
      options?.signal?.addEventListener("abort", cancel, { once: true });
    });

    const cleanup = () => {
      const p = this.pending.get(id);
      if (p) { clearTimeout(p.timer); p.cleanup(); }
      this.pending.delete(id);
    };

    let payload: string;
    try {
      payload = JSON.stringify({ hello: this.getToken(), id, action, params: params ?? {}, reportProgress: Boolean(options?.onProgress) });
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
