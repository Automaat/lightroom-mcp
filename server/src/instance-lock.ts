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
  baseDir = os.tmpdir(),
): InstanceLock {
  const lockDir = path.join(baseDir, `lightroom-mcp-${requestPort}-${responsePort}.lock`);
  const pidFile = path.join(lockDir, "pid");
  const candidateDir = `${lockDir}.${process.pid}.${Date.now()}.${Math.random()
    .toString(16)
    .slice(2)}.new`;

  fs.mkdirSync(candidateDir);
  fs.writeFileSync(path.join(candidateDir, "pid"), `${process.pid}\n`, { encoding: "utf8" });

  let acquired = false;
  while (!acquired) {
    try {
      fs.renameSync(candidateDir, lockDir);
      acquired = true;
      break;
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code;
      if (code !== "EEXIST" && code !== "ENOTEMPTY") {
        fs.rmSync(candidateDir, { recursive: true, force: true });
        throw err;
      }
    }

    const existingPid = readPid(pidFile);
    if (existingPid && pidIsAlive(existingPid)) {
      fs.rmSync(candidateDir, { recursive: true, force: true });
      throw new Error(
        `Another Lightroom MCP bridge is already running for ports ${requestPort}/${responsePort} (pid ${existingPid})`,
      );
    }

    const staleDir = `${lockDir}.stale.${process.pid}.${Date.now()}.${Math.random()
      .toString(16)
      .slice(2)}`;
    try {
      fs.renameSync(lockDir, staleDir);
      fs.rmSync(staleDir, { recursive: true, force: true });
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code;
      if (code !== "ENOENT" && code !== "EEXIST") {
        fs.rmSync(candidateDir, { recursive: true, force: true });
        throw err;
      }
    }
  }

  let released = false;
  const release = () => {
    if (released) return;
    released = true;
    if (readPid(pidFile) === process.pid) {
      fs.rmSync(lockDir, { recursive: true, force: true });
    }
  };

  process.once("exit", release);
  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.once(signal, () => {
      release();
      process.exit(0);
    });
  }

  return { release };
}
