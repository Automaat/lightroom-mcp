import { BrokerClient, BrokerServer, type ToolCaller } from "./broker.js";
import { LockHeldError, type InstanceLock } from "./instance-lock.js";
import type { CallOptions } from "./dispatcher.js";
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
  /** True when the lock holder stopped beating; followers then re-elect. */
  holderUnresponsive?: () => boolean;
  /** The pid the lock names now; a follower whose owner lost the lock re-elects. */
  lockHolder?: () => number | null;
  holderCheckMs?: number;
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
  | { kind: "follower"; client: BrokerClient; watch: NodeJS.Timeout | null };

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
  private readonly holderCheckMs: number;
  private readonly log: (msg: string) => void;

  constructor(private readonly opts: BridgeOptions) {
    this.retryMs = opts.retryMs ?? 200;
    this.readyWaitMs = opts.readyWaitMs ?? 10_000;
    this.holderCheckMs = opts.holderCheckMs ?? 5_000;
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

  async callTool(name: string, args: unknown, options?: CallOptions): Promise<ToolResponse> {
    await this.start();
    if (this.state.kind === "none") await this.waitForRole();
    switch (this.state.kind) {
      case "leader":
        return this.state.leader.callTool(name, args, options);
      case "follower":
        return this.state.client.callTool(name, args, options);
      case "none":
        return this.noOwnerResponse();
    }
  }

  private noOwnerResponse(): ToolResponse {
    return { content: [{ type: "text", text: this.noOwnerMessage() }], isError: true };
  }

  private noOwnerMessage(): string {
    if (this.unreachableOwner !== null) return unreachableOwnerMessage(this.unreachableOwner);
    if (this.lockError !== null) return `${NO_OWNER_MESSAGE} Last error: ${this.lockError}`;
    return NO_OWNER_MESSAGE;
  }

  /**
   * Stops once the calls other bridges forwarded here have finished, so a
   * leader whose own client exits does not throw away their results. Gives
   * up after graceMs; calls still running then get the owner-lost error.
   */
  async shutdown(graceMs: number): Promise<void> {
    if (this.state.kind === "leader") {
      const pending = this.state.server.inFlightCalls();
      if (pending > 0) {
        this.log(`[bridge] finishing ${pending} call(s) from other bridges before exiting`);
        if (!(await this.state.server.whenIdle(graceMs))) {
          this.log("[bridge] calls from other bridges still running, exiting anyway");
        }
      }
    }
    this.stop();
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
      if (state.watch) clearInterval(state.watch);
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
    let callTool: ToolCaller = async () => this.noOwnerResponse();
    const server = new BrokerServer({
      path: this.opts.ipcPath,
      callTool: (name, args, options) => callTool(name, args, options),
      readToken: this.opts.readToken,
      log: this.log,
    });
    // Listen before taking the plugin: a bridge that cannot serve the others
    // (a hung owner still holds the named pipe) must not churn its sockets.
    try {
      await server.listen();
    } catch (err) {
      this.log(`[bridge] failed to serve other bridges: ${(err as Error).message}`);
      lock.release();
      this.scheduleElection();
      return;
    }
    if (this.stopped) {
      server.close();
      lock.release();
      return;
    }
    let leader: Leader;
    try {
      leader = this.opts.startLeader();
    } catch (err) {
      this.log(`[bridge] failed to start as owner: ${(err as Error).message}`);
      server.close();
      lock.release();
      this.scheduleElection();
      return;
    }
    callTool = leader.callTool;
    this.state = { kind: "leader", leader, server, lock };
    this.log("[bridge] owning the plugin connection");
    lock.onLost(() => this.stepDown(lock));
    this.notify();
  }

  /** Another bridge reclaimed the lock while this one was stalled; leave the plugin to it. */
  private stepDown(lock: InstanceLock): void {
    const state = this.state;
    if (state.kind !== "leader" || state.lock !== lock) return;
    this.log("[bridge] another bridge took over the plugin connection, stepping down");
    this.state = { kind: "none" };
    state.server.abandon();
    state.leader.stop();
    lock.release();
    this.scheduleElection();
  }

  private async follow(holder: number | null): Promise<void> {
    const client = new BrokerClient({
      path: this.opts.ipcPath,
      readToken: this.opts.readToken,
      onClose: () => {
        if (this.state.kind !== "follower" || this.state.client !== client) return;
        if (this.state.watch) clearInterval(this.state.watch);
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
    this.state = { kind: "follower", client, watch: this.watchHolder(client, holder) };
    this.log("[bridge] another bridge owns the plugin connection, forwarding to it");
    this.notify();
  }

  /**
   * A hung owner keeps its IPC socket open, so onClose never fires; drop it
   * once its heartbeat goes stale, or once another follower has reclaimed
   * its lock, and let the election sort out the new owner.
   */
  private watchHolder(client: BrokerClient, holder: number | null): NodeJS.Timeout | null {
    const { holderUnresponsive, lockHolder } = this.opts;
    if (!holderUnresponsive && !lockHolder) return null;
    let strikes = 0;
    const watch = setInterval(() => {
      const current = lockHolder?.() ?? null;
      const moved = holder !== null && current !== null && current !== holder;
      strikes = holderUnresponsive?.() ? strikes + 1 : 0;
      // Two in a row: after a sleep the owner's overdue beat may just not have run yet.
      if (!moved && strikes < 2) return;
      clearInterval(watch);
      this.log(
        moved
          ? "[bridge] another bridge took over from the owning bridge, re-electing"
          : "[bridge] owning bridge stopped responding, re-electing",
      );
      client.close();
    }, this.holderCheckMs);
    watch.unref();
    return watch;
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
      const waiter = () => {
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w !== waiter);
        resolve();
      }, this.readyWaitMs);
      this.waiters.push(waiter);
    });
  }

  /** Waiters still parked for a role; exposed for leak tests. */
  pendingWaiters(): number {
    return this.waiters.length;
  }

  private notify(): void {
    const waiters = this.waiters;
    this.waiters = [];
    for (const w of waiters) w();
  }
}
