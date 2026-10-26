# Live-test kit

Reproducible fixtures and helpers for live testing the plugin against a real Lightroom Classic (macOS only, LrC 15.6). The mask tools need a live Lightroom, so CI cannot cover them. This kit makes a live run repeatable: the same images, the same throwaway catalog setup, the same pixel checks.

Everything that needs no Lightroom (PNG/EXIF encoders, orientation maths, manifest verification, catalog guard, preview maths) has unit tests in `unit/`. CI runs them (`mise run live:test`).

## Safety rules

- Live tests run only in a throwaway catalog. `lib/catalog-guard.mjs` finds the open catalog from Lightroom's open files (`lsof`) and refuses unless its folder holds `lrmcp-live-catalog.json` (written by `setup-catalog.mjs`) or `LRMCP_LIVE_THROWAWAY_CATALOG` names it. The real catalog (`~/Pictures/Lightroom`) is always refused, marker or not.
- `setup-catalog.mjs` clicks File > New Catalog while the real catalog is open, and does nothing else to it. It writes no marker and imports nothing until the new catalog is open and verified.
- The throwaway catalog is rebuilt, never committed. Never commit a `.lrcat`, a photo of unknown license, or a depth HEIC.
- Check the frontmost process before every click or keystroke. `ensureLightroomFrontmost()` activates Lightroom and throws if it still is not in front. Edge, Discord, ghostty and sail steal focus.
- Drive dialogs with Accessibility (AX) only. Do not send keystrokes into a window you have not confirmed. Do not force quit Lightroom or remove another process's socket.
- Back up the installed bundle outside `$TMPDIR` (macOS wipes it), restore it afterwards, verify with `diff -rq`.
- End the session on the real catalog in the Library module, ports 58763/58764 listening, Plug-in Manager closed, and `node tests/e2e/mcp-runner.mjs tool list_collections '{"limit":1}'` answering.

## Bootstrap

```sh
mise run build
mise run live:fixtures
node tests/e2e/live/install-bundle.mjs install
mise run live:setup
node tests/e2e/live/smoke.mjs
```

- `live:fixtures` generates the synthetic images, downloads the CC0 raw samples, verifies hashes and verifies the generated files. Output goes to `tests/e2e/live/.fixtures/` (gitignored). Set `LRMCP_LIVE_FIXTURES_DIR` to share one folder between worktrees.
- `install-bundle.mjs install [candidate-dir]` backs up the installed bundle to `~/.cache/lightroom-mcp-live-backups/<stamp>/`, installs the candidate (default: this checkout's plugin), and verifies with `diff -rq`. It lists added Lua files: Reload Plug-in does not see them, so quit and reopen Lightroom. The File > New Catalog relaunch in the next step also loads the new files.
- `live:setup` (`setup-catalog.mjs`) needs Lightroom running and the Accessibility permission for the process running `osascript`. It creates `~/Documents/lrmcp-live-<stamp>/` through File > New Catalog, waits for the relaunch, dismisses the blocking modals, waits for the plug-in, copies the fixtures into `<catalog folder>/images/`, imports each through `import_photos`, and writes photo ids by fixture name into `<catalog folder>/lrmcp-live-catalog.json`. Options: `--name`, `--parent-dir` (must be the folder the dialog proposes, normally Documents).
- `smoke.mjs` proves the kit works: EXIF orientation of all 8 previews, `list_masks`, a linear gradient on `orient_6` (preview diff by region), a radial gradient on `wide_plain` (IoU against the analytic ellipse), and the stored develop row. It removes its masks.
- `open-recent-catalog.mjs "Lightroom Catalog.lrcat"` returns to a catalog through File > Open Recent and clicks Relaunch. Then restore the bundle with `install-bundle.mjs restore`, closing Lightroom first if Lua files were added.

Manual fallback: if the New Catalog dialog proposes another folder or AX fails, create an empty catalog by hand (File > New Catalog in an empty folder), leave it open, and run `node tests/e2e/live/setup-catalog.mjs --adopt-open-catalog`. It refuses the real catalog and any catalog that already holds photos.

## Fixtures

Generated (`generate-fixtures.mjs`, deterministic; PNG is pure JS, JPEG goes through `sips` and gets its EXIF orientation injected in JS):

| Key | File | Purpose |
|---|---|---|
| `chart80` | 1000x800 PNG | 80 patches in a 10x8 grid, 100 px each: 72 HSV patches (12 hues x 6 saturation/value variants) then 8 grays. Known sRGB per patch (`chart80Patches()`). Color range, point colors, HSL. |
| `ramp256` | 1024x1024 PNG | 16x16 patches of 64 px, patch `i` is gray level `i`. Luminance range, curves, tone checks per patch. |
| `wide_plain` | 1000x600 JPEG | Flat gray 110 with 2 levels of noise. Any mask shape appears as a clean brightening, so IoU against an analytic shape works. |
| `pano` | 2400x240 JPEG | 10:1. Hue sweep over the top 80 percent, gray ramp in the bottom 20 percent. Aspect-ratio checks for radial width/height fractions. |
| `orient_1`..`orient_8` | 1000x600 JPEG | One asymmetric pattern (red, green, blue, yellow corner squares and a white F) stored once, EXIF orientation tag 1..8. A turned or mirrored result is detectable: `expectedDisplayedCorners(n)`, `classifyOrientation(sampleCorners(pixels))`. Orientations 5..8 display 600x1000. |
| `batch/batch_001..200.jpg` | 1200x800 JPEG | `make-batch.mjs [count]`: distinct crops of the 14-bit CC0 raw, with sky. `import-batch.mjs` imports them into the open throwaway catalog and stores their ids under `batch.ids` in the marker file (about 4 minutes for 200). For `create_mask_batch` and `delete_empty_masks`. |

Downloaded (`manifest.json`, `fetch-samples.mjs [--verify]`): both from raw.pixls.us, CC0 (the site lists them as Creative Commons 0 with the checksums used here). The manifest test rejects any non-CC0 sample or a bad hash, and the downloader only fetches URLs listed in `DOWNLOADABLE_URLS` in `lib/manifest.mjs`, so a new sample needs a code change as well as a manifest entry.

| Key | File | Purpose |
|---|---|---|
| `arw_14bit` | `_DSC0009.ARW` (Sony ILCE-7M3, 6000x4000) | Real raw with sky and trees: `create_mask` sky/subject/background, `create_landscape_mask`, batch source, denoise. |
| `arw_12bit` | `_DSC0010.ARW` | Same scene, 12-bit: second raw for batch and multi-photo checks. |

Supplied by you (never committed; the setup script imports whichever env var is set, checks skip when absent):

| Env var | Needed for |
|---|---|
| `LRMCP_LIVE_DEPTH_HEIC` | Depth range. Must be a real iPhone Portrait HEIC that carries a device depth map. Synthetic disparity files are ignored by Lightroom, so there is no generated stand-in. The Lightroom Killer Tips sample has no stated license, so it is not downloaded. |
| `LRMCP_LIVE_SUBJECT_PHOTO` | Subject/object mask on a clear foreground subject. |
| `LRMCP_LIVE_PEOPLE_PHOTO` | `create_people_mask` (needs a person). |

Other env vars: `LRMCP_LIVE_FIXTURES_DIR`, `LRMCP_LIVE_THROWAWAY_CATALOG`, and the usual `LIGHTROOM_MCP_REQUEST_PORT` / `LIGHTROOM_MCP_RESPONSE_PORT`.

## Helpers

| Module | Use |
|---|---|
| `lib/mcp.mjs` | `McpSession`: spawns the built server over stdio, waits until the plug-in answers, `tool(name, args, {timeoutMs})` returns `{isError, data, text, image, ms}`. Default timeout 120 s (`mcp-runner.mjs` has 35 s); pass a longer one for imports and batches. |
| `lib/live-catalog.mjs` | `openLiveSession()`: guard, marker (photo ids by fixture name), session. `requireFixtureId(marker, key)`. |
| `lib/catalog-guard.mjs` | `requireThrowawayCatalog()`, `assertThrowawayCatalog(list)`, `isRealCatalog`. Call first in every script that writes masks. |
| `lib/ax.mjs` | `ensureLightroomFrontmost()`, `dismissBlockingModals()` ("No X detected" gets OK, "Enable address lookup?" gets a decline button, never Enable), `closePluginManager()`, `clickMenuItem()`, `openNewCatalogDialog()`, `openRecentCatalog()`. |
| `lib/preview.mjs` | `measureChange(session, photoId, applyChange)`: settle protocol (stable preview before, run change, wait 3.5 s, stable preview after). `regionDeltas`, `bandDeltas`, `patchDeltas` (per-region or per-patch deltas), `intersectionOverUnion` with `ellipseInside` / `rectangleInside`. Before and after previews can differ in size (600x1000 then 540x900), so everything compares by normalized position. |
| `lib/catalog-db.mjs` | `readFlushedSettings(session, photoId, flushPhotoId)`: opens another photo in Develop to flush the lagging sqlite row, reads until two reads agree. `storedMaskGroups`, `summarizeMaskGroups`, `developHistory`. |
| `lib/snapshot.mjs`, `catalog-snapshot.mjs` | `snapshot [label]` copies the throwaway `.lrcat` with `-wal`/`-shm` to `~/.cache/lightroom-mcp-live-snapshots/<label>-<stamp>/` and runs `quick_check` on the copy. `restore <dir> <catalog>` needs Lightroom closed. |
| `lib/plugin-bundle.mjs`, `install-bundle.mjs` | Install and restore the bundle, backups outside `$TMPDIR`, `diff -rq` verification, added-Lua-file detection. |

A check is a few lines:

```js
const { session, marker } = await openLiveSession();
const photoId = requireFixtureId(marker, "orient_6");
const { before, after } = await measureChange(session, photoId, () => applyMask(session, photoId));
const deltas = regionDeltas(before, after, [{ name: "top", x0: 0.3, y0: 0, x1: 0.7, y1: 0.08 }]);
```

## Verification matrix

`node tests/e2e/live/duplicate-groups.mjs` reads the two ARW fixtures and `wide_plain`, derives the raw capture gap from `find_duplicate_groups.photos`, and checks that only the ARWs group at that gap. It verifies ratings, flags, keyword paths and reported collections stay unchanged. `get_photo_metadata.dateTimeOriginal` remains a display string and is never parsed. The script reads the marked throwaway catalog without changing its shared fixtures.

`node tests/e2e/live/photo-stats.mjs` checks `get_photo_stats` on untouched `ramp256` and `wide_plain`: each ramp quarter holds 25 percent of the histogram mass within 5 points; plain gray has mean luminance 110 within 4 and no clipping. The script only reads the marked throwaway catalog.

For a catalog whose shared fixtures already have develop edits, import your own gray ramp and gray-110 images and pass their IDs as `node tests/e2e/live/photo-stats.mjs RAMP_ID PLAIN_ID`. Preserve the shared fixtures and their edits.

For AI metadata, run `node tests/e2e/live/ai-metadata.mjs write`, then `verify`
after Reload Plug-in and again after quitting and reopening Lightroom. Run
`clear` to check clearing and restore the fixtures' original plug-in values.
Each phase checks that keywords, title and caption stay unchanged. The new
metadata provider registers a persistent schema: obtain approval of its field
IDs and types before installing it, keep it confined to the throwaway catalog,
and restore the original bundle while Lightroom is closed before reopening
the real catalog. Finish with `node tests/e2e/live/smoke.mjs` on the throwaway
catalog.

Positions are always in the displayed frame of the uncropped photo; Lightroom stores masks in the unrotated frame (`ImageFrame.lua`).

| Tool | Fixtures | Key checks |
|---|---|---|
| `list_masks` | any photo with masks | Ids are reusable for later calls. A range made in the Lightroom UI appears only after Lightroom saved it. Module, view source and selection are restored. Empty list for a photo without masks. |
| `create_gradient_mask` linear | `orient_1`..`orient_8`, `wide_plain`, `pano` | On every orientation the brightening lands on the side the displayed start point is on (`regionDeltas` top vs bottom, left vs right). A cropped and rotated copy (set `Crop*` and `CropAngle` on a duplicate): coordinates stay relative to the uncropped frame. |
| `create_gradient_mask` radial | `wide_plain`, `orient_1`..`orient_8`, `pano` | IoU against `ellipseInside` at 0 feather is at least 0.8 (0.99 measured). Large angles: rotation 60 and -60 differ, the opposite rotation scores clearly lower, rotation past 45 is reported as swapped width/height with the angle turned back by 90. Width/height are fractions of the image, so `pano` stays 10:1. `area: outside` is the complement. |
| `update_gradient_mask` | same as create | Only the given fields change, tool/mask ids and adjustments survive. |
| `create_brush_mask`, `add_brush_strokes` | `wide_plain`, `orient_6` | Delta band follows the stroke path in the displayed frame. Radius is a fraction of the long edge. Erase strokes remove earlier paint. Brush on a cropped photo. |
| `create_range_mask` luminance | `ramp256` | `patchDeltas` over the 256 patches: inside `[min, max]` full change, outside none, falloff ramps linearly, ramps clipped at 0 and 1. Band narrower than 0.01 refused. |
| `create_range_mask` color | `chart80` | Selection follows Lightroom's `l a b` triple, not sRGB (#338/#339): take the triple from a range clicked in the UI (`list_masks`) or use `copy_sample_from`. Exactly one sample point: two crash Lightroom and crash-loop the catalog. |
| `create_range_mask` depth | `LRMCP_LIVE_DEPTH_HEIC` | Range on near vs far regions of the depth map. Fails cleanly and leaves the photo unchanged on any photo without depth. Skip the check when the env var is unset. |
| `create_mask` subject/sky/background | `arw_14bit`, `arw_12bit`, `LRMCP_LIVE_SUBJECT_PHOTO` | Sky mask covers the sky region of the preview. "No X detected" modal blocks Develop until dismissed via AX. |
| `create_mask_batch` | `batch.ids` (200) | Budget: at most 200 photos per call, a call stops after about 230 s with `complete: false` and `remaining_ids`; repeat with the remainder until `complete`. First photo opens in Develop, so a "No X detected" on it stops the batch. Masks of earlier photos are kept. |
| `create_people_mask` | `LRMCP_LIVE_PEOPLE_PHOTO` | Mask per detected person. Skip when absent. |
| `create_landscape_mask` | `arw_14bit` | Mask of the chosen landscape category appears on the right region. |
| `combine_mask` | `wide_plain` | Intersect pixel check: only pixels inside both shapes change (IoU against the intersection of two analytic ellipses). Add and subtract against the union and difference. |
| `invert_mask` | `wide_plain` | Changed region is the complement of the shape. Inverting twice restores the original diff. |
| `set_mask_adjustments`, `get_mask_adjustments` | `wide_plain`, `ramp256` | Settle-after-adjust: the call returns after saving the sliders; the preview is stable only after about 3.5 s, so use `measureChange`. Stored row after `readFlushedSettings`: `local_Exposure` +2 is stored as `LocalExposure2012 = 0.5`. |
| `set_mask_curves`, `get_mask_curves` | `ramp256` | `patchDeltas` per gray level follow the curve points; round trip through `get_mask_curves`. |
| `edit_mask_point_colors`, `get_mask_point_colors` | `chart80` | A point-color edit changes the patches near the sampled color and leaves distant patches alone; round trip through `get_mask_point_colors`. |
| `delete_masks`, `delete_empty_masks` | any, `batch.ids` | Remaining count matches, the photos stay in the catalog. `delete_empty_masks` is catalog-only: it does not open Develop and keeps the selection. |

Run `node tests/e2e/live/folders.mjs` after importing the 200-photo batch to verify folder paths, fixture membership, pagination, direct counts, and count timing.

## Catalog removal check

After installing the candidate bundle and restarting into the marked throwaway catalog, run `node tests/e2e/live/remove-from-catalog.mjs`. It imports three uniquely named JPEG copies, verifies confirmation guards, removes two in one call, checks the catalog count and every original fixture, verifies surviving selection, and checks all three files still exist after cleanup. The copied files remain in the throwaway catalog folder for inspection. Run with exclusive app and bridge ownership: the script briefly closes MCP to stage selection through the test-only TCP action.

Stop without retrying if removal opens a blocking dialog, affects only the active photo, or removes unrequested virtual copies or stack members. Check master/virtual-copy and stacked-photo behavior manually on additional disposable imports before accepting a new Lightroom version. The tool refuses a master unless all its virtual copies are explicitly included. It restores module, sources and selection; Library remains in grid view because the documented SDK has no primary-view getter.

## Known traps

`node tests/e2e/live/style-summary.mjs` checks the single-photo median on `arw_14bit`, restores its exposure/rating and all other five-star ratings, then times a 200-photo summary (requires `make-batch.mjs` and `import-batch.mjs` first). Issue 387's prerequisite was checked on LrC 15.6 with a fresh synthetic import: protected raw `isExported` was Boolean `false`, `export_photos` exported one JPEG, and the same raw getter returned Boolean `true`. The diagnostic action was private to the temporary probe bundle. The summary intersects exported state with rating, uses SDK numeric keys, and reports settings omitted by the per-group size limit.

- `LrInitPlugin` runs only when Lightroom's window is first activated: after a relaunch that leaves another app in front, no server starts. `setup-catalog.mjs` and `ensureLightroomFrontmost()` activate it.
- "No X detected" and "Enable address lookup?" modals block the UI and make mask creation silently do nothing. Run `dismissBlockingModals()` after every launch and after any AI mask call that finds nothing.
- `get_photo_preview` is stale right after a photo enters Develop and can answer "error loading thumb" after a settings change until you select another photo and back. Use `measureChange` (stable twice before, 3.5 s wait, stable twice after) or a diff shows a false uniform change.
- The develop-settings sqlite row lags until you switch photos. Lightroom can also show a change in the panel and never save it, so verify through history or the flushed row, never the panel.
- Develop zoom changes between photo opens. Use View > Toggle Zoom View for Fit before pixel work.
- Reload Plug-in does not see an added `.lua` file (restart Lightroom), and `mise run plugin:reload` can leave Plug-in Manager open, which blocks clicks: `closePluginManager()`.
- After switching catalogs the plug-in can bind and then drop its sockets after the 10 s no-client timeout: Plug-in Manager, Stop Server, Start Server.
- `import_photos` silently skips RAF and CR3. ARW, CR2, NEF and JPEG import. Imports take about 1.2 s per small JPEG; pass a long `timeoutMs`.
- A Color Range with two PointModels crashes Lightroom and crash-loops the catalog. If it happens, quit Lightroom normally and `restore` a snapshot.
- Take a snapshot (`catalog-snapshot.mjs snapshot <label>`) before any test that writes masks you cannot delete again.
- klaudiush rejects comments in new code, also in JS. Put the reasoning in names and in this README.
