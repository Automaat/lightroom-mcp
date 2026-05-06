import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import type { Dispatcher } from "./dispatcher.js";
import { createCallToolHandler } from "./tool-handler.js";
import { listToolsHandler } from "./list-tools-handler.js";

export interface ServerDeps {
  dispatcher: Pick<Dispatcher, "call">;
  isReady: () => boolean;
}

export function createMcpServer(deps: ServerDeps): Server {
  const server = new Server(
    { name: "lightroom-mcp-server", version: "0.2.0" },
    { capabilities: { tools: {} } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () =>
    listToolsHandler(),
  );

  const callTool = createCallToolHandler(deps);
  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;
    return callTool(name, args ?? {});
  });

  return server;
}
