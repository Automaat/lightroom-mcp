# Lightroom Classic MCP Server

Lets Claude (and other AI assistants) talk to your **Adobe Lightroom Classic** photo catalog. Search photos, set ratings, edit develop settings, manage collections, import/export — all by chatting.

[![npm](https://img.shields.io/npm/v/@mskalski/lightroom-mcp.svg)](https://www.npmjs.com/package/@mskalski/lightroom-mcp)
[![release](https://img.shields.io/github/v/release/Automaat/lightroom-mcp.svg)](https://github.com/Automaat/lightroom-mcp/releases/latest)

> **Works with:** Claude Desktop, Claude Code, Codex CLI, Cursor, Windsurf, VS Code.
> **Needs:** Lightroom Classic on macOS or Windows. Nothing else — no programming required.

---

## Install (Claude Desktop — easiest, 3 steps)

This is the recommended path. Takes ~2 minutes, no terminal needed.

### 1. Download the installer

Go to the [latest release page](https://github.com/Automaat/lightroom-mcp/releases/latest) and download the file ending in **`.mcpb`** (it's near the top, called `lightroom-mcp-<version>.mcpb`).

### 2. Double-click the downloaded file

Claude Desktop opens automatically and asks: *"Install Lightroom Classic extension?"*. Click **Install**.

> Don't have Claude Desktop yet? Get it free from [claude.com/download](https://claude.com/download). It runs on Mac and Windows.

### 3. Turn on the plugin in Lightroom

1. **Quit and reopen Lightroom Classic.** (The plugin needs a restart to show up.)
2. In Lightroom, click **File** in the menu bar → **Plug-in Manager**.
3. In the left list, click **Lightroom MCP**.
4. On the right, click the **Start Server** button.
5. You should see "Server running" appear. Done!

### Try it

Open Claude Desktop and type:

> *List all my Lightroom collections.*

Claude will list every collection in your catalog.

Some other things to try:
- *"Find all my 5-star photos from last summer."*
- *"Add the keyword 'portfolio' to the photos I have selected in Lightroom."*
- *"Apply the 'Vivid' develop preset to these photos."*
- *"Export the selected photos to my Desktop as JPEGs at 2000px wide."*

---

## Install (other AI tools)

Already using Claude Code, Codex, Cursor, Windsurf, or VS Code? Pick your tool below. **All paths still end with the Lightroom step from the section above** — restart Lightroom and click **Start Server** in Plug-in Manager.

<details>
<summary><b>Claude Code</b></summary>

Same `.mcpb` file as Claude Desktop above — Claude Code accepts it too. Or install via the CLI:

```bash
claude mcp add lightroom -- npx -y @mskalski/lightroom-mcp
```

</details>

<details>
<summary><b>Codex CLI</b></summary>

```bash
codex mcp add lightroom -- npx -y @mskalski/lightroom-mcp
```

The Lightroom plugin installs itself the first time Codex talks to the server.

</details>

<details>
<summary><b>Cursor / Windsurf / VS Code (Continue, Cline, Roo, ...)</b></summary>

Open your client's MCP settings and add:

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

The plugin installs itself the first time your client starts the server. If your client only starts the server on first tool call, you can install the plugin upfront:

```bash
npx -y @mskalski/lightroom-mcp install-plugin
```

</details>

<details>
<summary><b>No Node.js installed? Use the standalone binary</b></summary>

1. Download the right file from the [latest release](https://github.com/Automaat/lightroom-mcp/releases/latest):
   - **Mac (Apple Silicon, M1/M2/M3/M4):** `lightroom-mcp-darwin-arm64`
   - **Mac (Intel):** `lightroom-mcp-darwin-x64`
   - **Windows:** `lightroom-mcp-windows-x64.exe`

2. **macOS only** — make it runnable and bypass Gatekeeper (the binary isn't signed):
   ```bash
   chmod +x ~/Downloads/lightroom-mcp-darwin-arm64
   xattr -d com.apple.quarantine ~/Downloads/lightroom-mcp-darwin-arm64
   ```

3. Install the Lightroom plugin:
   ```bash
   ~/Downloads/lightroom-mcp-darwin-arm64 install-plugin
   ```

4. Point your AI tool at the binary's full path. Example for Codex:
   ```bash
   codex mcp add lightroom -- /Users/you/Downloads/lightroom-mcp-darwin-arm64
   ```

</details>

<details>
<summary><b>Install the Lightroom plugin manually (any client)</b></summary>

If you'd rather drop the plugin in by hand:

1. Download the matching zip from the [latest release](https://github.com/Automaat/lightroom-mcp/releases/latest):
   - Mac: `LightroomMCP-macos.lrplugin.zip`
   - Windows: `LightroomMCP-windows.lrplugin.zip`
2. Unzip it. You get a folder called `LightroomMCP.lrplugin`.
3. Move that folder into Lightroom's Modules folder:
   - **Mac:** `~/Library/Application Support/Adobe/Lightroom/Modules/`
   - **Windows:** `%APPDATA%\Adobe\Lightroom\Modules\`
   - (If the `Modules` folder doesn't exist, create it.)
4. Restart Lightroom → **Plug-in Manager** → **Start Server**.

</details>

---

## Something not working?

1. Open Lightroom → **File → Plug-in Manager → Lightroom MCP → Show Status**. Both sockets should say `connected: true`. If not, click **Start Server**.
2. Make sure you **fully quit and reopened Lightroom** after install (Cmd+Q on Mac, Alt+F4 on Windows). "Reload Plug-in" alone is not enough.
3. See [Troubleshooting](#troubleshooting) below for specific errors.

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
3. Add a contract entry in `server/src/tool-contracts.ts`.
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
