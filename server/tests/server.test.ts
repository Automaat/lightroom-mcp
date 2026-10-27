import { describe, it, expect, afterEach } from '@jest/globals';
import { Client, InMemoryTransport } from '@modelcontextprotocol/client';
import { createMcpServer } from '../src/create-server.js';
import { TOOL_CONTRACTS } from '../src/tool-contracts.js';
import type { CallOptions, PluginResponse } from '../src/dispatcher.js';

const TOOL_CLASSES: Record<string, 'read-only' | 'additive' | 'destructive'> = {
  search_photos: 'read-only',
  get_selected_photos: 'read-only',
  get_photo_metadata: 'read-only',
  summarize_develop_settings: 'read-only',
  get_photo_preview: 'read-only',
  get_photo_previews: 'read-only',
  get_photo_stats: 'read-only',
  find_duplicate_groups: 'read-only',
  set_gps: 'destructive',
  set_location: 'destructive',
  set_metadata: 'destructive',
  set_ai_metadata: 'destructive',
  get_ai_metadata: 'read-only',
  list_folders: 'read-only',
  get_folder_photos: 'read-only',
  list_collections: 'read-only',
  create_collection: 'additive',
  create_smart_collection: 'additive',
  add_to_collection: 'additive',
  get_collection_photos: 'read-only',
  remove_from_collection: 'destructive',
  delete_collection: 'destructive',
  set_keywords: 'destructive',
  remove_keyword_subtree: 'destructive',
  list_keywords: 'read-only',
  rename_keyword: 'destructive',
  set_rating_and_flag: 'destructive',
  undo_last_step: 'destructive',
  remove_photos_from_catalog: 'destructive',
  set_color_label: 'destructive',
  import_photos: 'additive',
  export_photos: 'destructive',
  export_photo_metadata: 'destructive',
  list_develop_presets: 'read-only',
  get_develop_preset: 'read-only',
  compare_develop_presets: 'read-only',
  create_develop_preset: 'additive',
  export_develop_preset: 'additive',
  apply_develop_preset: 'destructive',
  copy_develop_settings: 'destructive',
  match_photo_style: 'destructive',
  set_develop_settings: 'destructive',
  get_lens_blur: 'read-only',
  set_lens_blur: 'destructive',
  set_process_version: 'destructive',
  list_develop_snapshots: 'read-only',
  create_develop_snapshot: 'destructive',
  create_virtual_copies: 'additive',
  apply_develop_snapshot: 'destructive',
  delete_develop_snapshot: 'destructive',
  reset_develop_adjustments: 'destructive',
  apply_denoise: 'destructive',
  apply_auto_adjustments: 'destructive',
  list_masks: 'read-only',
  list_spots: 'read-only',
  update_spot: 'destructive',
  delete_spot: 'destructive',
  create_gradient_mask: 'destructive',
  update_gradient_mask: 'destructive',
  create_brush_mask: 'additive',
  add_brush_strokes: 'destructive',
  create_range_mask: 'destructive',
  delete_masks: 'destructive',
  delete_empty_masks: 'destructive',
  set_mask_adjustments: 'destructive',
  get_mask_adjustments: 'read-only',
  invert_mask: 'destructive',
  create_mask: 'additive',
  create_mask_batch: 'additive',
  create_people_mask: 'additive',
  create_landscape_mask: 'additive',
  set_mask_curves: 'destructive',
  get_mask_curves: 'read-only',
  edit_mask_point_colors: 'destructive',
  get_mask_point_colors: 'read-only',
  combine_mask: 'destructive',
};

interface ToolResult {
  content: Array<{ type: string; text: string }>;
  isError?: boolean;
}

function asToolResult(r: unknown): ToolResult {
  return r as ToolResult;
}

type CallFn = (action: string, params: unknown, timeout?: number, options?: CallOptions) => Promise<PluginResponse>;

interface Pair {
  server: ReturnType<typeof createMcpServer>;
  client: Client;
}

async function connect(opts: { ready?: boolean; call?: CallFn } = {}): Promise<Pair> {
  const server = createMcpServer({
    isReady: () => opts.ready ?? true,
    dispatcher: {
      call: opts.call ?? (async () => ({ id: 'x', result: null })),
    },
  });
  const client = new Client({ name: 'test-client', version: '1.0.0' });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  return { server, client };
}

describe('createMcpServer', () => {
  let pair: Pair | null = null;

  it('returns static shared instructions to the client on initialize', async () => {
    pair = await connect();
    const instructions = pair.client.getInstructions();
    for (const phrase of [
      'Develop-driving calls run one at a time', 'a second call is rejected',
      'Lightroom Classic 15.6', 'process version 15.4', 'read back', 'roll back',
      'normalized 0 to 1', 'top-left', 'uncropped', 'y increasing down',
      'rotated or mirrored', 'crop does not move the origin',
    ]) expect(instructions).toContain(phrase);
    const second = await connect();
    try {
      expect(second.client.getInstructions()).toBe(instructions);
    } finally {
      await second.client.close();
      await second.server.close();
    }
  });

  it('keeps instructions shared and descriptions within the issue budgets', () => {
    const oldLengths: Record<string, number> = {
      create_range_mask: 4488, create_brush_mask: 2483, create_gradient_mask: 2184,
      create_mask_batch: 1751, combine_mask: 1578, edit_mask_point_colors: 1505,
      create_people_mask: 1446, set_mask_curves: 1445, set_mask_adjustments: 1367,
      create_mask: 1289, create_landscape_mask: 1274, invert_mask: 1201,
      add_brush_strokes: 1052,
    };
    for (const tool of TOOL_CONTRACTS) {
      expect(tool.description).not.toMatch(/Develop-driving|a second call is rejected|One call runs at a time/);
      expect(tool.description.length).toBeLessThan(4096);
    }
    for (const [name, oldLength] of Object.entries(oldLengths)) {
      const tool = TOOL_CONTRACTS.find((entry) => entry.name === name);
      expect(tool).toBeDefined();
      expect(tool?.description.length).toBeLessThanOrEqual(Math.floor(oldLength / 2));
    }
    expect(TOOL_CONTRACTS.reduce((sum, tool) => sum + tool.description.length, 0)).toBeLessThanOrEqual(25000);
  });

  it('keeps load-bearing tool guidance reachable alongside instructions', async () => {
    pair = await connect();
    const instructions = pair.client.getInstructions() ?? '';
    const required: Record<string, string[]> = {
      create_range_mask: ['sRGB', 'copy_sample_from', 'second sample point', 'Lightroom crashes', '0.01', 'different colors'],
      create_mask: ['No sky detected', 'modal alert', 'OK', 'omitted slider'],
      create_mask_batch: ['No sky detected', 'not_attempted', 'remaining_ids', '230'],
      create_people_mask: ['AI process is running', 'OK', 'single-person', '120'],
      create_landscape_mask: ['AI process is running', '120'],
      invert_mask: ['only one component', 'returned mask_id'],
      combine_mask: ['intersect', 'inverted true', 'No sky detected'],
    };
    for (const [name, phrases] of Object.entries(required)) {
      const tool = TOOL_CONTRACTS.find((entry) => entry.name === name);
      expect(tool).toBeDefined();
      const reachable = `${tool?.description} ${JSON.stringify(tool?.inputSchema)} ${instructions}`;
      for (const phrase of phrases) expect(reachable).toContain(phrase);
    }
    for (const name of ['create_gradient_mask', 'update_gradient_mask', 'create_brush_mask', 'add_brush_strokes', 'create_range_mask']) {
      const tool = TOOL_CONTRACTS.find((entry) => entry.name === name);
      expect(tool?.description).toContain('coordinate rules');
      expect(instructions).toContain('Photo coordinates');
    }
  });

  afterEach(async () => {
    if (pair) {
      await pair.client.close();
      await pair.server.close();
      pair = null;
    }
  });

  it('loads only three hot catalog tools upfront over the wire', async () => {
    pair = await connect();
    const { tools } = await pair.client.listTools();
    const hotNames = ['search_photos', 'get_photo_preview', 'set_rating_and_flag'];
    expect(tools.filter((tool) => tool._meta?.['anthropic/alwaysLoad'] === true).map((tool) => tool.name)).toEqual(hotNames);
    for (const tool of tools) {
      if (hotNames.includes(tool.name)) expect(tool._meta).toEqual({ 'anthropic/alwaysLoad': true });
      else expect(tool).not.toHaveProperty('_meta');
    }
  });

  it('keeps tool lists byte-identical across calls and fresh servers', async () => {
    pair = await connect();
    const first = await pair.client.listTools();
    const repeated = await pair.client.listTools();
    const second = await connect();
    try {
      expect(JSON.stringify(repeated)).toBe(JSON.stringify(first));
      expect(JSON.stringify(await second.client.listTools())).toBe(JSON.stringify(first));
      expect(first.tools.map((tool) => tool.name)).toEqual(TOOL_CONTRACTS.map((tool) => tool.name));
    } finally {
      await second.client.close();
      await second.server.close();
    }
  });


  it('sends progress to the connected client without resolving the tool early', async () => {
    pair = await connect({ call: async (_action, _params, _timeout, options) => {
      options?.onProgress?.({ progress: 1, total: 2, message: 'a.jpg' });
      options?.onProgress?.({ progress: 2, total: 2, message: 'b.jpg' });
      return { id: '1', result: { exported: 2 } };
    } });
    const progress: unknown[] = [];

    const result = asToolResult(await pair.client.callTool({ name: 'export_photos', arguments: {
      photo_ids: ['1', '2'], destination: '/out',
    } }, { onprogress: (value) => progress.push(value) }));

    expect(progress).toEqual([
      { progress: 1, total: 2, message: 'a.jpg' },
      { progress: 2, total: 2, message: 'b.jpg' },
    ]);
    expect(JSON.parse(result.content[0].text)).toEqual({ exported: 2 });
  });

  it('no progressToken leaves the result unchanged and requests no progress', async () => {
    let reporting = true;
    pair = await connect({ call: async (_action, _params, _timeout, options) => {
      reporting = options?.onProgress !== undefined;
      return { id: '1', result: { exported: 2 } };
    } });

    const result = asToolResult(await pair.client.callTool({ name: 'export_photos', arguments: {
      photo_ids: ['1', '2'], destination: '/out',
    } }));

    expect(reporting).toBe(false);
    expect(JSON.parse(result.content[0].text)).toEqual({ exported: 2 });
  });

  it('forwards client cancel to the running dispatcher request', async () => {
    let entered: () => void = () => {};
    const started = new Promise<void>((resolve) => { entered = resolve; });
    let cancelled: () => void = () => {};
    const stopped = new Promise<void>((resolve) => { cancelled = resolve; });
    pair = await connect({ call: async (_action, _params, _timeout, options) => {
      entered();
      await new Promise<void>((resolve) => options?.signal?.addEventListener('abort', () => {
        cancelled(); resolve();
      }, { once: true }));
      return { id: '1', result: { complete: false } };
    } });
    const controller = new AbortController();
    const pending = pair.client.callTool({ name: 'export_photos', arguments: {
      photo_ids: ['1', '2'], destination: '/out',
    } }, { signal: controller.signal });
    const rejection = expect(pending).rejects.toThrow();

    await started;
    controller.abort();

    await stopped;
    await rejection;
  });

  describe('ListTools', () => {
    it('exposes tool annotations and titles for every classified tool', async () => {
      pair = await connect();
      const { tools } = await pair.client.listTools();
      expect(tools.map((tool) => tool.name).sort()).toEqual(Object.keys(TOOL_CLASSES).sort());
      for (const tool of tools) {
        const classification = TOOL_CLASSES[tool.name];
        expect({ name: tool.name, title: tool.title }).toEqual({
          name: tool.name,
          title: expect.stringMatching(/\S/),
        });
        expect({ name: tool.name, annotations: tool.annotations }).toEqual({
          name: tool.name,
          annotations: classification === 'read-only'
            ? { readOnlyHint: true, openWorldHint: false }
            : { readOnlyHint: false, destructiveHint: classification === 'destructive', openWorldHint: false },
        });
      }
    });

    it('returns all 76 tools', async () => {
      pair = await connect();
      const { tools } = await pair.client.listTools();
      expect(tools).toHaveLength(76);
    });

    it('includes search_photos and set_develop_settings', async () => {
      pair = await connect();
      const { tools } = await pair.client.listTools();
      const names = tools.map((t) => t.name);
      expect(names).toContain('search_photos');
      expect(names).toContain('set_develop_settings');
    });

    it('each tool has a non-empty description and object inputSchema', async () => {
      pair = await connect();
      const { tools } = await pair.client.listTools();
      for (const tool of tools) {
        expect(tool.description!.length).toBeGreaterThan(0);
        expect(tool.inputSchema.type).toBe('object');
      }
    });
  });

  it('preserves preview image blocks over MCP', async () => {
    pair = await connect({ call: async () => ({
      id: '1',
      result: { photo_id: 914, bytes: 3, image: { mime_type: 'image/jpeg', data: 'QUJD' } },
    }) });

    const result = await pair.client.callTool({ name: 'get_photo_preview', arguments: { photo_id: 914 } });

    expect(result.isError).toBeUndefined();
    expect(result.content).toEqual([
      { type: 'text', text: '{"photo_id":914,"bytes":3}' },
      { type: 'image', data: 'QUJD', mimeType: 'image/jpeg' },
    ]);
  });

  it('preserves all batch preview image blocks over MCP', async () => {
    pair = await connect({ call: async () => ({ id: '1', result: {
      complete: true, remaining_ids: [], previews: [1, 2, 3].map(id => ({
        requested_id: id, photo_id: id, image: { mime_type: 'image/jpeg', data: 'QUJD' },
      })),
    } }) });
    const result = await pair.client.callTool({ name: 'get_photo_previews', arguments: { photo_ids: [1, 2, 3] } });
    expect(result.isError).toBeUndefined();
    expect(result.content).toEqual([
      { type: 'text', text: JSON.stringify({ complete: true, remaining_ids: [],
        previews: [1, 2, 3].map(id => ({ requested_id: id, photo_id: id, image_index: id })) }) },
      ...[1, 2, 3].map(() => ({ type: 'image', data: 'QUJD', mimeType: 'image/jpeg' })),
    ]);
  });

  it('serves the bundled skill prompt with its workflow references', async () => {
    pair = await connect({ ready: false });
    expect(pair.client.getServerCapabilities()).toMatchObject({ prompts: {}, tools: {} });
    const { prompts } = await pair.client.listPrompts();
    expect(prompts).toHaveLength(1);
    expect(prompts[0].name).toBe('raw-photo-lightroom-preset');
    const result = await pair.client.getPrompt({ name: prompts[0].name });
    expect(result.messages).toEqual([{
      role: 'user',
      content: { type: 'text', text: expect.stringContaining('Judge color only from RAW files rendered by Lightroom/Camera Raw.') },
    }]);
    expect(result.messages[0].content).toMatchObject({
      text: expect.stringContaining('# RAW-First Lightroom Workflow v2'),
    });
  });

  it('rejects an unknown skill prompt', async () => {
    pair = await connect();
    await expect(pair.client.getPrompt({ name: 'unknown' })).rejects.toThrow('Unknown prompt: unknown');
  });

  describe('CallTool — connection gate', () => {
    it('returns isError when plugin sockets not ready', async () => {
      pair = await connect({ ready: false });
      const result = asToolResult(await pair.client.callTool({ name: 'list_collections', arguments: {} }));
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toMatch(/not connected/i);
    });

    it('does not call dispatcher when not ready', async () => {
      let called = false;
      pair = await connect({
        ready: false,
        call: async () => { called = true; return { id: '1', result: null }; },
      });
      await pair.client.callTool({ name: 'list_collections', arguments: {} });
      expect(called).toBe(false);
    });
  });

  describe('CallTool — happy path', () => {
    it('forwards tool name and args to dispatcher', async () => {
      let captured: { action: string; params: unknown } | null = null;
      pair = await connect({
        call: async (action, params) => {
          captured = { action, params };
          return { id: '1', result: [] };
        },
      });
      await pair.client.callTool({ name: 'search_photos', arguments: { rating: 5 } });
      expect(captured).toEqual({ action: 'search_photos', params: { rating: 5 } });
    });

    it('returns pretty-printed JSON text on success', async () => {
      const data = { count: 2, items: ['a', 'b'] };
      pair = await connect({ call: async () => ({ id: '1', result: data }) });
      const result = asToolResult(await pair.client.callTool({ name: 'get_selected_photos', arguments: {} }));
      expect(result.isError).toBeFalsy();
      expect(JSON.parse(result.content[0].text)).toEqual(data);
    });

    it('passes undefined args as empty object to dispatcher', async () => {
      let capturedParams: unknown = 'not-set';
      pair = await connect({
        call: async (_action, params) => {
          capturedParams = params;
          return { id: '1', result: null };
        },
      });
      await pair.client.callTool({ name: 'list_develop_presets' });
      expect(capturedParams).toEqual({});
    });
  });

  describe('CallTool — error paths', () => {
    it('returns isError with prefixed message on plugin error response', async () => {
      pair = await connect({ call: async () => ({ id: '1', error: 'No catalog open' }) });
      const result = asToolResult(await pair.client.callTool({ name: 'list_collections', arguments: {} }));
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toBe('Error: No catalog open');
    });

    it('returns isError when dispatcher throws timeout', async () => {
      pair = await connect({
        call: async () => { throw new Error('Plugin response timeout (30s)'); },
      });
      const result = asToolResult(await pair.client.callTool({ name: 'search_photos', arguments: {} }));
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toBe('Plugin response timeout (30s)');
    });

    it('returns isError when dispatcher throws socket-dropped error', async () => {
      pair = await connect({
        call: async () => { throw new Error('Failed to send request to plugin (socket dropped)'); },
      });
      const result = asToolResult(await pair.client.callTool({
        name: 'set_rating_and_flag',
        arguments: { photo_ids: [914], rating: 3 },
      }));
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toMatch(/socket dropped/);
    });

    it('stringifies non-Error throws', async () => {
      pair = await connect({
        call: async () => { throw 'raw string error'; },
      });
      const result = asToolResult(await pair.client.callTool({ name: 'list_collections', arguments: {} }));
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toBe('raw string error');
    });
  });
});
