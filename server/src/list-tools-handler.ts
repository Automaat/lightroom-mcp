import type { Tool } from "@modelcontextprotocol/server";
import { TOOL_CONTRACTS } from "./tool-contracts.js";

export const TOOL_DEFINITIONS: Tool[] = TOOL_CONTRACTS.map(
  ({ name, title, annotations, description, inputSchema, alwaysLoad }) => ({
    name,
    title,
    annotations,
    description,
    inputSchema,
    ...(alwaysLoad ? { _meta: { "anthropic/alwaysLoad": true } } : {}),
  }),
);

export function listToolsHandler(): { tools: Tool[] } {
  return { tools: TOOL_DEFINITIONS };
}
