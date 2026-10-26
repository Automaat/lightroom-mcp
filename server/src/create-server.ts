import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  ListPromptsRequestSchema,
  GetPromptRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import type { ToolCaller } from "./broker.js";
import { createCallToolHandler, type ToolHandlerDeps } from "./tool-handler.js";
import { listToolsHandler } from "./list-tools-handler.js";
import { VERSION } from "./version.js";
import { getSkillPrompt, SKILL_PROMPT } from "./skill-prompt.js";

export type ServerDeps = ToolHandlerDeps | { callTool: ToolCaller };

export function createMcpServer(deps: ServerDeps): Server {
  const server = new Server(
    { name: "lightroom-mcp-server", version: VERSION },
    { capabilities: { tools: {}, prompts: {} } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () =>
    listToolsHandler(),
  );
  server.setRequestHandler(ListPromptsRequestSchema, async () => ({ prompts: [SKILL_PROMPT] }));
  server.setRequestHandler(GetPromptRequestSchema, async (request) => getSkillPrompt(request.params.name));

  const callTool = "callTool" in deps ? deps.callTool : createCallToolHandler(deps);
  server.setRequestHandler(CallToolRequestSchema, async (request, extra) => {
    const { name, arguments: args } = request.params;
    const progressToken = request.params._meta?.progressToken;
    return callTool(name, args ?? {}, {
      signal: extra.signal,
      onProgress: progressToken === undefined ? undefined : (progress) => {
        void extra.sendNotification({ method: "notifications/progress", params: { progressToken, ...progress } }).catch(() => {});
      },
    });
  });

  return server;
}
