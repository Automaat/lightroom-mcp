#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { PluginSocket } from "./plugin-socket.js";

const REQUEST_PORT = 58763; // plugin listens here, server writes commands
const RESPONSE_PORT = 58764; // plugin listens here, server reads responses
const REQUEST_TIMEOUT_MS = 30_000;

interface PluginResponse {
  id: string;
  result?: unknown;
  error?: string;
}

interface PendingResponse {
  resolve: (resp: PluginResponse) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
}

const pending = new Map<string, PendingResponse>();
let requestIdCounter = 0;

function handleResponseLine(line: string): void {
  let resp: PluginResponse;
  try {
    resp = JSON.parse(line) as PluginResponse;
  } catch (e) {
    console.error(`Bad JSON from plugin: ${line}`);
    return;
  }
  const p = pending.get(resp.id);
  if (!p) {
    console.error(`Response for unknown id: ${resp.id}`);
    return;
  }
  clearTimeout(p.timer);
  pending.delete(resp.id);
  p.resolve(resp);
}

const requestSocket = new PluginSocket({ port: REQUEST_PORT, label: "request" });
const responseSocket = new PluginSocket({
  port: RESPONSE_PORT,
  label: "response",
  onLine: handleResponseLine,
});
requestSocket.connect();
responseSocket.connect();

const server = new Server(
  {
    name: "lightroom-mcp-server",
    version: "0.2.0",
  },
  {
    capabilities: {
      tools: {},
    },
  },
);

server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: "search_photos",
        description: "Search for photos in Lightroom catalog by criteria",
        inputSchema: {
          type: "object",
          properties: {
            filename: { type: "string", description: "Search by filename (partial match)" },
            keywords: {
              type: "array",
              items: { type: "string" },
              description: "Search by keywords",
            },
            rating: {
              type: "number",
              description: "Filter by star rating (0-5)",
              minimum: 0,
              maximum: 5,
            },
            start_date: { type: "string", description: "Start date (YYYY-MM-DD)" },
            end_date: { type: "string", description: "End date (YYYY-MM-DD)" },
          },
        },
      },
      {
        name: "get_photo_metadata",
        description: "Get detailed metadata for a specific photo",
        inputSchema: {
          type: "object",
          properties: {
            photo_id: { type: "string", description: "Photo ID or file path" },
          },
          required: ["photo_id"],
        },
      },
      {
        name: "list_collections",
        description: "List all collections in Lightroom catalog",
        inputSchema: { type: "object", properties: {} },
      },
      {
        name: "create_collection",
        description: "Create a new collection",
        inputSchema: {
          type: "object",
          properties: {
            name: { type: "string", description: "Collection name" },
            parent: { type: "string", description: "Parent collection set (optional)" },
          },
          required: ["name"],
        },
      },
      {
        name: "add_to_collection",
        description: "Add photos to a collection",
        inputSchema: {
          type: "object",
          properties: {
            collection_name: { type: "string", description: "Collection name" },
            photo_ids: {
              type: "array",
              items: { type: "string" },
              description: "Array of photo IDs or file paths",
            },
          },
          required: ["collection_name", "photo_ids"],
        },
      },
      {
        name: "set_keywords",
        description: "Add or remove keywords from photos",
        inputSchema: {
          type: "object",
          properties: {
            photo_ids: {
              type: "array",
              items: { type: "string" },
              description: "Array of photo IDs or file paths",
            },
            add_keywords: {
              type: "array",
              items: { type: "string" },
              description: "Keywords to add",
            },
            remove_keywords: {
              type: "array",
              items: { type: "string" },
              description: "Keywords to remove",
            },
          },
          required: ["photo_ids"],
        },
      },
      {
        name: "set_rating",
        description: "Set star rating for photos",
        inputSchema: {
          type: "object",
          properties: {
            photo_ids: {
              type: "array",
              items: { type: "string" },
              description: "Array of photo IDs or file paths",
            },
            rating: {
              type: "number",
              description: "Star rating (0-5)",
              minimum: 0,
              maximum: 5,
            },
          },
          required: ["photo_ids", "rating"],
        },
      },
      {
        name: "import_photos",
        description: "Import photos into Lightroom catalog",
        inputSchema: {
          type: "object",
          properties: {
            source_path: { type: "string", description: "Path to photo or folder to import" },
            collection_name: {
              type: "string",
              description: "Collection to add imported photos to (optional)",
            },
            copy_to: {
              type: "string",
              description: "Destination folder for copying files (optional)",
            },
          },
          required: ["source_path"],
        },
      },
      {
        name: "export_photos",
        description: "Export photos from Lightroom",
        inputSchema: {
          type: "object",
          properties: {
            photo_ids: {
              type: "array",
              items: { type: "string" },
              description: "Array of photo IDs or file paths to export",
            },
            destination: { type: "string", description: "Export destination folder" },
            format: {
              type: "string",
              description: "Export format (jpeg, png, tiff, original)",
              enum: ["jpeg", "png", "tiff", "original"],
            },
            quality: {
              type: "number",
              description: "JPEG quality (0-100)",
              minimum: 0,
              maximum: 100,
            },
            width: { type: "number", description: "Max width in pixels (optional)" },
            height: { type: "number", description: "Max height in pixels (optional)" },
          },
          required: ["photo_ids", "destination"],
        },
      },
    ],
  };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  if (!requestSocket.isConnected() || !responseSocket.isConnected()) {
    return {
      content: [
        {
          type: "text",
          text: "Lightroom plugin not connected. Open Lightroom and click 'Start Server' in Plug-in Manager.",
        },
      ],
      isError: true,
    };
  }

  const id = `req_${Date.now()}_${requestIdCounter++}`;

  const responsePromise = new Promise<PluginResponse>((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`Plugin response timeout (${REQUEST_TIMEOUT_MS / 1000}s)`));
    }, REQUEST_TIMEOUT_MS);
    pending.set(id, { resolve, reject, timer });
  });

  const sent = requestSocket.send(JSON.stringify({ id, action: name, params: args ?? {} }));
  if (!sent) {
    const p = pending.get(id);
    if (p) clearTimeout(p.timer);
    pending.delete(id);
    return {
      content: [{ type: "text", text: "Failed to send request to plugin (socket dropped)" }],
      isError: true,
    };
  }

  try {
    const resp = await responsePromise;
    if (resp.error) {
      return {
        content: [{ type: "text", text: `Error: ${resp.error}` }],
        isError: true,
      };
    }
    return {
      content: [{ type: "text", text: JSON.stringify(resp.result, null, 2) }],
    };
  } catch (e) {
    return {
      content: [{ type: "text", text: e instanceof Error ? e.message : String(e) }],
      isError: true,
    };
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Lightroom MCP server running on stdio");
  console.error(`Connecting to plugin: request :${REQUEST_PORT}, response :${RESPONSE_PORT}`);
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
