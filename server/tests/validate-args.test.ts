import { describe, it, expect, jest } from '@jest/globals';
import { validateToolArgs } from '../src/validate-args.js';
import { createCallToolHandler } from '../src/tool-handler.js';

describe('validateToolArgs', () => {
  it('set_ai_metadata bounds scores and reasons and requires a change', () => {
    for (const score of [0, 72, 100, '']) {
      expect(validateToolArgs('set_ai_metadata', { photo_ids: [1, 2], score })).toBeNull();
    }
    for (const score of [-1, 101, 1.5, '72', null, false, NaN, Infinity]) {
      expect(validateToolArgs('set_ai_metadata', { photo_ids: [1], score })).not.toBeNull();
    }
    for (const reason of ['', 'eyes closed', 'é'.repeat(1024)]) {
      expect(validateToolArgs('set_ai_metadata', { photo_ids: [1], reason })).toBeNull();
    }
    for (const reason of [42, null, 'a'.repeat(1025), 'é'.repeat(1025)]) {
      expect(validateToolArgs('set_ai_metadata', { photo_ids: [1], reason })).not.toBeNull();
    }
    expect(validateToolArgs('set_ai_metadata', { photo_ids: [1] })).not.toBeNull();
    expect(validateToolArgs('set_ai_metadata', { photo_ids: [] , score: 72 })).not.toBeNull();
  });

  it('get_ai_metadata accepts 200 photos and rejects malformed batches', () => {
    expect(validateToolArgs('get_ai_metadata', { photo_ids: Array.from({ length: 200 }, (_, i) => i + 1) })).toBeNull();
    for (const photo_ids of [[], [null], Array.from({ length: 1001 }, () => 1)]) {
      expect(validateToolArgs('get_ai_metadata', { photo_ids })).not.toBeNull();
    }
  });

  it('bounds virtual-copy batches and accepts an optional nonblank copy name', () => {
    expect(validateToolArgs('create_virtual_copies', { photo_ids: [914, '/a.jpg'] })).toBeNull();
    expect(validateToolArgs('create_virtual_copies', { photo_ids: [914], copy_name: 'Experiment' })).toBeNull();
    expect(validateToolArgs('create_virtual_copies', { photo_ids: [] })).toContain('photo_ids');
    expect(validateToolArgs('create_virtual_copies', { photo_ids: Array.from({ length: 26 }, () => 914) })).toContain('photo_ids');
    expect(validateToolArgs('create_virtual_copies', { photo_ids: [914], copy_name: ' ' })).toContain('copy_name');
  });

  it('apply_auto_adjustments requires tone or white_balance to be true', () => {
    expect(validateToolArgs('apply_auto_adjustments', { photo_ids: [914] })).not.toBeNull();
    expect(validateToolArgs('apply_auto_adjustments', { photo_ids: [914], tone: false, white_balance: false })).not.toBeNull();
    expect(validateToolArgs('apply_auto_adjustments', { photo_ids: [914], tone: true })).toBeNull();
    expect(validateToolArgs('apply_auto_adjustments', { photo_ids: [914], white_balance: true })).toBeNull();
    expect(validateToolArgs('apply_auto_adjustments', { photo_ids: [914], tone: true, white_balance: true })).toBeNull();
    expect(validateToolArgs('apply_auto_adjustments', { photo_ids: [914], tone: 'true' })).not.toBeNull();
    expect(validateToolArgs('apply_auto_adjustments', { photo_ids: Array.from({ length: 101 }, () => '1'), tone: true })).not.toBeNull();
  });

  it('search_photos accepts intersecting Library filters', () => {
    expect(validateToolArgs('search_photos', {
      camera: 'Sony ILCE-7M3', lens: '24-70mm', iso: 100, focal_length: 32, flag: 'reject',
      color_label: 'red', edited: false, file_type: 'RAW', folder: 'Photos Travel', rating: 5,
    })).toBeNull();
    for (const flag of ['pick', 'reject', 'none']) {
      expect(validateToolArgs('search_photos', { flag })).toBeNull();
    }
    for (const color_label of ['red', 'yellow', 'green', 'blue', 'purple', 'none']) {
      expect(validateToolArgs('search_photos', { color_label })).toBeNull();
    }
  });

  it.each([
    ['flag', 'maybe'], ['file_type', 'GIF'], ['color_label', 'pink'],
    ['camera', ''], ['lens', 42], ['folder', '  '], ['iso', 0], ['iso', Infinity], ['edited', 'false'],
    ['focal_length', 0], ['focal_length', -32], ['focal_length', Infinity], ['focal_length', NaN], ['focal_length', '32 mm'],
  ])('search_photos rejects invalid %s filter %s', (key, value) => {
    expect(validateToolArgs('search_photos', { [key]: value })).toContain(key);
  });

  it('accepts arguments that satisfy the published schema', () => {
    expect(validateToolArgs('get_photo_metadata', { photo_id: 914 })).toBeNull();
    expect(validateToolArgs('get_photo_metadata', { photo_id: '/a.jpg' })).toBeNull();
    expect(validateToolArgs('set_rating', { photo_ids: [914], rating: 3 })).toBeNull();
    expect(validateToolArgs('search_photos', {})).toBeNull();
  });

  it('set_process_version accepts only named versions and explicit confirmation', () => {
    const args = { photo_ids: [914], version: 'Version 6', confirm: true };
    for (let version = 1; version <= 6; version++) {
      expect(validateToolArgs('set_process_version', { ...args, version: `Version ${version}` })).toBeNull();
    }
    for (const version of ['Version 7', '2012']) {
      expect(validateToolArgs('set_process_version', { ...args, version })).toContain('version');
    }
    expect(validateToolArgs('set_process_version', { ...args, confirm: false })).toContain('confirm');
    expect(validateToolArgs('set_process_version', { ...args, photo_ids: Array.from({ length: 101 }, () => '1') })).toContain('photo_ids');
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

  describe('create_people_mask and create_landscape_mask', () => {
    it('accepts known parts for all people', () => {
      expect(validateToolArgs('create_people_mask', { photo_id: 1, parts: ['hair', 'face_skin'] })).toBeNull();
      expect(validateToolArgs('create_people_mask', { photo_id: 1, parts: ['entire_person'] })).toBeNull();
    });

    it('rejects unknown, duplicate or missing people parts and a person option', () => {
      expect(validateToolArgs('create_people_mask', { photo_id: 1, parts: ['ears'] })).toContain('parts');
      expect(validateToolArgs('create_people_mask', { photo_id: 1, parts: ['hair', 'hair'] })).toContain('parts');
      expect(validateToolArgs('create_people_mask', { photo_id: 1, parts: [] })).toContain('parts');
      expect(validateToolArgs('create_people_mask', { photo_id: 1 })).toContain('parts');
      expect(validateToolArgs('create_people_mask', { parts: ['hair'] })).toContain('photo_id');
      expect(validateToolArgs('create_people_mask', { photo_id: 1, parts: ['hair'], person: 2 })).toContain(
        'unknown property "person"',
      );
    });

    it('accepts known landscape categories and rejects the rest', () => {
      expect(
        validateToolArgs('create_landscape_mask', { photo_id: '/a.dng', categories: ['water', 'sky'] }),
      ).toBeNull();
      expect(validateToolArgs('create_landscape_mask', { photo_id: 1, categories: ['lava'] })).toContain(
        'categories',
      );
      expect(validateToolArgs('create_landscape_mask', { photo_id: 1, categories: ['sky', 'sky'] })).toContain(
        'categories',
      );
      expect(validateToolArgs('create_landscape_mask', { photo_id: 1 })).toContain('categories');
      expect(validateToolArgs('create_landscape_mask', { photo_id: 1, categories: ['sky'], extra: 1 })).toContain(
        'unknown property "extra"',
      );
    });
  });

  describe('brush mask tools', () => {
    const stroke = { points: [{ x: 0.2, y: 0.3 }, { x: 0.4, y: 0.3 }], radius: 0.05, flow: 0.5 };
    const create = { photo_id: 1, strokes: [stroke] };

    it('accepts strokes with optional radius and flow', () => {
      expect(validateToolArgs('create_brush_mask', create)).toBeNull();
      expect(validateToolArgs('create_brush_mask', { ...create, name: 'Face' })).toBeNull();
      expect(validateToolArgs('create_brush_mask', { ...create, mask_id: 'abc' })).toBeNull();
      expect(validateToolArgs('create_brush_mask', { photo_id: 1, strokes: [{ points: [{ x: 0, y: 1 }] }] })).toBeNull();
      expect(validateToolArgs('add_brush_strokes', { ...create, tool_id: 'T1' })).toBeNull();
    });

    it('rejects an empty stroke list, a stroke without points and a missing list', () => {
      expect(validateToolArgs('create_brush_mask', { photo_id: 1, strokes: [] })).toContain('strokes');
      expect(validateToolArgs('create_brush_mask', { photo_id: 1, strokes: [{ points: [] }] })).toContain('points');
      expect(validateToolArgs('create_brush_mask', { photo_id: 1, strokes: [{}] })).toContain('points');
      expect(validateToolArgs('create_brush_mask', { photo_id: 1 })).toContain('strokes');
      expect(validateToolArgs('add_brush_strokes', { photo_id: 1, strokes: [stroke] })).toContain('tool_id');
    });

    it('rejects points outside the image', () => {
      expect(
        validateToolArgs('create_brush_mask', { photo_id: 1, strokes: [{ points: [{ x: 1.2, y: 0.5 }] }] }),
      ).toContain('points');
      expect(
        validateToolArgs('add_brush_strokes', { photo_id: 1, tool_id: 'T1', strokes: [{ points: [{ x: 0.5, y: -1 }] }] }),
      ).toContain('points');
    });

    it('bounds radius and flow', () => {
      expect(validateToolArgs('create_brush_mask', { ...create, strokes: [{ ...stroke, radius: 0 }] })).toContain('radius');
      expect(validateToolArgs('create_brush_mask', { ...create, strokes: [{ ...stroke, radius: 2 }] })).toContain('radius');
      expect(validateToolArgs('create_brush_mask', { ...create, strokes: [{ ...stroke, flow: 0 }] })).toContain('flow');
      expect(validateToolArgs('create_brush_mask', { ...create, strokes: [{ ...stroke, flow: 2 }] })).toContain('flow');
    });

    it('accepts feather, density and erase and bounds them', () => {
      const withExtra = (extra: object) => ({ ...create, strokes: [{ ...stroke, ...extra }] });
      expect(validateToolArgs('create_brush_mask', withExtra({ feather: 0, density: 0.3 }))).toBeNull();
      expect(validateToolArgs('create_brush_mask', withExtra({ feather: 100, density: 1 }))).toBeNull();
      expect(validateToolArgs('create_brush_mask', withExtra({ erase: true, feather: 20 }))).toBeNull();
      expect(validateToolArgs('add_brush_strokes', { ...create, tool_id: 'T1', strokes: [{ ...stroke, erase: true }] })).toBeNull();
      expect(validateToolArgs('create_brush_mask', withExtra({ feather: -1 }))).toContain('feather');
      expect(validateToolArgs('create_brush_mask', withExtra({ feather: 101 }))).toContain('feather');
      expect(validateToolArgs('create_brush_mask', withExtra({ density: 0 }))).toContain('density');
      expect(validateToolArgs('create_brush_mask', withExtra({ density: 2 }))).toContain('density');
      expect(validateToolArgs('create_brush_mask', withExtra({ erase: 'yes' }))).toContain('erase');
    });

    it('has no size option and no whole-brush mode', () => {
      expect(validateToolArgs('create_brush_mask', { ...create, strokes: [{ ...stroke, size: 0.1 }] })).toContain(
        'unknown property "size"',
      );
      expect(validateToolArgs('create_brush_mask', { ...create, mode: 'subtract' })).toContain('unknown property "mode"');
    });
  });

  describe('create_range_mask', () => {
    const luminance = { photo_id: 1, type: 'luminance', luminance: { min: 0.3, max: 0.6, falloff: 0.1 } };
    const sample = { x: 0.2, y: 0.8, l: 0.46, a: 0.5, b: 0.52 };
    const color = { photo_id: '/a.dng', type: 'color', color: { sample, amount: 0.4 } };
    const depth = { photo_id: 7, type: 'depth', depth: { min: 0, max: 0.1, falloff: 0.25 } };

    it('accepts luminance, color and depth ranges', () => {
      expect(validateToolArgs('create_range_mask', luminance)).toBeNull();
      expect(validateToolArgs('create_range_mask', color)).toBeNull();
      expect(validateToolArgs('create_range_mask', depth)).toBeNull();
      expect(
        validateToolArgs('create_range_mask', { ...luminance, mask_id: 'C1', mode: 'subtract', invert: true }),
      ).toBeNull();
      expect(validateToolArgs('create_range_mask', { ...color, name: 'Foliage' })).toBeNull();
    });

    it('requires a photo and a type, and rejects an unknown type', () => {
      expect(validateToolArgs('create_range_mask', { type: 'luminance' })).toContain('photo_id');
      expect(validateToolArgs('create_range_mask', { photo_id: 1 })).toContain('type');
      expect(validateToolArgs('create_range_mask', { ...luminance, type: 'hue' })).toContain('type');
    });

    it('bounds the depth numbers and rejects unknown depth properties', () => {
      expect(validateToolArgs('create_range_mask', { ...depth, depth: { min: -0.1, max: 0.5 } })).toContain(
        'depth.min',
      );
      expect(validateToolArgs('create_range_mask', { ...depth, depth: { min: 0.1 } })).toContain('max');
      expect(validateToolArgs('create_range_mask', { ...depth, depth: { min: 0.1, max: 0.5, falloff: 2 } })).toContain(
        'depth.falloff',
      );
      expect(validateToolArgs('create_range_mask', { ...depth, depth: { min: 0.1, max: 0.5, x: 0.5 } })).toContain(
        'unknown property "x"',
      );
    });

    it('accepts one sample point only', () => {
      expect(validateToolArgs('create_range_mask', { ...color, color: { sample: [sample, sample] } })).toContain(
        'color.sample',
      );
      expect(validateToolArgs('create_range_mask', { ...color, color: { samples: [sample] } })).toContain(
        'unknown property "samples"',
      );
    });

    it('accepts copy_sample_from with only its ids required', () => {
      const copy = { photo_id: 1, type: 'color', copy_sample_from: { mask_id: 'C1', tool_id: 'C1T1' } };
      expect(validateToolArgs('create_range_mask', copy)).toBeNull();
      expect(validateToolArgs('create_range_mask', { ...copy, color: { amount: 0.3 }, invert: true })).toBeNull();
      expect(
        validateToolArgs('create_range_mask', {
          ...copy,
          mask_id: 'C2',
          mode: 'subtract',
          copy_sample_from: { photo_id: '/b.dng', mask_id: 'C1', tool_id: 'C1T1' },
        }),
      ).toBeNull();
      expect(validateToolArgs('create_range_mask', { ...copy, copy_sample_from: { mask_id: 'C1' } })).toContain(
        'tool_id',
      );
      expect(validateToolArgs('create_range_mask', { ...copy, copy_sample_from: { tool_id: 'T' } })).toContain(
        'mask_id',
      );
      expect(
        validateToolArgs('create_range_mask', { ...copy, copy_sample_from: { mask_id: 'C1', tool_id: 'T', x: 1 } }),
      ).toContain('unknown property "x"');
      expect(validateToolArgs('create_range_mask', { ...copy, color: { amount: 0 } })).toContain('color.amount');
    });

    it('takes Lightroom l, a and b, not sRGB', () => {
      const { l: _l, a: _a, b: _b, ...position } = sample;
      expect(validateToolArgs('create_range_mask', { ...color, color: { sample: position } })).toContain("'l'");
      expect(
        validateToolArgs('create_range_mask', { ...color, color: { sample: { ...sample, red: 0.5 } } }),
      ).toContain('unknown property "red"');
      expect(validateToolArgs('create_range_mask', { ...color, color: { sample: { ...sample, a: 1.5 } } })).toContain(
        'color.sample.a',
      );
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
      expect(validateToolArgs('create_range_mask', { ...luminance, hue: {} })).toContain('unknown property "hue"');
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

  it('validates create_mask_batch photo ids, type and adjustment ranges', () => {
    expect(validateToolArgs('create_mask_batch', { photo_ids: [914, '/a.dng'], type: 'sky' })).toBeNull();
    expect(validateToolArgs('create_mask_batch', {
      photo_ids: [914],
      type: 'subject',
      adjustments: { exposure: 0.7, noise: -100 },
    })).toBeNull();
    expect(validateToolArgs('create_mask_batch', { type: 'sky' })).toContain('photo_ids');
    expect(validateToolArgs('create_mask_batch', { photo_ids: [914] })).toContain('type');
    expect(validateToolArgs('create_mask_batch', { photo_ids: [], type: 'sky' })).toContain('photo_ids');
    expect(validateToolArgs('create_mask_batch', {
      photo_ids: Array.from({ length: 201 }, (_, index) => index + 1),
      type: 'sky',
    })).toContain('photo_ids');
    expect(validateToolArgs('create_mask_batch', {
      photo_ids: Array.from({ length: 200 }, (_, index) => index + 1),
      type: 'sky',
    })).toBeNull();
    expect(validateToolArgs('create_mask_batch', { photo_ids: [914], type: 'people' })).toContain('type');
    expect(validateToolArgs('create_mask_batch', { photo_ids: 914, type: 'sky' })).toContain('photo_ids');
    expect(validateToolArgs('create_mask_batch', {
      photo_ids: [914],
      type: 'sky',
      adjustments: { exposure: 4.1 },
    })).toContain('adjustments.exposure');
    expect(validateToolArgs('create_mask_batch', {
      photo_ids: [914],
      type: 'sky',
      adjustments: { vibrance: 1 },
    })).toContain('unknown property "vibrance"');
    expect(validateToolArgs('create_mask_batch', {
      photo_id: 914,
      photo_ids: [914],
      type: 'sky',
    })).toContain('unknown property "photo_id"');
  });

  it('validates set_mask_curves channels and point arrays', () => {
    const base = { photo_id: 914, mask_id: 'm-1' };
    expect(validateToolArgs('set_mask_curves', { ...base, curves: { main: [0, 0, 64, 48, 255, 255] } })).toBeNull();
    expect(validateToolArgs('set_mask_curves', {
      ...base,
      curves: { red: [0, 0, 255, 255], blue: [0, 10, 255, 255] },
    })).toBeNull();
    expect(validateToolArgs('set_mask_curves', base)).toContain('curves');
    expect(validateToolArgs('set_mask_curves', { ...base, curves: {} })).toContain('curves');
    expect(validateToolArgs('set_mask_curves', { ...base, curves: { alpha: [0, 0, 255, 255] } }))
      .toContain('unknown property "alpha"');
    expect(validateToolArgs('set_mask_curves', { ...base, curves: { main: [0, 0] } })).toContain('curves.main');
    expect(validateToolArgs('set_mask_curves', { ...base, curves: { main: [0, 0, 256, 255] } })).toContain('curves.main');
    expect(validateToolArgs('set_mask_curves', { ...base, curves: { main: [0, 0, 12.5, 255] } })).toContain('curves.main');
    expect(validateToolArgs('set_mask_curves', { photo_id: 914, curves: { main: [0, 0, 255, 255] } })).toContain('mask_id');
    expect(validateToolArgs('get_mask_curves', base)).toBeNull();
    expect(validateToolArgs('get_mask_curves', { photo_id: 914 })).toContain('mask_id');
  });

  it('validates edit_mask_point_colors actions, indexes and swatch fields', () => {
    const base = { photo_id: 914, mask_id: 'm-1' };
    const swatch = { SrcHue: 1.5, SrcSat: 0.4, SrcLum: 0.6, HueShift: -0.2 };
    expect(validateToolArgs('edit_mask_point_colors', { ...base, action: 'add', swatch })).toBeNull();
    expect(validateToolArgs('edit_mask_point_colors', {
      ...base,
      action: 'update',
      index: 2,
      swatch: { SatScale: 0.3, HueRange: { LowerNone: 0, LowerFull: 0.2, UpperFull: 0.6, UpperNone: 1 } },
    })).toBeNull();
    expect(validateToolArgs('edit_mask_point_colors', { ...base, action: 'delete', index: 1 })).toBeNull();
    expect(validateToolArgs('edit_mask_point_colors', { ...base, action: 'clear' })).toBeNull();
    expect(validateToolArgs('edit_mask_point_colors', base)).toContain('action');
    expect(validateToolArgs('edit_mask_point_colors', { ...base, action: 'rename' })).toContain('action');
    expect(validateToolArgs('edit_mask_point_colors', { ...base, action: 'delete', index: 0 })).toContain('index');
    expect(validateToolArgs('edit_mask_point_colors', { ...base, action: 'delete', index: 9 })).toContain('index');
    expect(validateToolArgs('edit_mask_point_colors', { ...base, action: 'delete', index: 1.5 })).toContain('index');
    expect(validateToolArgs('edit_mask_point_colors', {
      ...base,
      action: 'add',
      swatch: { ...swatch, SrcHue: 7 },
    })).toContain('swatch.SrcHue');
    expect(validateToolArgs('edit_mask_point_colors', {
      ...base,
      action: 'add',
      swatch: { ...swatch, Brightness: 1 },
    })).toContain('unknown property "Brightness"');
    expect(validateToolArgs('edit_mask_point_colors', {
      ...base,
      action: 'update',
      index: 1,
      swatch: { HueRange: { LowerNone: 0 } },
    })).toContain('swatch.HueRange');
    expect(validateToolArgs('get_mask_point_colors', base)).toBeNull();
    expect(validateToolArgs('get_mask_point_colors', { mask_id: 'm-1' })).toContain('photo_id');
  });

  it('validates combine_mask operation and type', () => {
    const valid = { photo_id: 914, mask_id: 'abc', operation: 'subtract', type: 'sky' };
    expect(validateToolArgs('combine_mask', valid)).toBeNull();
    expect(validateToolArgs('combine_mask', { ...valid, photo_id: '/a.dng', operation: 'add', type: 'background' })).toBeNull();
    expect(validateToolArgs('combine_mask', { ...valid, operation: 'intersect', type: 'subject' })).toBeNull();
    expect(validateToolArgs('combine_mask', { ...valid, operation: 'invert' })).toContain('operation');
    expect(validateToolArgs('combine_mask', { ...valid, type: 'people' })).toContain('type');
    expect(validateToolArgs('combine_mask', { ...valid, mask_id: '' })).toContain('mask_id');
    expect(validateToolArgs('combine_mask', { photo_id: 914, operation: 'add', type: 'sky' })).toContain('mask_id');
    expect(validateToolArgs('combine_mask', { photo_id: 914, mask_id: 'abc', type: 'sky' })).toContain('operation');
    expect(validateToolArgs('combine_mask', { photo_id: 914, mask_id: 'abc', operation: 'add' })).toContain('type');
    expect(validateToolArgs('combine_mask', { ...valid, adjustments: {} })).toContain('unknown property "adjustments"');
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
