# Lightroom MCP

MCP server bridging Claude to Adobe Lightroom Classic.

## Layout

- `server/` — TypeScript MCP server (ESM, NodeNext). Stdio transport for Claude + Express HTTP on `:8765` for plugin.
- `plugin/LightroomMCP.lrplugin/` — Lua plugin loaded by Lightroom Classic.
- `PLAN.md` — original plan; stale on details, keep README as truth.
- `manual-test.mjs`, `test-*.mjs` — ad-hoc integration scripts hitting `:8765`.

## Architecture quirk (read before changing transport)

LrSocket **cannot bind a server socket** — outbound only. So the plugin **polls** the MCP server, not the other way around.

- MCP server queues requests in-memory, plugin GETs `/poll-request` every 3s, POSTs results to `/submit-response`.
- Tool calls block up to 30s waiting for matching response id (`server/src/index.ts`).
- Do not propose "plugin exposes HTTP server" designs — they will not work on LrSocket.
- `HttpServer.lua` exists but is dead code from an earlier attempt; live polling lives in `PluginInfoProvider.lua`.

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

Click **Start Polling** in Plug-in Manager. Logs at `~/Documents/LrClassicLogs/LightroomMCP.log`.

## Conventions

- TS strict mode on. ESM imports must include `.js` extension (NodeNext).
- New Lua handlers: add file under `plugin/LightroomMCP.lrplugin/Handler*.lua`, route in dispatcher, declare any new LR globals in `.luacheckrc`.
- New MCP tool: add schema in `server/src/index.ts` `ListToolsRequestSchema` handler **and** corresponding action handling in plugin polling loop.
- Port `8765` is hardcoded both sides — change in lockstep.

## Status

Plugin currently returns mock data for most actions. Real catalog ops (`LrApplication.activeCatalog()` + `withReadAccessDo`/`withWriteAccessDo`) are the active work.
