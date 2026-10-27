import { describe, expect, it, jest } from '@jest/globals';
import jpeg from 'jpeg-js';
import { createCallToolHandler } from '../src/tool-handler.js';
import type { PluginResponse } from '../src/dispatcher.js';

function fixture() {
  const data = Buffer.alloc(32 * 16 * 4);
  for (let y = 0; y < 16; y++) {
    for (let x = 0; x < 32; x++) {
      const i = (y * 32 + x) * 4;
      data[i + (x < 16 ? 0 : 1)] = 255;
      data[i + 3] = 255;
    }
  }
  const image = jpeg.encode({ width: 32, height: 16, data }, 100).data;
  return { photo_id: 914, requested_size: 1024, width: 32, height: 16, bytes: image.length,
    image: { mime_type: 'image/jpeg', data: image.toString('base64') } };
}

function makeHandler(response: PluginResponse = { id: 'preview', result: fixture() }) {
  const call = jest.fn(async (_action: string, _args: unknown) => response);
  return { handler: createCallToolHandler({ isReady: () => true, dispatcher: { call } }), call };
}

describe('get_photo_preview region', () => {
  it('returns only the requested pixels and reports encoded dimensions and bytes', async () => {
    const { handler, call } = makeHandler();
    const result = await handler('get_photo_preview', {
      photo_id: 914, region: { x: 0.5, y: 0, width: 0.5, height: 0.5 },
    });

    expect(result.isError).toBeUndefined();
    expect(call).toHaveBeenCalledWith('get_photo_preview', { photo_id: 914, size: 1024 });
    const image = result.content[1];
    if (image.type !== 'image') throw new Error('Expected cropped JPEG');
    const encoded = Buffer.from(image.data, 'base64');
    const cropped = jpeg.decode(encoded);
    expect([cropped.width, cropped.height]).toEqual([16, 8]);
    expect(JSON.parse(result.content[0].text)).toEqual({
      photo_id: 914, requested_size: 1024, width: 16, height: 8, bytes: encoded.length,
    });
    for (let i = 0; i < cropped.data.length; i += 4) {
      expect(cropped.data[i]).toBeLessThan(5);
      expect(cropped.data[i + 1]).toBeGreaterThan(250);
      expect(cropped.data[i + 2]).toBeLessThan(5);
    }
  });

  it.each([
    { size: undefined, expected: 2048 },
    { size: 64, expected: 640 },
    { size: 2048, expected: 2048 },
  ])('requests a larger source for a small region (size=$size)', async ({ size, expected }) => {
    const { handler, call } = makeHandler();
    await handler('get_photo_preview', {
      photo_id: 'photo.raw', ...(size === undefined ? {} : { size }),
      region: { x: 0, y: 0, width: 0.1, height: 0.1 },
    });
    expect(call).toHaveBeenCalledWith('get_photo_preview', { photo_id: 'photo.raw', size: expected });
  });

  it('leaves the no-region full-frame arguments, metadata and JPEG bytes unchanged', async () => {
    const preview = fixture();
    const { handler, call } = makeHandler({ id: 'preview', result: preview });
    const result = await handler('get_photo_preview', { photo_id: 914, size: 1024 });
    const { image, ...metadata } = preview;
    expect(call).toHaveBeenCalledWith('get_photo_preview', { photo_id: 914, size: 1024 });
    expect(result.content).toEqual([
      { type: 'text', text: JSON.stringify(metadata) },
      { type: 'image', data: image.data, mimeType: image.mime_type },
    ]);
  });

  it.each([
    { size: 'cull', expected: 1024 },
    { size: 'detail', expected: 2048 },
  ])('normalizes named size $size before applying region source scaling', async ({ size, expected }) => {
    const { handler, call } = makeHandler();
    const result = await handler('get_photo_preview', {
      photo_id: 914, size, region: { x: 0, y: 0, width: 0.5, height: 0.5 },
    });
    expect(result.isError).toBeUndefined();
    expect(call).toHaveBeenCalledWith('get_photo_preview', { photo_id: 914, size: expected });
  });

  it('rounds a subpixel region outward to at least one pixel', async () => {
    const { handler } = makeHandler();
    const result = await handler('get_photo_preview', {
      photo_id: 914, region: { x: 0.999, y: 0.999, width: 0.001, height: 0.001 },
    });
    expect(result.isError).toBeUndefined();
    expect(JSON.parse(result.content[0].text)).toMatchObject({ width: 1, height: 1 });
  });

  it('returns a valid pixel when a positive region is smaller than floating-point spacing', async () => {
    const { handler } = makeHandler();
    const result = await handler('get_photo_preview', {
      photo_id: 914, region: { x: 0.5, y: 0.5, width: 1e-20, height: 1e-20 },
    });
    expect(result.isError).toBeUndefined();
    expect(JSON.parse(result.content[0].text)).toMatchObject({ width: 1, height: 1 });
    const image = result.content[1];
    if (image.type !== 'image') throw new Error('Expected cropped JPEG');
    const decoded = jpeg.decode(Buffer.from(image.data, 'base64'));
    expect([decoded.width, decoded.height, decoded.data.length]).toEqual([1, 1, 4]);
  });

  it.each([
    {}, { x: 0, y: 0, width: 0.2 }, null, [],
    { x: 0, y: 0, width: 0, height: 1 },
    { x: 0, y: 0, width: 1, height: -0.1 },
    { x: -0.1, y: 0, width: 0.1, height: 1 },
    { x: 1, y: 0, width: 0.1, height: 1 },
    { x: 0.9, y: 0, width: 0.5, height: 1 },
    { x: 0, y: 0.9, width: 1, height: 0.5 },
    { x: 0, y: 0, width: 0.1, height: 1, extra: true },
  ])('rejects malformed or out-of-frame region %j before rendering', async (region) => {
    const { handler, call } = makeHandler();
    const result = await handler('get_photo_preview', { photo_id: 914, region });
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toMatch(/region|extra/);
    expect(call).not.toHaveBeenCalled();
  });

  it.each([
    { id: 'preview', result: null },
    { id: 'preview', result: { image: { mime_type: 'image/png', data: 'broken' } } },
    { id: 'preview', result: { image: { mime_type: 'image/jpeg', data: 'broken' } } },
    { id: 'preview', error: 'Photo not found: 914' },
  ])('returns an error without an image for unusable plugin response %j', async (response) => {
    const { handler } = makeHandler(response);
    const result = await handler('get_photo_preview', {
      photo_id: 914, region: { x: 0, y: 0, width: 0.1, height: 0.1 },
    });
    expect(result.isError).toBe(true);
    expect(result.content).toHaveLength(1);
  });
});
