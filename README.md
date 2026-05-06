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

The plugin opens **two `LrSocket.bind` servers** on localhost; the MCP server connects as a TCP client. Same dual-port pattern that MIDI2LR has used in production for years.

```
┌─────────────┐   stdio    ┌──────────────────┐   TCP :58763 →    ┌──────────────────┐
│   Claude    │ ◄────────► │   MCP Server     │ ─────────────────► │ Lightroom Plugin │
│   Desktop   │            │  (Node TCP)      │ ←───────────────── │   (LrSocket)     │
└─────────────┘            └──────────────────┘   ← TCP :58764     └──────────────────┘
                                                                            │
                                                                            ▼
                                                                  catalog:withReadAccessDo
```

**How it works**:
1. Plugin binds two LrSockets: `:58763` in `mode='receive'` (request channel), `:58764` in `mode='send'` (response channel).
2. MCP server opens persistent TCP connections to both, with auto-reconnect.
3. Claude calls an MCP tool over stdio.
4. Server writes `{"id","action","params"}\n` on the request socket.
5. Plugin's `onMessage` decodes, dispatches to a `Handler*.lua` module under `LrTasks.startAsyncTask` (so `withReadAccessDo` can yield), encodes the result, writes `\n`-terminated to its send socket.
6. Server matches response by `id` and returns to Claude.

Frame: line-delimited JSON, `\n` terminator on every message.

## Current Status

✅ **Working** (verified end-to-end against real catalog):
- LrSocket dual-port transport (no HTTP, no polling)
- Real catalog ops via `LrApplication.activeCatalog()` + `withReadAccessDo`/`withWriteAccessDo`
- All handler modules wired through a dispatch table
- Auto-reconnect on disconnect (server side) and `:reconnect()` on socket timeout (plugin side)

🚧 **Known issues**:
- "Reload Plug-in" doesn't kill the prior async task; sockets stay bound. Workaround: Quit Lightroom (Cmd+Q) and reopen.

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
5. Click **"Start Server"** button in the plugin manager
6. Click **"Show Status"** — both `Request socket` and `Response socket` should show `connected: true` once the MCP server connects

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

## Security

### Token file permissions

On first **Start Server**, the plugin generates a 256-bit random token and
writes it to:

- macOS/Linux: `~/.config/lightroom-mcp/token`
- Windows: `%USERPROFILE%\.config\lightroom-mcp\token`

The token authenticates every message from the MCP server to the plugin over
the localhost socket. It is regenerated each time the plugin starts.

**Lightroom's Lua sandbox has no `os.execute`**, so the plugin cannot call
`chmod` itself. The file is created with whatever permissions your OS umask
applies (typically `644` on Linux — world-readable by local users).

**macOS**: home directories are not world-readable by default
(`drwx------`), so `~/.config/` inherits that privacy. No action needed for
single-user macOS installs.

**Linux / multi-user systems**: if `~/.config/` or its parents are
world-readable (common on shared servers), other local users can read the
token. After the first **Start Server** click, lock down the directory:

```bash
chmod 700 ~/.config/lightroom-mcp
```

This makes the directory and its contents accessible only to your user.

**Risk scope**: the token only gates a localhost TCP socket. An attacker
must already have local-user access on the machine to exploit a readable
token file — there is no remote attack surface.

## Configuration

Default ports: `58763` (request) / `58764` (response). To override (e.g. port conflict, multiple Lightroom instances), set both sides to matching values:

- **Server**: env vars `LIGHTROOM_MCP_REQUEST_PORT` / `LIGHTROOM_MCP_RESPONSE_PORT` (set them in your Claude Desktop config under `env`, or in the shell that launches the server).
- **Plugin**: open **File > Plug-in Manager > Lightroom MCP** and edit the **Request port** / **Response port** fields. Stop and Start the server for the change to take effect.

Both sides must agree, otherwise the server cannot connect.

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

### Direct TCP probe (bypass MCP)

`manual-test.mjs` opens raw TCP connections to plugin ports — useful for validating plugin dispatch without spinning up MCP.

```bash
# Stop the MCP server first (only one client per plugin port)
node manual-test.mjs list_collections
node manual-test.mjs search_photos '{"rating":5}'
```

### Check Plugin Status in Lightroom

1. **File > Plug-in Manager > Lightroom MCP**
2. Click **"Show Status"** — pop-up shows socket state, requests processed, recent log lines

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
3. Click **"Show Status"** — popup shows socket state and recent logs

### View Logs

Plugin logs viewable in the Show Status popup or:
- macOS: `~/Documents/LrClassicLogs/LightroomMCP.log`

### Verify Plugin is Listening

```bash
# Check ports 58763 and 58764 are bound by Adobe Lightroom
lsof -nP -iTCP:58763 -iTCP:58764
```

### MCP Server Issues

Check Claude Desktop logs:
- macOS: `~/Library/Logs/Claude/mcp*.log`

Common issues:
- **`failed to open localhost:58763` (or your configured port) after Reload Plug-in** — old async task still owns the port; Quit Lightroom (Cmd+Q) and reopen.
- **MCP server reports "plugin not connected"** — click **Start Server** in Plug-in Manager; server reconnects automatically within 1s.
- **Timeout errors** — handler may be scanning a large catalog without filters; add `rating`, `filename`, `keywords`, or date filters to narrow the search. Check Show Status for `Last event` timestamp.

## Troubleshooting

### Plugin Not Starting

- Verify plugin is in correct directory
- Check Lightroom version (requires v8+ SDK)
- Look for errors in Lightroom logs

### Connection Refused

- Ensure Lightroom is running and plugin shows **Start Server** clicked
- Check ports 58763/58764 are bound: `lsof -nP -iTCP:58763 -iTCP:58764`
- Quit + reopen Lightroom (NOT just Reload Plug-in) to release stale sockets

### Photos Not Found

- Photo IDs are catalog-specific
- Use file paths as alternative: `/full/path/to/photo.jpg`
- Verify photos are imported into catalog

## Project Structure

```
lightroom-mcp/
├── .mise.toml                # Tool version management
├── README.md                 # This file
├── manual-test.mjs           # Direct TCP probe (bypass MCP)
├── server/
│   ├── package.json
│   ├── tsconfig.json
│   ├── src/
│   │   ├── index.ts          # MCP stdio server + dispatch
│   │   └── plugin-socket.ts  # Persistent TCP client w/ reconnect + line framing
│   └── tests/
│       ├── plugin-socket.test.ts
│       └── tools.test.ts
└── plugin/
    └── LightroomMCP.lrplugin/
        ├── Info.lua                # Plugin metadata
        ├── PluginInfoProvider.lua  # LrSocket binds + dispatch + status UI
        ├── JSON.lua                # JSON encoder/decoder
        └── Handler*.lua            # One module per action group
```

### Key Files

- **server/src/index.ts**: MCP stdio server. Maintains TCP clients to plugin sockets, routes tool calls by request id.
- **server/src/plugin-socket.ts**: `PluginSocket` class — persistent TCP client with auto-reconnect and `\n`-delimited line framing.
- **plugin/.../PluginInfoProvider.lua**: Binds two `LrSocket` servers, runs a monitor loop that calls `:reconnect()` when callbacks set the rebind flag. Dispatches `onMessage` JSON to `Handler*.lua` modules under `LrTasks.startAsyncTask`.

## API Reference

### Available Tools

#### `search_photos`
Search catalog by criteria (paginated, default limit 100).

**Parameters:**
- `filename` (string, optional): Partial filename match
- `keywords` (string[], optional): Filter by keywords (AND logic)
- `rating` (number, optional): Star rating 0-5
- `start_date` (string, optional): Date range start (YYYY-MM-DD)
- `end_date` (string, optional): Date range end (YYYY-MM-DD)
- `limit` (number, optional): Max photos to return (default 100)
- `offset` (number, optional): Photos to skip for pagination (default 0)

**Returns:** `{ count, photos[], has_more, warning? }` — `warning` is set when no filters are applied (full-catalog scan).

> **Performance note:** Always provide at least one filter (`rating`, `filename`, `keywords`, or date range). Without filters the plugin scans the full catalog via LR's internal SQL search engine; response includes a `warning` field in that case.

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
