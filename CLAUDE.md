# Lightroom MCP

MCP server bridging Claude to Adobe Lightroom Classic.

## Layout

- `server/` — TypeScript MCP server (ESM, NodeNext). Stdio transport for Claude + raw TCP client to plugin sockets.
- `plugin/LightroomMCP.lrplugin/` — Lua plugin loaded by Lightroom Classic.
- `manual-test.mjs` — direct TCP probe (bypasses MCP) for validating plugin dispatch.

## Architecture (read before changing transport)

Plugin opens **two LrSocket binds** as servers; MCP server connects to both.

- Plugin :58763 (default) in `mode='receive'` — server writes line-delimited JSON requests
- Plugin :58764 (default) in `mode='send'` — server reads line-delimited JSON responses
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
- `mise run lua:lint` — `luacheck plugin --no-color --codes`
- `mise run lua:test` — `busted` specs for the plugin

Lua tooling: `mise install` provisions `lua` + `luarocks`; `lua:lint`/`lua:test` auto-install `luacheck`/`busted` into `lua_modules/` (gitignored) via the `lua:deps` task. `.luacheckrc` declares LR SDK globals, excludes `JSON.lua`.

## CI

- `.github/workflows/ci.yml` — build+test on ubuntu/macos/windows, Node 22.
- `.github/workflows/lua-lint.yml` — luacheck on plugin changes.
- Type check runs `npm run check` (`tsc --noEmit` on src + `tsconfig.test.json` on tests); do not break it.

## Pre-commit checklist

Run before every commit (CI runs the same):

- `cd server && npm run check` — type check (src + tests) must pass
- `mise run build` — `tsc` compile must succeed
- `mise run test` — Jest suite must pass
- `mise run lua:lint` — only if Lua changed
- `mise run lua:test` — only if Lua changed

## Plugin install (manual, no automation)

Copy `plugin/LightroomMCP.lrplugin/` to:
- macOS: `~/Library/Application Support/Adobe/Lightroom/Plugins/`
- Windows: `%APPDATA%\Adobe\Lightroom\Plugins\`

Bundle is pure Lua — same content ships in both `LightroomMCP-macos.lrplugin.zip` and `LightroomMCP-windows.lrplugin.zip` release artifacts. Split is for download UX, not platform code.

Click **Start Server** in Plug-in Manager. Logs at `~/Documents/LrClassicLogs/LightroomMCP.log`.

**Reload behaviour**: "Reload Plug-in" cancels the old task's `LrFunctionContext` (freeing its LrSocket ports) and starts fresh. PluginInit sleeps 0.5 s before binding so the context cancel can flush. Server is ready in ~1 s.

## Conventions

- TS strict mode on. ESM imports must include `.js` extension (NodeNext).
- New Lua handlers: add file under `plugin/LightroomMCP.lrplugin/Handler*.lua`, register in `DISPATCH` table in `PluginInfoProvider.lua`, declare any new LR globals in `.luacheckrc`.
- New MCP tool: add contract in `server/src/tool-contracts.ts` **and** add a `DISPATCH` entry in `PluginInfoProvider.lua`.
- Default ports `58763` (request) / `58764` (response). Server overrides via env vars `LIGHTROOM_MCP_REQUEST_PORT` / `LIGHTROOM_MCP_RESPONSE_PORT` (parsed in `server/src/ports.ts`); plugin overrides via Plug-in Manager fields stored in `LrPrefs` (`requestPort` / `responsePort`). Both sides must agree — change in lockstep.
