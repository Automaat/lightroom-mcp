import { describe, expect, it } from '@jest/globals';
import { listToolsHandler } from '../src/list-tools-handler.js';

// Raise only after reviewing size changes; lower this when tool definitions shrink.
const TOOLS_LIST_SIZE_BUDGET = 104_000;

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
  it('prints every tool largest first and guards the serialized total', () => {
    const list = listToolsHandler();
    console.log([
      ...toolSizes(list).map(tool => `${tool.name}: ${tool.size} characters`),
      `Total: ${JSON.stringify(list).length} characters (budget: ${TOOLS_LIST_SIZE_BUDGET})`,
    ].join('\n'));

    assertToolListSize(list, TOOLS_LIST_SIZE_BUDGET);
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

  it('rejects a 10000-character description increase on any current tool', () => {
    const list = listToolsHandler();
    for (const [index, tool] of list.tools.entries()) {
      const enlarged = { tools: list.tools.map((entry, entryIndex) => entryIndex === index
        ? { ...entry, description: `${tool.description ?? ''}${'x'.repeat(10_000)}` }
        : entry) };

      expect(() => assertToolListSize(enlarged, TOOLS_LIST_SIZE_BUDGET))
        .toThrow(`budget is ${TOOLS_LIST_SIZE_BUDGET}`);
    }
  });
});
