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
const runCommand: RunCommand = (file, args) =>
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

/** Extracts the PIDs of LISTENING TCP sockets on `port` from `netstat -ano`. */
export function parseNetstatListeners(output: string, port: number): number[] {
  const pids = new Set<number>();
  for (const line of output.split(/\r?\n/)) {
    const cols = line.trim().split(/\s+/);
    if (cols.length < 5 || cols[0] !== "TCP" || cols[3] !== "LISTENING") continue;
    if (!cols[1].endsWith(`:${port}`)) continue;
    const pid = Number(cols[4]);
    if (Number.isInteger(pid) && pid > 0) pids.add(pid);
  }
  return [...pids];
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

/** Extracts the PIDs of ESTABLISHED TCP connections to `port` from `netstat -ano`. */
export function parseNetstatClients(output: string, port: number): number[] {
  const pids = new Set<number>();
  for (const line of output.split(/\r?\n/)) {
    const cols = line.trim().split(/\s+/);
    if (cols.length < 5 || cols[0] !== "TCP" || cols[3] !== "ESTABLISHED") continue;
    if (!cols[2].endsWith(`:${port}`)) continue;
    const pid = Number(cols[4]);
    if (Number.isInteger(pid) && pid > 0) pids.add(pid);
  }
  return [...pids];
}

/** Extracts the image name from `tasklist /FO CSV /NH` output. */
export function parseTasklistName(output: string): string | undefined {
  const match = /^"([^"]+)"/.exec(output.trim());
  return match?.[1];
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
      const name = parseTasklistName(
        await run("tasklist", ["/FI", `PID eq ${pid}`, "/FO", "CSV", "/NH"]),
      );
      return { pid, command: name };
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
): Promise<number[] | null> {
  try {
    const pids =
      platform === "win32"
        ? parseNetstatClients(await run("netstat", ["-ano", "-p", "TCP"]), port)
        : parseLsofClients(
            await run("lsof", ["+c", "0", "-nP", `-iTCP:${port}`, "-sTCP:ESTABLISHED", "-Fpcn"]),
            port,
          ).map((c) => c.pid);
    return pids.filter((pid) => pid !== selfPid);
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
  /** PIDs of other processes connected to the port; null when unknown. */
  otherClients: number[] | null;
}

export const STALE_LISTENER_MESSAGE =
  "Lightroom owns the plugin's ports but is not answering, and no other bridge is connected. " +
  "A listener left behind by 'Reload Plug-in' keeps the port without serving it. " +
  "Restart Lightroom Classic.";

function describeOwner({ port, listener }: PortOwnership): string {
  const name = listener?.command ?? "an unknown process";
  return `port ${port} is held by ${name} (pid ${listener?.pid})`;
}

/**
 * Explains why a connected plugin is not answering. A foreign process bound to
 * a plugin port accepts the bridge's connection itself, so requests or
 * responses silently go to it instead of Lightroom (issue 225). When
 * Lightroom owns every port yet nobody else is connected, the listener is a
 * leftover from 'Reload Plug-in', not another bridge.
 */
export function describeUnresponsive(ports: PortOwnership[]): string {
  const foreign = ports.filter((p) => p.listener && !isLightroom(p.listener));
  if (foreign.length === 0) {
    const ownedByLightroom = ports.every((p) => p.listener && isLightroom(p.listener));
    const noOtherClients = ports.every((p) => p.otherClients?.length === 0);
    if (ownedByLightroom && noOtherClients) return STALE_LISTENER_MESSAGE;
    const others = [...new Set(ports.flatMap((p) => p.otherClients ?? []))];
    return others.length > 0
      ? `${SHADOW_BRIDGE_MESSAGE} Other processes connected: pid ${others.join(", ")}.`
      : SHADOW_BRIDGE_MESSAGE;
  }
  return (
    `Connected, but not to Lightroom: ${foreign.map(describeOwner).join("; ")}. ` +
    "The Lightroom plugin cannot bind a port another process already owns, so the bridge talks to that process instead. " +
    "Quit it, or pick free ports in Lightroom's Plug-in Manager and set the same values in " +
    "LIGHTROOM_MCP_REQUEST_PORT / LIGHTROOM_MCP_RESPONSE_PORT. " +
    "MIDI2LR uses the same default ports (58763/58764)."
  );
}

export interface PortInspector {
  listener: (port: number) => Promise<PortListener | null>;
  otherClients: (port: number) => Promise<number[] | null>;
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
