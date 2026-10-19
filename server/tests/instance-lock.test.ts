import { describe, it, expect, afterEach, jest } from "@jest/globals";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  acquireInstanceLock,
  lockHolderUnresponsive,
  LockHeldError,
  type InstanceLock,
} from "../src/instance-lock.js";

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
    const old = new Date(Date.now() - 60_000);
    fs.utimesSync(lockFile, old, old);

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

  it("reports the live holder's pid", () => {
    locks.push(acquireInstanceLock(58763, 58764, baseDir()));

    let caught: unknown;
    try {
      acquireInstanceLock(58763, 58764, baseDir());
    } catch (err) {
      caught = err;
    }

    expect(caught).toBeInstanceOf(LockHeldError);
    expect((caught as LockHeldError).pid).toBe(process.pid);
  });

  it("leaves only the lock and its heartbeat behind", () => {
    const dir = baseDir();
    locks.push(acquireInstanceLock(58763, 58764, dir));

    expect(fs.readdirSync(dir).sort()).toEqual(["bridge-58763-58764.lock", "bridge-58763-58764.lock.alive"]);
  });

  it("removes the heartbeat on release", () => {
    const dir = baseDir();
    acquireInstanceLock(58763, 58764, dir).release();

    expect(fs.readdirSync(dir)).toEqual([]);
  });

  describe("live owner liveness", () => {
    // The parent of the Jest worker is alive for the whole test but is not us.
    const livePid = process.ppid;
    const old = () => new Date(Date.now() - 120_000);

    function writeLock(
      dir: string,
      opts: { lockAge?: Date; heartbeatAge?: Date | null; heartbeatPid?: number },
    ): string {
      const lockFile = path.join(dir, "bridge-58763-58764.lock");
      fs.writeFileSync(lockFile, `${livePid}\n`);
      if (opts.lockAge) fs.utimesSync(lockFile, opts.lockAge, opts.lockAge);
      if (opts.heartbeatAge !== null) {
        const heartbeat = `${lockFile}.alive`;
        fs.writeFileSync(heartbeat, `${opts.heartbeatPid ?? livePid}\n`);
        if (opts.heartbeatAge) fs.utimesSync(heartbeat, opts.heartbeatAge, opts.heartbeatAge);
      }
      return lockFile;
    }

    it("reclaims a live pid whose heartbeat went stale", () => {
      const dir = baseDir();
      const lockFile = writeLock(dir, { lockAge: old(), heartbeatAge: old() });

      expect(lockHolderUnresponsive(58763, 58764, dir)).toBe(true);
      locks.push(acquireInstanceLock(58763, 58764, dir));

      expect(fs.readFileSync(lockFile, "utf8")).toBe(`${process.pid}\n`);
      expect(fs.readFileSync(`${lockFile}.alive`, "utf8")).toBe(`${process.pid}\n`);
      expect(lockHolderUnresponsive(58763, 58764, dir)).toBe(false);
    });

    it("keeps a live owner whose heartbeat is fresh", () => {
      const dir = baseDir();
      writeLock(dir, { lockAge: old() });

      expect(lockHolderUnresponsive(58763, 58764, dir)).toBe(false);
      expect(() => acquireInstanceLock(58763, 58764, dir)).toThrow(LockHeldError);
    });

    it("keeps a live owner that never wrote a heartbeat", () => {
      const dir = baseDir();
      writeLock(dir, { lockAge: old(), heartbeatAge: null });

      expect(lockHolderUnresponsive(58763, 58764, dir)).toBe(false);
      expect(() => acquireInstanceLock(58763, 58764, dir)).toThrow(LockHeldError);
    });

    it("keeps a newly taken lock beside a stale leftover heartbeat", () => {
      const dir = baseDir();
      writeLock(dir, { heartbeatAge: old() });

      expect(() => acquireInstanceLock(58763, 58764, dir)).toThrow(LockHeldError);
    });

    it("keeps a live owner beside a stale heartbeat left by an earlier owner", () => {
      const dir = baseDir();
      writeLock(dir, { lockAge: old(), heartbeatAge: old(), heartbeatPid: 999999999 });

      expect(lockHolderUnresponsive(58763, 58764, dir)).toBe(false);
      expect(() => acquireInstanceLock(58763, 58764, dir)).toThrow(LockHeldError);
    });

    it("removes the dead owner's heartbeat with its lock", () => {
      const dir = baseDir();
      const lockFile = path.join(dir, "bridge-58763-58764.lock");
      fs.writeFileSync(lockFile, "999999999\n");
      fs.writeFileSync(`${lockFile}.alive`, "999999999\n");
      const removed: string[] = [];
      const rmSync = fs.rmSync.bind(fs);
      const spy = jest.spyOn(fs, "rmSync").mockImplementation((target, opts) => {
        removed.push(path.basename(String(target)));
        rmSync(target, opts);
      });
      try {
        locks.push(acquireInstanceLock(58763, 58764, dir));
      } finally {
        spy.mockRestore();
      }

      expect(removed).toEqual(
        expect.arrayContaining(["bridge-58763-58764.lock.alive", "bridge-58763-58764.lock"]),
      );
      expect(removed.indexOf("bridge-58763-58764.lock.alive")).toBeLessThan(
        removed.indexOf("bridge-58763-58764.lock"),
      );
    });

    describe("owner", () => {
      afterEach(() => {
        jest.useRealTimers();
      });

      function own(dir: string): { lockFile: string; lost: () => number } {
        const lockFile = path.join(dir, "bridge-58763-58764.lock");
        const lock = acquireInstanceLock(58763, 58764, dir);
        locks.push(lock);
        let lostCount = 0;
        lock.onLost(() => (lostCount += 1));
        return { lockFile, lost: () => lostCount };
      }

      it("stops beating and reports the loss once another bridge reclaims the lock", () => {
        jest.useFakeTimers();
        const { lockFile, lost } = own(baseDir());
        fs.writeFileSync(lockFile, `${livePid}\n`);
        fs.writeFileSync(`${lockFile}.alive`, `${livePid}\n`);

        jest.advanceTimersByTime(20_000);

        expect(fs.readFileSync(`${lockFile}.alive`, "utf8")).toBe(`${livePid}\n`);
        expect(lost()).toBe(1);
      });

      it("reports the loss when its lock is removed", () => {
        jest.useFakeTimers();
        const { lockFile, lost } = own(baseDir());
        fs.rmSync(lockFile);

        jest.advanceTimersByTime(5_000);

        expect(lost()).toBe(1);
      });

      it("reports a loss to a listener that subscribes late", () => {
        jest.useFakeTimers();
        const dir = baseDir();
        const lockFile = path.join(dir, "bridge-58763-58764.lock");
        const lock = acquireInstanceLock(58763, 58764, dir);
        locks.push(lock);
        fs.writeFileSync(lockFile, `${livePid}\n`);
        jest.advanceTimersByTime(5_000);
        let lost = false;

        lock.onLost(() => (lost = true));

        expect(lost).toBe(true);
      });

      it("keeps beating through a lock it cannot read", () => {
        jest.useFakeTimers();
        const { lockFile, lost } = own(baseDir());
        fs.writeFileSync(lockFile, "garbage\n");
        jest.advanceTimersByTime(10_000);
        fs.writeFileSync(lockFile, `${process.pid}\n`);
        const heartbeat = `${lockFile}.alive`;
        const stale = old();
        fs.utimesSync(heartbeat, stale, stale);

        jest.advanceTimersByTime(5_000);

        expect(lost()).toBe(0);
        expect(fs.statSync(heartbeat).mtimeMs).toBeGreaterThan(stale.getTime() + 60_000);
      });
    });
  });

  it("backs off while another bridge is reclaiming a stale lock", () => {
    const dir = baseDir();
    const lockFile = path.join(dir, "bridge-58763-58764.lock");
    fs.writeFileSync(lockFile, "999999999\n");
    fs.writeFileSync(`${lockFile}.reclaim`, "");

    expect(() => acquireInstanceLock(58763, 58764, dir)).toThrow(/reclaiming the stale lock/);
    expect(fs.readFileSync(lockFile, "utf8")).toBe("999999999\n");
  });

  it("clears a reclaim guard left by a bridge that died mid-reclaim", () => {
    const dir = baseDir();
    const lockFile = path.join(dir, "bridge-58763-58764.lock");
    fs.writeFileSync(lockFile, "999999999\n");
    const guard = `${lockFile}.reclaim`;
    fs.writeFileSync(guard, "");
    const old = new Date(Date.now() - 60_000);
    fs.utimesSync(guard, old, old);

    expect(() => acquireInstanceLock(58763, 58764, dir)).toThrow(/reclaiming the stale lock/);
    expect(fs.existsSync(guard)).toBe(false);

    locks.push(acquireInstanceLock(58763, 58764, dir));
    expect(fs.readFileSync(lockFile, "utf8")).toBe(`${process.pid}\n`);
  });

  it("leaves a pid-less lock alone while it may still be mid-write", () => {
    const dir = baseDir();
    const lockFile = path.join(dir, "bridge-58763-58764.lock");
    fs.writeFileSync(lockFile, "");

    expect(() => acquireInstanceLock(58763, 58764, dir)).toThrow(/still writing the lock/);
    expect(fs.readFileSync(lockFile, "utf8")).toBe("");
  });

  it.each(["EPERM", "ENOTSUP"])("falls back to exclusive create when hard links fail with %s", (code) => {
    const dir = baseDir();
    const lockFile = path.join(dir, "bridge-58763-58764.lock");
    const spy = jest.spyOn(fs, "linkSync").mockImplementation(() => {
      throw Object.assign(new Error(code), { code });
    });
    try {
      locks.push(acquireInstanceLock(58763, 58764, dir));
      expect(fs.readFileSync(lockFile, "utf8")).toBe(`${process.pid}\n`);
      expect(() => acquireInstanceLock(58763, 58764, dir)).toThrow(LockHeldError);
    } finally {
      spy.mockRestore();
    }
  });

  it("rethrows unexpected link failures", () => {
    const spy = jest.spyOn(fs, "linkSync").mockImplementation(() => {
      throw Object.assign(new Error("EIO"), { code: "EIO" });
    });
    try {
      expect(() => acquireInstanceLock(58763, 58764, baseDir())).toThrow(/EIO/);
      expect(fs.readdirSync(baseDir())).toEqual([]);
    } finally {
      spy.mockRestore();
    }
  });
});
