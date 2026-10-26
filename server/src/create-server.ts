import { Server } from "@modelcontextprotocol/server";
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

  server.setRequestHandler("tools/list", async () =>
    listToolsHandler(),
  );
  server.setRequestHandler("prompts/list", async () => ({ prompts: [SKILL_PROMPT] }));
  server.setRequestHandler("prompts/get", async (request) => getSkillPrompt(request.params.name));

  const callTool = "callTool" in deps ? deps.callTool : createCallToolHandler(deps);
  server.setRequestHandler("tools/call", async (request, ctx) => {
    const { name, arguments: args } = request.params;
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
