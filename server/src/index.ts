#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const LIGHTROOM_PLUGIN_URL = "http://localhost:8765";

const server = new Server(
  {
    name: "lightroom-mcp-server",
    version: "0.1.0",
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// List available tools
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: "search_photos",
        description: "Search for photos in Lightroom catalog by criteria",
        inputSchema: {
          type: "object",
          properties: {
            filename: {
              type: "string",
              description: "Search by filename (partial match)",
            },
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
            start_date: {
              type: "string",
              description: "Start date (YYYY-MM-DD)",
            },
            end_date: {
              type: "string",
              description: "End date (YYYY-MM-DD)",
            },
          },
        },
      },
      {
        name: "get_photo_metadata",
        description: "Get detailed metadata for a specific photo",
        inputSchema: {
          type: "object",
          properties: {
            photo_id: {
              type: "string",
              description: "Photo ID or file path",
            },
          },
          required: ["photo_id"],
        },
      },
      {
        name: "list_collections",
        description: "List all collections in Lightroom catalog",
        inputSchema: {
          type: "object",
          properties: {},
        },
      },
      {
        name: "create_collection",
        description: "Create a new collection",
        inputSchema: {
          type: "object",
          properties: {
            name: {
              type: "string",
              description: "Collection name",
            },
            parent: {
              type: "string",
              description: "Parent collection set (optional)",
            },
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
            collection_name: {
              type: "string",
              description: "Collection name",
            },
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
            source_path: {
              type: "string",
              description: "Path to photo or folder to import",
            },
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
            destination: {
              type: "string",
              description: "Export destination folder",
            },
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
            width: {
              type: "number",
              description: "Max width in pixels (optional)",
            },
            height: {
              type: "number",
              description: "Max height in pixels (optional)",
            },
          },
          required: ["photo_ids", "destination"],
        },
      },
    ],
  };
});

// Handle tool calls
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    const response = await fetch(`${LIGHTROOM_PLUGIN_URL}/${name}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify(args || {}),
    });

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`);
    }

    const result = await response.json();

    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(result, null, 2),
        },
      ],
    };
  } catch (error) {
    return {
      content: [
        {
          type: "text",
          text: `Error: ${error instanceof Error ? error.message : String(error)}`,
        },
      ],
      isError: true,
    };
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Lightroom MCP server running on stdio");
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
