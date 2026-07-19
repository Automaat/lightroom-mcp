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
    const lockDir = path.join(dir, "lightroom-mcp-58763-58764.lock");
    fs.mkdirSync(lockDir);
    fs.writeFileSync(path.join(lockDir, "pid"), "999999999\n");

    locks.push(acquireInstanceLock(58763, 58764, dir));

    expect(fs.readFileSync(path.join(lockDir, "pid"), "utf8")).toBe(`${process.pid}\n`);
  });
});
