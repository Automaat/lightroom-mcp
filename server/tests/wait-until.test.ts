import { describe, it, expect } from '@jest/globals';
import { waitUntil } from '../src/wait-until.js';

describe('waitUntil', () => {
  it('returns immediately when the predicate already holds', async () => {
    let sleeps = 0;
    const held = await waitUntil(() => true, 3_000, 50, () => 0, async () => {
      sleeps += 1;
    });

    expect(held).toBe(true);
    expect(sleeps).toBe(0);
  });

  it('returns true once the predicate flips before the deadline', async () => {
    let ticks = 0;
    const held = await waitUntil(
      () => ticks >= 3,
      3_000,
      50,
      () => ticks * 50,
      async () => {
        ticks += 1;
      },
    );

    expect(held).toBe(true);
    expect(ticks).toBe(3);
  });

  it('gives up at the deadline instead of waiting forever', async () => {
    let clock = 0;
    const held = await waitUntil(
      () => false,
      200,
      50,
      () => clock,
      async () => {
        clock += 50;
      },
    );

    expect(held).toBe(false);
    expect(clock).toBe(200);
  });
});
