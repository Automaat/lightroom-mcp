import { describe, it, expect, jest, afterEach } from '@jest/globals';
import jpeg from 'jpeg-js';
import { createCallToolHandler } from '../src/tool-handler.js';
import type { PluginResponse } from '../src/dispatcher.js';

function image(reverse = false) {
  const data = Buffer.alloc(90 * 80 * 4);
  for (let y = 0; y < 80; y++) {
    for (let x = 0; x < 90; x++) {
      const i = (y * 90 + x) * 4;
      data.fill(reverse ? 250 - x * 2 : x * 2, i, i + 3);
      data[i + 3] = 255;
    }
  }
  return jpeg.encode({ width: 90, height: 80, data }, 100).data.toString('base64');
}
const forward = image(), reversed = image(true);
function preview(id: number, time: number | null = id, data = forward): PluginResponse {
  return { id: 'test', result: { photo_id: id, capture_time: time, image: { mime_type: 'image/jpeg', data } } };
}
function handler(call: (action: string, args: unknown) => Promise<PluginResponse>) {
  return createCallToolHandler({ isReady: () => true, dispatcher: { call } });
}
interface Result {
  groups: { photo_ids: number[] }[];
  unprocessed: { photo_id: number; reason: string }[];
  complete: boolean;
  remaining_ids: number[];
}
afterEach(() => { jest.useRealTimers(); });

describe('duplicate groups', () => {
  it('signals require both nearby capture time and similar content', async () => {
    const call = handler(async (action, args) => {
      expect(action).toBe('find_duplicate_groups');
      const id = (args as { photo_ids: number[] }).photo_ids[0];
      return preview(id, id === 3 ? 600 : id, id === 4 ? reversed : forward);
    });
    const response = await call('find_duplicate_groups', { photo_ids: [1, 2, 3, 4] });
    const result = JSON.parse(response.content[0].text) as Result;
    expect(result.groups).toEqual([{ photo_ids: [1, 2] }]);
    expect(result.complete).toBe(true);
    expect(result.unprocessed).toEqual([]);
    expect(response.content).toHaveLength(1);
  });

  it('errors isolate failed previews, invalid JPEGs and absent raw capture times', async () => {
    const call = handler(async (_action, args) => {
      const id = (args as { photo_ids: number[] }).photo_ids[0];
      if (id === 2) return { id: 'test', error: 'Preview failed' };
      return preview(id, id === 3 ? null : 1, id === 4 ? 'broken' : forward);
    });
    const response = await call('find_duplicate_groups', { photo_ids: [1, 2, 3, 4, 5] });
    const result = JSON.parse(response.content[0].text) as Result;
    expect(response.isError).toBeUndefined();
    expect(result.groups).toEqual([{ photo_ids: [1, 5] }]);
    expect(result.unprocessed).toEqual([
      { photo_id: 2, reason: 'Preview failed' },
      { photo_id: 3, reason: 'No raw capture time' },
      { photo_id: 4, reason: expect.any(String) },
    ]);
  });

  it('limits reject more than 100 ids before dispatch', async () => {
    const dispatch = jest.fn(async () => preview(1));
    const response = await handler(dispatch)('find_duplicate_groups', { photo_ids: Array<number>(101).fill(1) });
    expect(response.isError).toBe(true);
    expect(response.content[0].text).toMatch(/100/);
    expect(dispatch).not.toHaveBeenCalled();
  });

  it('limits return groups so far and unreached ids at the deadline', async () => {
    jest.useFakeTimers();
    const call = handler(async (_action, args) => {
      const id = (args as { photo_ids: number[] }).photo_ids[0];
      if (id === 3) jest.advanceTimersByTime(25_001);
      return preview(id);
    });
    const response = await call('find_duplicate_groups', { photo_ids: [1, 2, 3, 4] });
    const result = JSON.parse(response.content[0].text) as Result;
    expect(result.groups).toEqual([{ photo_ids: [1, 2] }]);
    expect(result.complete).toBe(false);
    expect(result.remaining_ids).toEqual([3, 4]);
  });

  it('deduplicates ids and applies inclusive caller thresholds to every pair', async () => {
    const call = handler(async (_action, args) => {
      const id = (args as { photo_ids: number[] }).photo_ids[0];
      return preview(id, (id - 1) * 5);
    });
    const response = await call('find_duplicate_groups', {
      photo_ids: [1, 1, 2, 3], time_window_seconds: 5, max_hamming_distance: 0,
    });
    expect((JSON.parse(response.content[0].text) as Result).groups).toEqual([{ photo_ids: [1, 2] }]);
  });
});
