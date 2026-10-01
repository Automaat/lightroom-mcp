import { BrokerClient, BrokerServer, type ToolCaller } from "./broker.js";
import { LockHeldError, type InstanceLock } from "./instance-lock.js";
import type { ToolResponse } from "./tool-handler.js";

export interface Leader {
  callTool: ToolCaller;
  stop: () => void;
}

export interface BridgeOptions {
  ipcPath: string;
  acquireLock: () => InstanceLock;
  startLeader: () => Leader;
  readToken: () => string | null;
  retryMs?: number;
  readyWaitMs?: number;
  log?: (msg: string) => void;
}

export type BridgeRole = "none" | "leader" | "follower";

export const NO_OWNER_MESSAGE =
  "No Lightroom MCP bridge owns the plugin connection yet. Retry in a few seconds.";

export function unreachableOwnerMessage(pid: number): string {
  return (
    `Lightroom MCP bridge pid ${pid} holds the plugin connection but does not accept ` +
    "other bridges, most likely an older lightroom-mcp version. Quit or update that " +
    "MCP client, then retry."
  );
}

type RoleState =
  | { kind: "none" }
  | { kind: "leader"; leader: Leader; server: BrokerServer; lock: InstanceLock }
  | { kind: "follower"; client: BrokerClient };

/**
 * Elects one bridge per port pair to own the plugin connection. The lock
 * holder becomes the leader and serves the others; followers forward tool
 * calls and re-run the election when the leader goes away.
 */
export class Bridge {
  private state: RoleState = { kind: "none" };
  private retryTimer: NodeJS.Timeout | null = null;
  private stopped = false;
  private started: Promise<void> | null = null;
  private unreachableOwner: number | null = null;
  private lockError: string | null = null;
  private waiters: Array<() => void> = [];
  private readonly retryMs: number;
  private readonly readyWaitMs: number;
  private readonly log: (msg: string) => void;

  constructor(private readonly opts: BridgeOptions) {
    this.retryMs = opts.retryMs ?? 200;
    this.readyWaitMs = opts.readyWaitMs ?? 10_000;
    this.log = opts.log ?? ((msg: string) => console.error(msg));
  }

  /**
   * Idempotent. Deferred until the MCP client initializes (or first calls a
   * tool) so short-lived host probes never claim the plugin connection.
   */
  start(): Promise<void> {
    this.started ??= this.elect();
    return this.started;
  }

  role(): BridgeRole {
    return this.state.kind;
  }

  async callTool(name: string, args: unknown): Promise<ToolResponse> {
    await this.start();
    if (this.state.kind === "none") await this.waitForRole();
    switch (this.state.kind) {
      case "leader":
        return this.state.leader.callTool(name, args);
      case "follower":
        return this.state.client.callTool(name, args);
      case "none":
        return { content: [{ type: "text", text: this.noOwnerMessage() }], isError: true };
    }
  }

  private noOwnerMessage(): string {
    if (this.unreachableOwner !== null) return unreachableOwnerMessage(this.unreachableOwner);
    if (this.lockError !== null) return `${NO_OWNER_MESSAGE} Last error: ${this.lockError}`;
    return NO_OWNER_MESSAGE;
  }

  stop(): void {
    this.stopped = true;
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.retryTimer = null;
    const state = this.state;
    this.state = { kind: "none" };
    if (state.kind === "leader") {
      state.server.close();
      state.leader.stop();
      state.lock.release();
    } else if (state.kind === "follower") {
      state.client.close();
    }
    this.notify();
  }

  private async elect(): Promise<void> {
    if (this.stopped) return;
    let lock: InstanceLock | null = null;
    let holder: number | null = null;
    try {
      lock = this.opts.acquireLock();
    } catch (err) {
      if (err instanceof LockHeldError) {
        holder = err.pid;
        this.lockError = null;
      } else {
        this.noteLockError((err as Error).message);
      }
    }
    if (lock) {
      this.unreachableOwner = null;
      this.lockError = null;
      await this.lead(lock);
    } else {
      await this.follow(holder);
    }
  }

  private async lead(lock: InstanceLock): Promise<void> {
    let leader: Leader;
    try {
      leader = this.opts.startLeader();
    } catch (err) {
      this.log(`[bridge] failed to start as owner: ${(err as Error).message}`);
      lock.release();
      this.scheduleElection();
      return;
    }
    const server = new BrokerServer({
      path: this.opts.ipcPath,
      callTool: leader.callTool,
      readToken: this.opts.readToken,
      log: this.log,
    });
    try {
      await server.listen();
    } catch (err) {
      this.log(`[bridge] failed to serve other bridges: ${(err as Error).message}`);
      leader.stop();
      lock.release();
      this.scheduleElection();
      return;
    }
    if (this.stopped) {
      server.close();
      leader.stop();
      lock.release();
      return;
    }
    this.state = { kind: "leader", leader, server, lock };
    this.log("[bridge] owning the plugin connection");
    this.notify();
  }

  private async follow(holder: number | null): Promise<void> {
    const client = new BrokerClient({
      path: this.opts.ipcPath,
      readToken: this.opts.readToken,
      onClose: () => {
        if (this.state.kind !== "follower" || this.state.client !== client) return;
        this.state = { kind: "none" };
        this.log("[bridge] owning bridge went away, re-electing");
        this.scheduleElection();
      },
    });
    try {
      await client.connect();
    } catch {
      this.unreachableOwner = holder;
      this.scheduleElection();
      return;
    }
    this.unreachableOwner = null;
    if (this.stopped) {
      client.close();
      return;
    }
    this.state = { kind: "follower", client };
    this.log("[bridge] another bridge owns the plugin connection, forwarding to it");
    this.notify();
  }

  private noteLockError(message: string): void {
    if (message !== this.lockError) this.log(`[bridge] cannot take the bridge lock: ${message}`);
    this.lockError = message;
  }

  /** Jittered so followers orphaned together do not race for the lock in step. */
  private scheduleElection(): void {
    if (this.stopped || this.retryTimer) return;
    const delay = this.retryMs + Math.random() * this.retryMs;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      void this.elect();
    }, delay);
  }

  private waitForRole(): Promise<void> {
    return new Promise((resolve) => {
      const timer = setTimeout(done, this.readyWaitMs);
      const waiter = () => done();
      function done() {
        clearTimeout(timer);
        resolve();
      }
      this.waiters.push(waiter);
    });
  }

  private notify(): void {
    const waiters = this.waiters;
    this.waiters = [];
    for (const w of waiters) w();
  }
}
