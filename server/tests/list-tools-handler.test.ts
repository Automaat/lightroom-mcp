import { describe, it, expect } from '@jest/globals';
import { Ajv } from 'ajv';
import fs from 'node:fs';
import path from 'node:path';
import { validateToolArgs } from '../src/validate-args.js';
import { TOOL_DEFINITIONS, listToolsHandler } from '../src/list-tools-handler.js';
import {
  DEVELOP_SETTING_KEYS,
  LOCAL_ADJUSTMENT_KEYS,
  MASK_CURVE_CHANNELS,
  POINT_CURVE_SETTING_KEYS,
  TOOL_CONTRACTS,
} from '../src/tool-contracts.js';

const EXPECTED_TOOL_NAMES = [
  'search_photos',
  'get_selected_photos',
  'get_photo_metadata',
  'summarize_develop_settings',
  'get_photo_preview',
  'get_photo_previews',
  'get_photo_stats',
  'find_duplicate_groups',
  'set_gps',
  'set_location',
  'set_metadata',
  'set_ai_metadata',
  'get_ai_metadata',
  'list_folders',
  'get_folder_photos',
  'list_collections',
  'create_collection',
  'create_smart_collection',
  'add_to_collection',
  'get_collection_photos',
  'remove_from_collection',
  'delete_collection',
  'set_keywords',
  'remove_keyword_subtree',
  'list_keywords',
  'rename_keyword',
  'set_rating_and_flag',
  'undo_last_step',
  'remove_photos_from_catalog',
  'set_color_label',
  'import_photos',
  'export_photos',
  'export_photo_metadata',
  'list_develop_presets',
  'get_develop_preset',
  'compare_develop_presets',
  'create_develop_preset',
  'export_develop_preset',
  'apply_develop_preset',
  'copy_develop_settings',
  'match_photo_style',
  'set_develop_settings',
  'get_lens_blur',
  'set_lens_blur',
  'set_process_version',
  'list_develop_snapshots',
  'create_virtual_copies',
  'create_develop_snapshot',
  'apply_develop_snapshot',
  'delete_develop_snapshot',
  'reset_develop_adjustments',
  'apply_denoise',
  'apply_auto_adjustments',
  'list_masks',
  'list_spots',
  'update_spot',
  'delete_spot',
  'create_gradient_mask',
  'update_gradient_mask',
  'create_brush_mask',
  'add_brush_strokes',
  'create_range_mask',
  'delete_masks',
  'delete_empty_masks',
  'set_mask_adjustments',
  'get_mask_adjustments',
  'invert_mask',
  'create_mask',
  'create_mask_batch',
  'create_people_mask',
  'create_landscape_mask',
  'set_mask_curves',
  'get_mask_curves',
  'edit_mask_point_colors',
  'get_mask_point_colors',
  'combine_mask',
] as const;

describe('TOOL_DEFINITIONS', () => {
  it('get_photo_preview describes named uses and approximate token costs', () => {
    const tool = TOOL_DEFINITIONS.find(tool => tool.name === 'get_photo_preview');
    const sizeSchema = tool?.inputSchema.properties?.size as { description: string };
    const guidance = `${tool?.description} ${sizeSchema.description}`;
    expect(guidance).toMatch(/cull.*culling.*650 tokens/);
    expect(guidance).toMatch(/detail.*details.*2\.5k tokens/);
    expect(guidance).toContain('earlier Claude estimates');
    expect(guidance).toContain('width/height/bytes');
    expect(guidance).toContain('each turn in history');
    const validate = new Ajv({ strict: false }).compile(tool!.inputSchema);
    for (const size of ['cull', 'detail', 64, 1024, 2048]) {
      expect(validate({ photo_id: 914, size })).toBe(true);
    }
    for (const size of ['huge', 5000]) {
      expect(validate({ photo_id: 914, size })).toBe(false);
    }
  });

  it('contains exactly 76 tools', () => {
    expect(TOOL_DEFINITIONS).toHaveLength(76);
  });

  it('replaces the separate rating and flag tools', () => {
    const names = TOOL_DEFINITIONS.map(tool => tool.name);
    expect(names).toContain('set_rating_and_flag');
    expect(names).not.toContain('set_rating');
    expect(names).not.toContain('set_flag');
  });

  it.each(['set_rating_and_flag', 'get_photo_metadata', 'create_gradient_mask', 'create_brush_mask', 'create_range_mask'])(
    'publishes %s without root unions rejected by Claude Code', name => {
      const schema = TOOL_DEFINITIONS.find(tool => tool.name === name)!.inputSchema;
      expect(schema.type).toBe('object');
      expect(schema).not.toHaveProperty('anyOf');
      expect(schema).not.toHaveProperty('oneOf');
      expect(schema).not.toHaveProperty('allOf');
    },
  );

  it('tool names are unique', () => {
    const names = TOOL_DEFINITIONS.map((t) => t.name);
    expect(new Set(names).size).toBe(names.length);
  });

  it.each(EXPECTED_TOOL_NAMES)('"%s" is present', (name) => {
    expect(TOOL_DEFINITIONS.some((t) => t.name === name)).toBe(true);
  });

  it('every tool has name, description, and inputSchema', () => {
    for (const tool of TOOL_DEFINITIONS) {
      expect(typeof tool.name).toBe('string');
      expect(typeof tool.description).toBe('string');
      expect(tool.inputSchema).toBeDefined();
      expect(tool.inputSchema.type).toBe('object');
    }
  });

  it('is generated from tool contracts', () => {
    expect(TOOL_DEFINITIONS).toEqual(
      TOOL_CONTRACTS.map(({ name, title, annotations, description, inputSchema, alwaysLoad }) => ({
        name,
        title,
        annotations,
        description,
        inputSchema,
        ...(alwaysLoad ? { _meta: { 'anthropic/alwaysLoad': true } } : {}),
      })),
    );
  });

  it('rejects unknown top-level arguments for every tool', () => {
    for (const tool of TOOL_DEFINITIONS) {
      expect(tool.inputSchema.additionalProperties).toBe(false);
    }
  });
});

describe('listToolsHandler', () => {
  it('returns { tools: TOOL_DEFINITIONS }', () => {
    const result = listToolsHandler(new Set(['core', 'develop', 'masks']));
    expect(result.tools).toEqual(TOOL_DEFINITIONS);
  });

  it('keeps repeated tool lists byte-identical and in contract order', () => {
    expect(JSON.stringify(listToolsHandler(new Set(['core', 'develop', 'masks'])))).toBe(JSON.stringify(listToolsHandler(new Set(['core', 'develop', 'masks']))));
    expect(listToolsHandler(new Set(['core', 'develop', 'masks'])).tools.map((tool) => tool.name)).toEqual(TOOL_CONTRACTS.map((tool) => tool.name));
  });

  it.each(TOOL_DEFINITIONS.filter((tool) => tool._meta?.['anthropic/alwaysLoad'] === true).map((tool) => [tool.name, tool.description] as const))(
    'upfront tool %s stays within the 4096-character description limit', (_name, description) => {
      expect(description).toBeDefined();
      expect(description!.length).toBeLessThanOrEqual(4096);
    },
  );
});

describe('photo list schemas', () => {
  it.each([
    ['search_photos', {}],
    ['get_selected_photos', {}],
    ['get_collection_photos', { collection_name: 'Trips / 2026 / Paris' }],
  ])('%s accepts an optional path opt-in and rejects unknown arguments', (name, args) => {
    const tool = TOOL_DEFINITIONS.find((entry) => entry.name === name)!;
    const validate = new Ajv({ strict: false }).compile(tool.inputSchema);

    expect(validate(args)).toBe(true);
    expect(validate({ ...args, include_path: true })).toBe(true);
    expect(validate({ ...args, include_path: false })).toBe(true);
    expect(validate({ ...args, include_path: 'true' })).toBe(false);
    expect(validate({ ...args, include_path: 1 })).toBe(false);
    expect(validate({ ...args, unknown_field: true })).toBe(false);
  });
});

describe('tool required fields', () => {
  function toolRequired(name: string): string[] | undefined {
    return TOOL_DEFINITIONS.find((t) => t.name === name)?.inputSchema.required as string[] | undefined;
  }

  it.each<[string, string[]]>([
    ['get_photo_preview', ['photo_id']],
    ['set_gps', ['photo_ids', 'latitude', 'longitude']],
    ['set_location', ['photo_ids']],
    ['set_metadata', ['photo_ids']],
    ['create_collection', ['name']],
    ['add_to_collection', ['collection_name', 'photo_ids']],
    ['get_collection_photos', ['collection_name']],
    ['remove_from_collection', ['collection_name', 'photo_ids']],
    ['delete_collection', ['collection_name']],
    ['set_keywords', ['photo_ids']],
    ['set_rating_and_flag', ['photo_ids']],
    ['undo_last_step', ['confirm']],
    ['set_color_label', ['photo_ids', 'label']],
    ['rename_keyword', ['keyword', 'new_name']],
    ['import_photos', ['source_path']],
    ['export_photos', ['photo_ids', 'destination']],
    ['export_photo_metadata', ['destination']],
    ['compare_develop_presets', ['base', 'candidate']],
    ['create_develop_preset', ['photo_id', 'preset_name', 'settings']],
    ['export_develop_preset', ['destination_dir']],
    ['apply_develop_preset', ['photo_ids']],
    ['copy_develop_settings', ['source_id', 'target_ids']],
    ['match_photo_style', ['reference_id', 'target_ids']],
    ['set_develop_settings', ['photo_id', 'settings']],
    ['get_lens_blur', ['photo_id']],
    ['set_lens_blur', ['photo_id']],
    ['set_process_version', ['photo_ids', 'version', 'confirm']],
    ['list_develop_snapshots', ['photo_id']],
    ['create_develop_snapshot', ['photo_id', 'name']],
    ['create_virtual_copies', ['photo_ids']],
    ['apply_develop_snapshot', ['photo_id', 'snapshot_id']],
    ['delete_develop_snapshot', ['photo_id', 'snapshot_id']],
    ['reset_develop_adjustments', ['photo_ids', 'confirm']],
    ['apply_denoise', ['photo_ids', 'amount']],
    ['apply_auto_adjustments', ['photo_ids']],
    ['list_masks', ['photo_id']],
    ['create_gradient_mask', ['photo_id', 'shape']],
    ['update_gradient_mask', ['photo_id', 'tool_id']],
    ['create_brush_mask', ['photo_id', 'strokes']],
    ['add_brush_strokes', ['photo_id', 'tool_id', 'strokes']],
    ['create_range_mask', ['photo_id', 'type']],
    ['delete_masks', ['photo_id']],
    ['delete_empty_masks', ['photo_ids']],
    ['set_mask_adjustments', ['photo_id', 'mask_id', 'adjustments']],
    ['get_mask_adjustments', ['photo_id', 'mask_id']],
    ['invert_mask', ['photo_id', 'mask_id', 'mode']],
    ['create_mask', ['photo_id', 'type']],
    ['create_mask_batch', ['photo_ids', 'type']],
    ['create_people_mask', ['photo_id', 'parts']],
    ['create_landscape_mask', ['photo_id', 'categories']],
    ['set_mask_curves', ['photo_id', 'mask_id', 'curves']],
    ['get_mask_curves', ['photo_id', 'mask_id']],
    ['edit_mask_point_colors', ['photo_id', 'mask_id', 'action']],
    ['get_mask_point_colors', ['photo_id', 'mask_id']],
    ['combine_mask', ['photo_id', 'mask_id', 'operation', 'type']],
  ])('%s requires %j', (name, required) => {
    expect(toolRequired(name)).toEqual(required);
  });

  it.each([
    'search_photos',
    'get_selected_photos',
    'list_collections',
    'list_keywords',
    'list_develop_presets',
    'get_develop_preset',
  ])(
    '%s has no required fields',
    (name) => {
      expect(toolRequired(name)).toBeUndefined();
    },
  );
});

describe('set_keywords schema', () => {
  it('caps add/remove keyword arrays', () => {
    const tool = TOOL_DEFINITIONS.find((t) => t.name === 'set_keywords');
    const properties = tool?.inputSchema.properties as Record<string, { maxItems?: number }>;

    expect(properties.add_keywords.maxItems).toBe(1000);
    expect(properties.remove_keywords.maxItems).toBe(1000);
  });

  it('offers create_missing as an optional boolean', () => {
    const tool = TOOL_DEFINITIONS.find((t) => t.name === 'set_keywords');
    const properties = tool?.inputSchema.properties as Record<string, { type?: string }>;

    expect(properties.create_missing.type).toBe('boolean');
    expect(tool?.inputSchema.required).toEqual(['photo_ids']);
  });
});

describe('photo array schema', () => {
  it.each([
    ['add_to_collection', 'photo_ids'],
    ['remove_from_collection', 'photo_ids'],
    ['set_gps', 'photo_ids'],
    ['set_location', 'photo_ids'],
    ['set_metadata', 'photo_ids'],
    ['set_keywords', 'photo_ids'],
    ['set_rating_and_flag', 'photo_ids'],
    ['set_color_label', 'photo_ids'],
    ['export_photos', 'photo_ids'],
    ['export_photo_metadata', 'photo_ids'],
    ['apply_develop_preset', 'photo_ids'],
    ['copy_develop_settings', 'target_ids'],
    ['match_photo_style', 'target_ids'],
    ['delete_empty_masks', 'photo_ids'],
  ])('%s.%s requires 1-1000 ids', (toolName, propertyName) => {
    const tool = TOOL_DEFINITIONS.find((t) => t.name === toolName);
    const properties = tool?.inputSchema.properties as Record<
      string,
      { minItems?: number; maxItems?: number }
    >;

    expect(properties[propertyName].minItems).toBe(1);
    expect(properties[propertyName].maxItems).toBe(1000);
  });
});

describe('develop setting schema', () => {
  function parseLuaDevelopSettingKeys(): string[] {
    const pluginPath = path.resolve(process.cwd(), '..', 'plugin', 'LightroomMCP.lrplugin', 'HandlerDevelop.lua');
    const source = fs.readFileSync(pluginPath, 'utf8');
    const match = source.match(/local ALLOWED_DEVELOP_SETTING_KEYS = \{([\s\S]*?)\n\}/);
    if (!match) {
      throw new Error('ALLOWED_DEVELOP_SETTING_KEYS table not found');
    }

    return [...match[1].matchAll(/^\s*"([^"]+)",/gm)].map((entry) => entry[1]);
  }

  it('publishes one key list and curve schema within the size budget', () => {
    const names = ['set_develop_settings', 'copy_develop_settings', 'create_develop_preset'];
    const tools = TOOL_DEFINITIONS.filter(t => names.includes(t.name));
    const definitions = tools.map(({ name, description, inputSchema }) =>
      JSON.stringify({ name, description, inputSchema })).join('');
    const schemas = tools.map(t => JSON.stringify(t.inputSchema)).join('');
    expect(definitions.length).toBeLessThanOrEqual(7000);
    for (const key of DEVELOP_SETTING_KEYS) {
      expect(schemas.split(JSON.stringify(key)).length - 1).toBe(1);
    }
    expect(schemas.split('Flat input/output pairs').length - 1).toBe(1);
    expect(schemas).not.toMatch(/"\$(?:ref|defs)"/);
  });

  it('accepts mixed valid settings and copy keys', () => {
    expect(validateToolArgs('set_develop_settings', {
      photo_id: 914,
      settings: { Exposure2012: 0.5, WhiteBalance: 'As Shot',
        ToneCurvePV2012: [0, 0, 64, 48, 192, 210, 255, 255] },
    })).toBeNull();
    expect(validateToolArgs('copy_develop_settings', {
      source_id: 914, target_ids: [915], settings: ['Exposure2012'], dry_run: true,
    })).toBeNull();
    for (const key of DEVELOP_SETTING_KEYS) {
      expect(validateToolArgs('set_develop_settings', {
        photo_id: 914, settings: { [key]: POINT_CURVE_SETTING_KEYS.includes(
          key as typeof POINT_CURVE_SETTING_KEYS[number]) ? [0, 0, 255, 255] : 1 },
      })).toBeNull();
    }
  });

  it('rejects malformed point curve payloads before dispatch', () => {
    const check = (curve: unknown[]) => validateToolArgs('set_develop_settings',
      { photo_id: '1', settings: { ToneCurvePV2012: curve } }) === null;

    expect(check([0, 0, 64, 48, 192, 210, 255, 255])).toBe(true);
    expect(check([0, 0, 255, 255])).toBe(true);
    expect(check([0, 0, 128, 120, 255])).toBe(false);
    expect(check([0, 0, 128.5, 120, 255, 255])).toBe(false);
    expect(check([0, 0, 128, 300, 255, 255])).toBe(false);
    expect(check([0, 0, 128, -1, 255, 255])).toBe(false);
    expect(check([0, 0])).toBe(false);
    expect(check(Array.from({ length: 66 }, () => 0))).toBe(false);
  });

  it('undo_last_step requires literal confirm true', () => {
    const tool = TOOL_DEFINITIONS.find((t) => t.name === 'undo_last_step');
    const validate = new Ajv({ strict: false }).compile(tool!.inputSchema);
    expect(validate({ confirm: true })).toBe(true);
    for (const args of [{}, { confirm: false }, { confirm: 'true' }, { confirm: 1 }]) {
      expect(validate(args)).toBe(false);
    }
  });

  it('accepts the numeric photo ids the catalog hands back', () => {
    const ajv = new Ajv({ strict: false });
    const validateFor = (name: string) =>
      ajv.compile(TOOL_DEFINITIONS.find((t) => t.name === name)!.inputSchema);

    expect(validateFor('get_photo_metadata')({ photo_id: 914 })).toBe(true);
    expect(validateFor('get_photo_metadata')({ photo_id: '914' })).toBe(true);
    expect(validateFor('set_rating_and_flag')({ photo_ids: [914, '/a.jpg'], rating: 3 })).toBe(true);
    expect(validateFor('set_develop_settings')({
      photo_id: 914,
      settings: { Exposure2012: 0.5 },
    })).toBe(true);
    expect(validateFor('copy_develop_settings')({ source_id: 914, target_ids: [915] })).toBe(true);

    expect(validateFor('get_photo_metadata')({ photo_id: '' })).toBe(false);
    expect(validateFor('set_rating_and_flag')({ photo_ids: [], rating: 3 })).toBe(false);
    expect(validateFor('set_rating_and_flag')({ photo_ids: [true], rating: 3 })).toBe(false);
  });

  it('requires explicit allowlisted keys when creating a preset checkpoint', () => {
    const tool = TOOL_DEFINITIONS.find((t) => t.name === 'create_develop_preset');
    const properties = tool?.inputSchema.properties as Record<
      string,
      { items?: { enum?: readonly string[] }; minItems?: number; uniqueItems?: boolean }
    >;

    expect(properties.settings.items?.enum).toBeUndefined();
    expect(properties.settings.minItems).toBe(1);
    expect(properties.settings.uniqueItems).toBe(true);
  });

  it('matches Lua develop setting allowlist', () => {
    expect(parseLuaDevelopSettingKeys()).toEqual(DEVELOP_SETTING_KEYS);
  });

  it('reads back every settable key in get_photo_metadata', () => {
    const metadataPath = path.resolve(process.cwd(), '..', 'plugin', 'LightroomMCP.lrplugin', 'HandlerMetadata.lua');
    const source = fs
      .readFileSync(metadataPath, 'utf8')
      .split(/\r?\n/)
      .filter((line) => !line.trim().startsWith('--'))
      .join('\n');
    const groupTable = source.match(/local SDK_DEVELOP_GROUPS = \{([\s\S]*?)\n\}\n/);
    if (!groupTable) {
      throw new Error('SDK_DEVELOP_GROUPS table not found');
    }

    const groupKeys = [...groupTable[1].matchAll(/"([A-Z]\w+)"/g)].map((entry) => entry[1]);
    const fieldKeys = [...source.matchAll(/=\s*developSettings\.(\w+)/g)].map((entry) => entry[1]);

    expect(new Set(groupKeys).size).toBe(groupKeys.length);
    expect([...groupKeys, ...fieldKeys].sort()).toEqual([...DEVELOP_SETTING_KEYS].sort());
  });
});

/**
 * Lua DISPATCH entries that exist for e2e setup only: reachable from the raw TCP
 * probe, deliberately absent from TOOL_CONTRACTS so no MCP client can call them.
 */
const TEST_ONLY_ACTIONS: Record<string, string> = {
  set_selection: 'HandlerSelection.setSelection',
};

describe('local adjustment schema', () => {
  it('matches the slider table the Lua handler validates against', () => {
    const luaPath = path.resolve(process.cwd(), '..', 'plugin', 'LightroomMCP.lrplugin', 'LocalSliders.lua');
    const luaNames = [...fs.readFileSync(luaPath, 'utf8').matchAll(/"(local_\w+)"/g)].map((m) => m[1]);

    expect(luaNames).toEqual([...LOCAL_ADJUSTMENT_KEYS]);
  });

  it('offers every slider as a number property of set_mask_adjustments', () => {
    const contract = TOOL_CONTRACTS.find((c) => c.name === 'set_mask_adjustments');
    const properties = contract?.inputSchema.properties as Record<string, { properties?: Record<string, unknown> }>;

    expect(Object.keys(properties.adjustments.properties ?? {})).toEqual([...LOCAL_ADJUSTMENT_KEYS]);
  });
});

describe('mask curve schema', () => {
  it('matches the channel table the Lua handler writes through', () => {
    const luaPath = path.resolve(process.cwd(), '..', 'plugin', 'LightroomMCP.lrplugin', 'MaskCurves.lua');
    const luaChannels = [...fs.readFileSync(luaPath, 'utf8').matchAll(/name = "(\w+)", parameter = "local_\w+curve"/g)]
      .map((m) => m[1]);

    expect(luaChannels).toEqual([...MASK_CURVE_CHANNELS]);
  });

  it('offers every channel as a property of set_mask_curves', () => {
    const contract = TOOL_CONTRACTS.find((c) => c.name === 'set_mask_curves');
    const properties = contract?.inputSchema.properties as Record<string, { properties?: Record<string, unknown> }>;

    expect(Object.keys(properties.curves.properties ?? {})).toEqual([...MASK_CURVE_CHANNELS]);
  });
});

describe('AI mask types', () => {
  function typeEnumOf(toolName: string): string[] {
    const contract = TOOL_CONTRACTS.find((c) => c.name === toolName);
    const properties = contract?.inputSchema.properties as Record<string, { enum?: string[] }>;
    return properties.type.enum ?? [];
  }

  it('offers the types the Lua type table knows to create_mask and combine_mask alike', () => {
    const luaPath = path.resolve(process.cwd(), '..', 'plugin', 'LightroomMCP.lrplugin', 'MaskTypes.lua');
    const source = fs.readFileSync(luaPath, 'utf8');
    const namesBlock = source.match(/MaskTypes\.NAMES = \{([^}]*)\}/)?.[1] ?? '';
    const luaNames = [...namesBlock.matchAll(/"(\w+)"/g)].map((m) => m[1]);

    expect(luaNames.length).toBeGreaterThan(0);
    expect(typeEnumOf('create_mask')).toEqual(luaNames);
    expect(typeEnumOf('combine_mask')).toEqual(luaNames);
  });
});

describe('tool contracts vs mcpb manifest', () => {
  function readManifestTools(): Array<{ name: string; description: string }> {
    const manifestPath = path.resolve(process.cwd(), '..', 'mcpb', 'manifest.json');
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8')) as {
      tools: Array<{ name: string; description: string }>;
    };
    return manifest.tools;
  }

  it('lists exactly the contract tool names', () => {
    const manifestNames = readManifestTools().map((tool) => tool.name).sort();
    const contractNames = TOOL_CONTRACTS.map((contract) => contract.name).sort();

    expect(manifestNames).toEqual(contractNames);
  });

  it('gives every manifest tool a description', () => {
    for (const tool of readManifestTools()) {
      expect(tool.description.trim()).not.toBe('');
    }
  });
});

describe('tool contracts vs Lua dispatch', () => {
  function parseLuaDispatch(): Record<string, string> {
    const pluginPath = path.resolve(process.cwd(), '..', 'plugin', 'LightroomMCP.lrplugin', 'PluginInfoProvider.lua');
    const source = fs.readFileSync(pluginPath, 'utf8');
    const match = source.match(/local DISPATCH = \{([\s\S]*?)\n\}/);
    if (!match) {
      throw new Error('DISPATCH table not found');
    }

    return Object.fromEntries(
      [...match[1].matchAll(/^\s*([a-z_]+)\s*=\s*([A-Za-z][A-Za-z0-9_]*\.[A-Za-z][A-Za-z0-9_]*)\s*,/gm)]
        .map((entry) => [entry[1], entry[2]]),
    );
  }

  it('matches manifest names and handler targets', () => {
    const dispatch = parseLuaDispatch();
    const manifest = Object.fromEntries(
      TOOL_CONTRACTS.map((contract) => [contract.name, contract.luaHandler]),
    );

    for (const action of Object.keys(TEST_ONLY_ACTIONS)) {
      delete dispatch[action];
    }

    expect(dispatch).toEqual(manifest);
  });

  it('keeps test-only actions off the MCP tool surface', () => {
    const dispatch = parseLuaDispatch();

    for (const [action, luaHandler] of Object.entries(TEST_ONLY_ACTIONS)) {
      expect(dispatch[action]).toBe(luaHandler);
      expect(TOOL_CONTRACTS.some((contract) => contract.name === action)).toBe(false);
    }
  });
});


describe('set_color_label schema', () => {
  const tool = TOOL_DEFINITIONS.find((t) => t.name === 'set_color_label')!;
  const validate = new Ajv({ strict: false }).compile(tool.inputSchema);

  it.each(['red', 'yellow', 'green', 'blue', 'purple', 'none'])('accepts %s', (label) => {
    expect(validate({ photo_ids: ['1'], label })).toBe(true);
  });

  it('rejects pink in set_color_label', () => {
    expect(validate({ photo_ids: ['1'], label: 'pink' })).toBe(false);
  });
});


describe('create_smart_collection schema', () => {
  const smart = TOOL_DEFINITIONS.find((tool) => tool.name === 'create_smart_collection')!;
  const search = TOOL_DEFINITIONS.find((tool) => tool.name === 'search_photos')!;
  const validate = new Ajv({ strict: false }).compile(smart.inputSchema);

  it('create_smart_collection rejects a name without a filter', () => {
    expect(validate({ name: 'x' })).toBe(false);
    expect(validate({ name: 'x', parent: 'Trips / 2026' })).toBe(false);
  });

  it('shares every search filter definition without pagination', () => {
    const { limit, offset, include_path, ...filters } = search.inputSchema.properties!;
    const { name, parent, ...savedFilters } = smart.inputSchema.properties!;
    expect(limit).toBeDefined();
    expect(offset).toBeDefined();
    expect(include_path).toBeDefined();
    expect(name).toBeDefined();
    expect(parent).toBeDefined();
    expect(savedFilters).toEqual(filters);
  });

  it.each([
    [{ rating: 0 }, true], [{ edited: false }, true], [{ focal_length: 35 }, true],
    [{ iso: 0 }, false], [{ focal_length: -1 }, false], [{ camera: ' ' }, false],
    [{ flag: 'invalid' }, false], [{ keywords: [] }, false], [{ rating: 6 }, false],
    [{ limit: 10 }, false],
  ])('validates filter %j', (filter, valid) => {
    expect(validate({ name: 'Review', ...filter })).toBe(valid);
  });
});

describe('keyword subtree description', () => {
  it('explains explicit scope, parent inclusion and retained catalog keywords', () => {
    const tool = TOOL_DEFINITIONS.find((t) => t.name === 'remove_keyword_subtree');
    expect(tool?.description).toMatch(/parent keyword and every descendant/);
    expect(tool?.description).toContain('catalog_wide=true');
    expect(tool?.description).toContain('Keyword nodes stay in the catalog');
    expect(tool?.description).toContain('list_keywords');
    expect(tool?.inputSchema.required).toEqual(['parent']);
  });
});


describe('Remove spot contracts', () => {
  it('accepts only the proven uppercase Opacity field', () => {
    const schema = TOOL_CONTRACTS.find((tool) => tool.name === 'update_spot')!.inputSchema;
    const validate = new Ajv().compile(schema);
    expect(validate({ photo_id: '1', index: 1, params: { Opacity: 0.6 } })).toBe(true);
    expect(validate({ photo_id: '1', index: 1, params: { opacity: 0.6 } })).toBe(false);
    expect(validate({ photo_id: '1', index: 1, params: { Opacity: 2 } })).toBe(false);
    expect(validate({ photo_id: '1', index: 1.5, params: { Opacity: 0.6 } })).toBe(false);
  });
});
