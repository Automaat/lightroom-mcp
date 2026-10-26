import { describe, it, expect } from '@jest/globals';
import jpeg from 'jpeg-js';
import { createCallToolHandler } from '../src/tool-handler.js';
import { photoStats } from '../src/photo-stats.js';
import type { PluginResponse } from '../src/dispatcher.js';

function image(width: number, height: number, value: (x: number, y: number) => number) {
  const data = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const offset = (y * width + x) * 4;
      data.fill(Math.round(value(x, y)), offset, offset + 3);
      data[offset + 3] = 255;
    }
  }
  return jpeg.encode({ width, height, data }, 100).data.toString('base64');
}

function handler(call: (action: string, params: unknown) => Promise<PluginResponse>) {
  return createCallToolHandler({ isReady: () => true, dispatcher: { call } });
}

function preview(data: string): PluginResponse {
  return { id: 'preview', result: { image: { data, mime_type: 'image/jpeg' } } };
}

describe('photo stats', () => {
  it.each([
    { name: 'white', value: 255, shadow: 0, highlight: 1, bin: 63 },
    { name: 'black', value: 0, shadow: 1, highlight: 0, bin: 0 },
    { name: 'mid-gray', value: 128, shadow: 0, highlight: 0, bin: 32 },
  ])('clipping for $name JPEG', async ({ value, shadow, highlight, bin }) => {
    const call = handler(async () => preview(image(32, 32, () => value)));

    const response = await call('get_photo_stats', { photo_ids: [1] });
    const data = JSON.parse(response.content[0].text) as { results: ReturnType<typeof photoStats>[] };

    expect(response.content).toHaveLength(1);
    expect(data.results[0].shadow_fraction).toBe(shadow);
    expect(data.results[0].highlight_fraction).toBe(highlight);
    expect(data.results[0].histogram[bin]).toBe(1);
    expect(data.results[0].mean_luminance).toBeCloseTo(value, 0);
    expect(data.results[0].sharpness).toBe(0);
  });

  it('sharpness ranks a checkerboard at least twice its box blur', () => {
    const checker = (x: number, y: number) => (Math.floor(x / 16) + Math.floor(y / 16)) % 2 * 255;
    const blurred = (x: number, y: number) => {
      let total = 0;
      for (let dy = -4; dy <= 4; dy++) {
        for (let dx = -4; dx <= 4; dx++) total += checker(Math.max(0, x + dx), Math.max(0, y + dy));
      }
      return total / 81;
    };

    const sharp = photoStats(image(512, 512, checker));
    const soft = photoStats(image(512, 512, blurred));

    expect(sharp.sharpness).toBeGreaterThanOrEqual(soft.sharpness * 2);
  });

  it('scale keeps scores within 25 percent at 512 and 1024 pixels', () => {
    const smaller = image(512, 256, (x, y) => (Math.floor(x / 16) + Math.floor(y / 16)) % 2 * 255);
    const larger = image(1024, 512, (x, y) => (Math.floor(x / 32) + Math.floor(y / 32)) % 2 * 255);

    const ratio = photoStats(larger).sharpness / photoStats(smaller).sharpness;

    expect(ratio).toBeGreaterThanOrEqual(0.75);
    expect(ratio).toBeLessThanOrEqual(1.25);
  });

  it('batch preserves input order and isolates a missing preview', async () => {
    const encoded = image(8, 8, () => 128);
    const call = handler(async (_action, params) => {
      const { photo_ids } = params as { photo_ids: number[] };
      return photo_ids[0] === 2 ? { id: 'missing', error: 'Photo not found: 2' } : preview(encoded);
    });

    const response = await call('get_photo_stats', { photo_ids: [1, 2, 3] });
    const data: unknown = JSON.parse(response.content[0].text);

    expect(response.isError).toBeUndefined();
    expect(data).toEqual({ results: [
      expect.objectContaining({ photo_id: 1, mean_luminance: 128 }),
      { photo_id: 2, error: 'Photo not found: 2' },
      expect.objectContaining({ photo_id: 3, mean_luminance: 128 }),
    ] });
  });

  it.each([
    { name: 'too many ids', photo_ids: Array<number>(21).fill(1), message: /20/ },
    { name: 'no ids', photo_ids: [], message: /1/ },
  ])('batch rejects $name', async ({ photo_ids, message }) => {
    const call = handler(async () => { throw new Error('unexpected dispatch'); });

    const response = await call('get_photo_stats', { photo_ids });

    expect(response.isError).toBe(true);
    expect(response.content[0].text).toMatch(message);
  });

  it('batch isolates invalid JPEG data and keeps duplicate ids', async () => {
    let count = 0;
    const encoded = image(8, 8, () => 110);
    const call = handler(async () => preview(++count === 2 ? 'broken' : encoded));

    const response = await call('get_photo_stats', { photo_ids: [1, 1, 1] });
    const data: unknown = JSON.parse(response.content[0].text);

    expect(data).toEqual({ results: [
      expect.objectContaining({ photo_id: 1, mean_luminance: 110 }),
      { photo_id: 1, error: expect.any(String) },
      expect.objectContaining({ photo_id: 1, mean_luminance: 110 }),
    ] });
  });

  it('size serializes one photo below 1500 characters', async () => {
    const encoded = image(256, 256, (x, y) => (x * 19 + y * 7) % 256);
    const call = handler(async () => preview(encoded));

    const response = await call('get_photo_stats', { photo_ids: [1] });

    expect(response.content[0].text.length).toBeLessThanOrEqual(1500);
  });
});
