import { describe, it, expect, beforeEach, afterEach, jest } from '@jest/globals';
import { startHeartbeat, type HeartbeatDispatcher } from '../src/heartbeat.js';

const okDispatcher = (): HeartbeatDispatcher => ({
  call: jest.fn((_action: string, _params: unknown) => Promise.resolve({ pong: true })),
});

const failingDispatcher = (failure: Error): HeartbeatDispatcher => ({
  call: jest.fn((_action: string, _params: unknown) => Promise.reject(failure)),
});

describe('startHeartbeat', () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('does not ping before the interval elapses', () => {
    const dispatcher = okDispatcher();
    startHeartbeat(dispatcher, 30_000);

    expect(dispatcher.call).not.toHaveBeenCalled();
  });

  it('pings once per interval with action "ping" and empty params', () => {
    const dispatcher = okDispatcher();
    startHeartbeat(dispatcher, 30_000);

    jest.advanceTimersByTime(30_000);
    expect(dispatcher.call).toHaveBeenCalledTimes(1);
    expect(dispatcher.call).toHaveBeenCalledWith('ping', {});

    jest.advanceTimersByTime(30_000);
    expect(dispatcher.call).toHaveBeenCalledTimes(2);

    jest.advanceTimersByTime(60_000);
    expect(dispatcher.call).toHaveBeenCalledTimes(4);
  });

  it('logs via onError and does not throw when a ping is rejected', async () => {
    const failure = new Error('timeout');
    const dispatcher = failingDispatcher(failure);
    const onError = jest.fn();
    startHeartbeat(dispatcher, 30_000, onError);

    expect(() => jest.advanceTimersByTime(30_000)).not.toThrow();
    // Let the rejected promise's .catch handler run before asserting.
    await Promise.resolve();
    await Promise.resolve();

    expect(onError).toHaveBeenCalledWith(failure);
  });

  it('defaults onError to a console.error log line mentioning the failure', async () => {
    const failure = new Error('socket dropped');
    const dispatcher = failingDispatcher(failure);
    const consoleSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
    startHeartbeat(dispatcher, 30_000);

    jest.advanceTimersByTime(30_000);
    await Promise.resolve();
    await Promise.resolve();

    expect(consoleSpy).toHaveBeenCalledWith(expect.stringContaining('[heartbeat] ping failed: socket dropped'));
    consoleSpy.mockRestore();
  });

  it('stops pinging once the returned timer is cleared', () => {
    const dispatcher = okDispatcher();
    const timer = startHeartbeat(dispatcher, 30_000);
    clearInterval(timer);

    jest.advanceTimersByTime(120_000);
    expect(dispatcher.call).not.toHaveBeenCalled();
  });
});