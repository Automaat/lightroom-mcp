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

  it('rejects a non-finite altitude that JSON would turn into null', () => {
    const base = { photo_ids: [914], latitude: 1, longitude: 1 };

    expect(validateToolArgs('set_gps', { ...base, altitude: Infinity })).toContain('altitude');
    expect(validateToolArgs('set_gps', { ...base, altitude: -Infinity })).toContain('altitude');
    expect(validateToolArgs('set_gps', { ...base, altitude: 8848 })).toBeNull();
    expect(validateToolArgs('set_gps', { ...base, clear_altitude: true })).toBeNull();
  });

  it('rejects a control character that would cut the .json path short', () => {
    expect(validateToolArgs('export_photo_metadata', { destination: '/u/.zshrc\u0000.json' })).toContain('destination');
    expect(validateToolArgs('export_photo_metadata', { destination: '/u/a\nb.json' })).toContain('destination');
    expect(validateToolArgs('export_photo_metadata', { destination: '/u/zdjęcia 東京.json' })).toBeNull();
  });

  it('accepts only pick, reject or none as a flag', () => {
    const base = { photo_ids: [914] };

    expect(validateToolArgs('set_flag', { ...base, flag: 'pick' })).toBeNull();
    expect(validateToolArgs('set_flag', { ...base, flag: 'none' })).toBeNull();
    expect(validateToolArgs('set_flag', { ...base, flag: 'rejected' })).toContain('flag');
    expect(validateToolArgs('set_flag', { ...base, flag: -1 })).toContain('flag');
  });

  it('accepts IPTC location strings and rejects other types or unknown fields', () => {
    const base = { photo_ids: [914] };

    expect(validateToolArgs('set_location', { ...base, city: 'Kansas City', iso_country_code: 'US' })).toBeNull();
    expect(validateToolArgs('set_location', { ...base, sublocation: '' })).toBeNull();
    expect(validateToolArgs('set_location', { ...base, city: 42 })).toContain('city');
    expect(validateToolArgs('set_location', { ...base, state: 'Missouri' })).toContain('state');
  });

  it('bounds the preview size', () => {
    expect(validateToolArgs('get_photo_preview', { photo_id: 914 })).toBeNull();
    expect(validateToolArgs('get_photo_preview', { photo_id: 914, size: 2048 })).toBeNull();
    expect(validateToolArgs('get_photo_preview', { photo_id: 914, size: 4096 })).toContain('size');
    expect(validateToolArgs('get_photo_preview', { photo_id: 914, size: '1024' })).toContain('size');
  });

  it('requires a non-empty keyword and new name to rename', () => {
    expect(validateToolArgs('rename_keyword', { keyword: 'Places|KC', new_name: 'Kansas City' })).toBeNull();
    expect(validateToolArgs('rename_keyword', { keyword: 'person' })).toContain("required property 'new_name'");
    expect(validateToolArgs('rename_keyword', { keyword: '', new_name: 'x' })).toContain('keyword');
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
