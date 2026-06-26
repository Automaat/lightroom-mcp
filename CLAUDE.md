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
- Catalog queries that yield (`getTargetPhotos`, `findPhotos`) must run **outside** `withReadAccessDo`. Nesting a yielding query inside the read gate deadlocks on Windows: the task yields to the UI thread holding the gate, never returns, never releases it, wedging the bridge until the server timeout (#124/#134). Only non-yielding per-photo metadata reads belong inside the gate. `getAllPhotos` is a non-yielding enumeration, safe either side. Specs guard this via `getQueriedInsideReadAccess()` in `spec_helper`.

Pattern verified against MIDI2LR (`rsjaffe/MIDI2LR`, see `src/plugin/Client.lua`) — same dual-port LrSocket model, ports 58763/58764 also chosen there.

## Commands

Use mise tasks from repo root:

- `mise run install` — npm ci in `server/`
- `mise run build` — `tsc` (outputs `server/dist/`)
- `mise run test` — Jest (ESM via ts-jest)
- `mise run dev` — `tsc --watch`
- `mise run lua:lint` — `selene plugin/LightroomMCP.lrplugin`
- `mise run lua:test` — `busted` specs for the plugin

Lua tooling: `mise install` provisions `lua` + `luarocks` + `selene`. `lua:test` auto-installs `busted` into `lua_modules/` (gitignored) via the `lua:deps` task. `selene` is a mise tool (`aqua:Kampfkarren/selene`), a native binary that does not run on `lua` — so unlike luacheck it is immune to Lua-version breakage. `selene.toml` configures it; `lightroom.yml` is the custom std declaring LR SDK globals; `JSON.lua` is excluded.

## CI

- `.github/workflows/ci.yml` — build+test on ubuntu/macos/windows, Node 22.
- `.github/workflows/lua-lint.yml` — selene (via mise-action) on plugin changes.
- Type check runs `npm run check` (`tsc --noEmit` on src + `tsconfig.test.json` on tests); do not break it.
- Lint runs `npm run lint` (ESLint flat config, type-aware rules over src + tests); do not break it.

## Pre-commit checklist

Run before every commit (CI runs the same):

- `cd server && npm run check` — type check (src + tests) must pass
- `cd server && npm run lint` — ESLint must pass
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
- New Lua handlers: add file under `plugin/LightroomMCP.lrplugin/Handler*.lua`, register in `DISPATCH` table in `PluginInfoProvider.lua`, declare any new LR globals in `lightroom.yml`.
- New MCP tool: add contract in `server/src/tool-contracts.ts` **and** add a `DISPATCH` entry in `PluginInfoProvider.lua`.
- Default ports `58763` (request) / `58764` (response). Server overrides via env vars `LIGHTROOM_MCP_REQUEST_PORT` / `LIGHTROOM_MCP_RESPONSE_PORT` (parsed in `server/src/ports.ts`); plugin overrides via Plug-in Manager fields stored in `LrPrefs` (`requestPort` / `responsePort`). Both sides must agree — change in lockstep.
