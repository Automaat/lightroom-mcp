# Lightroom MCP

MCP server bridging Claude to Adobe Lightroom Classic.

## Layout

- `server/` — TypeScript MCP server (ESM, NodeNext). Stdio transport for Claude + raw TCP client to plugin sockets.
- `plugin/LightroomMCP.lrplugin/` — Lua plugin loaded by Lightroom Classic.
- `PLAN.md` — original plan; stale, ignore.
- `manual-test.mjs` — direct TCP probe (bypasses MCP) for validating plugin dispatch.

## Architecture (read before changing transport)

Plugin opens **two LrSocket binds** as servers; MCP server connects to both.

- Plugin :58763 in `mode='receive'` — server writes line-delimited JSON requests
- Plugin :58764 in `mode='send'` — server reads line-delimited JSON responses
- Frame: `\n` terminator on every message (LrSocket buffers until newline)
- Plugin allows **one client per port at a time**. MCP server holds a persistent connection.
- `LrSocket.bind` in `mode='receive'` has a 10s no-client timeout that fires `onError`. Plugin auto-calls `:reconnect()` from a monitor loop in response. Reconnect storms are prevented by setting flags in callbacks and acting on them in the loop (never `:reconnect()` synchronously from `onError`).
- `onMessage` runs in non-yielding context — handler dispatch must be wrapped in `LrTasks.startAsyncTask` so `catalog:withReadAccessDo` can yield.

Pattern verified against MIDI2LR (`rsjaffe/MIDI2LR`, see `src/plugin/Client.lua`) — same dual-port LrSocket model, ports 58763/58764 also chosen there.

## Commands

Use mise tasks from repo root:

- `mise run install` — npm ci in `server/`
- `mise run build` — `tsc` (outputs `server/dist/`)
- `mise run test` — Jest (ESM via ts-jest)
- `mise run dev` — `tsc --watch`

Lua: `luacheck plugin --no-color --codes` (CI runs this; `.luacheckrc` declares LR SDK globals, excludes `JSON.lua`).

## CI

- `.github/workflows/ci.yml` — build+test on ubuntu/macos/windows, Node 22.
- `.github/workflows/lua-lint.yml` — luacheck on plugin changes.
- Type check uses `tsc --noEmit`; do not break it.

## Pre-commit checklist

Run before every commit (CI runs the same):

- `cd server && npx tsc --noEmit` — type check must pass
- `mise run build` — `tsc` compile must succeed
- `mise run test` — Jest suite must pass
- `luacheck plugin --no-color --codes` — only if Lua changed

## Plugin install (manual, no automation)

Copy `plugin/LightroomMCP.lrplugin/` to:
- macOS: `~/Library/Application Support/Adobe/Lightroom/Plugins/`

Click **Start Server** in Plug-in Manager. Logs at `~/Documents/LrClassicLogs/LightroomMCP.log`.

**Reload caveat**: Lightroom's "Reload Plug-in" does NOT kill the previous async task — its sockets stay bound and block new ones. Quit Lightroom (Cmd+Q) and reopen if you see "failed to open localhost:58763" after a reload.

## Conventions

- TS strict mode on. ESM imports must include `.js` extension (NodeNext).
- New Lua handlers: add file under `plugin/LightroomMCP.lrplugin/Handler*.lua`, register in `DISPATCH` table in `PluginInfoProvider.lua`, declare any new LR globals in `.luacheckrc`.
- New MCP tool: add schema in `server/src/index.ts` `ListToolsRequestSchema` handler **and** add a `DISPATCH` entry in `PluginInfoProvider.lua`.
- Ports `58763` (request) and `58764` (response) are hardcoded both sides — change in lockstep.
