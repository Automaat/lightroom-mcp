import { describe, it, expect } from '@jest/globals';
import { readFileSync } from 'node:fs';
import { createCallToolHandler } from '../src/tool-handler.js';

import type { PluginResponse } from '../src/dispatcher.js';

describe('develop setting schema', () => {
  const invalidCurves = [
    [0, 0, 128, 120, 255], [0, 0, 128.5, 120, 255, 255],
    [0, 0, 128, 300, 255, 255], [0, 0, 128, -1, 255, 255],
    [0, 0], Array.from({ length: 66 }, () => 0),
  ];
  const invalidCalls: [string, Record<string, unknown>, string][] = [
    ['set_develop_settings', { photo_id: 914, settings: { NotAKey: 1 } }, 'NotAKey'],
    ['copy_develop_settings', { source_id: 914, target_ids: [915], settings: ['NotAKey'] }, 'settings'],
    ['create_develop_preset', { photo_id: 914, preset_name: 'test', settings: ['NotAKey'] }, 'settings'],
    ['set_develop_settings', { photo_id: 914, settings: {} }, 'settings'],
    ['set_develop_settings', { photo_id: 914, settings: { Exposure2012: [0, 0, 255, 255] } }, 'Exposure2012'],
    ['set_develop_settings', { photo_id: 914, settings: { ToneCurvePV2012: 1 } }, 'ToneCurvePV2012'],
    ...invalidCurves.map((curve): [string, Record<string, unknown>, string] =>
      ['set_develop_settings', { photo_id: 914, settings: { ToneCurvePV2012: curve } }, 'ToneCurvePV2012']),
  ];

  it.each(invalidCalls)('rejects invalid %s settings before dispatch (%#)', async (name, args, field) => {
    let calls = 0;
    const handler = makeHandler({ call: async () => {
      calls++;
      return { id: '1', result: {} };
    } });
    const result = await handler(name, args);
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain(field);
    expect(calls).toBe(0);
  });
});

function makeHandler(opts: {
  ready?: boolean;
  call?: (action: string, params: unknown) => Promise<PluginResponse>;
} = {}) {
  return createCallToolHandler({
    isReady: () => opts.ready ?? true,
    dispatcher: {
      call: opts.call ?? (async () => ({ id: 'x', result: null })),
    },
  });
}

describe('createCallToolHandler', () => {
  it.each([['cull', 512], ['detail', 1024]] as const)('get_photo_preview resolves %s before dispatch', async (size, edge) => {
    const args = { photo_id: 914, size };
    let captured: unknown;
    const handler = makeHandler({ call: async (_action, params) => {
      captured = params;
      return { id: '1', result: { requested_size: edge, width: 855, height: 570,
        image: { mime_type: 'image/jpeg', data: 'QUJD' } } };
    } });
    const result = await handler('get_photo_preview', args);
    expect(captured).toEqual({ photo_id: 914, size: edge });
    expect(args.size).toBe(size);
    expect(JSON.parse(result.content[0].text)).toEqual({ requested_size: edge, width: 855, height: 570 });
    expect(result.content[1]).toEqual({ type: 'image', mimeType: 'image/jpeg', data: 'QUJD' });
  });

  it.each([undefined, 64, 512.5, 1024, 2048])('get_photo_preview preserves numeric or omitted size %s', async size => {
    const args = size === undefined ? { photo_id: 914 } : { photo_id: 914, size };
    let captured: unknown;
    await makeHandler({ call: async (_action, params) => {
      captured = params;
      return { id: '1', result: null };
    } })('get_photo_preview', args);
    expect(captured).toEqual(args);
  });

  it.each(['huge', '512', '', 63, 5000, null, true, {}, NaN, Infinity])('get_photo_preview rejects invalid size %s before dispatch', async size => {
    let calls = 0;
    const result = await makeHandler({ call: async () => { calls++; return { id: '1', result: null }; } })
      ('get_photo_preview', { photo_id: 914, size });
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toMatch(/cull.*detail.*64.*2048/);
    expect(calls).toBe(0);
  });

  it('get_photo_previews keeps numeric-only sizes', async () => {
    let calls = 0;
    const result = await makeHandler({ call: async () => { calls++; return { id: '1', result: null }; } })
      ('get_photo_previews', { photo_ids: [914], size: 'cull' });
    expect(result.isError).toBe(true);
    expect(calls).toBe(0);
  });

  it('returns isError when plugin not connected', async () => {
    const handler = makeHandler({ ready: false });
    const result = await handler('list_collections', {});
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toMatch(/not connected/i);
    expect(result.content[0].text).not.toMatch(/[\r\n]/);
    expect(result.content[0].text.length).toBeLessThan(160);
    expect(result.content[0].text).toMatch(/bring Lightroom to the front|Start Server/);
  });

  it('forwards action and args to dispatcher', async () => {
    let captured: { action: string; params: unknown } | null = null;
    const handler = makeHandler({
      call: async (action, params) => {
        captured = { action, params };
        return { id: '1', result: { ok: true } };
      },
    });
    await handler('search_photos', { rating: 5 });
    expect(captured).toEqual({ action: 'search_photos', params: { rating: 5 } });
  });

  it('serializes successful result as pretty JSON in text content', async () => {
    const handler = makeHandler({
      call: async () => ({ id: '1', result: { count: 3, items: ['a', 'b'] } }),
    });
    const result = await handler('list_collections', {});
    expect(result.isError).toBeUndefined();
    expect(result.content[0].type).toBe('text');
    expect(JSON.parse(result.content[0].text)).toEqual({ count: 3, items: ['a', 'b'] });
  });

  it('returns an image result as JSON text followed by an image block', async () => {
    const handler = makeHandler({
      call: async () => ({
        id: '1',
        result: { photo_id: 914, bytes: 3, image: { mime_type: 'image/jpeg', data: 'QUJD' } },
      }),
    });
    const result = await handler('get_photo_preview', { photo_id: 914 });

    expect(result.isError).toBeUndefined();
    expect(JSON.parse(result.content[0].text)).toEqual({ photo_id: 914, bytes: 3 });
    expect(result.content[1]).toEqual({ type: 'image', data: 'QUJD', mimeType: 'image/jpeg' });
    expect(result.content).toHaveLength(2);
  });

  it('batch preview maps three ids to images in input order', async () => {
    const previews = [1, 2, 3].map(id => ({ photo_id: id, requested_id: id,
      image: { mime_type: 'image/jpeg', data: `jpeg${id}` } }));
    const result = await makeHandler({ call: async () => ({ id: '1', result: { previews, complete: true } }) })
      ('get_photo_previews', { photo_ids: [1, 2, 3] });
    expect(JSON.parse(result.content[0].text)).toEqual({ complete: true,
      previews: [1, 2, 3].map(id => ({ photo_id: id, requested_id: id, image_index: id })) });
    expect(result.content.slice(1)).toEqual([1, 2, 3].map(id => ({ type: 'image', mimeType: 'image/jpeg', data: `jpeg${id}` })));
  });

  it('batch preview error keeps good images and identifies the failed input', async () => {
    const previews = [
      { requested_id: 1, image: { mime_type: 'image/jpeg', data: 'one' } },
      { requested_id: 2, error: 'Photo not found: 2' },
      { requested_id: 3, image: { mime_type: 'image/jpeg', data: 'three' } },
    ];
    const result = await makeHandler({ call: async () => ({ id: '1', result: { previews } }) })
      ('get_photo_previews', { photo_ids: [1, 2, 3] });
    expect(JSON.parse(result.content[0].text).previews).toEqual([
      { requested_id: 1, image_index: 1 }, { requested_id: 2, error: 'Photo not found: 2' },
      { requested_id: 3, image_index: 2 },
    ]);
    expect(result.content.slice(1).map(c => c.type === 'image' ? c.data : undefined)).toEqual(['one', 'three']);
  });

  it('batch preview limit rejects more than 20 ids before dispatch', async () => {
    let calls = 0;
    const result = await makeHandler({ call: async () => { calls++; return { id: '1', result: null }; } })
      ('get_photo_previews', { photo_ids: Array.from({ length: 21 }, (_, i) => i + 1) });
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain('20');
    expect(calls).toBe(0);
  });

  it('batch preview timeout entry allows the plugin deadline to return a partial batch', () => {
    const source = readFileSync('src/index.ts', 'utf8');
    expect(source).toMatch(/get_photo_previews: 30_000/);
  });

  it('batch preview timeout preserves partial results and remaining ids', async () => {
    const result = await makeHandler({ call: async () => ({ id: '1', result: {
      complete: false, remaining_ids: [2, 3],
      previews: [{ requested_id: 1, image: { mime_type: 'image/jpeg', data: 'one' } }],
    } }) })('get_photo_previews', { photo_ids: [1, 2, 3] });
    expect(JSON.parse(result.content[0].text)).toEqual({ complete: false, remaining_ids: [2, 3],
      previews: [{ requested_id: 1, image_index: 1 }] });
    expect(result.content).toHaveLength(2);
  });

  it('leaves a result whose image field is not image data as plain JSON', async () => {
    const result = { name: 'Portfolio', image: 'cover.jpg' };
    const handler = makeHandler({ call: async () => ({ id: '1', result }) });
    const res = await handler('list_collections', {});

    expect(res.content).toHaveLength(1);
    expect(JSON.parse(res.content[0].text)).toEqual(result);
  });

  it('returns isError with prefixed message on plugin error response', async () => {
    const handler = makeHandler({
      call: async () => ({ id: '1', error: 'Unknown action' }),
    });
    const result = await handler('bogus', {});
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toBe('Error: Unknown action');
  });

  it('catches dispatcher rejections and returns isError', async () => {
    const handler = makeHandler({
      call: async () => {
        throw new Error('Plugin response timeout (30s)');
      },
    });
    const result = await handler('x', {});
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toBe('Plugin response timeout (30s)');
  });

  it('handles non-Error throws by stringifying', async () => {
    const handler = makeHandler({
      call: async () => {
        throw 'raw string';
      },
    });
    const result = await handler('x', {});
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toBe('raw string');
  });
});
