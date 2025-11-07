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
cd server
npm install
```

### 2. Install Lightroom Plugin

1. Copy `plugin/LightroomMCP.lrplugin` to Lightroom plugins directory:
   - macOS: `~/Library/Application Support/Adobe/Lightroom/Plugins/`
   - Windows: `%APPDATA%\Adobe\Lightroom\Plugins\`

2. Open Lightroom Classic
3. Go to **File > Plug-in Manager**
4. Click **Add** and select `LightroomMCP.lrplugin`
5. Verify plugin shows as "Running" with green status

The plugin will start an HTTP server on `localhost:8765`.

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
3. Check status is "Running"

### View Logs

Plugin logs: `~/Documents/LrClassicLogs/LightroomMCP.log`

### Test HTTP Server

```bash
# Test if Lightroom plugin is responding
curl -X POST http://localhost:8765/list_collections \
  -H "Content-Type: application/json" \
  -d '{}'
```

Should return JSON with your collections.

### MCP Server Issues

Check Claude Desktop logs:
- macOS: `~/Library/Logs/Claude/mcp*.log`

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
├── .mise.toml              # Tool version management
├── PLAN.md                 # Implementation plan
├── README.md               # This file
├── server/                 # TypeScript MCP server
│   ├── package.json
│   ├── tsconfig.json
│   ├── jest.config.js
│   ├── src/
│   │   └── index.ts        # Main MCP server
│   └── tests/
│       └── tools.test.ts
└── plugin/
    └── LightroomMCP.lrplugin/
        ├── Info.lua            # Plugin metadata
        ├── LightroomMCP.lua    # Plugin entry point
        ├── HttpServer.lua      # HTTP server
        ├── JSON.lua            # JSON encoder/decoder
        └── handlers/           # Request handlers
            ├── search.lua
            ├── metadata.lua
            ├── collections.lua
            ├── organization.lua
            ├── import.lua
            └── export.lua
```

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
