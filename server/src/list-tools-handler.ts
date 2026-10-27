import type { Tool } from "@modelcontextprotocol/server";
import type { Toolset } from "./toolsets.js";
import { TOOL_CONTRACTS } from "./tool-contracts.js";

export function publishedInputSchema(schema: Tool["inputSchema"]): Tool["inputSchema"] {
  const published = { ...schema };
  // Claude Code drops tools with root combinators; private validation keeps them.
  delete published.oneOf;
  delete published.anyOf;
  delete published.allOf;
  return published;
}

export const TOOL_DEFINITIONS: Tool[] = TOOL_CONTRACTS.map(
  ({ name, title, annotations, description, inputSchema, alwaysLoad }) => ({
    name,
    title,
    annotations,
    description,
    inputSchema: publishedInputSchema(inputSchema),
    ...(alwaysLoad ? { _meta: { "anthropic/alwaysLoad": true } } : {}),
  }),
);

export function listToolsHandler(toolsets: ReadonlySet<Toolset> = new Set(["core"])): { tools: Tool[] } {
  return { tools: TOOL_DEFINITIONS.filter((_tool, index) => toolsets.has(TOOL_CONTRACTS[index].toolset)) };
}
