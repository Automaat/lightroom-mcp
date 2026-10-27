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

describe('set_rating_and_flag', () => {
  const invalid: Array<[Record<string, unknown>, string]> = [
    [{ photo_ids: [914] }, 'rating'],
    [{ photo_ids: [914], rating: 6, flag: 'pick' }, 'rating'],
    [{ photo_ids: [914], rating: '3', flag: 'pick' }, 'rating'],
    [{ photo_ids: [914], rating: 3, flag: 'rejected' }, 'flag'],
    [{ photo_ids: [914], flag: false }, 'flag'],
    [{ photo_ids: [], rating: 3 }, 'photo_ids'],
    [{ photo_ids: [914], rating: 3, label: 'red' }, 'label'],
  ];

  it.each(invalid)('rejects invalid arguments before dispatch (%#)', async (args, field) => {
    let calls = 0;
    const handler = makeHandler({ call: async () => {
      calls++;
      return { id: '1', result: {} };
    } });
    const result = await handler('set_rating_and_flag', args);
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain('Invalid arguments for set_rating_and_flag');
    expect(result.content[0].text).toContain(field);
    expect(calls).toBe(0);
  });

  it.each([
    { photo_ids: [914, '/a.jpg'], rating: 3 },
    { photo_ids: [914], flag: 'reject' },
    { photo_ids: [914], rating: 3, flag: 'pick' },
    { photo_ids: [914], rating: 0, flag: 'none' },
  ])('dispatches valid single-field and combined calls unchanged (%#)', async args => {
    const received: unknown[] = [];
    const handler = makeHandler({ call: async (action, params) => {
      received.push([action, params]);
      return { id: '1', result: { success: true, updated: 1, missing: [] } };
    } });
    const result = await handler('set_rating_and_flag', args);
    expect(result.isError).not.toBe(true);
    expect(received).toEqual([['set_rating_and_flag', args]]);
  });
});

describe('client-compatible metadata selectors', () => {
  const invalid: Array<[unknown, string]> = [
    [{}, 'photo_id'],
    [{ sections: ['developSettings'] }, 'photo_ids'],
    [{ photo_id: 914, photo_ids: [915] }, 'photo_id'],
    [{ photo_id: null }, 'photo_id'],
    [{ photo_id: false, photo_ids: [914] }, 'photo_id'],
    [{ photo_ids: '914' }, 'photo_ids'],
    [{ photo_ids: [] }, 'photo_ids'],
    [{ photo_ids: [null] }, 'photo_ids'],
    [{ photo_ids: [914], sections: ['unknown'] }, 'sections'],
    [false, 'object'],
  ];

  it.each(invalid)('never dispatches invalid selector combinations (%#)', async (args, field) => {
    let calls = 0;
    const handler = makeHandler({ call: async () => {
      calls++;
      return { id: '1', result: {} };
    } });
    const result = await handler('get_photo_metadata', args);
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain(field);
    expect(calls).toBe(0);
  });

  const photo = { id: 914, rating: 3, pickStatus: 1, title: 'Example' };
  const batch = { photos: [photo, photo], missing: ['absent'] };
  const valid: Array<[Record<string, unknown>, unknown]> = [
    [{ photo_id: 914 }, photo],
    [{ photo_id: '/a.jpg', sections: [] }, photo],
    [{ photo_id: 914, sections: ['developSettings', 'developSettings'] }, photo],
    [{ photo_ids: [914, '/a.jpg', 'absent'] }, batch],
    [{ photo_ids: [914, 914], sections: ['developSettings'] }, batch],
  ];

  it.each(valid)('preserves single/batch arguments and returned metadata (%#)', async (args, metadata) => {
    const received: unknown[] = [];
    const handler = makeHandler({ call: async (action, params) => {
      received.push([action, params]);
      return { id: '1', result: metadata };
    } });
    const result = await handler('get_photo_metadata', args);
    expect(result.isError).not.toBe(true);
    expect(received).toEqual([['get_photo_metadata', args]]);
    expect(JSON.parse(result.content[0].text)).toEqual(metadata);
  });
});

describe('createCallToolHandler', () => {
  const deletionFields = ['photo_id', 'photo_ids', 'mask_ids', 'tool_ids', 'all'] as const;
  const deletionValues: Record<(typeof deletionFields)[number], unknown> = {
    photo_id: 914, photo_ids: [914], mask_ids: ['m'], tool_ids: ['t'], all: true,
  };
  const deletionCombinations = Array.from({ length: 32 }, (_, bits) => {
    const fields = deletionFields.filter((_, i) => bits & (1 << i));
    const args: Record<string, unknown> = Object.fromEntries(fields.map(field => [field, deletionValues[field]]));
    const targets = fields.filter(field => ['mask_ids', 'tool_ids', 'all'].includes(field));
    const valid = fields.includes('photo_ids')
      ? fields.length === 1
      : fields.includes('photo_id') && targets.length === 1;
    return { args, valid };
  });

  it.each(deletionCombinations)('enforces private delete_masks selectors before dispatch (%#)', async ({ args, valid }) => {
    let calls = 0;
    const result = await makeHandler({ call: async () => {
      calls++;
      return { id: '1', result: null };
    } })('delete_masks', args);
    expect(Boolean(result.isError)).toBe(!valid);
    expect(calls).toBe(valid ? 1 : 0);
  });

  it.each([
    {},
    { photo_ids: [] },
    { photo_ids: [914], photo_id: 914 },
    { photo_ids: [914], mask_ids: ['m'] },
    { photo_ids: [914], tool_ids: ['t'] },
    { photo_ids: [914], all: true },
    { photo_ids: [914], photo_id: 914, all: true },
    { photo_id: 914, mask_ids: ['m'], empty: true },
  ])('rejects ambiguous delete_masks selectors before dispatch (%#)', async args => {
    let calls = 0;
    const result = await makeHandler({ call: async () => {
      calls++;
      return { id: '1', result: null };
    } })('delete_masks', args);
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain('Invalid arguments for delete_masks');
    expect(calls).toBe(0);
  });

  it.each([
    { photo_id: 914, mask_ids: ['m'] },
    { photo_id: 914, tool_ids: ['t'] },
    { photo_id: 914, all: true },
    { photo_ids: [914, '/a.dng'] },
  ])('dispatches each delete_masks mode unchanged (%#)', async args => {
    let captured: unknown;
    await makeHandler({ call: async (_action, params) => {
      captured = params;
      return { id: '1', result: null };
    } })('delete_masks', args);
    expect(captured).toEqual(args);
  });

  it.each([
    { photo_id: 1, type: 'people', parts: ['hair', 'hair'] },
    { photo_id: 1, type: 'people', parts: ['ears'] },
    { photo_id: 1, type: 'people' },
    { photo_id: 1, type: 'people', parts: [] },
    { photo_id: 1, type: 'landscape' },
    { photo_id: 1, type: 'landscape', categories: [] },
    { photo_id: 1, type: 'landscape', categories: ['lava'] },
    { photo_id: 1, type: 'landscape', categories: ['sky', 'sky'] },
    { photo_id: 1, type: 'sky', parts: ['hair'] },
    { photo_id: 1, type: 'subject', categories: ['sky'] },
    { photo_id: 1, type: 'background', parts: ['hair'] },
    { photo_id: 1, type: 'people', parts: ['hair'], categories: ['sky'] },
    { photo_id: 1, type: 'landscape', categories: ['sky'], parts: ['hair'] },
    { photo_id: 1, type: 'people', parts: ['hair'], adjustments: {} },
    { photo_id: 1, type: 'landscape', categories: ['sky'], adjustments: {} },
  ])('rejects invalid create_mask selectors before plugin dispatch: %j', async (args) => {
    let calls = 0;
    const handler = makeHandler({ call: async () => { calls++; return { id: '1', result: {} }; } });
    const result = await handler('create_mask', args);
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain('Invalid arguments for create_mask');
    expect(calls).toBe(0);
  });
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
