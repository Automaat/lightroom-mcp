import { describe, it, expect, beforeEach } from '@jest/globals';
import { Dispatcher } from '../src/dispatcher.js';

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
    const sentObj = JSON.parse(sent[0]);
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
    const id1 = JSON.parse(sent[0]).id;
    const id2 = JSON.parse(sent[1]).id;
    expect(id1).not.toBe(id2);

    // Resolve in reverse order
    dispatcher.handleResponseLine(JSON.stringify({ id: id2, result: 'second' }));
    dispatcher.handleResponseLine(JSON.stringify({ id: id1, result: 'first' }));

    expect((await p1).result).toBe('first');
    expect((await p2).result).toBe('second');
  });

  it('propagates plugin errors through the response', async () => {
    const promise = dispatcher.call('bogus', {});
    const id = JSON.parse(sent[0]).id;
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
    const id = JSON.parse(sent[0]).id;
    expect(dispatcher.pendingCount()).toBe(1);
    dispatcher.handleResponseLine(JSON.stringify({ id, result: 'ok' }));
    await p;
    expect(dispatcher.pendingCount()).toBe(0);
  });

  it('defaults params to empty object when undefined', async () => {
    const p = dispatcher.call('x', undefined);
    const sentObj = JSON.parse(sent[0]);
    expect(sentObj.params).toEqual({});
    await p.catch(() => {});
  });
});
