# @mskalski/lightroom-mcp

MCP server bridging Claude / Codex / Cursor to Adobe Lightroom Classic via a bundled Lua plugin.

The preset round-trip tools can inspect and compare historical Develop presets, create versioned plugin-managed checkpoints from an edited representative photo, and export a preset backing file without overwriting an existing file. Plugin checkpoints are hidden from Lightroom's Develop panel by Adobe SDK design.

## Quick install

### Claude Desktop / Claude Code (one-click)

Grab the `.mcpb` from [GitHub Releases](https://github.com/Automaat/lightroom-mcp/releases/latest) and double-click. The Lightroom plugin auto-installs on first run.

### Codex CLI

```bash
codex mcp add lightroom -- npx -y @mskalski/lightroom-mcp
```

Then install the Lightroom plugin once:

```bash
npx -y @mskalski/lightroom-mcp install-plugin
```

### Cursor / Windsurf / VS Code

Add to MCP config:

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

## Commands

```
lightroom-mcp [stdio]            Run MCP over stdio (default)
lightroom-mcp install-plugin     Copy plugin into Lightroom Modules folder
```

## Docs and source

Full documentation, architecture notes, and the Lightroom plugin live at
<https://github.com/Automaat/lightroom-mcp>.

## License

MIT
