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

  it('bounds apply_denoise amount and batch size', () => {
    expect(validateToolArgs('apply_denoise', { photo_ids: [914], amount: 45 })).toBeNull();
    expect(validateToolArgs('apply_denoise', { photo_ids: [914], amount: 0 })).toContain('amount');
    expect(validateToolArgs('apply_denoise', { photo_ids: [914], amount: 101 })).toContain('amount');
    expect(validateToolArgs('apply_denoise', { photo_ids: [914], amount: 30.5 })).toContain('amount');
    expect(validateToolArgs('apply_denoise', { photo_ids: [914] })).toContain('amount');
    const tooMany = Array.from({ length: 101 }, (_, i) => i + 1);
    expect(validateToolArgs('apply_denoise', { photo_ids: tooMany, amount: 30 })).toContain('photo_ids');
  });

  it('requires a single photo for list_masks', () => {
    expect(validateToolArgs('list_masks', { photo_id: 914 })).toBeNull();
    expect(validateToolArgs('list_masks', { photo_id: '/a.dng' })).toBeNull();
    expect(validateToolArgs('list_masks', {})).toContain('photo_id');
    expect(validateToolArgs('list_masks', { photo_id: [914] })).toContain('photo_id');
    expect(validateToolArgs('list_masks', { photo_id: 914, extra: 1 })).toContain('unknown property "extra"');
  });

  describe('gradient mask tools', () => {
    const linear = {
      photo_id: 1,
      shape: 'linear',
      start: { x: 0.5, y: 0.2 },
      end: { x: 0.5, y: 0.6 },
    };
    const radial = {
      photo_id: '/a.dng',
      shape: 'radial',
      center: { x: 0.5, y: 0.5 },
      width: 0.4,
      height: 0.6,
      rotation: 30,
      feather: 20,
      area: 'outside',
      mask_id: 'abc',
      mode: 'subtract',
    };

    it('accepts linear and radial gradients', () => {
      expect(validateToolArgs('create_gradient_mask', linear)).toBeNull();
      expect(validateToolArgs('create_gradient_mask', radial)).toBeNull();
      expect(validateToolArgs('create_gradient_mask', { ...linear, name: 'Sky' })).toBeNull();
    });

    it('requires a photo and a shape', () => {
      expect(validateToolArgs('create_gradient_mask', { shape: 'linear' })).toContain('photo_id');
      expect(validateToolArgs('create_gradient_mask', { photo_id: 1 })).toContain('shape');
      expect(validateToolArgs('create_gradient_mask', { ...linear, shape: 'brush' })).toContain('shape');
    });

    it('rejects coordinates outside the image', () => {
      expect(validateToolArgs('create_gradient_mask', { ...linear, end: { x: 0.5, y: 1.1 } })).toContain('end');
      expect(validateToolArgs('create_gradient_mask', { ...linear, start: { x: -0.1, y: 0.5 } })).toContain('start');
      expect(validateToolArgs('create_gradient_mask', { ...radial, center: { x: 2, y: 0.5 } })).toContain('center');
    });

    it('rejects pixel-style or incomplete points and unknown properties', () => {
      expect(validateToolArgs('create_gradient_mask', { ...linear, start: { x: 0.5 } })).toContain('start');
      expect(validateToolArgs('create_gradient_mask', { ...linear, start: [0.5, 0.5] })).toContain('start');
      expect(validateToolArgs('create_gradient_mask', { ...linear, start: { x: '0.5', y: 0.5 } })).toContain('start');
      expect(validateToolArgs('create_gradient_mask', { ...linear, extra: 1 })).toContain('unknown property "extra"');
    });

    it('bounds the radial fields', () => {
      expect(validateToolArgs('create_gradient_mask', { ...radial, width: 0 })).toContain('width');
      expect(validateToolArgs('create_gradient_mask', { ...radial, height: 3 })).toContain('height');
      expect(validateToolArgs('create_gradient_mask', { ...radial, feather: 101 })).toContain('feather');
      expect(validateToolArgs('create_gradient_mask', { ...radial, rotation: 400 })).toContain('rotation');
      expect(validateToolArgs('create_gradient_mask', { ...radial, area: 'around' })).toContain('area');
      expect(validateToolArgs('create_gradient_mask', { ...radial, mode: 'intersect' })).toContain('mode');
    });

    it('updates a gradient by tool id with any subset of fields', () => {
      expect(validateToolArgs('update_gradient_mask', { photo_id: 1, tool_id: 'T1', feather: 5 })).toBeNull();
      expect(
        validateToolArgs('update_gradient_mask', { photo_id: 1, tool_id: 'T1', end: { x: 0.1, y: 0.9 } }),
      ).toBeNull();
      expect(validateToolArgs('update_gradient_mask', { photo_id: 1, feather: 5 })).toContain('tool_id');
      expect(validateToolArgs('update_gradient_mask', { photo_id: 1, tool_id: 'T1', feather: 500 })).toContain('feather');
      expect(
        validateToolArgs('update_gradient_mask', { photo_id: 1, tool_id: 'T1', shape: 'radial' }),
      ).toContain('unknown property "shape"');
    });
  });

  describe('create_range_mask', () => {
    const luminance = { photo_id: 1, type: 'luminance', luminance: { min: 0.3, max: 0.6, falloff: 0.1 } };
    const sample = { x: 0.2, y: 0.8, red: 0.46, green: 0.46, blue: 0.46 };
    const color = { photo_id: '/a.dng', type: 'color', color: { sample, amount: 0.4 } };

    it('accepts luminance and color ranges', () => {
      expect(validateToolArgs('create_range_mask', luminance)).toBeNull();
      expect(validateToolArgs('create_range_mask', color)).toBeNull();
      expect(
        validateToolArgs('create_range_mask', { ...luminance, mask_id: 'C1', mode: 'subtract', invert: true }),
      ).toBeNull();
      expect(validateToolArgs('create_range_mask', { ...color, name: 'Foliage' })).toBeNull();
    });

    it('requires a photo and a type, and offers no depth type', () => {
      expect(validateToolArgs('create_range_mask', { type: 'luminance' })).toContain('photo_id');
      expect(validateToolArgs('create_range_mask', { photo_id: 1 })).toContain('type');
      expect(validateToolArgs('create_range_mask', { ...luminance, type: 'depth' })).toContain('type');
    });

    it('accepts one sample point only', () => {
      expect(validateToolArgs('create_range_mask', { ...color, color: { sample: [sample, sample] } })).toContain(
        'color.sample',
      );
      expect(validateToolArgs('create_range_mask', { ...color, color: { samples: [sample] } })).toContain(
        'unknown property "samples"',
      );
      expect(validateToolArgs('create_range_mask', { ...color, color: { amount: 0.4 } })).toContain('sample');
    });

    it('bounds the numbers', () => {
      expect(
        validateToolArgs('create_range_mask', { ...luminance, luminance: { min: -0.1, max: 0.5 } }),
      ).toContain('luminance.min');
      expect(validateToolArgs('create_range_mask', { ...luminance, luminance: { min: 0.1 } })).toContain('max');
      expect(
        validateToolArgs('create_range_mask', { ...luminance, luminance: { min: 0.1, max: 0.5, falloff: 2 } }),
      ).toContain('luminance.falloff');
      expect(
        validateToolArgs('create_range_mask', { ...color, color: { sample: { ...sample, x: 1.5 } } }),
      ).toContain('color.sample.x');
      expect(validateToolArgs('create_range_mask', { ...color, color: { sample, amount: 0 } })).toContain(
        'color.amount',
      );
      expect(validateToolArgs('create_range_mask', { ...color, color: { sample, amount: 1.1 } })).toContain(
        'color.amount',
      );
      expect(validateToolArgs('create_range_mask', { ...luminance, mode: 'intersect' })).toContain('mode');
    });

    it('rejects unknown properties', () => {
      expect(validateToolArgs('create_range_mask', { ...luminance, depth: {} })).toContain('unknown property "depth"');
      expect(
        validateToolArgs('create_range_mask', { ...luminance, luminance: { min: 0, max: 1, extra: 1 } }),
      ).toContain('unknown property "extra"');
    });
  });

  it('requires exactly one deletion target for delete_masks', () => {
    expect(validateToolArgs('delete_masks', { photo_id: 914, mask_ids: ['m-1'] })).toBeNull();
    expect(validateToolArgs('delete_masks', { photo_id: 914, tool_ids: ['t-1', 't-2'] })).toBeNull();
    expect(validateToolArgs('delete_masks', { photo_id: '/a.dng', all: true })).toBeNull();
    expect(validateToolArgs('delete_masks', { photo_id: 914 })).toContain('Invalid arguments for delete_masks');
    expect(validateToolArgs('delete_masks', { photo_id: 914, mask_ids: ['m'], all: true })).toContain('oneOf');
    expect(validateToolArgs('delete_masks', { photo_id: 914, mask_ids: ['m'], tool_ids: ['t'] })).toContain('oneOf');
    expect(validateToolArgs('delete_masks', { photo_id: 914, all: false })).toContain('all');
    expect(validateToolArgs('delete_masks', { photo_id: 914, mask_ids: [] })).toContain('mask_ids');
    expect(validateToolArgs('delete_masks', { photo_id: 914, mask_ids: [7] })).toContain('mask_ids');
    expect(validateToolArgs('delete_masks', { mask_ids: ['m'] })).toContain('photo_id');
    const tooMany = Array.from({ length: 101 }, (_, i) => `m-${i}`);
    expect(validateToolArgs('delete_masks', { photo_id: 914, mask_ids: tooMany })).toContain('mask_ids');
  });

  it('requires a photo list for delete_empty_masks', () => {
    expect(validateToolArgs('delete_empty_masks', { photo_ids: [914, '/a.dng'] })).toBeNull();
    expect(validateToolArgs('delete_empty_masks', {})).toContain('photo_ids');
    expect(validateToolArgs('delete_empty_masks', { photo_ids: [] })).toContain('photo_ids');
    expect(validateToolArgs('delete_empty_masks', { photo_ids: 914 })).toContain('photo_ids');
    expect(validateToolArgs('delete_empty_masks', { photo_ids: [914], extra: 1 })).toContain('unknown property "extra"');
  });

  it('requires photo, mask and a known numeric slider for set_mask_adjustments', () => {
    const ok = { photo_id: 914, mask_id: 'm-1', adjustments: { local_Exposure: 0.5, local_Shadows: -20 } };

    expect(validateToolArgs('set_mask_adjustments', ok)).toBeNull();
    expect(validateToolArgs('set_mask_adjustments', { ...ok, photo_id: '/a.dng' })).toBeNull();
    expect(validateToolArgs('set_mask_adjustments', { ...ok, mask_id: undefined })).toContain('mask_id');
    expect(validateToolArgs('set_mask_adjustments', { ...ok, mask_id: '' })).toContain('mask_id');
    expect(validateToolArgs('set_mask_adjustments', { ...ok, adjustments: undefined })).toContain('adjustments');
    expect(validateToolArgs('set_mask_adjustments', { ...ok, adjustments: {} })).toContain('adjustments');
    expect(validateToolArgs('set_mask_adjustments', { ...ok, adjustments: { local_Bogus: 1 } })).toContain(
      'unknown property "local_Bogus"',
    );
    expect(validateToolArgs('set_mask_adjustments', { ...ok, adjustments: { local_Exposure: '1' } })).toContain(
      'adjustments.local_Exposure',
    );
    expect(validateToolArgs('set_mask_adjustments', { ...ok, extra: 1 })).toContain('unknown property "extra"');
  });

  it('requires photo and mask for get_mask_adjustments', () => {
    expect(validateToolArgs('get_mask_adjustments', { photo_id: 914, mask_id: 'm-1' })).toBeNull();
    expect(validateToolArgs('get_mask_adjustments', { photo_id: 914 })).toContain('mask_id');
    expect(validateToolArgs('get_mask_adjustments', { mask_id: 'm-1' })).toContain('photo_id');
    expect(validateToolArgs('get_mask_adjustments', { photo_id: 914, mask_id: 7 })).toContain('mask_id');
  });

  it('requires a photo, a mask id and a mode for invert_mask', () => {
    const valid = { photo_id: 914, mask_id: 'abc', mode: 'in_place' };
    expect(validateToolArgs('invert_mask', valid)).toBeNull();
    expect(validateToolArgs('invert_mask', { ...valid, mode: 'copy' })).toBeNull();
    expect(validateToolArgs('invert_mask', { photo_id: 914, mode: 'copy' })).toContain('mask_id');
    expect(validateToolArgs('invert_mask', { photo_id: 914, mask_id: 'abc' })).toContain('mode');
    expect(validateToolArgs('invert_mask', { ...valid, mode: 'toggle' })).toContain('mode');
    expect(validateToolArgs('invert_mask', { ...valid, mask_id: '' })).toContain('mask_id');
    expect(validateToolArgs('invert_mask', { ...valid, extra: 1 })).toContain('unknown property "extra"');
  });

  it('validates create_mask type and adjustment ranges', () => {
    expect(validateToolArgs('create_mask', { photo_id: 914, type: 'sky' })).toBeNull();
    expect(validateToolArgs('create_mask', { photo_id: '/a.dng', type: 'subject', adjustments: {} })).toBeNull();
    expect(validateToolArgs('create_mask', {
      photo_id: 914,
      type: 'background',
      adjustments: { exposure: -4, noise: 100, temperature: -100, tint: 12.5 },
    })).toBeNull();
    expect(validateToolArgs('create_mask', { photo_id: 914 })).toContain('type');
    expect(validateToolArgs('create_mask', { type: 'sky' })).toContain('photo_id');
    expect(validateToolArgs('create_mask', { photo_id: 914, type: 'people' })).toContain('type');
    expect(validateToolArgs('create_mask', { photo_id: [914], type: 'sky' })).toContain('photo_id');
    expect(validateToolArgs('create_mask', {
      photo_id: 914,
      type: 'sky',
      adjustments: { exposure: 4.1 },
    })).toContain('adjustments.exposure');
    expect(validateToolArgs('create_mask', {
      photo_id: 914,
      type: 'sky',
      adjustments: { contrast: -101 },
    })).toContain('adjustments.contrast');
    expect(validateToolArgs('create_mask', {
      photo_id: 914,
      type: 'sky',
      adjustments: { exposure: '1' },
    })).toContain('adjustments.exposure');
    expect(validateToolArgs('create_mask', {
      photo_id: 914,
      type: 'sky',
      adjustments: { vibrance: 1 },
    })).toContain('unknown property "vibrance"');
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

  it('accepts metadata strings and rejects other types or unknown fields', () => {
    const base = { photo_ids: [914] };

    expect(validateToolArgs('set_metadata', { ...base, title: 'Dunluce Castle', caption: '' })).toBeNull();
    expect(validateToolArgs('set_metadata', { ...base, copyright_info_url: 'https://example.com', creator_url: '' })).toBeNull();
    expect(validateToolArgs('set_metadata', { ...base, copyright_status: 'copyrighted' })).toContain('copyright_status');
    expect(validateToolArgs('set_metadata', { ...base, title: 7 })).toContain('title');
    expect(validateToolArgs('set_metadata', { ...base, artist: 'Jane' })).toContain('artist');
  });

  it('requires a non-empty keyword and new name to rename', () => {
    expect(validateToolArgs('rename_keyword', { keyword: 'Places|KC', new_name: 'Kansas City' })).toBeNull();
    expect(validateToolArgs('rename_keyword', { keyword: 'person' })).toContain("required property 'new_name'");
    expect(validateToolArgs('rename_keyword', { keyword: '', new_name: 'x' })).toContain('keyword');
  });

  it('requires a collection name to delete and nothing else', () => {
    expect(validateToolArgs('delete_collection', { collection_name: 'Temp' })).toBeNull();
    expect(validateToolArgs('delete_collection', {})).toContain("required property 'collection_name'");
    expect(validateToolArgs('delete_collection', { collection_name: 'Temp', photo_ids: [914] })).toContain('photo_ids');
  });

  it('requires a collection name to list its photos and pages with limit/offset', () => {
    expect(validateToolArgs('get_collection_photos', { collection_name: 'Trip', limit: 10, offset: 20 })).toBeNull();
    expect(validateToolArgs('get_collection_photos', {})).toContain("required property 'collection_name'");
    expect(validateToolArgs('get_collection_photos', { collection_name: 'Trip', offset: -1 })).toContain('offset');
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
