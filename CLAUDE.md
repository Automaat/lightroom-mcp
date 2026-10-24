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
- Hosts spawn several bridges at once (Claude Desktop: chat + Cowork/Code shared pool, #238). `Bridge` (`server/src/bridge.ts`) elects one per port pair via the instance lock: the leader owns the plugin sockets and serves tool calls over local IPC (`broker.ts`: Unix socket in `~/.config/lightroom-mcp/`, named pipe on Windows, plugin token checked); followers forward, and re-elect when the leader exits. Never `process.exit` on lock contention.
- `LrSocket.bind` in `mode='receive'` has a 10s no-client timeout that fires `onError`. Plugin auto-calls `:reconnect()` from a monitor loop in response. Reconnect storms are prevented by setting flags in callbacks and acting on them in the loop (never `:reconnect()` synchronously from `onError`).
- `onMessage` runs in non-yielding context — handler dispatch must be wrapped in `LrTasks.startAsyncTask` so `catalog:withReadAccessDo` can yield.
- Catalog queries that yield (`getTargetPhotos`, `findPhotos`) must run **outside** `withReadAccessDo`. Nesting a yielding query inside the read gate deadlocks on Windows: the task yields to the UI thread holding the gate, never returns, never releases it, wedging the bridge until the server timeout (#124/#134). Only non-yielding per-photo metadata reads belong inside the gate. `getAllPhotos` is a non-yielding enumeration, safe either side. `PhotoLookup` resolves paths with `findPhotoByPath`, a catalog query, so handlers resolve photo ids before opening either gate. Specs guard this via `getQueriedInsideReadAccess()` in `spec_helper`.
- Every SDK getter call (`getRawMetadata`, `getFormattedMetadata`, `LrKeyword` getters) costs ~0.1-1 ms; per-call overhead dominates handler time on large catalogs. Read photo fields for a page with `catalog:batchGetRawMetadata` / `batchGetFormattedMetadata` (`PhotoSummary`), read keyword name and synonyms with one `getAttributes`, and avoid `LrTasks.pcall` per item (~1 ms each).
- `catalog:getPhotoByLocalId` returns a dangling photo object, not nil, for an unknown id; its metadata reads return nil. `PhotoLookup` keeps only photos whose batched `uuid` read is non-nil.

- `LrDevelopController` (denoise, masks) only acts on the photo active in Develop. Handlers that need it go through `DevelopSession.lua`: `withPhoto` opens one photo in Develop, runs a callback, then restores module, view source and selection; `run` is the lower-level form for multi-photo flows. One Develop-driving call runs at a time. Mask handlers live in `HandlerMasks.lua` (listing) and `HandlerMaskDelete.lua` (deleting; `delete_empty_masks` uses `catalog:deleteAllEmptyMasks`, LrC 14+, no Develop session); `requireMaskApi` gates them on LrC 11 (SDK 11.0). Local mask sliders (`local_*`) are read and written through `LrDevelopController.getValue`/`setValue` with the mask selected by id; `HandlerMaskAdjustments.lua` owns that flow and `LocalSliders.lua` is the slider table (SDK name, fallback range, read-back tolerance). Add a slider there and in `LOCAL_ADJUSTMENT_KEYS` (`tool-contracts.ts`); a Jest test checks the two lists match.
- Mask geometry (gradient position, later brush and range masks) has no SDK call, so it is written through the undocumented `MaskGroupBasedCorrections` develop setting, only via `GuardedMaskWrite.lua`: a version gate (LrC 15.6, ProcessVersion 15.4), a pinned per-`What` key schema checked on the new and every existing entry (`Mask/Image` is opaque), a whole-array write, a read-back compare within 1e-5 that ignores derived fields, and a rollback to the previous array on any mismatch. Never write that setting directly. Widening the tested versions or schema needs a live check on that version. Gradient handlers: `HandlerGradientMasks.lua`, pure geometry in `GradientGeometry.lua`. Brush handlers: `HandlerBrushMasks.lua`, pure stroke-to-dab encoding in `BrushStrokes.lua`; strokes are add-only because Lightroom coerces a written stroke's blend mode to add. Mask coordinates are stored in the unrotated frame of the photo, not as Lightroom displays it, so `ImageFrame.lua` converts displayed points from the photo's `orientation` (live check on 15.6); a brush `radius` is a fraction of the longer edge.

Pattern verified against MIDI2LR (`rsjaffe/MIDI2LR`, see `src/plugin/Client.lua`) — same dual-port LrSocket model, ports 58763/58764 also chosen there.

## Commands

Use mise tasks from repo root:

- `mise run install` — npm ci in `server/`
- `mise run build` — `tsc` (outputs `server/dist/`)
- `mise run test` — Jest (ESM via ts-jest)
- `mise run dev` — `tsc --watch`
- `mise run plugin:reload` — reload the installed plug-in in Lightroom Classic on macOS
- `mise run lua:lint` — `selene plugin/LightroomMCP.lrplugin`
- `mise run lua:test` — `busted` specs for the plugin
- `mise run skill:test` — Python unittest for bundled skill scripts

Lua tooling: `mise install` provisions `lua` + `luarocks` + `selene`. `lua:test` auto-installs `busted` into `lua_modules/` (gitignored) via the `lua:deps` task. `selene` is a mise tool (`aqua:Kampfkarren/selene`), a native binary that does not run on `lua` — so unlike luacheck it is immune to Lua-version breakage. `selene.toml` configures it; `lightroom.yml` is the custom std declaring LR SDK globals; `JSON.lua` is excluded.

## CI

- `.github/workflows/ci.yml` — build+test on ubuntu/macos/windows, Node 24.15.0.
- `.github/workflows/lua-lint.yml` — selene (via mise-action) on plugin changes.
- `.github/workflows/skill-test.yml` — Python unittest for bundled skill scripts, on `skills/` changes.
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
- `mise run skill:test` — only if `skills/` changed

## Plugin install (manual, no automation)

Copy `plugin/LightroomMCP.lrplugin/` to:
- macOS: `~/Library/Application Support/Adobe/Lightroom/Plugins/`
- Windows: `%APPDATA%\Adobe\Lightroom\Plugins\`

Bundle is pure Lua — same content ships in both `LightroomMCP-macos.lrplugin.zip` and `LightroomMCP-windows.lrplugin.zip` release artifacts. Split is for download UX, not platform code.

Click **Start Server** in Plug-in Manager. Logs at `~/Documents/LrClassicLogs/LightroomMCP.log`.

**Start-up**: Lightroom runs `LrInitPlugin` (auto-start) only when its window is first activated, not at launch: a background launch (`open -g`, automation that leaves another app in front) starts no server until Lightroom is brought to the front (`osascript -e 'tell application "Adobe Lightroom Classic" to activate'`). Verified on LrC 15.6 macOS.

**Reload behaviour**: "Reload Plug-in" loads a fresh Lua state but does **not** reliably cancel the old task's `LrFunctionContext` — the old monitor loop can keep running and hold a port (LrC 15.5.1 macOS). The new instance rewrites the token file; the old loop polls it (`isSuperseded`) and exits on a foreign token, releasing its ports via the context cleanup handler. The new instance's binds fail with `failed to open` until then and recover through the reconnect path.

"Reload Plug-in" does not see a `.lua` file added to the bundle after Lightroom started: `require` fails with `Could not load toolkit script` and the plug-in is disabled. Restart Lightroom after adding a file.

## Live manual testing on macOS

- Work from an isolated checkout. Back up the installed `LightroomMCP.lrplugin` bundle before copying a candidate into `~/Library/Application Support/Adobe/Lightroom/Plugins/`; restore the backup after testing.
- With Lightroom running, use `mise run plugin:reload` to select Lightroom MCP in Plug-in Manager and click **Reload Plug-in**. The task runs `tests/e2e/reload-plugin.applescript`; macOS must grant Accessibility access to the process running `osascript`.
- Check `lsof -nP -iTCP:58763-58764 -sTCP:LISTEN`, then call `node tests/e2e/mcp-runner.mjs tool list_collections '{"limit":1}'` from the tested checkout. A listening socket alone does not prove that requests work. Use the configured ports if they differ from the defaults.
- If reload does not answer the tool call, check Plug-in Manager. A stale `Running: true` state can remain after `Server task context cleanup`; click **Stop Server**, then **Start Server**, and retry the tool call. If the plug-in is disabled or reports a toolkit script error, close Plug-in Manager and any Save dialog, quit Lightroom normally, and reopen it. Check the sockets and tool call again. Do not force quit Lightroom or remove another process's socket.
- For collection changes, create a uniquely named temporary collection, add known photos, test member, nonmember, missing and duplicate IDs, then delete only that temporary collection. Confirm its photos remain in the catalog. Restore the original bundle and restart Lightroom when finished.
- For keyword changes, record the photo's keywords and `list_keywords` paths before testing. Use a unique temporary keyword on a known photo; verify its path and photo association after each rename, including a case-only rename. Remove the tag from the photo, then delete the empty temporary keyword in Lightroom's Keyword List and confirm the original catalog state. Restore the original bundle when finished.

## Conventions

- TS strict mode on. ESM imports must include `.js` extension (NodeNext).
- New Lua handlers: add file under `plugin/LightroomMCP.lrplugin/Handler*.lua`, register in `DISPATCH` table in `PluginInfoProvider.lua`, declare any new LR globals in `lightroom.yml`.
- New MCP tool: add contract in `server/src/tool-contracts.ts` **and** add a `DISPATCH` entry in `PluginInfoProvider.lua`.
- Default ports `58763` (request) / `58764` (response). Server overrides via env vars `LIGHTROOM_MCP_REQUEST_PORT` / `LIGHTROOM_MCP_RESPONSE_PORT` (parsed in `server/src/ports.ts`); plugin overrides via Plug-in Manager fields stored in `LrPrefs` (`requestPort` / `responsePort`). Both sides must agree — change in lockstep.
