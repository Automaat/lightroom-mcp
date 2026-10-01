import { describe, it, expect, afterEach } from '@jest/globals';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { Bridge, NO_OWNER_MESSAGE, unreachableOwnerMessage, type Leader } from '../src/bridge.js';
import { BrokerClient, BrokerServer, OWNER_LOST_MESSAGE, brokerPath, signNonce } from '../src/broker.js';
import { acquireInstanceLock } from '../src/instance-lock.js';
import type { ToolResponse } from '../src/tool-handler.js';

function text(resp: ToolResponse): string {
  return resp.content[0]?.text ?? '';
}

function ok(body: string): ToolResponse {
  return { content: [{ type: 'text', text: body }] };
}

function waitFor(check: () => boolean, timeoutMs = 3000): Promise<void> {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const tick = () => {
      if (check()) return resolve();
      if (Date.now() - start > timeoutMs) return reject(new Error('waitFor timeout'));
      setTimeout(tick, 10);
    };
    tick();
  });
}

const tmpDirs: string[] = [];
function tmpDir(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lrmcp-'));
  tmpDirs.push(dir);
  return dir;
}

const isWindows = process.platform === 'win32';
const unixOnly = isWindows ? it.skip : it;

function ipcPath(dir: string): string {
  if (isWindows) return `\\\\.\\pipe\\${path.basename(dir)}`;
  return brokerPath(58763, 58764, dir);
}

afterEach(() => {
  while (tmpDirs.length > 0) {
    fs.rmSync(tmpDirs.pop()!, { recursive: true, force: true });
  }
});

describe('brokerPath', () => {
  it('uses a named pipe on Windows', () => {
    expect(brokerPath(1, 2, '/x', 'win32')).toMatch(/^\\\\\.\\pipe\\lightroom-mcp-.+-bridge-1-2$/);
  });

  it('uses a socket in the config dir when the path fits', () => {
    expect(brokerPath(1, 2, '/cfg', 'darwin')).toBe(path.join('/cfg', 'bridge-1-2.sock'));
  });

  it('measures the socket path in bytes, not characters', () => {
    const p = brokerPath(1, 2, '/' + 'ż'.repeat(45), 'darwin');
    expect(p.startsWith(os.tmpdir())).toBe(true);
  });

  it('falls back to the temp dir when the config path is too long for a Unix socket', () => {
    const long = '/' + 'a'.repeat(120);
    const p = brokerPath(1, 2, long, 'linux');
    expect(p.startsWith(os.tmpdir())).toBe(true);
    expect(p).toMatch(/bridge-1-2\.sock$/);
  });
});

describe('broker', () => {
  const closers: Array<() => void> = [];
  afterEach(() => {
    while (closers.length > 0) closers.pop()!();
  });

  async function serve(
    callTool: (name: string, args: unknown) => Promise<ToolResponse>,
    token = 't',
    log: (msg: string) => void = () => {},
  ) {
    const p = ipcPath(tmpDir());
    const server = new BrokerServer({ path: p, callTool, readToken: () => token, log });
    await server.listen();
    closers.push(() => server.close());
    return { p, server };
  }

  async function connect(p: string, token: string | null = 't', onClose?: () => void) {
    const client = new BrokerClient({ path: p, readToken: () => token, onClose });
    await client.connect();
    closers.push(() => client.close());
    return client;
  }

  async function rawHandshake(p: string, token: string) {
    const sock = net.createConnection(p);
    closers.push(() => sock.destroy());
    sock.setEncoding('utf8');
    const lines: string[] = [];
    let buffer = '';
    sock.on('data', (chunk: string) => {
      buffer += chunk;
      let idx: number;
      while ((idx = buffer.indexOf('\n')) !== -1) {
        lines.push(buffer.slice(0, idx));
        buffer = buffer.slice(idx + 1);
      }
    });
    await new Promise<void>((resolve) => sock.once('connect', () => resolve()));
    sock.write(JSON.stringify({ challenge: 'c' }) + '\n');
    await waitFor(() => lines.length > 0);
    const hello = JSON.parse(lines.shift()!) as { nonce: string; proof: string };
    expect(hello.proof).toBe(signNonce(token, 'owner:c'));
    return { sock, hello, lines };
  }

  it('forwards tool calls and returns the owner response', async () => {
    const { p } = await serve(async (name, args) => ok(`${name}:${JSON.stringify(args)}`));
    const client = await connect(p);

    const [a, b] = await Promise.all([
      client.callTool('get_selection', {}),
      client.callTool('search_photos', { query: 'x' }),
    ]);

    expect(text(a)).toBe('get_selection:{}');
    expect(text(b)).toBe('search_photos:{"query":"x"}');
  });

  it('refuses to connect a follower whose token does not match', async () => {
    const { p } = await serve(async () => ok('done'));

    await expect(connect(p, 'wrong')).rejects.toThrow(/could not prove/);
    await expect(connect(p, null)).rejects.toThrow(/could not prove/);
  });

  it('rejects a call signed with the wrong token', async () => {
    const calls: string[] = [];
    const { p } = await serve(async (name) => {
      calls.push(name);
      return ok('done');
    });
    const { sock, hello, lines } = await rawHandshake(p, 't');

    sock.write(JSON.stringify({ id: 7, auth: signNonce('wrong', `follower:${hello.nonce}`), name: 'ping' }) + '\n');

    await waitFor(() => lines.length > 0);
    expect(JSON.parse(lines[0]!)).toMatchObject({ id: 7, result: { isError: true } });
    expect(lines[0]).toMatch(/token mismatch/);
    expect(calls).toEqual([]);
  });

  it('fails in-flight calls when the owner goes away', async () => {
    let release: (() => void) | undefined;
    const { p, server } = await serve(
      () => new Promise<ToolResponse>((resolve) => (release = () => resolve(ok('late')))),
    );
    let closed = false;
    const client = await connect(p, 't', () => (closed = true));

    const pending = client.callTool('export_photos', {});
    await waitFor(() => release !== undefined);
    server.close();

    const resp = await pending;
    expect(resp.isError).toBe(true);
    expect(text(resp)).toBe(OWNER_LOST_MESSAGE);
    expect(closed).toBe(true);
    expect(client.isConnected()).toBe(false);
    expect(text(await client.callTool('ping', {}))).toBe(OWNER_LOST_MESSAGE);
    release?.();
  });

  unixOnly('replaces a stale socket file left by a dead owner', async () => {
    const p = ipcPath(tmpDir());
    fs.writeFileSync(p, '', { mode: 0o600, flag: 'wx' });
    const server = new BrokerServer({ path: p, callTool: async () => ok('x'), readToken: () => null });
    await server.listen();
    closers.push(() => server.close());

    const client = await connect(p, null);
    expect(text(await client.callTool('ping', {}))).toBe('x');
  });

  it.each(['not json', 'null', '[]', '1', '"x"', '{"id":"1","name":"ping"}', '{"id":1,"name":"ping","auth":5}'])(
    'survives a malformed request line %s',
    async (line) => {
      const logs: string[] = [];
      const { p } = await serve(async () => ok('x'), 't', (m) => logs.push(m));
      const { sock } = await rawHandshake(p, 't');

      sock.write(line + '\n');

      await waitFor(() => logs.length > 0);
      expect(logs[0]).toMatch(/malformed request/);
      const client = await connect(p);
      expect(text(await client.callTool('ping', {}))).toBe('x');
    },
  );

  it('drops a follower that opens without a challenge', async () => {
    const logs: string[] = [];
    const { p } = await serve(async () => ok('x'), 't', (m) => logs.push(m));
    const sock = net.createConnection(p);
    closers.push(() => sock.destroy());
    const closed = new Promise<void>((resolve) => sock.once('close', () => resolve()));
    await new Promise<void>((resolve) => sock.once('connect', () => resolve()));

    sock.write('{"id":1,"name":"ping","auth":null}\n');

    await closed;
    expect(logs[0]).toMatch(/without a challenge/);
  });

  it('drops a peer that streams an oversized unterminated frame', async () => {
    const { p } = await serve(async () => ok('x'));
    const sock = net.createConnection(p);
    closers.push(() => sock.destroy());
    sock.on('error', () => {});
    const closed = new Promise<void>((resolve) => sock.once('close', () => resolve()));
    await new Promise<void>((resolve) => sock.once('connect', () => resolve()));

    sock.write('x'.repeat(4096));

    await closed;
  });

  it('refuses an impostor owner without leaking the token', async () => {
    const p = ipcPath(tmpDir());
    const received: string[] = [];
    const squatter = net.createServer((sock) => {
      sock.setEncoding('utf8');
      sock.on('data', (chunk: string) => {
        received.push(chunk);
        sock.write(JSON.stringify({ nonce: 'n', proof: 'forged' }) + '\n');
      });
    });
    await new Promise<void>((resolve) => squatter.listen(p, () => resolve()));
    closers.push(() => squatter.close());
    const client = new BrokerClient({ path: p, readToken: () => 'secret-token' });

    await expect(client.connect()).rejects.toThrow(/could not prove/);
    expect(client.isConnected()).toBe(false);
    expect(received.join('')).not.toContain('secret-token');
  });

  it('gives up on an owner that never greets', async () => {
    const p = ipcPath(tmpDir());
    const silent = net.createServer(() => {});
    await new Promise<void>((resolve) => silent.listen(p, () => resolve()));
    closers.push(() => silent.close());
    const client = new BrokerClient({ path: p, readToken: () => null, helloTimeoutMs: 50 });

    await expect(client.connect()).rejects.toThrow(/did not greet/);
    expect(client.isConnected()).toBe(false);
  });

  it('gives up on an owner that hangs up before greeting', async () => {
    const p = ipcPath(tmpDir());
    const rude = net.createServer((sock) => sock.destroy());
    await new Promise<void>((resolve) => rude.listen(p, () => resolve()));
    closers.push(() => rude.close());
    const client = new BrokerClient({ path: p, readToken: () => null });

    await expect(client.connect()).rejects.toThrow();
  });
});

describe('Bridge', () => {
  const bridges: Bridge[] = [];
  afterEach(() => {
    while (bridges.length > 0) bridges.pop()!.stop();
  });

  function makeBridge(dir: string, label: string, started: string[], stopped: string[] = []) {
    const bridge = new Bridge({
      ipcPath: ipcPath(dir),
      acquireLock: () => acquireInstanceLock(58763, 58764, dir),
      startLeader: (): Leader => {
        started.push(label);
        return {
          callTool: async (name) => ok(`${label}:${name}`),
          stop: () => stopped.push(label),
        };
      },
      readToken: () => 'tok',
      retryMs: 20,
      readyWaitMs: 2000,
      log: () => {},
    });
    bridges.push(bridge);
    return bridge;
  }

  it('lets a second bridge start and forwards its calls to the owner', async () => {
    const dir = tmpDir();
    const started: string[] = [];
    const a = makeBridge(dir, 'a', started);
    const b = makeBridge(dir, 'b', started);

    await a.start();
    await b.start();

    expect(a.role()).toBe('leader');
    expect(b.role()).toBe('follower');
    expect(started).toEqual(['a']);
    expect(text(await b.callTool('get_selection', {}))).toBe('a:get_selection');
    expect(text(await a.callTool('get_selection', {}))).toBe('a:get_selection');
  });

  it('promotes a follower when the owner exits', async () => {
    const dir = tmpDir();
    const started: string[] = [];
    const stopped: string[] = [];
    const a = makeBridge(dir, 'a', started, stopped);
    const b = makeBridge(dir, 'b', started, stopped);
    await a.start();
    await b.start();

    a.stop();

    await waitFor(() => b.role() === 'leader');
    expect(stopped).toEqual(['a']);
    expect(started).toEqual(['a', 'b']);
    expect(text(await b.callTool('ping', {}))).toBe('b:ping');
  });

  it('holds a call until the election settles', async () => {
    const dir = tmpDir();
    const started: string[] = [];
    const a = makeBridge(dir, 'a', started);
    const b = makeBridge(dir, 'b', started);
    await a.start();
    await b.start();
    a.stop();

    await waitFor(() => b.role() !== 'follower');
    expect(text(await b.callTool('ping', {}))).toBe('b:ping');
  });

  it('releases the lock and retries when the owner fails to start', async () => {
    const dir = tmpDir();
    let attempts = 0;
    const logs: string[] = [];
    const bridge = new Bridge({
      ipcPath: ipcPath(dir),
      acquireLock: () => acquireInstanceLock(58763, 58764, dir),
      startLeader: () => {
        attempts += 1;
        if (attempts === 1) throw new Error('boom');
        return { callTool: async () => ok('second'), stop: () => {} };
      },
      readToken: () => null,
      retryMs: 20,
      log: (m) => logs.push(m),
    });
    bridges.push(bridge);

    await bridge.start();

    await waitFor(() => bridge.role() === 'leader');
    expect(logs[0]).toMatch(/failed to start as owner: boom/);
    expect(text(await bridge.callTool('ping', {}))).toBe('second');
  });

  unixOnly('releases the lock and retries when it cannot serve other bridges', async () => {
    const dir = tmpDir();
    const blocker = path.join(dir, 'blocked');
    fs.mkdirSync(path.join(blocker, 'bridge-58763-58764.sock'), { recursive: true, mode: 0o700 });
    fs.writeFileSync(path.join(blocker, 'bridge-58763-58764.sock', 'keep'), '', { mode: 0o600, flag: 'wx' });
    const stopped: string[] = [];
    const logs: string[] = [];
    const bridge = new Bridge({
      ipcPath: ipcPath(blocker),
      acquireLock: () => acquireInstanceLock(58763, 58764, dir),
      startLeader: () => ({ callTool: async () => ok('x'), stop: () => stopped.push('x') }),
      readToken: () => null,
      retryMs: 1000,
      log: (m) => logs.push(m),
    });
    bridges.push(bridge);

    await bridge.start();

    expect(bridge.role()).toBe('none');
    expect(stopped).toEqual(['x']);
    expect(logs[0]).toMatch(/failed to serve other bridges/);
    expect(() => acquireInstanceLock(58763, 58764, dir).release()).not.toThrow();
  });

  it('elects on the first tool call when start was never called', async () => {
    const dir = tmpDir();
    const started: string[] = [];
    const a = makeBridge(dir, 'a', started);

    expect(a.role()).toBe('none');
    expect(text(await a.callTool('ping', {}))).toBe('a:ping');
    expect(started).toEqual(['a']);
  });

  it('names the lock holder when it does not serve other bridges', async () => {
    const dir = tmpDir();
    const lock = acquireInstanceLock(58763, 58764, dir);
    const bridge = new Bridge({
      ipcPath: ipcPath(dir),
      acquireLock: () => acquireInstanceLock(58763, 58764, dir),
      startLeader: () => ({ callTool: async () => ok('x'), stop: () => {} }),
      readToken: () => null,
      retryMs: 20,
      readyWaitMs: 50,
      log: () => {},
    });
    bridges.push(bridge);
    try {
      const resp = await bridge.callTool('ping', {});
      expect(resp.isError).toBe(true);
      expect(text(resp)).toBe(unreachableOwnerMessage(process.pid));
    } finally {
      lock.release();
    }
  });

  it('surfaces a lock error instead of a bare retry hint', async () => {
    const logs: string[] = [];
    const bridge = new Bridge({
      ipcPath: ipcPath(tmpDir()),
      acquireLock: () => {
        throw new Error('EACCES: permission denied');
      },
      startLeader: () => ({ callTool: async () => ok('x'), stop: () => {} }),
      readToken: () => null,
      retryMs: 10,
      readyWaitMs: 100,
      log: (m) => logs.push(m),
    });
    bridges.push(bridge);

    const resp = await bridge.callTool('ping', {});

    expect(text(resp)).toBe(`${NO_OWNER_MESSAGE} Last error: EACCES: permission denied`);
    expect(logs.filter((m) => m.includes('cannot take the bridge lock'))).toHaveLength(1);
  });

  it('forgets callers that timed out waiting for an owner', async () => {
    const bridge = new Bridge({
      ipcPath: ipcPath(tmpDir()),
      acquireLock: () => {
        throw new Error('EACCES');
      },
      startLeader: () => ({ callTool: async () => ok('x'), stop: () => {} }),
      readToken: () => null,
      retryMs: 10,
      readyWaitMs: 20,
      log: () => {},
    });
    bridges.push(bridge);

    await bridge.callTool('ping', {});
    await bridge.callTool('ping', {});

    expect(bridge.pendingWaiters()).toBe(0);
  });
});
