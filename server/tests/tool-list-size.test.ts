import { describe, expect, it } from '@jest/globals';
import { listToolsHandler } from '../src/list-tools-handler.js';
import type { Toolset } from '../src/toolsets.js';

// Fixed limits approved for every toolset/read-only combination. Raise only after
// reviewing intentional size changes; lower these when tool definitions shrink.
// Current full list: 101738 characters; nonempty headroom is 1000–1999 characters.
const TOOLS_LIST_SIZE_BUDGETS = [
  { toolsets: [], write: 12, readOnly: 12 },
  { toolsets: ['core'], write: 34_000, readOnly: 16_000 },
  { toolsets: ['develop'], write: 27_000, readOnly: 7_000 },
  { toolsets: ['core', 'develop'], write: 60_000, readOnly: 21_000 },
  { toolsets: ['masks'], write: 45_000, readOnly: 4_000 },
  { toolsets: ['core', 'masks'], write: 77_000, readOnly: 18_000 },
  { toolsets: ['develop', 'masks'], write: 71_000, readOnly: 10_000 },
  { toolsets: ['core', 'develop', 'masks'], write: 103_000, readOnly: 24_000 },
] satisfies Array<{ toolsets: Toolset[]; write: number; readOnly: number }>;

const configurations = TOOLS_LIST_SIZE_BUDGETS.flatMap(({ toolsets, write, readOnly }) =>
  [false, true].map(enabled => ({
    name: `${toolsets.join('+') || 'empty'}, readOnly=${enabled}`,
    toolsets: new Set(toolsets),
    readOnly: enabled,
    budget: enabled ? readOnly : write,
  })),
);

type ToolList = ReturnType<typeof listToolsHandler>;
type ListedTool = ToolList['tools'][number];

function toolSizes(list: ToolList): Array<{ name: string; size: number }> {
  return list.tools
    .map(tool => ({ name: tool.name, size: JSON.stringify(tool).length }))
    .sort((a, b) => b.size - a.size);
}

function assertToolListSize(list: ToolList, budget: number): void {
  const total = JSON.stringify(list).length;
  if (total > budget) {
    const largest = toolSizes(list).slice(0, 5)
      .map(tool => `${tool.name} (${tool.size})`).join(', ');
    throw new Error(
      `tools/list is ${total} characters; budget is ${budget}. Five largest tools: ${largest}.`,
    );
  }
}

function syntheticTool(name: string, description: string): ListedTool {
  return { name, description, inputSchema: { type: 'object' } };
}

describe('tools/list size', () => {
  describe.each(configurations)('$name', ({ name, toolsets, readOnly, budget }) => {
    it('prints every tool largest first and guards the serialized total', () => {
      const list = listToolsHandler(toolsets, readOnly);
      console.log([
        name,
        ...toolSizes(list).map(tool => `${tool.name}: ${tool.size} characters`),
        `Total: ${JSON.stringify(list).length} characters (budget: ${budget})`,
      ].join('\n'));

      assertToolListSize(list, budget);
    });

    it('accepts the exact fixed limit and rejects overflow', () => {
      const list = listToolsHandler(toolsets, readOnly);
      const first = list.tools[0];
      const exact = first ? { tools: [
        { ...first, description: `${first.description ?? ''}${'x'.repeat(budget - JSON.stringify(list).length)}` },
        ...list.tools.slice(1),
      ] } : list;

      expect(JSON.stringify(exact).length).toBe(budget);
      expect(() => assertToolListSize(exact, budget)).not.toThrow();
      expect(() => assertToolListSize(exact, budget - 1)).toThrow(`budget is ${budget - 1}`);
      const over = first ? { tools: [
        { ...exact.tools[0], description: `${exact.tools[0].description ?? ''}x` },
        ...exact.tools.slice(1),
      ] } : { tools: [syntheticTool('new', '')] };

      if (first) expect(JSON.stringify(over).length).toBe(budget + 1);
      expect(() => assertToolListSize(over, budget)).toThrow(`budget is ${budget}`);
    });

    it('rejects a 10000-character description increase on any listed tool', () => {
      const list = listToolsHandler(toolsets, readOnly);
      for (const [index, tool] of list.tools.entries()) {
        const enlarged = { tools: list.tools.map((entry, entryIndex) => entryIndex === index
          ? { ...entry, description: `${tool.description ?? ''}${'x'.repeat(10_000)}` }
          : entry) };

        expect(() => assertToolListSize(enlarged, budget)).toThrow(`budget is ${budget}`);
      }
    });
  });

  it('accepts exactly the budget using JSON characters including the list envelope', () => {
    const list = { tools: [syntheticTool('unicode', 'Zażółć 🖼️')] };
    const total = JSON.stringify(list).length;

    expect(() => assertToolListSize(list, total)).not.toThrow();
    expect(() => assertToolListSize(list, total - 1)).toThrow(`budget is ${total - 1}`);
  });

  it('names the total, budget and five largest tools when over budget', () => {
    const list = { tools: [
      syntheticTool('smallest', 'x'),
      syntheticTool('fourth', 'x'.repeat(400)),
      syntheticTool('largest', 'x'.repeat(1000)),
      syntheticTool('fifth', 'x'.repeat(200)),
      syntheticTool('second', 'x'.repeat(800)),
      syntheticTool('third', 'x'.repeat(600)),
    ] };
    const total = JSON.stringify(list).length;
    const largest = ['largest', 'second', 'third', 'fourth', 'fifth'].map(name => {
      const tool = list.tools.find(tool => tool.name === name)!;
      return `${name} (${JSON.stringify(tool).length})`;
    }).join(', ');

    expect(() => assertToolListSize(list, total - 1)).toThrow(
      `tools/list is ${total} characters; budget is ${total - 1}. Five largest tools: ${largest}.`,
    );
  });
});
