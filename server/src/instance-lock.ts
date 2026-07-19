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

export function acquireInstanceLock(
  requestPort: number,
  responsePort: number,
  baseDir = path.join(os.homedir(), ".config", "lightroom-mcp"),
): InstanceLock {
  fs.mkdirSync(baseDir, { recursive: true, mode: 0o700 });
  const lockFile = path.join(baseDir, `bridge-${requestPort}-${responsePort}.lock`);

  while (true) {
    let fd: number | null = null;
    try {
      fd = fs.openSync(lockFile, "wx", 0o600);
      fs.writeFileSync(fd, `${process.pid}\n`, { encoding: "utf8" });
      break;
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code;
      if (code !== "EEXIST") {
        throw err;
      }

      const existingPid = readPid(lockFile);
      if (existingPid && pidIsAlive(existingPid)) {
        throw new Error(
          `Another Lightroom MCP bridge is already running for ports ${requestPort}/${responsePort} (pid ${existingPid})`,
        );
      }

      try {
        fs.unlinkSync(lockFile);
      } catch (unlinkErr) {
        if ((unlinkErr as NodeJS.ErrnoException).code !== "ENOENT") throw unlinkErr;
      }
    } finally {
      if (fd !== null) fs.closeSync(fd);
    }
  }

  let released = false;
  const exitHandler = () => release();
  const signalHandler = () => {
    release();
    process.exit(0);
  };
  const release = () => {
    if (released) return;
    released = true;
    process.off("exit", exitHandler);
    process.off("SIGINT", signalHandler);
    process.off("SIGTERM", signalHandler);
    if (readPid(lockFile) === process.pid) {
      fs.unlinkSync(lockFile);
    }
  };

  process.once("exit", exitHandler);
  process.once("SIGINT", signalHandler);
  process.once("SIGTERM", signalHandler);

  return { release };
}
