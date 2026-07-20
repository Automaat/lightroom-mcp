import { describe, it, expect, afterEach } from "@jest/globals";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { acquireInstanceLock, type InstanceLock } from "../src/instance-lock.js";

describe("instance lock", () => {
  let tmpDir: string | null = null;
  const locks: InstanceLock[] = [];

  afterEach(() => {
    while (locks.length > 0) {
      locks.pop()?.release();
    }
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      tmpDir = null;
    }
  });

  function baseDir(): string {
    tmpDir ??= fs.mkdtempSync(path.join(os.tmpdir(), "lightroom-mcp-lock-test-"));
    return tmpDir;
  }

  it("rejects a second live bridge for the same ports", () => {
    locks.push(acquireInstanceLock(58763, 58764, baseDir()));

    expect(() => acquireInstanceLock(58763, 58764, baseDir())).toThrow(
      /Another Lightroom MCP bridge is already running/,
    );
  });

  it("allows different port pairs to run independently", () => {
    locks.push(acquireInstanceLock(58763, 58764, baseDir()));
    locks.push(acquireInstanceLock(58765, 58766, baseDir()));
  });

  it("replaces a stale lock with a fully written live lock", () => {
    const dir = baseDir();
    const lockFile = path.join(dir, "bridge-58763-58764.lock");
    fs.writeFileSync(lockFile, "999999999\n");

    locks.push(acquireInstanceLock(58763, 58764, dir));

    expect(fs.readFileSync(lockFile, "utf8")).toBe(`${process.pid}\n`);
  });

  it("replaces a malformed stale lock", () => {
    const dir = baseDir();
    const lockFile = path.join(dir, "bridge-58763-58764.lock");
    fs.writeFileSync(lockFile, "not-a-pid\n");

    locks.push(acquireInstanceLock(58763, 58764, dir));

    expect(fs.readFileSync(lockFile, "utf8")).toBe(`${process.pid}\n`);
  });

  it("allows release after the lock file is already gone", () => {
    const dir = baseDir();
    const lockFile = path.join(dir, "bridge-58763-58764.lock");
    const lock = acquireInstanceLock(58763, 58764, dir);
    fs.unlinkSync(lockFile);

    lock.release();
    lock.release();

    expect(fs.existsSync(lockFile)).toBe(false);
  });

  it("removes process handlers when released", () => {
    const beforeExit = process.listenerCount("exit");
    const beforeSigint = process.listenerCount("SIGINT");
    const beforeSigterm = process.listenerCount("SIGTERM");

    const lock = acquireInstanceLock(58763, 58764, baseDir());
    expect(process.listenerCount("exit")).toBe(beforeExit + 1);
    expect(process.listenerCount("SIGINT")).toBe(beforeSigint + 1);
    expect(process.listenerCount("SIGTERM")).toBe(beforeSigterm + 1);

    lock.release();

    expect(process.listenerCount("exit")).toBe(beforeExit);
    expect(process.listenerCount("SIGINT")).toBe(beforeSigint);
    expect(process.listenerCount("SIGTERM")).toBe(beforeSigterm);
  });
});
