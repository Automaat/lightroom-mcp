import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import { TOOL_CONTRACTS } from "./tool-contracts.js";

export const TOOL_DEFINITIONS: Tool[] = TOOL_CONTRACTS.map(
  ({ name, description, inputSchema }) => ({
    name,
    description,
    inputSchema,
  }),
);

export function listToolsHandler(): { tools: Tool[] } {
  return { tools: TOOL_DEFINITIONS };
}
