import { afterEach, beforeEach, describe, expect, it, jest } from '@jest/globals';
import { ConnectionLossDeadline } from '../src/connection-loss.js';

describe('ConnectionLossDeadline', () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });
  afterEach(() => {
    jest.useRealTimers();
  });

  it('expires once, counted from the first loss', () => {
    const expired = jest.fn();
    const deadline = new ConnectionLossDeadline(1000, expired);
    deadline.start();
    jest.advanceTimersByTime(600);
    deadline.start();
    jest.advanceTimersByTime(400);
    expect(expired).toHaveBeenCalledTimes(1);
    jest.advanceTimersByTime(5000);
    expect(expired).toHaveBeenCalledTimes(1);
  });

  it('does not expire after the connection recovers', () => {
    const expired = jest.fn();
    const deadline = new ConnectionLossDeadline(1000, expired);
    deadline.start();
    deadline.clear();
    jest.advanceTimersByTime(5000);
    expect(expired).not.toHaveBeenCalled();
  });

  it('can start again after expiring', () => {
    const expired = jest.fn();
    const deadline = new ConnectionLossDeadline(1000, expired);
    deadline.start();
    jest.advanceTimersByTime(1000);
    deadline.start();
    jest.advanceTimersByTime(1000);
    expect(expired).toHaveBeenCalledTimes(2);
  });
});
