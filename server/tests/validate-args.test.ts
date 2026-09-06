import { describe, it, expect, jest } from '@jest/globals';
import { validateToolArgs } from '../src/validate-args.js';
import { createCallToolHandler } from '../src/tool-handler.js';

describe('validateToolArgs', () => {
  it('accepts arguments that satisfy the published schema', () => {
    expect(validateToolArgs('get_photo_metadata', { photo_id: 914 })).toBeNull();
    expect(validateToolArgs('get_photo_metadata', { photo_id: '/a.jpg' })).toBeNull();
    expect(validateToolArgs('set_rating', { photo_ids: [914], rating: 3 })).toBeNull();
    expect(validateToolArgs('search_photos', {})).toBeNull();
  });

  it('rejects a photo id that is neither a string nor a number', () => {
    const msg = validateToolArgs('get_photo_metadata', { photo_id: { nested: true } });

    expect(msg).toContain('Invalid arguments for get_photo_metadata');
    expect(msg).toContain('photo_id');
  });

  it('names a misspelled property instead of silently ignoring it', () => {
    const msg = validateToolArgs('search_photos', { not_a_real_filter: 1 });

    expect(msg).toContain('unknown property "not_a_real_filter"');
  });

  it('enforces documented ranges and types', () => {
    expect(validateToolArgs('set_rating', { photo_ids: [914], rating: 99 })).toContain('rating');
    expect(validateToolArgs('set_rating', { photo_ids: [914], rating: '3' })).toContain('rating');
    expect(validateToolArgs('search_photos', { limit: 'many' })).toContain('limit');
    expect(validateToolArgs('export_photos', {
      photo_ids: [914],
      destination: '/tmp',
      on_existing: 'ask',
    })).toContain('on_existing');
  });

  it('reports a missing required field', () => {
    const msg = validateToolArgs('set_rating', { photo_ids: [914] });

    expect(msg).toContain("required property 'rating'");
  });

  it('treats missing arguments as an empty object', () => {
    expect(validateToolArgs('search_photos', undefined)).toBeNull();
    expect(validateToolArgs('set_rating', undefined)).toContain('required property');
  });

  it('reports a violation that has no field path', () => {
    const msg = validateToolArgs('search_photos', 'not-an-object');

    expect(msg).toContain('Invalid arguments for search_photos');
    expect(msg).toContain('object');
  });

  it('leaves unknown tool names to the dispatcher', () => {
    expect(validateToolArgs('no_such_tool', { anything: true })).toBeNull();
  });
});

describe('tool handler argument validation', () => {
  it('fails before touching Lightroom', async () => {
    const call = jest.fn((_action: string, _params: unknown) =>
      Promise.resolve({ id: 'req_1', result: {} }));
    const handler = createCallToolHandler({ dispatcher: { call }, isReady: () => true });

    const res = await handler('get_photo_metadata', { photo_id: { nested: true } });

    expect(res.isError).toBe(true);
    expect(res.content[0].text).toContain('Invalid arguments');
    expect(call).not.toHaveBeenCalled();
  });

  it('lets a valid call through', async () => {
    const call = jest.fn((_action: string, _params: unknown) =>
      Promise.resolve({ id: 'req_1', result: { ok: true } }));
    const handler = createCallToolHandler({ dispatcher: { call }, isReady: () => true });

    const res = await handler('get_photo_metadata', { photo_id: 914 });

    expect(res.isError).toBeUndefined();
    expect(call).toHaveBeenCalledWith('get_photo_metadata', { photo_id: 914 });
  });
});
