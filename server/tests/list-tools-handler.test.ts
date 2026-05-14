import { describe, it, expect } from '@jest/globals';
import { TOOL_DEFINITIONS, listToolsHandler } from '../src/list-tools-handler.js';

const EXPECTED_TOOL_NAMES = [
  'search_photos',
  'get_selected_photos',
  'get_photo_metadata',
  'list_collections',
  'create_collection',
  'add_to_collection',
  'set_keywords',
  'set_rating',
  'import_photos',
  'export_photos',
  'list_develop_presets',
  'apply_develop_preset',
  'copy_develop_settings',
  'set_develop_settings',
] as const;

describe('TOOL_DEFINITIONS', () => {
  it('contains exactly 14 tools', () => {
    expect(TOOL_DEFINITIONS).toHaveLength(14);
  });

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
});

describe('listToolsHandler', () => {
  it('returns { tools: TOOL_DEFINITIONS }', () => {
    const result = listToolsHandler();
    expect(result.tools).toEqual(TOOL_DEFINITIONS);
  });
});

describe('tool required fields', () => {
  function toolRequired(name: string): string[] | undefined {
    return TOOL_DEFINITIONS.find((t) => t.name === name)?.inputSchema.required as string[] | undefined;
  }

  it.each<[string, string[]]>([
    ['get_photo_metadata', ['photo_id']],
    ['create_collection', ['name']],
    ['add_to_collection', ['collection_name', 'photo_ids']],
    ['set_keywords', ['photo_ids']],
    ['set_rating', ['photo_ids', 'rating']],
    ['import_photos', ['source_path']],
    ['export_photos', ['photo_ids', 'destination']],
    ['apply_develop_preset', ['photo_ids', 'preset_name']],
    ['copy_develop_settings', ['source_id', 'target_ids']],
    ['set_develop_settings', ['photo_id', 'settings']],
  ])('%s requires %j', (name, required) => {
    expect(toolRequired(name)).toEqual(required);
  });

  it.each(['search_photos', 'get_selected_photos', 'list_collections', 'list_develop_presets'])(
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
});
