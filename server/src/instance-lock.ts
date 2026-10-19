import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export interface InstanceLock {
  release: () => void;
}

function pidIsAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === "EPERM";
  }
}

function readPid(pidFile: string): number | null {
  try {
    const raw = fs.readFileSync(pidFile, "utf8").trim();
    const parsed = Number(raw);
    return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
  } catch {
    return null;
  }
}

/** Like readPid, but tells a missing lock apart from an unreadable one. */
function readOwner(lockFile: string): number | null | "missing" {
  try {
    fs.statSync(lockFile);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return "missing";
  }
  return readPid(lockFile);
}

const NO_HARD_LINKS = new Set(["EPERM", "ENOTSUP", "ENOSYS", "EOPNOTSUPP"]);

/**
 * Publishes the pending pid file as the lock; false when a lock already
 * exists. Filesystems without hard links fall back to exclusive create, which
 * reopens the brief empty-lock window the link avoids.
 */
function publish(pending: string, lockFile: string): boolean {
  try {
    fs.linkSync(pending, lockFile);
    return true;
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code ?? "";
    if (code === "EEXIST") return false;
    if (!NO_HARD_LINKS.has(code)) throw err;
  }
  let fd: number;
  try {
    fd = fs.openSync(lockFile, "wx", 0o600);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "EEXIST") return false;
    throw err;
  }
  try {
    fs.writeFileSync(fd, `${process.pid}\n`, { encoding: "utf8" });
  } finally {
    fs.closeSync(fd);
  }
  return true;
}

/** Thrown when a live process holds the lock; carries its pid for diagnostics. */
export class LockHeldError extends Error {
  constructor(
    readonly pid: number,
    requestPort: number,
    responsePort: number,
  ) {
    super(
      `Another Lightroom MCP bridge is already running for ports ${requestPort}/${responsePort} (pid ${pid})`,
    );
  }
}

/** A guard or pid-less lock older than this belongs to a process that died. */
const STALE_GUARD_MS = 5_000;

function isFresh(file: string, maxAgeMs = STALE_GUARD_MS): boolean {
  try {
    return Date.now() - fs.statSync(file).mtimeMs <= maxAgeMs;
  } catch {
    return false;
  }
}

/** How often the owner refreshes its heartbeat file. */
const HEARTBEAT_MS = 5_000;
/** An owner whose heartbeat is older than this is hung, or its pid was reused. */
const HEARTBEAT_STALE_MS = 60_000;

function heartbeatPath(lockFile: string): string {
  return `${lockFile}.alive`;
}

/**
 * True when a live pid's lock no longer has a working owner: the owner kept a
 * heartbeat and stopped refreshing it, and the lock itself is not newly
 * taken. Owners that never wrote a heartbeat (older versions) never qualify.
 */
function ownerUnresponsive(lockFile: string): boolean {
  const heartbeat = heartbeatPath(lockFile);
  if (!fs.existsSync(heartbeat)) return false;
  return !isFresh(heartbeat, HEARTBEAT_STALE_MS) && !isFresh(lockFile, HEARTBEAT_STALE_MS);
}

/**
 * Removes a dead owner's lock, but only if it still names that owner. The
 * guard serializes reclaimers: without it, two of them can both see the dead
 * pid, and the slower one deletes the lock the faster one just took. A lock
 * that has vanished is never removed: a non-reclaiming bridge may be linking
 * a fresh one into its place.
 */
function reclaimStale(lockFile: string, deadPid: number | null): boolean {
  const guard = `${lockFile}.reclaim`;
  try {
    fs.closeSync(fs.openSync(guard, "wx", 0o600));
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "EEXIST") throw err;
    if (!isFresh(guard)) fs.rmSync(guard, { force: true });
    return false;
  }
  try {
    const current = readOwner(lockFile);
    const midWrite = current === null && isFresh(lockFile);
    if (current !== "missing" && current === deadPid && !midWrite) fs.rmSync(lockFile, { force: true });
  } finally {
    fs.rmSync(guard, { force: true });
  }
  return true;
}

/**
 * Takes the per-port-pair bridge lock. The pid is written to a private file
 * first and hard-linked into place, so the lock never exists without its pid:
 * an empty lock seen mid-write would look stale and be reclaimed while live.
 * The owner refreshes a heartbeat file beside the lock, so a live pid that
 * stopped beating (hung, or reused by an unrelated process after a crash) is
 * reclaimed like a dead one. Throws LockHeldError when a live, beating bridge
 * holds it.
 */
export function acquireInstanceLock(
  requestPort: number,
  responsePort: number,
  baseDir = path.join(os.homedir(), ".config", "lightroom-mcp"),
): InstanceLock {
  fs.mkdirSync(baseDir, { recursive: true, mode: 0o700 });
  const lockFile = path.join(baseDir, `bridge-${requestPort}-${responsePort}.lock`);

  const pending = `${lockFile}.${process.pid}.tmp`;
  fs.writeFileSync(pending, `${process.pid}\n`, { encoding: "utf8", mode: 0o600 });
  try {
    while (!publish(pending, lockFile)) {
      const existingPid = readOwner(lockFile);
      if (existingPid === "missing") continue;
      if (existingPid === null && isFresh(lockFile)) {
        throw new Error(`Another bridge is still writing the lock for ports ${requestPort}/${responsePort}`);
      }
      if (existingPid && pidIsAlive(existingPid) && !ownerUnresponsive(lockFile)) {
        throw new LockHeldError(existingPid, requestPort, responsePort);
      }
      if (!reclaimStale(lockFile, existingPid)) {
        throw new Error(`Another bridge is reclaiming the stale lock for ports ${requestPort}/${responsePort}`);
      }
    }
  } finally {
    fs.rmSync(pending, { force: true });
  }

  const heartbeatFile = heartbeatPath(lockFile);
  const beat = () => {
    // A reclaimed owner that wakes up must not refresh its successor's heartbeat.
    if (readPid(lockFile) !== process.pid) {
      clearInterval(heartbeat);
      return;
    }
    try {
      fs.writeFileSync(heartbeatFile, `${process.pid}\n`, { encoding: "utf8", mode: 0o600 });
    } catch {
      // Best effort: a missed beat only delays reclaim if this process hangs.
    }
  };
  const heartbeat = setInterval(beat, HEARTBEAT_MS);
  heartbeat.unref();
  beat();

  let released = false;
  const exitHandler = () => release();
  const signalHandler = () => {
    release();
    process.exit(0);
  };
  const release = () => {
    if (released) return;
    released = true;
    clearInterval(heartbeat);
    process.off("exit", exitHandler);
    process.off("SIGINT", signalHandler);
    process.off("SIGTERM", signalHandler);
    if (readPid(lockFile) === process.pid) {
      fs.rmSync(heartbeatFile, { force: true });
      fs.unlinkSync(lockFile);
    }
  };

  process.once("exit", exitHandler);
  process.once("SIGINT", signalHandler);
  process.once("SIGTERM", signalHandler);

  return { release };
}
