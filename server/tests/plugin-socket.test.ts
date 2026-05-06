import { describe, it, expect, beforeEach, afterEach } from '@jest/globals';
import net from 'node:net';
import { PluginSocket } from '../src/plugin-socket.js';

function freePort(): Promise<number> {
  return new Promise((resolve) => {
    const srv = net.createServer();
    srv.listen(0, () => {
      const addr = srv.address();
      const port = typeof addr === 'object' && addr ? addr.port : 0;
      srv.close(() => resolve(port));
    });
  });
}

function waitFor(check: () => boolean, timeoutMs = 2000): Promise<void> {
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

describe('PluginSocket', () => {
  let server: net.Server | null = null;
  let port: number;
  let serverConn: net.Socket | null = null;
  let socket: PluginSocket | null = null;

  beforeEach(async () => {
    port = await freePort();
  });

  afterEach(async () => {
    socket?.stop();
    socket = null;
    serverConn?.destroy();
    serverConn = null;
    if (server) {
      await new Promise<void>((resolve) => server!.close(() => resolve()));
      server = null;
    }
  });

  it('reports not connected before plugin listens', async () => {
    socket = new PluginSocket({ port, label: 'test', reconnectDelayMs: 50, log: () => {} });
    socket.connect();
    expect(socket.isConnected()).toBe(false);
    expect(socket.send('hello')).toBe(false);
  });

  it('connects once plugin starts listening, sends newline-framed messages', async () => {
    socket = new PluginSocket({ port, label: 'test', reconnectDelayMs: 50, log: () => {} });
    socket.connect();

    const received: string[] = [];
    server = net.createServer((conn) => {
      serverConn = conn;
      let buf = '';
      conn.setEncoding('utf8');
      conn.on('data', (chunk: string) => {
        buf += chunk;
        let idx;
        while ((idx = buf.indexOf('\n')) !== -1) {
          received.push(buf.slice(0, idx));
          buf = buf.slice(idx + 1);
        }
      });
    });
    await new Promise<void>((resolve) => server!.listen(port, '127.0.0.1', () => resolve()));

    await waitFor(() => socket!.isConnected());
    expect(socket.send('{"id":"a","action":"ping"}')).toBe(true);
    expect(socket.send('{"id":"b","action":"pong"}')).toBe(true);

    await waitFor(() => received.length >= 2);
    expect(received).toEqual(['{"id":"a","action":"ping"}', '{"id":"b","action":"pong"}']);
  });

  it('parses incoming newline-delimited lines including split chunks', async () => {
    const lines: string[] = [];
    socket = new PluginSocket({
      port,
      label: 'test',
      reconnectDelayMs: 50,
      onLine: (line) => lines.push(line),
      log: () => {},
    });

    server = net.createServer((conn) => {
      serverConn = conn;
      // Send across two chunks split mid-message
      conn.write('{"id":"1","resu');
      setTimeout(() => conn.write('lt":42}\n{"id":"2","result":"x"}\n'), 20);
    });
    await new Promise<void>((resolve) => server!.listen(port, '127.0.0.1', () => resolve()));
    socket.connect();

    await waitFor(() => lines.length >= 2);
    expect(lines).toEqual(['{"id":"1","result":42}', '{"id":"2","result":"x"}']);
  });

  it('reconnects after the plugin closes the connection', async () => {
    let connectionCount = 0;
    server = net.createServer((conn) => {
      connectionCount++;
      serverConn = conn;
      if (connectionCount === 1) {
        // Drop first connection immediately
        setTimeout(() => conn.destroy(), 30);
      }
    });
    await new Promise<void>((resolve) => server!.listen(port, '127.0.0.1', () => resolve()));

    socket = new PluginSocket({ port, label: 'test', reconnectDelayMs: 50, log: () => {} });
    socket.connect();

    await waitFor(() => connectionCount >= 2, 3000);
    expect(connectionCount).toBeGreaterThanOrEqual(2);
  });

  it('stop() prevents further reconnects', async () => {
    let connectionCount = 0;
    server = net.createServer((conn) => {
      connectionCount++;
      conn.destroy();
    });
    await new Promise<void>((resolve) => server!.listen(port, '127.0.0.1', () => resolve()));

    socket = new PluginSocket({ port, label: 'test', reconnectDelayMs: 50, log: () => {} });
    socket.connect();
    await waitFor(() => connectionCount >= 1);
    socket.stop();

    const countAtStop = connectionCount;
    await new Promise((r) => setTimeout(r, 200));
    expect(connectionCount).toBe(countAtStop);
  });
});
