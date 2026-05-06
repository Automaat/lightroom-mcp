#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { PluginSocket } from "./plugin-socket.js";
import { Dispatcher } from "./dispatcher.js";
import { createCallToolHandler } from "./tool-handler.js";
import { readToken, tokenFilePath } from "./token.js";
import { requestPort, responsePort } from "./ports.js";

const REQUEST_TIMEOUT_MS = 30_000;

let REQUEST_PORT: number;
let RESPONSE_PORT: number;
try {
  REQUEST_PORT = requestPort();
  RESPONSE_PORT = responsePort();
  readToken();
} catch (err) {
  console.error((err as Error).message);
  process.exit(1);
}

const requestSocket = new PluginSocket({
  port: REQUEST_PORT,
  label: "request",
});
const dispatcher = new Dispatcher({
  send: (line) => requestSocket.send(line),
  // Re-read on every call so a token rotation by the plugin (e.g. server
  // restart in Plug-in Manager) is picked up without bouncing this process.
  getToken: () => readToken(),
  timeoutMs: REQUEST_TIMEOUT_MS,
});
const responseSocket = new PluginSocket({
  port: RESPONSE_PORT,
  label: "response",
  onLine: (line) => dispatcher.handleResponseLine(line),
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
        description: "Search for photos in Lightroom catalog by criteria (paginated, default limit 100)",
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
            limit: { type: "number", description: "Max photos to return (default 100)", minimum: 0 },
            offset: { type: "number", description: "Number of photos to skip (default 0)", minimum: 0 },
          },
        },
      },
      {
        name: "get_selected_photos",
        description: "Get currently selected photos in Lightroom (or filmstrip if no selection). Paginated, default limit 100.",
        inputSchema: {
          type: "object",
          properties: {
            limit: { type: "number", description: "Max photos to return (default 100)", minimum: 0 },
            offset: { type: "number", description: "Number of photos to skip (default 0)", minimum: 0 },
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
        description: "List all collections in Lightroom catalog (paginated, default limit 100)",
        inputSchema: {
          type: "object",
          properties: {
            limit: { type: "number", description: "Max collections to return (default 100)", minimum: 0 },
            offset: { type: "number", description: "Number of collections to skip (default 0)", minimum: 0 },
          },
        },
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
      {
        name: "list_develop_presets",
        description: "List available Develop presets across all preset folders",
        inputSchema: {
          type: "object",
          properties: {},
        },
      },
      {
        name: "apply_develop_preset",
        description: "Apply a named Develop preset to one or more photos",
        inputSchema: {
          type: "object",
          properties: {
            photo_ids: {
              type: "array",
              items: { type: "string" },
              description: "Array of photo IDs or file paths",
            },
            preset_name: {
              type: "string",
              description: "Preset name (first match across folders)",
            },
          },
          required: ["photo_ids", "preset_name"],
        },
      },
      {
        name: "copy_develop_settings",
        description: "Copy Develop settings from one photo to others",
        inputSchema: {
          type: "object",
          properties: {
            source_id: {
              type: "string",
              description: "Source photo ID or file path",
            },
            target_ids: {
              type: "array",
              items: { type: "string" },
              description: "Target photo IDs or file paths",
            },
            settings: {
              type: "array",
              items: { type: "string" },
              description: "Optional whitelist of SDK setting keys (e.g., Exposure2012, Contrast2012). Omit to copy all.",
            },
          },
          required: ["source_id", "target_ids"],
        },
      },
      {
        name: "set_develop_settings",
        description: "Set Develop settings directly on a photo. Keys use Lightroom SDK names (Exposure2012, WhiteBalance, Contrast2012, Highlights2012, Shadows2012, Whites2012, Blacks2012, Clarity2012, Vibrance, Saturation, etc.)",
        inputSchema: {
          type: "object",
          properties: {
            photo_id: {
              type: "string",
              description: "Photo ID or file path",
            },
            settings: {
              type: "object",
              description: "SDK setting key/value pairs (e.g., {\"Exposure2012\": 0.5})",
            },
          },
          required: ["photo_id", "settings"],
        },
      },
    ],
  };
});

const callTool = createCallToolHandler({
  dispatcher,
  isReady: () => requestSocket.isConnected() && responseSocket.isConnected(),
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  return callTool(name, args);
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Lightroom MCP server running on stdio");
  console.error(`Connecting to plugin: request :${REQUEST_PORT}, response :${RESPONSE_PORT}`);
  console.error(`Token file: ${tokenFilePath()}`);
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
