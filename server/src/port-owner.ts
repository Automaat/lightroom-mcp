import { execFile } from "node:child_process";
import { SHADOW_BRIDGE_MESSAGE } from "./plugin-liveness.js";

export interface PortListener {
  pid: number;
  command?: string;
}

export type RunCommand = (file: string, args: string[]) => Promise<string>;

const COMMAND_TIMEOUT_MS = 3_000;

/**
 * Resolves with stdout even on a non-zero exit that still printed output;
 * lsof exits 1 when nothing matches, which is an answer, not a failure.
 */
export const runCommand: RunCommand = (file, args) =>
  new Promise((resolve, reject) => {
    execFile(file, args, { timeout: COMMAND_TIMEOUT_MS, windowsHide: true }, (err, stdout) => {
      if (err && !stdout) {
        reject(err);
        return;
      }
      resolve(stdout);
    });
  });

/** Parses `lsof -F pc` output: one `p<pid>` line followed by its `c<command>`. */
export function parseLsofListeners(output: string): PortListener[] {
  const listeners: PortListener[] = [];
  for (const line of output.split(/\r?\n/)) {
    if (line.startsWith("p")) {
      const pid = Number(line.slice(1));
      if (Number.isInteger(pid) && pid > 0) listeners.push({ pid });
    } else if (line.startsWith("c") && listeners.length > 0) {
      listeners[listeners.length - 1].command = line.slice(1);
    }
  }
  return listeners;
}

interface NetstatRow {
  local: string;
  foreign: string;
  pid: number;
}

/**
 * Parses TCP rows of `netstat -ano`. The state column is localized (e.g.
 * ABHÖREN on German Windows), so rows are told apart by address instead.
 */
function parseNetstatRows(output: string): NetstatRow[] {
  const rows: NetstatRow[] = [];
  for (const line of output.split(/\r?\n/)) {
    const cols = line.trim().split(/\s+/);
    if (cols.length < 5 || cols[0] !== "TCP") continue;
    const pid = Number(cols[cols.length - 1]);
    if (!Number.isInteger(pid) || pid <= 0) continue;
    rows.push({ local: cols[1], foreign: cols[2], pid });
  }
  return rows;
}

/** Extracts the PIDs listening on `port` (foreign address `*:0`) from `netstat -ano`. */
export function parseNetstatListeners(output: string, port: number): number[] {
  const rows = parseNetstatRows(output).filter(
    (r) => r.local.endsWith(`:${port}`) && r.foreign.endsWith(":0"),
  );
  return [...new Set(rows.map((r) => r.pid))];
}

/**
 * Parses `lsof -F pcn` output for processes whose connection's remote end is
 * `port`, i.e. clients of whatever listens there.
 */
export function parseLsofClients(output: string, port: number): PortListener[] {
  const clients = new Map<number, PortListener>();
  let current: PortListener | null = null;
  for (const line of output.split(/\r?\n/)) {
    if (line.startsWith("p")) {
      const pid = Number(line.slice(1));
      current = Number.isInteger(pid) && pid > 0 ? { pid } : null;
    } else if (line.startsWith("c") && current) {
      current.command = line.slice(1);
    } else if (line.startsWith("n") && current && line.endsWith(`->127.0.0.1:${port}`)) {
      clients.set(current.pid, current);
    }
  }
  return [...clients.values()];
}

/** Extracts the PIDs with a connection whose remote end is `port` from `netstat -ano`. */
export function parseNetstatClients(output: string, port: number): number[] {
  const rows = parseNetstatRows(output).filter((r) => r.foreign.endsWith(`:${port}`));
  return [...new Set(rows.map((r) => r.pid))];
}

/** Maps PID to image name from `tasklist /FO CSV /NH` output. */
export function parseTasklist(output: string): Map<number, string> {
  const names = new Map<number, string>();
  for (const line of output.split(/\r?\n/)) {
    const match = /^"([^"]+)","(\d+)"/.exec(line.trim());
    if (match) names.set(Number(match[2]), match[1]);
  }
  return names;
}

async function windowsProcessNames(run: RunCommand): Promise<Map<number, string>> {
  try {
    return parseTasklist(await run("tasklist", ["/FO", "CSV", "/NH"]));
  } catch {
    return new Map();
  }
}

/**
 * Finds the process listening on a local TCP port. Returns null when nothing
 * listens or the platform tool is unavailable -- this is a diagnostic, so any
 * failure degrades to "unknown" rather than throwing. `+c 0` keeps lsof from
 * truncating "Adobe Lightroom Classic" to "Adobe\x20".
 */
export async function findPortListener(
  port: number,
  platform: NodeJS.Platform = process.platform,
  run: RunCommand = runCommand,
): Promise<PortListener | null> {
  try {
    if (platform === "win32") {
      const [pid] = parseNetstatListeners(await run("netstat", ["-ano", "-p", "TCP"]), port);
      if (pid === undefined) return null;
      return { pid, command: (await windowsProcessNames(run)).get(pid) };
    }
    const [listener] = parseLsofListeners(
      await run("lsof", ["+c", "0", "-nP", `-iTCP:${port}`, "-sTCP:LISTEN", "-Fpc"]),
    );
    return listener ?? null;
  } catch {
    return null;
  }
}

/**
 * Lists processes other than `selfPid` connected to a local TCP port. Returns
 * null when the platform tool is unavailable, so callers can tell "nobody"
 * apart from "could not check".
 */
export async function findPortClients(
  port: number,
  selfPid: number = process.pid,
  platform: NodeJS.Platform = process.platform,
  run: RunCommand = runCommand,
): Promise<PortListener[] | null> {
  try {
    let clients: PortListener[];
    if (platform === "win32") {
      const pids = parseNetstatClients(await run("netstat", ["-ano", "-p", "TCP"]), port);
      const names = pids.length > 0 ? await windowsProcessNames(run) : new Map<number, string>();
      clients = pids.map((pid) => ({ pid, command: names.get(pid) }));
    } else {
      clients = parseLsofClients(
        await run("lsof", ["+c", "0", "-nP", `-iTCP:${port}`, "-sTCP:ESTABLISHED", "-Fpcn"]),
        port,
      );
    }
    return clients.filter((c) => c.pid !== selfPid);
  } catch {
    return null;
  }
}

function isLightroom(listener: PortListener): boolean {
  return /lightroom/i.test(listener.command ?? "");
}

export interface PortOwnership {
  port: number;
  listener: PortListener | null;
  /** Other processes connected to the port; null when unknown. */
  otherClients: PortListener[] | null;
}

const PORT_CHANGE_HINT =
  "pick free ports in Lightroom's Plug-in Manager and set the same values in " +
  "LIGHTROOM_MCP_REQUEST_PORT / LIGHTROOM_MCP_RESPONSE_PORT";

/**
 * Another Lightroom plugin binding the same ports (MIDI2LR does, from inside
 * Lightroom) is indistinguishable from our own plugin at the socket level, so
 * every Lightroom-owned verdict has to name it as a possibility.
 */
const SAME_PORT_PLUGIN_HINT =
  "another Lightroom plugin bound to the same ports (MIDI2LR uses 58763/58764)";

export const STALE_LISTENER_MESSAGE =
  "Lightroom owns the plugin's ports but is not answering, and no other client is connected. " +
  `Likely causes: ${SAME_PORT_PLUGIN_HINT}, a listener left behind by 'Reload Plug-in', or a stuck plugin. ` +
  `Restart Lightroom Classic; if that does not help, ${PORT_CHANGE_HINT}.`;

interface ForeignOwnership extends PortOwnership {
  listener: PortListener;
}

function isForeign(p: PortOwnership): p is ForeignOwnership {
  return p.listener !== null && !isLightroom(p.listener);
}

function describeProcess(p: PortListener): string {
  return `${p.command ?? "an unknown process"} (pid ${p.pid})`;
}

function describeOwner({ port, listener }: ForeignOwnership): string {
  return `port ${port} is held by ${describeProcess(listener)}`;
}

/**
 * Explains why a connected plugin is not answering. A foreign process bound to
 * a plugin port accepts the bridge's connection itself, so requests or
 * responses silently go to it instead of Lightroom (issue 225). When
 * Lightroom owns the ports, the listener may still not be ours: another
 * plugin can hold them, or a pre-reload instance of this one.
 */
export function describeUnresponsive(ports: PortOwnership[]): string {
  const foreign = ports.filter(isForeign);
  if (foreign.length > 0) {
    return (
      `Connected, but not to Lightroom: ${foreign.map(describeOwner).join("; ")}. ` +
      "The Lightroom plugin cannot bind a port another process already owns, so the bridge talks to that process instead. " +
      `Quit it, or ${PORT_CHANGE_HINT}.`
    );
  }
  const ownedByLightroom = ports.every((p) => p.listener && isLightroom(p.listener));
  if (!ownedByLightroom) return SHADOW_BRIDGE_MESSAGE;
  if (ports.some((p) => p.otherClients === null)) return SHADOW_BRIDGE_MESSAGE;
  const others = new Map<number, PortListener>();
  for (const client of ports.flatMap((p) => p.otherClients ?? [])) others.set(client.pid, client);
  if (others.size === 0) return STALE_LISTENER_MESSAGE;
  return (
    "Lightroom owns the plugin's ports but is not answering. Other processes are connected to them: " +
    `${[...others.values()].map(describeProcess).join(", ")}. ` +
    "If one is another lightroom-mcp bridge, quit it (pgrep -fl lightroom-mcp). " +
    `If one belongs to ${SAME_PORT_PLUGIN_HINT}, ${PORT_CHANGE_HINT}.`
  );
}

export interface PortInspector {
  listener: (port: number) => Promise<PortListener | null>;
  otherClients: (port: number) => Promise<PortListener[] | null>;
}

const systemInspector: PortInspector = {
  listener: (port) => findPortListener(port),
  otherClients: (port) => findPortClients(port),
};

export async function diagnoseUnresponsive(
  ports: number[],
  inspect: PortInspector = systemInspector,
): Promise<string> {
  const ownership = await Promise.all(
    ports.map(async (port) => ({
      port,
      listener: await inspect.listener(port),
      otherClients: await inspect.otherClients(port),
    })),
  );
  return describeUnresponsive(ownership);
}

export const DIAGNOSIS_REFRESH_MS = 60_000;

/**
 * Owns the "why is the plugin not answering" verdict for one outage. The
 * recovery probe fires every few seconds while the plugin is down; each
 * inspection spawns several lsof/netstat processes, so the verdict is reused
 * for DIAGNOSIS_REFRESH_MS and only re-derived after that (or after recovery).
 */
export class UnresponsiveReporter {
  private message = SHADOW_BRIDGE_MESSAGE;
  private diagnosedAt: number | null = null;
  private inFlight: Promise<void> | null = null;

  private readonly diagnose: () => Promise<string>;
  private readonly log: (msg: string) => void;
  private readonly refreshMs: number;
  private readonly now: () => number;

  constructor(opts: {
    diagnose: () => Promise<string>;
    log: (msg: string) => void;
    refreshMs?: number;
    now?: () => number;
  }) {
    this.diagnose = opts.diagnose;
    this.log = opts.log;
    this.refreshMs = opts.refreshMs ?? DIAGNOSIS_REFRESH_MS;
    this.now = opts.now ?? Date.now;
  }

  current(): string {
    return this.message;
  }

  report(): void {
    if (this.inFlight) return;
    if (this.diagnosedAt !== null && this.now() - this.diagnosedAt < this.refreshMs) {
      this.log(this.message);
      return;
    }
    this.inFlight = this.diagnose()
      .then((message) => {
        this.message = message;
        this.diagnosedAt = this.now();
        this.log(message);
      })
      .finally(() => {
        this.inFlight = null;
      });
  }

  /** Resolves once a running diagnosis has produced its verdict. */
  async settled(): Promise<void> {
    await this.inFlight;
  }

  /** Forgets the verdict once the plugin answers again. */
  clear(): void {
    this.diagnosedAt = null;
    this.message = SHADOW_BRIDGE_MESSAGE;
  }
}
