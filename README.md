# Lightroom Classic MCP Server

MCP (Model Context Protocol) server for Adobe Lightroom Classic. Interact with your photo catalog using Claude and other AI assistants.

## Features

### Catalog Management
- **Search Photos**: Find photos by filename, keywords, rating, date range
- **Get Metadata**: Retrieve EXIF data, develop settings, and file information
- **List Collections**: View all collections and collection sets

### Organization
- **Create Collections**: Organize photos into collections
- **Add to Collection**: Add photos to existing collections
- **Set Keywords**: Batch add/remove keywords
- **Set Ratings**: Apply star ratings (0-5)

### Import & Export
- **Import Photos**: Import photos into catalog and collections
- **Export Photos**: Export with custom formats (JPEG, PNG, TIFF), quality, dimensions

## Architecture

**⚠️ Architecture Limitation**: Lightroom's LrSocket API does **not support server sockets**. The socket only supports outbound connections.

**Implemented Solution**: Reverse HTTP polling architecture where the MCP server runs an HTTP server on port 8765, and the Lightroom plugin polls it every 3 seconds for pending requests.

```
┌─────────────┐    stdio    ┌──────────────────┐    HTTP Poll    ┌──────────────────┐
│   Claude    │ ◄──────────► │   MCP Server     │ ◄──────────────► │ Lightroom Plugin │
│   Desktop   │              │ (HTTP on :8765)  │    (Every 3s)    │  (HTTP Client)   │
└─────────────┘              └──────────────────┘                  └──────────────────┘
                                     │                                       │
                                     │  Queue Request                        │
                                     │──────────────────────────────────────►│
                                     │                                       │
                                     │                                       ▼
                                     │                               Execute in Catalog
                                     │                                       │
                                     │◄──────────────────────────────────────│
                                     │    Submit Response
                                     │
                                     └──► Return to Claude
```

**How it works**:
1. Claude calls an MCP tool via stdio
2. MCP server queues the request with a unique ID
3. Plugin polls `/poll-request` endpoint (every 3s)
4. Plugin receives request and executes Lightroom catalog operation
5. Plugin POSTs response to `/submit-response` endpoint
6. MCP server waits for response (up to 30s) and returns to Claude

## Current Status

✅ **Working**:
- MCP server with HTTP server on port 8765
- Request/response queue system
- Plugin polling loop (3-second intervals)
- JSON request/response encoding
- End-to-end communication flow
- Mock data responses for testing

🚧 **In Progress**:
- Real Lightroom catalog access (currently returns mock data)
- Implementing all tool actions (search, metadata, collections, etc.)

📋 **Next Steps**:
- Implement actual catalog operations using LrApplication.activeCatalog()
- Handle catalog access context properly (withReadAccessDo/withWriteAccessDo)
- Add error handling and retry logic
- Test with real photo catalog

## Prerequisites

- **Lightroom Classic** (tested with v13+)
- **Node.js** 22+ (managed via mise)
- **mise** - Development tool version manager

## Installation

### 1. Install Dependencies

```bash
# Install mise if not already installed
curl https://mise.run | sh

# Trust and install tools (Node.js)
mise trust
mise install

# Install npm dependencies
mise run install
```

### 2. Install Lightroom Plugin

1. Copy `plugin/LightroomMCP.lrplugin` to Lightroom plugins directory:
   - macOS: `~/Library/Application Support/Adobe/Lightroom/Plugins/`
   - Windows: `%APPDATA%\Adobe\Lightroom\Plugins\`

2. Open Lightroom Classic
3. Go to **File > Plug-in Manager**
4. Click **Add** and select `LightroomMCP.lrplugin`
5. Click **"Start Polling"** button in the plugin manager
6. Verify plugin shows status as "Polling: true"

The plugin will poll the MCP server's HTTP endpoint at `http://localhost:8765/poll-request` every 3 seconds.

### 3. Build MCP Server

```bash
cd server
npm run build
```

### 4. Configure Claude Desktop

Edit Claude Desktop config:
- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`

Add:

```json
{
  "mcpServers": {
    "lightroom": {
      "command": "node",
      "args": [
        "/Users/YOUR_USERNAME/sideprojects/lightroom-mcp/server/dist/index.js"
      ]
    }
  }
}
```

Replace `/Users/YOUR_USERNAME/` with your actual path.

### 5. Restart Claude Desktop

Restart Claude Desktop to load the MCP server.

## Usage Examples

### Search Photos

```
Find all 5-star rated photos from 2024
```

Claude will use the `search_photos` tool with parameters:
```json
{
  "rating": 5,
  "start_date": "2024-01-01",
  "end_date": "2024-12-31"
}
```

### Get Photo Details

```
Get metadata for photo at /Users/me/Photos/IMG_1234.jpg
```

### Create and Organize

```
Create a collection called "Best of 2024" and add all 5-star photos to it
```

Claude will:
1. Use `create_collection` to create the collection
2. Use `search_photos` to find 5-star photos
3. Use `add_to_collection` to add them

### Batch Keywords

```
Add keywords "landscape" and "sunset" to all photos in the Summer collection
```

### Export Photos

```
Export all photos with keyword "portfolio" to ~/Desktop/Portfolio as JPEGs at 2000px wide
```

## Testing

### Test Integration Flow

With the MCP server running and Lightroom plugin polling:

```bash
# Test full request/response flow
node test-full-flow.mjs
```

This will:
1. Queue a test request via the debug endpoint
2. Wait for the plugin to process it
3. Verify the response was submitted
4. Show timing and status

### Manual Testing via Debug Endpoint

```bash
# Queue a test request
curl -X POST http://localhost:8765/debug/queue-request \
  -H "Content-Type: application/json" \
  -d '{"action":"list_collections","params":{}}'

# Check server status
curl http://localhost:8765/health

# Should show:
# {
#   "status": "ok",
#   "pendingRequests": 0,    # Request was processed
#   "pendingResponses": 1    # Response received
# }
```

### Check Plugin Status in Lightroom

1. Go to **File > Plug-in Manager > Lightroom MCP**
2. Click **"Refresh Status"** button
3. View logs showing polling activity and processed requests

## Development

### Run Tests

```bash
cd server
npm test
```

### Watch Mode

```bash
npm run watch
```

### Mise Tasks

```bash
# Install dependencies
mise run install

# Build
mise run build

# Test
mise run test

# Watch mode
mise run dev
```

## Debugging

### Check Plugin Status

1. Open Lightroom > **File > Plug-in Manager**
2. Select "Lightroom MCP"
3. Verify "Polling: true" in status
4. Check "Last Poll" timestamp is recent (within 3s)
5. Click "Refresh Status" to see detailed logs

### View Logs

Plugin logs viewable in Plugin Manager status panel or:
- macOS: `~/Documents/LrClassicLogs/LightroomMCP.log`

### Test MCP Server

```bash
# Check server health
curl http://localhost:8765/health

# Test connection from plugin perspective
# (in Lightroom Plugin Manager, click "Test Connection")

# Queue a manual test request
curl -X POST http://localhost:8765/debug/queue-request \
  -H "Content-Type: application/json" \
  -d '{"action":"list_collections","params":{}}'
```

### Verify HTTP Server is Running

```bash
# Check port 8765 is listening
lsof -i :8765

# Should show node process for MCP server
```

### MCP Server Issues

Check Claude Desktop logs:
- macOS: `~/Library/Logs/Claude/mcp*.log`

Common issues:
- **Server not starting**: Check Node.js version (22+ required)
- **Port already in use**: Kill existing process on port 8765
- **Plugin not polling**: Click "Start Polling" in Plugin Manager
- **Timeout errors**: Ensure Lightroom is running and plugin is polling

## Troubleshooting

### Plugin Not Starting

- Verify plugin is in correct directory
- Check Lightroom version (requires v8+ SDK)
- Look for errors in Lightroom logs

### Connection Refused

- Ensure Lightroom plugin is running
- Check port 8765 is not in use: `lsof -i :8765`
- Restart Lightroom

### Photos Not Found

- Photo IDs are catalog-specific
- Use file paths as alternative: `/full/path/to/photo.jpg`
- Verify photos are imported into catalog

## Project Structure

```
lightroom-mcp/
├── .mise.toml                # Tool version management
├── PLAN.md                   # Implementation plan
├── README.md                 # This file
├── test-full-flow.mjs        # Integration test script
├── server/                   # TypeScript MCP server
│   ├── package.json
│   ├── tsconfig.json
│   ├── src/
│   │   └── index.ts          # Main MCP server with HTTP endpoints
│   └── dist/
│       └── index.js          # Compiled server (for Claude Desktop)
└── plugin/
    └── LightroomMCP.lrplugin/
        ├── Info.lua              # Plugin metadata
        ├── PluginInfoProvider.lua # Plugin UI and polling loop
        └── JSON.lua              # JSON encoder/decoder
```

### Key Files

- **server/src/index.ts**: MCP server with:
  - MCP stdio transport for Claude Desktop
  - HTTP server on port 8765 with endpoints:
    - `GET /poll-request` - Plugin polls for pending requests
    - `POST /submit-response` - Plugin submits results
    - `GET /health` - Server status
    - `POST /debug/queue-request` - Manual testing endpoint

- **plugin/.../PluginInfoProvider.lua**: Lightroom plugin with:
  - Polling loop (every 3 seconds)
  - Request execution (currently mock data)
  - Response submission via HTTP POST
  - Status UI with Start/Stop Polling buttons

## API Reference

### Available Tools

#### `search_photos`
Search catalog by criteria.

**Parameters:**
- `filename` (string, optional): Partial filename match
- `keywords` (string[], optional): Filter by keywords (AND logic)
- `rating` (number, optional): Star rating 0-5
- `start_date` (string, optional): Date range start (YYYY-MM-DD)
- `end_date` (string, optional): Date range end (YYYY-MM-DD)

**Returns:** Array of photos with id, path, filename, rating, date

#### `get_photo_metadata`
Get detailed metadata for a photo.

**Parameters:**
- `photo_id` (string, required): Photo ID or file path

**Returns:** Full metadata including EXIF, develop settings, keywords

#### `list_collections`
List all collections.

**Returns:** Array of collections with name, type, photo count

#### `create_collection`
Create new collection.

**Parameters:**
- `name` (string, required): Collection name
- `parent` (string, optional): Parent collection set

#### `add_to_collection`
Add photos to collection.

**Parameters:**
- `collection_name` (string, required): Target collection
- `photo_ids` (string[], required): Photo IDs or paths

#### `set_keywords`
Batch set keywords.

**Parameters:**
- `photo_ids` (string[], required): Photos to update
- `add_keywords` (string[], optional): Keywords to add
- `remove_keywords` (string[], optional): Keywords to remove

#### `set_rating`
Set star rating.

**Parameters:**
- `photo_ids` (string[], required): Photos to update
- `rating` (number, required): Rating 0-5

#### `import_photos`
Import photos into catalog.

**Parameters:**
- `source_path` (string, required): File or folder path
- `collection_name` (string, optional): Add to collection
- `copy_to` (string, optional): Copy destination

#### `export_photos`
Export photos.

**Parameters:**
- `photo_ids` (string[], required): Photos to export
- `destination` (string, required): Export folder
- `format` (string, optional): jpeg|png|tiff|original (default: jpeg)
- `quality` (number, optional): JPEG quality 0-100 (default: 90)
- `width` (number, optional): Max width in pixels
- `height` (number, optional): Max height in pixels

## Contributing

Issues and PRs welcome!

## License

MIT
