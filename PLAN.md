# Lightroom Classic MCP Server

## Overview

MCP (Model Context Protocol) server for Adobe Lightroom Classic, enabling AI assistants like Claude to interact with your photo catalog.

**Project Location:** `/Users/marcin.skalski@konghq.com/sideprojects/lightroom-mcp/`

## Architecture

- **TypeScript MCP Server**: Implements MCP protocol using `@modelcontextprotocol/sdk`
- **Lightroom Lua Plugin**: Acts as bridge between MCP server and Lightroom Classic
- **Communication**: HTTP REST API between MCP server and Lua plugin

```
┌─────────────┐      stdio      ┌─────────────┐      HTTP      ┌──────────────────┐
│   Claude    │ ◄──────────────► │  MCP Server │ ◄─────────────► │ Lightroom Plugin │
│   Desktop   │                  │ (TypeScript)│                 │     (Lua)        │
└─────────────┘                  └─────────────┘                 └──────────────────┘
                                                                          │
                                                                          ▼
                                                                  ┌──────────────────┐
                                                                  │    Lightroom     │
                                                                  │     Catalog      │
                                                                  └──────────────────┘
```

## Features

### Catalog Querying
- `search_photos`: Search photos by filename, date, rating, keywords
- `get_photo_metadata`: Retrieve EXIF data, develop settings, file info
- `list_collections`: List all collections in catalog

### Organization
- `create_collection`: Create new photo collection
- `add_to_collection`: Add photos to existing collection
- `set_keywords`: Add or remove keywords from photos
- `set_rating`: Set star rating (0-5)

### Import & Export
- `import_photos`: Import photos into catalog and optionally add to collection
- `export_photos`: Export photos with custom presets, formats, and destinations

## Implementation Steps

### 1. Project Setup
- [x] Create `lightroom-mcp/` directory structure
- [ ] Initialize git repository
- [ ] Create `.gitignore` for Node.js and macOS
- [ ] Initialize TypeScript project with dependencies
- [ ] Create Lua plugin folder structure

### 2. MCP Server (TypeScript)
- [ ] Set up MCP server with stdio transport
- [ ] Define tool schemas for all operations
- [ ] Implement HTTP client to communicate with Lua plugin
- [ ] Add Jest unit tests for tool handlers
- [ ] Test MCP server with MCP Inspector

### 3. Lua Plugin Bridge
- [ ] Create plugin Info.lua with metadata
- [ ] Implement HTTP server using LrSocket
- [ ] Create REST endpoints for catalog operations
- [ ] Handle plugin initialization and shutdown
- [ ] Add error handling and logging
- [ ] Optional: Add Lua unit tests (busted framework)

### 4. Catalog Tools Implementation
- [ ] Implement search_photos endpoint
- [ ] Implement get_photo_metadata endpoint
- [ ] Implement list_collections endpoint

### 5. Organization Tools Implementation
- [ ] Implement create_collection endpoint
- [ ] Implement add_to_collection endpoint
- [ ] Implement set_keywords endpoint
- [ ] Implement set_rating endpoint

### 6. Import & Export Implementation
- [ ] Implement import_photos endpoint
- [ ] Implement export_photos endpoint with preset support

### 7. Testing & Documentation
- [ ] Run MCP server test suite
- [ ] Manual integration testing with Lightroom Classic
- [ ] Write README with installation instructions
- [ ] Document Claude Desktop configuration
- [ ] Add usage examples and troubleshooting

## Technical Details

### MCP Server Stack
- TypeScript
- `@modelcontextprotocol/sdk` - MCP protocol implementation
- `node-fetch` or `axios` - HTTP client for Lua plugin communication
- Jest - Testing framework

### Lua Plugin Stack
- Lua 5.1 (Lightroom's embedded version)
- Lightroom SDK API
- LrSocket - HTTP server implementation
- LrHttp - HTTP utilities
- LrTasks - Async task management

### Communication Protocol
- MCP Server listens on stdin/stdout for Claude Desktop
- Lua Plugin runs HTTP server on localhost (e.g., port 8765)
- MCP Server sends HTTP requests to Lua Plugin
- Lua Plugin executes Lightroom SDK calls and returns JSON responses

## Directory Structure

```
lightroom-mcp/
├── .git/
├── .gitignore
├── PLAN.md
├── README.md
├── server/
│   ├── package.json
│   ├── tsconfig.json
│   ├── src/
│   │   ├── index.ts
│   │   ├── tools/
│   │   │   ├── search.ts
│   │   │   ├── metadata.ts
│   │   │   ├── collections.ts
│   │   │   ├── organization.ts
│   │   │   ├── import.ts
│   │   │   └── export.ts
│   │   └── client.ts
│   └── tests/
│       └── tools.test.ts
└── plugin/
    └── LightroomMCP.lrplugin/
        ├── Info.lua
        ├── LightroomMCP.lua
        ├── HttpServer.lua
        └── handlers/
            ├── search.lua
            ├── metadata.lua
            ├── collections.lua
            ├── organization.lua
            ├── import.lua
            └── export.lua
```

## Deliverables

- ✅ PLAN.md - This planning document
- [ ] TypeScript MCP server with full tool implementation
- [ ] Jest test suite for MCP server
- [ ] Lightroom Lua plugin with HTTP bridge
- [ ] Git repository with proper .gitignore
- [ ] Comprehensive README with setup instructions
- [ ] Claude Desktop configuration guide

## Resources

- [Lightroom Classic SDK Documentation](https://developer.adobe.com/lightroom-classic/)
- [Model Context Protocol Specification](https://modelcontextprotocol.io/)
- [MCP TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk)
- [Lightroom SDK Examples](https://github.com/Jaid/lightroom-sdk-8-examples)
