import { describe, it, expect, beforeEach, afterEach, jest } from '@jest/globals';
import { Dispatcher } from '../src/dispatcher.js';

interface SentRequest {
  id: string;
  action: string;
  params: unknown;
}

const parseSent = (line: string): SentRequest => JSON.parse(line) as SentRequest;

describe('Dispatcher', () => {
  let sent: string[];
  let canSend: boolean;
  let dispatcher: Dispatcher;
  let logs: string[];

  beforeEach(() => {
    sent = [];
    canSend = true;
    logs = [];
    dispatcher = new Dispatcher({
      send: (line) => {
        if (!canSend) return false;
        sent.push(line);
        return true;
      },
      getToken: () => 'test-token',
      timeoutMs: 1000,
      log: (msg) => logs.push(msg),
    });
  });

  it('serializes the call as line-delimited JSON with id, action, params', async () => {
    const promise = dispatcher.call('list_collections', { foo: 'bar' });
    expect(sent).toHaveLength(1);
    const sentObj = parseSent(sent[0]);
    expect(sentObj.action).toBe('list_collections');
    expect(sentObj.params).toEqual({ foo: 'bar' });
    expect(typeof sentObj.id).toBe('string');

    dispatcher.handleResponseLine(JSON.stringify({ id: sentObj.id, result: { count: 0 } }));
    const resp = await promise;
    expect(resp).toEqual({ id: sentObj.id, result: { count: 0 } });
  });

  it('routes responses to the correct caller by id', async () => {
    const p1 = dispatcher.call('a', {});
    const p2 = dispatcher.call('b', {});
    const id1 = parseSent(sent[0]).id;
    const id2 = parseSent(sent[1]).id;
    expect(id1).not.toBe(id2);

    // Resolve in reverse order
    dispatcher.handleResponseLine(JSON.stringify({ id: id2, result: 'second' }));
    dispatcher.handleResponseLine(JSON.stringify({ id: id1, result: 'first' }));

    expect((await p1).result).toBe('first');
    expect((await p2).result).toBe('second');
  });

  it('propagates plugin errors through the response', async () => {
    const promise = dispatcher.call('bogus', {});
    const id = parseSent(sent[0]).id;
    dispatcher.handleResponseLine(JSON.stringify({ id, error: 'Unknown action' }));
    const resp = await promise;
    expect(resp.error).toBe('Unknown action');
    expect(resp.result).toBeUndefined();
  });

  it('rejects with timeout if no response arrives within timeoutMs', async () => {
    const promise = dispatcher.call('slow', {});
    await expect(promise).rejects.toThrow(/timeout/i);
    expect(dispatcher.pendingCount()).toBe(0);
  });

  it('throws synchronously if send returns false', async () => {
    canSend = false;
    await expect(dispatcher.call('x', {})).rejects.toThrow(/socket dropped/);
    expect(dispatcher.pendingCount()).toBe(0);
  });

  it('drops responses with unknown id without crashing', () => {
    dispatcher.handleResponseLine(JSON.stringify({ id: 'never-sent', result: 'x' }));
    expect(logs.some((l) => l.includes('unknown id'))).toBe(true);
  });

  it('drops malformed JSON without crashing', () => {
    dispatcher.handleResponseLine('not json {{{');
    expect(logs.some((l) => l.includes('Bad JSON'))).toBe(true);
  });

  it('cleans up pending map after timeout fires', async () => {
    const p = dispatcher.call('x', {});
    expect(dispatcher.pendingCount()).toBe(1);
    await p.catch(() => {});
    expect(dispatcher.pendingCount()).toBe(0);
  });

  it('cleans up pending map after response received', async () => {
    const p = dispatcher.call('x', {});
    const id = parseSent(sent[0]).id;
    expect(dispatcher.pendingCount()).toBe(1);
    dispatcher.handleResponseLine(JSON.stringify({ id, result: 'ok' }));
    await p;
    expect(dispatcher.pendingCount()).toBe(0);
  });

  it('defaults params to empty object when undefined', async () => {
    const p = dispatcher.call('x', undefined);
    const sentObj = parseSent(sent[0]);
    expect(sentObj.params).toEqual({});
    await p.catch(() => {});
  });

  describe('per-action timeout overrides', () => {
    afterEach(() => {
      jest.useRealTimers();
    });

    it('honors a longer timeout for the configured action', async () => {
      jest.useFakeTimers();
      const d = new Dispatcher({
        send: (line) => {
          sent.push(line);
          return true;
        },
        getToken: () => 'test-token',
        timeoutMs: 1000,
        actionTimeoutsMs: { export_photos: 60_000 },
      });

      const p = d.call('export_photos', {});
      let settled = false;
      void p.catch(() => {
        settled = true;
      });

      // Past the default timeout, but the override keeps it pending.
      jest.advanceTimersByTime(1000);
      await Promise.resolve();
      expect(settled).toBe(false);
      expect(d.pendingCount()).toBe(1);

      // Past the override: now it rejects, reporting the override duration.
      jest.advanceTimersByTime(59_000);
      await expect(p).rejects.toThrow(/timeout \(60s\)/);
      expect(d.pendingCount()).toBe(0);
    });

    it('falls back to the default timeout for unlisted actions', async () => {
      jest.useFakeTimers();
      const d = new Dispatcher({
        send: (line) => {
          sent.push(line);
          return true;
        },
        getToken: () => 'test-token',
        timeoutMs: 1000,
        actionTimeoutsMs: { export_photos: 60_000 },
      });

      const p = d.call('list_collections', {});
      jest.advanceTimersByTime(1000);
      await expect(p).rejects.toThrow(/timeout \(1s\)/);
      expect(d.pendingCount()).toBe(0);
    });

    it('falls back to the default when an override is non-positive', async () => {
      jest.useFakeTimers();
      const d = new Dispatcher({
        send: (line) => {
          sent.push(line);
          return true;
        },
        getToken: () => 'test-token',
        timeoutMs: 1000,
        // 0 must mean "no override", not a 0 ms timer that rejects immediately.
        actionTimeoutsMs: { export_photos: 0 },
      });

      const p = d.call('export_photos', {});
      jest.advanceTimersByTime(1000);
      await expect(p).rejects.toThrow(/timeout \(1s\)/);
      expect(d.pendingCount()).toBe(0);
    });
  });
});
