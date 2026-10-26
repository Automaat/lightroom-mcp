import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import type { ToolCaller } from "./broker.js";
import { createCallToolHandler, type ToolHandlerDeps } from "./tool-handler.js";
import { listToolsHandler } from "./list-tools-handler.js";
import { VERSION } from "./version.js";

export type ServerDeps = ToolHandlerDeps | { callTool: ToolCaller };

export function createMcpServer(deps: ServerDeps): Server {
  const server = new Server(
    { name: "lightroom-mcp-server", version: VERSION },
    { capabilities: { tools: {} } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () =>
    listToolsHandler(),
  );

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
