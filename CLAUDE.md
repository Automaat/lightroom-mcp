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

- `LrDevelopController` (denoise, masks) only acts on the photo active in Develop. Handlers that need it go through `DevelopSession.lua`: `withPhoto` opens one photo in Develop, runs a callback, then restores module, view source and selection; `run` is the lower-level form for multi-photo flows. One Develop-driving call runs at a time. Mask handlers live in `HandlerMasks.lua` (listing) and `HandlerMaskDelete.lua` (deleting; `delete_masks` with only `photo_ids` uses `catalog:deleteAllEmptyMasks`, LrC 14+, no Develop session); `requireMaskApi` gates them on LrC 11 (SDK 11.0). Local mask sliders (`local_*`) are read and written through `LrDevelopController.getValue`/`setValue` with the mask selected by id; `HandlerMaskAdjustments.lua` owns that flow and `LocalSliders.lua` is the slider table (SDK name, fallback range, read-back tolerance). Add a slider there and in `LOCAL_ADJUSTMENT_KEYS` (`tool-contracts.ts`); a Jest test checks the two lists match. Local tone curves (`local_Maincurve`, `local_Redcurve`, `local_Greencurve`, `local_Bluecurve`, flat 0-255 point arrays, `HandlerMaskCurves.lua`, `MaskCurves.lua`) and local Point Color (`local_PointColors` with the `*PointColorSwatch` calls and `isForMasking = true`, `HandlerMaskPointColors.lua`, `MaskPointColors.lua`) use only documented SDK calls, never `MaskGroupBasedCorrections`; `MaskSelection.lua` is the shared select-mask-by-id wrapper for them. Curve channels are listed in `MASK_CURVE_CHANNELS` (`tool-contracts.ts`), checked against `MaskCurves.lua` by a Jest test. `MaskTypes.lua` is the shared table of AI mask types (`subject`, `sky`, `background` mapped to `createNewMask` tool type and subtype) used by `create_mask` and `combine_mask`; add a type there and to `MASK_TYPES` in `tool-contracts.ts`, and a Jest test checks the lists match. `HandlerMaskCombine.lua` (`combine_mask`) selects the mask by id, verifies `getSelectedMask`, calls `addToCurrentMask`/`subtractFromCurrentMask`/`intersectWithCurrentMask` (the only way to get an intersect; Lightroom stores it as a subtracted, inverted component and settings coerce blend mode 2 to 0) and finds the new component id by diffing the mask's tools in `getAllMasks`.
- Mask geometry (gradient position, later brush and range masks) has no SDK call, so it is written through the undocumented `MaskGroupBasedCorrections` develop setting, only via `GuardedMaskWrite.lua`: a version gate (LrC 15.6, ProcessVersion 15.4), a pinned per-`What` key schema checked on the new and every existing entry (`Mask/Image` is opaque), a whole-array write, a read-back compare within 1e-5 that ignores derived fields, and a rollback to the previous array on any mismatch. Never write that setting directly. Widening the tested versions or schema needs a live check on that version. Gradient handlers: `HandlerGradientMasks.lua`, pure geometry in `GradientGeometry.lua`. Range masks (luminance, color, depth): `HandlerRangeMasks.lua`, pure parsing and format in `RangeMaskGeometry.lua`. A depth range is stored as `Type -1` with a four-number `DepthRange` trapezoid (0 near, 1 far) and is refused when the read-back has no `LuminanceDepthSampleInfo`, which marks a photo without device depth; Lightroom replaces any band narrower than 0.01 with its default. A color range holds exactly one `PointModels` entry: two crash Lightroom and crash-loop the catalog on reopen. Its triple is `l a b` in Lightroom's own per-photo ranking of the sampled color (lightness, green to red, blue to yellow, 0 to 1), not sRGB: the same color stores different triples in different photos (black stores `0 0.4122 0.4824` in one chart and `0 0.4872 0.5202` in another), develop edits leave it unchanged, Lightroom averages a small neighborhood when it samples, and selection follows the triple, not the x, y pin. Lua cannot compute it from RGB, so `create_range_mask` takes l, a and b verbatim and `list_masks` reads Lightroom-authored ones back (`RangeMaskGeometry.rangeOf`); `copy_sample_from` {mask_id, tool_id, optional photo_id} reuses such a range's triple, pin (mapped between the two photos' frames) and amount without knowing l, a, b, refuses any source that is not a color range with exactly one `PointModels` entry, and still writes a single entry; the busted specs hold Lightroom-authored samples as ground truth. Brush handlers: `HandlerBrushMasks.lua`, pure stroke-to-dab encoding in `BrushStrokes.lua`; a stroke's `Mask/Paint` carries `Radius`, `Flow`, `CenterWeight` (hardness) and `MaskValue` (density; 0 is an erase stroke, `MaskBlendMode` stays 0). Lightroom's Size slider is a screen size (stored `Radius` times the displayed long edge is constant, so it changes with the Develop zoom), so only `radius` is exposed. Lowering Feather shrinks the stored `Radius` and raises `CenterWeight` by a fixed curve independent of size and photo (`BrushFeather.lua`, interpolated from Lightroom-authored samples); a leading `h` dab token echoes `CenterWeight` like the `f` token echoes `Flow`, and the field alone is enough. Mask coordinates are stored in the unrotated frame of the photo, not as Lightroom displays it, so `ImageFrame.lua` converts displayed points from the photo's `orientation` (live check on 15.6); gradients also swap width and height and flip the rotation sign when the frame swaps or mirrors the axes; a brush `radius` is a fraction of the longer edge.
- People and Landscape masks by part (`HandlerAiMasks.lua`, part tables in `AiMaskParts.lua`) also go through `GuardedMaskWrite.lua`: the SDK's `createNewMask('aiSelection', 'people'|'landscape')` makes no mask because Lightroom waits for a menu pick. Each part is a `Mask/Image` correction with `MaskSubType` 3 (all people) or 0 (landscape) and `MaskSubCategoryID` as the part (2 face skin ... 12 teeth, 13 entire person) or 50001-50008 (landscape), written without digests. Lightroom ignores `InstanceIDs` in a written mask and always masks the first person (live check on 15.6), so a single person cannot be chosen. `photo:updateAISettings()` in a second write gate computes them. A part Lightroom cannot find reads back `ErrorReason` non-zero and the new entries are removed; never write to the photo while the digests are still pending (a write during a Landscape compute froze Lightroom for a third-party client).
- `create_mask_batch` (`HandlerMaskBatch.lua`) opens only the first photo in Develop (`create_mask` logic), then adds that mask's correction to every other photo through `GuardedMaskWrite.apply` with ids and `AIMaskData` computed digests stripped, and calls `updateAISettings` per target in its own write transaction. A mask that keeps its digests is never recomputed, so a target must never receive the source's digests. A nothing-found target is detected by the missing `MaskDigest` after the recompute and rolled back. Nothing-found on a photo opened in Develop raises a modal alert that blocks all Develop reads, so the batch stops there.

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
- `mise run live:test` — node:test unit tests for the live-test kit (`tests/e2e/live/unit/`)

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

`tests/e2e/live/` is the kit for live runs (README there: fixtures, tool-by-fixture verification matrix, traps). It never touches the real catalog: `openLiveSession()`, the snapshot and DB helpers and `smoke.mjs` call `requireThrowawayCatalog()`, which refuses unless the open catalog has the `lrmcp-live-catalog.json` marker written by the setup script.

- Bootstrap: `mise run build`, `mise run live:fixtures` (generates synthetic images, downloads the CC0 ARW samples into gitignored `tests/e2e/live/.fixtures/`), `node tests/e2e/live/install-bundle.mjs install`, `mise run live:setup` (File > New Catalog in a new empty folder through AX, imports the fixtures, records photo ids by fixture name in the marker), `node tests/e2e/live/smoke.mjs`. For the 200-photo batch budget: `make-batch.mjs`, then `import-batch.mjs`.
- Helpers in `tests/e2e/live/lib/`: `ax` (front-process assert and re-activate, dismiss "No X detected" and "Enable address lookup?", close Plug-in Manager), `preview` (settle protocol, region/patch deltas, IoU against an analytic shape), `catalog-db` (stored develop row and masks, flushed by switching photos), `snapshot` (copy `.lrcat` + `-wal`/`-shm` to `~/.cache/lightroom-mcp-live-snapshots/`), `plugin-bundle` (install/restore with backup outside TMPDIR, `diff -rq`), `mcp` (session against the built server).
- The throwaway catalog is rebuilt with `live:setup`, never committed. Never commit a `.lrcat`, a photo of unknown license or a depth HEIC. Depth range needs a user-supplied iPhone Portrait HEIC (`LRMCP_LIVE_DEPTH_HEIC`); depth checks skip without it.
- `mise run live:test` runs the kit's unit tests (no Lightroom); CI runs them too.
- Work from an isolated checkout. Back up the installed `LightroomMCP.lrplugin` bundle outside `$TMPDIR` before copying a candidate into `~/Library/Application Support/Adobe/Lightroom/Plugins/` (`install-bundle.mjs` does it); restore the backup after testing.
- With Lightroom running, use `mise run plugin:reload` to select Lightroom MCP in Plug-in Manager and click **Reload Plug-in**. The task runs `tests/e2e/reload-plugin.applescript`; macOS must grant Accessibility access to the process running `osascript`.
- Check `lsof -nP -iTCP:58763-58764 -sTCP:LISTEN`, then call `node tests/e2e/mcp-runner.mjs tool list_collections '{"limit":1}'` from the tested checkout. A listening socket alone does not prove that requests work. Use the configured ports if they differ from the defaults.
- If reload does not answer the tool call, check Plug-in Manager. A stale `Running: true` state can remain after `Server task context cleanup`; click **Stop Server**, then **Start Server**, and retry the tool call. If the plug-in is disabled or reports a toolkit script error, close Plug-in Manager and any Save dialog, quit Lightroom normally, and reopen it. Check the sockets and tool call again. Do not force quit Lightroom or remove another process's socket.
- For collection changes, create a uniquely named temporary collection, add known photos, test member, nonmember, missing and duplicate IDs, then delete only that temporary collection. Confirm its photos remain in the catalog. Restore the original bundle and restart Lightroom when finished.
- For keyword changes, record the photo's keywords and `list_keywords` paths before testing. Use a unique temporary keyword on a known photo; verify its path and photo association after each rename, including a case-only rename. Remove the tag from the photo, then delete the empty temporary keyword in Lightroom's Keyword List and confirm the original catalog state. Restore the original bundle when finished.
- For mask changes (LrC 15.6), dismiss blocking modals via Accessibility before reading or creating anything: an "Enable address lookup?" modal after launching into a catalog makes menu-driven mask creation silently do nothing, and a "No subject/sky/people detected" modal blocks all Develop reads.
- `get_photo_preview` is stale right after a photo enters Develop. For preview-diff checks, set the value, wait about 3.5 s, and fetch the preview twice before and twice after.
- The develop-settings sqlite row lags until you switch photos. Flush by opening another photo, then read twice.
- Depth range masks need a photo with real device depth (iPhone Portrait HEIC); synthetic disparity files are ignored.

## Conventions

- TS strict mode on. ESM imports must include `.js` extension (NodeNext).
- New Lua handlers: add file under `plugin/LightroomMCP.lrplugin/Handler*.lua`, register in `DISPATCH` table in `PluginInfoProvider.lua`, declare any new LR globals in `lightroom.yml`.
- New MCP tool: add contract in `server/src/tool-contracts.ts` **and** add a `DISPATCH` entry in `PluginInfoProvider.lua`.
- Default ports `58763` (request) / `58764` (response). Server overrides via env vars `LIGHTROOM_MCP_REQUEST_PORT` / `LIGHTROOM_MCP_RESPONSE_PORT` (parsed in `server/src/ports.ts`); plugin overrides via Plug-in Manager fields stored in `LrPrefs` (`requestPort` / `responsePort`). Both sides must agree — change in lockstep.
