# Lightroom Classic MCP Server

MCP (Model Context Protocol) server for Adobe Lightroom Classic. Talk to your photo catalog from Claude Desktop, Claude Code, Codex CLI, Cursor, Windsurf, and VS Code.

[![npm](https://img.shields.io/npm/v/@mskalski/lightroom-mcp.svg)](https://www.npmjs.com/package/@mskalski/lightroom-mcp)
[![release](https://img.shields.io/github/v/release/Automaat/lightroom-mcp.svg)](https://github.com/Automaat/lightroom-mcp/releases/latest)

## Requirements

- **Adobe Lightroom Classic** (any version with the LR SDK — LR 6 / CC 2015+ tested up to LR 14)
- macOS or Windows (Linux works for the server but Lightroom is Mac/Windows-only)

That's it for the install paths below — they bundle everything else.

## Install

Pick the path that matches your AI assistant. **All paths end with the same step**: open Lightroom → **File → Plug-in Manager → Lightroom MCP → Start Server**. The plugin auto-installs into Lightroom's Modules folder; just restart Lightroom once after install.

### Claude Desktop / Claude Code (1-click)

1. Download `lightroom-mcp-<version>.mcpb` from [the latest release](https://github.com/Automaat/lightroom-mcp/releases/latest).
2. Double-click the file. Claude installs it.
3. Restart Lightroom Classic. Click **Start Server** in Plug-in Manager.

No Node.js, no terminal, no JSON editing.

### Codex CLI

```bash
codex mcp add lightroom -- npx -y @mskalski/lightroom-mcp
```

The plugin auto-installs into Lightroom's Modules folder the first time Codex starts the server. Restart Lightroom and click **Start Server**.

### Cursor / Windsurf / VS Code (Continue, Cline, Roo, etc.)

Add to your client's MCP config:

```json
{
  "mcpServers": {
    "lightroom": {
      "command": "npx",
      "args": ["-y", "@mskalski/lightroom-mcp"]
    }
  }
}
```

The plugin auto-installs the first time the client starts the server. If the client never starts the server (some only spawn it on first tool call), pre-install with:

```bash
npx -y @mskalski/lightroom-mcp install-plugin
```

Restart Lightroom and click **Start Server**.

### Standalone binary (no Node required)

If Node isn't installed:

1. Download from [the latest release](https://github.com/Automaat/lightroom-mcp/releases/latest):
   - macOS Apple Silicon: `lightroom-mcp-darwin-arm64`
   - macOS Intel: `lightroom-mcp-darwin-x64`
   - Windows: `lightroom-mcp-windows-x64.exe`
2. Make it executable + bypass macOS Gatekeeper (binaries are not signed):
   ```bash
   chmod +x ~/Downloads/lightroom-mcp-darwin-arm64
   xattr -d com.apple.quarantine ~/Downloads/lightroom-mcp-darwin-arm64
   ```
3. Install the Lightroom plugin once:
   ```bash
   ~/Downloads/lightroom-mcp-darwin-arm64 install-plugin
   ```
4. Point your MCP client at the binary path:
   ```bash
   codex mcp add lightroom -- /full/path/to/lightroom-mcp-darwin-arm64
   ```
5. Restart Lightroom, click **Start Server**.

### Manual plugin install (any client)

If you'd rather skip the auto-installer, drop `LightroomMCP.lrplugin` (from the `LightroomMCP-macos.lrplugin.zip` / `LightroomMCP-windows.lrplugin.zip` release asset) into Lightroom's auto-load Modules folder:

- macOS: `~/Library/Application Support/Adobe/Lightroom/Modules/`
- Windows: `%APPDATA%\Adobe\Lightroom\Modules\`

Lightroom auto-loads it on next start. Then click **Start Server** in Plug-in Manager.

## Verify it works

After **Start Server**, ask your assistant something like:

> List all my Lightroom collections.

Should return a JSON dump of every collection in your active catalog. If it doesn't:

- Plug-in Manager → **Lightroom MCP** → **Show Status** — check both sockets show `connected: true`.
- See [Troubleshooting](#troubleshooting).

## Tools

| Tool | What it does |
| --- | --- |
| `search_photos` | Search by filename / keywords / rating / date range. |
| `get_selected_photos` | Photos selected in Lightroom (or filmstrip). |
| `get_photo_metadata` | EXIF + develop settings for one photo. |
| `list_collections` | All collections and collection sets. |
| `create_collection` | New collection (optional parent set). |
| `add_to_collection` | Add photos to a named collection. |
| `set_keywords` | Add or remove keywords on photos. |
| `set_rating` | Set 0-5 star rating on photos. |
| `import_photos` | Import a file or folder into the catalog. |
| `export_photos` | Export with format / quality / dimensions. |
| `list_develop_presets` | Discover available Develop presets. |
| `apply_develop_preset` | Apply a named preset to photos. |
| `copy_develop_settings` | Copy develop settings between photos. |
| `set_develop_settings` | Write SDK setting key/values directly. |

Full schemas and parameter docs: [`server/src/list-tools-handler.ts`](server/src/list-tools-handler.ts).

## How it works

```
┌─────────────┐    stdio    ┌──────────────────┐  TCP :58763 →   ┌──────────────────┐
│  AI client  │ ◄─────────► │   MCP server     │ ──────────────► │ Lightroom plugin │
│ (Claude/    │             │  (Node TCP)      │ ←────────────── │   (LrSocket)     │
│  Codex/...) │             └──────────────────┘   ← TCP :58764  └──────────────────┘
└─────────────┘                                                           │
                                                                          ▼
                                                                catalog:withReadAccessDo
```

Plugin binds two `LrSocket` servers on localhost (`58763` request, `58764` response). Server connects as TCP client. Frame: line-delimited JSON, `\n` terminator. Auto-reconnect on both sides. Same dual-port pattern as MIDI2LR.

## CLI reference

```
lightroom-mcp [stdio]            Run MCP over stdio (default)
lightroom-mcp install-plugin     Copy bundled plugin into Lightroom Modules folder
lightroom-mcp --help | --version
```

Env vars:

| Var | Default | Purpose |
| --- | --- | --- |
| `LIGHTROOM_MCP_REQUEST_PORT` | `58763` | Plugin request port. |
| `LIGHTROOM_MCP_RESPONSE_PORT` | `58764` | Plugin response port. |
| `LIGHTROOM_MCP_TOKEN_PATH` | `~/.config/lightroom-mcp/token` | Auth token file. |

If you change ports on the server side, change them in **Plug-in Manager → Lightroom MCP** to match.

## Security

The plugin generates a 256-bit token in `~/.config/lightroom-mcp/token` on **Start Server**. The MCP server attaches it to every request. Localhost-only — no remote attack surface.

## Develop

```bash
mise install                        # tools (node, bun)
mise run install                    # npm ci
mise run build                      # tsc
mise run test                       # jest
mise run mcpb                       # build .mcpb bundle
mise run binary                     # build single-file binaries via Bun
luacheck plugin --no-color --codes  # lint Lua plugin
```

Repo layout:

- `server/` — TypeScript MCP server (ESM, NodeNext).
- `plugin/LightroomMCP.lrplugin/` — Lua plugin loaded by Lightroom Classic.
- `mcpb/manifest.json` — `.mcpb` bundle manifest.
- `scripts/build-mcpb.mjs` — pack the .mcpb.
- `scripts/build-binary.mjs` — Bun `--compile` per-target binaries.
- `manual-test.mjs` — direct TCP probe (bypasses MCP).

## Adding a new tool

1. Add a new `Handler*.lua` under `plugin/LightroomMCP.lrplugin/`.
2. Register it in the `DISPATCH` table in `PluginInfoProvider.lua`.
3. Add a schema entry in `server/src/list-tools-handler.ts`.
4. Declare any new LR globals in `.luacheckrc`.

## Troubleshooting

- **`failed to open localhost:58763` after Reload Plug-in** — old async task still owns the port. Quit Lightroom (Cmd+Q on macOS / Alt+F4 on Windows) and reopen.
- **Plugin not connected** — click **Start Server** in Plug-in Manager; the server reconnects within ~1s.
- **Timeout errors** — handler may be scanning a large catalog without filters; add `rating`, `filename`, `keywords`, or date filters to narrow.
- **macOS "cannot be opened because the developer cannot be verified"** (binary path) — `xattr -d com.apple.quarantine /path/to/binary`. Or right-click → Open the first time.
- **Windows SmartScreen blocks the .exe** — More info → Run anyway.

Logs:

| Component | macOS | Windows |
| --- | --- | --- |
| Plugin | `~/Documents/LrClassicLogs/LightroomMCP.log` | `%USERPROFILE%\Documents\LrClassicLogs\LightroomMCP.log` |
| Claude Desktop | `~/Library/Logs/Claude/mcp*.log` | `%APPDATA%\Claude\Logs\mcp*.log` |

## License

MIT
