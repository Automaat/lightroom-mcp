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
  log?: (msg: string) => void;
}

export class Dispatcher {
  private pending = new Map<string, PendingResponse>();
  private idCounter = 0;
  private readonly timeoutMs: number;
  private readonly send: (line: string) => boolean;
  private readonly getToken: () => string;
  private readonly log: (msg: string) => void;

  constructor(opts: DispatcherOptions) {
    this.send = opts.send;
    this.getToken = opts.getToken;
    this.timeoutMs = opts.timeoutMs ?? 30_000;
    this.log = opts.log ?? ((msg: string) => console.error(msg));
  }

  handleResponseLine(line: string): void {
    let resp: PluginResponse;
    try {
      resp = JSON.parse(line) as PluginResponse;
    } catch {
      this.log(`Bad JSON from plugin: ${line}`);
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

    const responsePromise = new Promise<PluginResponse>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Plugin response timeout (${this.timeoutMs / 1000}s)`));
      }, this.timeoutMs);
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
