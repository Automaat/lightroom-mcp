import { Server } from "@modelcontextprotocol/server";
import type { ToolCaller } from "./broker.js";
import { createCallToolHandler, type ToolHandlerDeps } from "./tool-handler.js";
import { TOOL_CONTRACTS } from "./tool-contracts.js";
import { parseToolsets, type Toolset } from "./toolsets.js";
import { listToolsHandler } from "./list-tools-handler.js";
import { VERSION } from "./version.js";
import { getSkillPrompt, SKILL_PROMPT } from "./skill-prompt.js";
import { SERVER_INSTRUCTIONS } from "./server-instructions.js";
import { parseReadOnly } from "./read-only.js";

export type ServerDeps = ToolHandlerDeps | { callTool: ToolCaller };

export function createMcpServer(deps: ServerDeps, options: { toolsets?: readonly Toolset[]; readOnly?: boolean } = {}): Server {
  const enabledToolsets = new Set<Toolset>(["core", ...(options.toolsets ?? parseToolsets())]);
  const readOnly = options.readOnly ?? parseReadOnly(process.env.LIGHTROOM_MCP_READ_ONLY);
  const tools = listToolsHandler(enabledToolsets, readOnly);
  const allowedTools = new Set(tools.tools.map((tool) => tool.name));
  const hiddenTools = new Map(TOOL_CONTRACTS.filter((tool) => !enabledToolsets.has(tool.toolset))
    .map((tool) => [tool.name, tool.toolset]));
  const server = new Server(
    { name: "lightroom-mcp-server", version: VERSION },
    { capabilities: { tools: {}, prompts: {} }, instructions: SERVER_INSTRUCTIONS },
  );

  server.setRequestHandler("tools/list", async () =>
    tools,
  );
  server.setRequestHandler("prompts/list", async () => ({ prompts: [SKILL_PROMPT] }));
  server.setRequestHandler("prompts/get", async (request) => getSkillPrompt(request.params.name));

  const callTool = "callTool" in deps ? deps.callTool : createCallToolHandler(deps);
  server.setRequestHandler("tools/call", async (request, ctx) => {
    const { name, arguments: args } = request.params;
    if (readOnly && !allowedTools.has(name)) {
      return { isError: true, content: [{ type: "text", text: `Tool "${name}" is unavailable with LIGHTROOM_MCP_READ_ONLY enabled and the selected LIGHTROOM_MCP_TOOLSETS. Only listed read tools can be called. Change the settings and restart the server to enable other tools.` }] };
    }
    const toolset = hiddenTools.get(name);
    if (toolset) {
      return { isError: true, content: [{ type: "text", text: `Tool "${name}" is disabled. Enable "${toolset}" in LIGHTROOM_MCP_TOOLSETS and restart the server.` }] };
    }
    const progressToken = request.params._meta?.progressToken;
    return callTool(name, args ?? {}, {
      signal: ctx.mcpReq.signal,
      onProgress: progressToken === undefined ? undefined : (progress) => {
        void ctx.mcpReq.notify({ method: "notifications/progress", params: { progressToken, ...progress } }).catch(() => {});
      },
    });
  });

  return server;
}
