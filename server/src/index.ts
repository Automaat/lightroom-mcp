#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import express from "express";
import cors from "cors";

const HTTP_PORT = 8765;

// Request/Response queue management
interface PendingRequest {
  id: string;
  action: string;
  params: any;
  timestamp: number;
}

interface PendingResponse {
  id: string;
  result: any;
  error?: string;
}

const pendingRequests: PendingRequest[] = [];
const pendingResponses: Map<string, PendingResponse> = new Map();
let requestIdCounter = 0;

// Create Express HTTP server for plugin polling
const app = express();
app.use(cors());
app.use(express.json());

// Plugin polls this endpoint for pending requests
app.get("/poll-request", (req, res) => {
  if (pendingRequests.length > 0) {
    const request = pendingRequests.shift()!;
    res.json(request);
  } else {
    res.json({ action: "none" });
  }
});

// Plugin submits responses here
app.post("/submit-response", (req, res) => {
  const { id, result, error } = req.body;

  if (!id) {
    res.status(400).json({ error: "Missing request id" });
    return;
  }

  pendingResponses.set(id, { id, result, error });
  res.json({ success: true });
});

// Health check
app.get("/health", (req, res) => {
  res.json({
    status: "ok",
    pendingRequests: pendingRequests.length,
    pendingResponses: pendingResponses.size,
  });
});

// Debug endpoint to manually queue a request (for testing)
app.post("/debug/queue-request", (req, res) => {
  const { action, params } = req.body;

  if (!action) {
    res.status(400).json({ error: "Missing action" });
    return;
  }

  const requestId = `req_${Date.now()}_${requestIdCounter++}`;

  const pendingRequest: PendingRequest = {
    id: requestId,
    action,
    params: params || {},
    timestamp: Date.now(),
  };

  pendingRequests.push(pendingRequest);

  res.json({
    success: true,
    requestId,
    message: "Request queued. Plugin will pick it up on next poll."
  });
});

// Start HTTP server
app.listen(HTTP_PORT, () => {
  console.error(`HTTP server listening on port ${HTTP_PORT}`);
});

// MCP Server setup
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

// Handle tool calls - queue request and wait for response
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    // Generate unique request ID
    const requestId = `req_${Date.now()}_${requestIdCounter++}`;

    // Queue the request for plugin to pick up
    const pendingRequest: PendingRequest = {
      id: requestId,
      action: name,
      params: args || {},
      timestamp: Date.now(),
    };

    pendingRequests.push(pendingRequest);

    // Wait for response with timeout (30 seconds)
    const timeoutMs = 30000;
    const startTime = Date.now();

    while (Date.now() - startTime < timeoutMs) {
      if (pendingResponses.has(requestId)) {
        const response = pendingResponses.get(requestId)!;
        pendingResponses.delete(requestId);

        if (response.error) {
          return {
            content: [
              {
                type: "text",
                text: `Error: ${response.error}`,
              },
            ],
            isError: true,
          };
        }

        return {
          content: [
            {
              type: "text",
              text: JSON.stringify(response.result, null, 2),
            },
          ],
        };
      }

      // Wait 100ms before checking again
      await new Promise((resolve) => setTimeout(resolve, 100));
    }

    // Timeout
    return {
      content: [
        {
          type: "text",
          text: `Timeout: Lightroom plugin did not respond within ${timeoutMs / 1000}s. Make sure Lightroom is running with the plugin active.`,
        },
      ],
      isError: true,
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
  console.error(`Plugin should poll: http://localhost:${HTTP_PORT}/poll-request`);
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
