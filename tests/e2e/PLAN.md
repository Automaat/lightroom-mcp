# Lightroom MCP — manual e2e playbook

End-to-end manual test plan. Designed to be **run in order**: each phase
builds on the prior. Stop at the first failing phase, fix, restart.

Two helpers do most of the work:

- `tests/e2e/mcp-runner.mjs` — spawns the built MCP server and drives it
  over stdio (same protocol Claude Desktop uses). Scripted, repeatable.
- `manual-test.mjs` — raw TCP probe straight at plugin sockets, bypasses
  MCP. Useful for isolating "is it the server or the plugin?".

Both honour `LIGHTROOM_MCP_REQUEST_PORT` / `LIGHTROOM_MCP_RESPONSE_PORT`
/ `LIGHTROOM_MCP_TOKEN_PATH`.

---

## Phase 0 — pre-flight (one-time setup)

Goal: plugin installed, server built, all artefacts present.

**Steps**

1. Copy plugin into Lightroom plugins dir
   ```sh
   cp -R plugin/LightroomMCP.lrplugin "$HOME/Library/Application Support/Adobe/Lightroom/Plugins/"
   ```
2. Open Lightroom Classic → **File → Plug-in Manager → Lightroom MCP**
3. Auto-start should be on. If not, click **Start Server**
4. Build server
   ```sh
   mise run install && mise run build
   ```

**Pass criteria** — all of:

```sh
ls -la "$HOME/.config/lightroom-mcp/token"                   # exists, non-empty
ls -la "$HOME/Documents/LrClassicLogs/LightroomMCP.log"      # exists
lsof -nP -iTCP:58763 -iTCP:58764 | grep -i adobe             # both bound by Lightroom
ls server/dist/index.js                                       # built
```

If anything's missing → see Phase 9 troubleshooting.

---

## Phase 1 — connectivity smoke

Goal: server connects, token handshake succeeds, single round trip works.

**Steps**

```sh
node manual-test.mjs list_collections
```

**Pass criteria**

- `[request] connected :58763` and `[response] connected :58764` printed
- `<<< { "id": "manual_…", "result": { "count": …, "collections": […] } }`
- No `error` key in response
- Lightroom Plug-in Manager → **Show Status** shows `Request socket connected: true`, `Response socket connected: true`, `Requests processed >= 1`

**Failure modes & meaning**

| symptom | cause |
| --- | --- |
| `ECONNREFUSED` on either port | plugin not started, or stale sockets after Reload Plug-in. Quit Lightroom (Cmd+Q), reopen |
| `token read failed` | plugin never wrote token — Start Server hasn't been clicked |
| handshake-then-immediate-disconnect | token mismatch; delete `~/.config/lightroom-mcp/token`, restart server in plugin |
| timeout waiting for response | handler stuck; check Show Status `Last event` and the log file |

---

## Phase 2 — read-only suite (scripted)

Goal: every read tool returns well-formed data against the live catalog.

```sh
node tests/e2e/mcp-runner.mjs read
```

**What it covers**

- `tools/list` returns 14 tools (matches `server/src/index.ts`)
- `list_collections` — paginated, count + array shape
- `get_selected_photos` — paginated, array shape (works whether something is selected or not; falls back to filmstrip)
- `search_photos` no-filter — returns first N photos
- `search_photos` with `rating: 5` — exercises the searchDesc builder
- `get_photo_metadata` by `localIdentifier` AND by file path — both lookup paths
- `list_develop_presets` — exercises preset folder iteration

**Pass criteria** — all `OK`, summary line shows `0 failed`.

**Manual check in Lightroom (visual)**

- Plug-in Manager → Show Status → `Requests processed` increased by ~7

---

## Phase 3 — selection-aware behaviour

Goal: `get_selected_photos` actually reflects the filmstrip selection.

**Steps**

1. In Lightroom, navigate to a folder, **select 3 photos** in the filmstrip (Shift-click or Cmd-click)
2. Run:
   ```sh
   node tests/e2e/mcp-runner.mjs tool get_selected_photos '{"limit":10}'
   ```

**Pass criteria**

- `count: 3`, `photos: [...]` array length 3
- The `filename` and `path` fields match what's selected

**Edge: deselect everything** — repeat. `getTargetPhotos()` falls back to the entire filmstrip / folder; expect `count` to equal the visible photo count, not 0.

---

## Phase 4 — write suite (mutating, scripted)

Goal: collections, ratings, keywords roundtrip via the catalog.

⚠️ This phase **mutates** your catalog. It creates a uniquely-named
collection (`MCP_E2E_<timestamp>`) and bumps rating/keywords on the first
photo returned by `search_photos` (then restores). Use a non-production
catalog if you'd rather not.

```sh
node tests/e2e/mcp-runner.mjs write
```

**What it covers**

- `create_collection` with timestamped name
- `list_collections` finds the new collection
- `add_to_collection` adds first photo, asserts `added: 1`
- `set_rating` 3 then restore to original
- `get_photo_metadata` confirms rating roundtrip
- `set_keywords` add `mcp_e2e_<ts>`, confirm via metadata, then remove, confirm gone

**Manual check in Lightroom (visual)**

- Library → Collections panel → new `MCP_E2E_…` collection visible, contains 1 photo
- Open that photo → Keywording panel briefly showed `mcp_e2e_*` (then removed)

**Cleanup**

- Right-click `MCP_E2E_…` collection → Delete (the script doesn't auto-delete it; intentional, so you can inspect first)

---

## Phase 5 — develop suite (scripted)

Goal: develop settings can be read, written directly, and applied via preset.

⚠️ Mutates the first photo's exposure (sets to +0.5 EV, then restores to 0).

```sh
node tests/e2e/mcp-runner.mjs develop
```

**What it covers**

- `set_develop_settings` with `Exposure2012: 0.5`, then read back via `get_photo_metadata.developSettings.exposure`, expect ~0.5
- Restore to 0
- `apply_develop_preset` using the first preset returned by `list_develop_presets`

**Manual check**

- Develop module on the test photo → Exposure briefly shows +0.50, then 0.00
- After preset applied, History panel shows the preset name

---

## Phase 6 — copy_develop_settings (semi-manual)

Not yet covered by the runner because it needs two distinct photo IDs.

**Steps**

1. Get two photo IDs:
   ```sh
   node tests/e2e/mcp-runner.mjs tool search_photos '{"limit":2}'
   ```
   note `photos[0].id` and `photos[1].id`.
2. Apply a tweak to photo 0:
   ```sh
   node tests/e2e/mcp-runner.mjs tool set_develop_settings \
     '{"photo_id":"<id0>","settings":{"Contrast2012":40,"Saturation":20}}'
   ```
3. Copy from 0 → 1:
   ```sh
   node tests/e2e/mcp-runner.mjs tool copy_develop_settings \
     '{"source_id":"<id0>","target_ids":["<id1>"]}'
   ```
4. Verify on photo 1:
   ```sh
   node tests/e2e/mcp-runner.mjs tool get_photo_metadata '{"photo_id":"<id1>"}'
   ```
   Expect `developSettings.contrast == 40`, `developSettings.saturation == 20`.

**Whitelist variant**

Repeat step 3 with `"settings":["Contrast2012"]` and verify only contrast (not saturation) was copied.

---

## Phase 7 — import / export (semi-manual, slowest)

Goal: catalog ingest + render pipeline.

### 7a Import

**Setup**

```sh
mkdir -p /tmp/lr_import_e2e
# drop 2-3 sample JPEGs in there (any photo files you don't mind importing)
```

**Run**

```sh
node tests/e2e/mcp-runner.mjs tool import_photos \
  '{"source_path":"/tmp/lr_import_e2e"}'
```

**Pass criteria**

- response `{ "success": true, "imported": <n> }` with n matching files in folder
- Library → Previous Import shows the new photos

**Cleanup** — right-click in Library → Remove from Catalog.

### 7b Export

**Run**

```sh
mkdir -p /tmp/lr_export_e2e
# pick a real photo id first:
node tests/e2e/mcp-runner.mjs tool search_photos '{"limit":1}'
# then export it as JPEG @1024px
node tests/e2e/mcp-runner.mjs tool export_photos \
  '{"photo_ids":["<id>"],"destination":"/tmp/lr_export_e2e","format":"jpeg","quality":85,"width":1024,"height":1024}'
```

**Pass criteria**

- response `{ "success": true, "exported": 1 }`
- `ls /tmp/lr_export_e2e` shows the JPEG
- `sips -g pixelWidth -g pixelHeight /tmp/lr_export_e2e/*.jpg` shows long edge ≤ 1024

**Format matrix** — repeat with `"png"`, `"tiff"`, `"original"`. Each should produce the corresponding file extension; for `original` the input format is preserved.

---

## Phase 8 — failure & edge cases (scripted)

Goal: bad input is rejected with `isError: true`, not silent success or hang.

```sh
node tests/e2e/mcp-runner.mjs failure
```

**Covers**

- unknown tool name → `isError: true`, "Unknown action: …"
- `get_photo_metadata` with bogus id → `isError: true`, "Photo not found"
- `set_rating` with rating=9 → `isError: true`, validation message
- `create_collection` with no name → `isError: true`

**Additional edges to probe by hand**

| case | how | expected |
| --- | --- | --- |
| empty `photo_ids` array | `set_rating '{"photo_ids":[],"rating":3}'` | error "photo_ids is required" |
| `add_to_collection` with non-existent collection | use a junk name | error "Collection not found" |
| `import_photos` source_path doesn't exist | `'{"source_path":"/nope"}'` | error "Source path does not exist" |
| `export_photos` destination not writable | `'{"photo_ids":["<id>"],"destination":"/etc/lr_e2e_denied"}'` | error from LrExportSession |

---

## Phase 9 — resilience: reload, restart, port mismatch

These probe the auto-reconnect + token + port-config code paths.

### 9a Plugin reload (sockets stay bound)

1. With server running, hit **Reload Plug-in** in Plug-in Manager
2. Run `node tests/e2e/mcp-runner.mjs read` again — should still work (token regenerates, server reconnects, picks up new token from disk)
3. **Known limitation** (CLAUDE.md): if Reload leaves the prior async task wedged, you'll see `failed to open localhost:58763`. Fix is Cmd+Q + reopen, not Reload again.

### 9b Server restart

1. Mid-suite, kill the harness process (Ctrl-C)
2. Re-run — plugin should still be bound, new server reconnects within ~1s
3. Plug-in Manager → Show Status → `Request socket connected: true` resumes

### 9c Wrong token

1. Backup token: `cp ~/.config/lightroom-mcp/token /tmp/tok_real`
2. Corrupt: `printf 'wrong' > ~/.config/lightroom-mcp/token`
3. Run `node tests/e2e/mcp-runner.mjs tool list_collections '{}'`
4. Expect: server connects, plugin drops connection, server logs reconnect storm; tool call times out
5. Restore: `cp /tmp/tok_real ~/.config/lightroom-mcp/token` and verify recovery

### 9d Port mismatch

1. Set `LIGHTROOM_MCP_REQUEST_PORT=58773 LIGHTROOM_MCP_RESPONSE_PORT=58774` in shell
2. Run `node tests/e2e/mcp-runner.mjs tool list_collections '{}'`
3. Expect: server prints connect failures; tool returns `Lightroom plugin not connected.`
4. Open Plug-in Manager, edit ports to 58773/58774, Stop + Start server
5. Re-run: succeeds. Restore defaults afterwards.

---

## Phase 10 — concurrency / pagination

Goal: Dispatcher correctly demuxes responses by id; pagination is consistent.

### 10a Pagination consistency

```sh
node tests/e2e/mcp-runner.mjs tool search_photos '{"limit":3,"offset":0}'
node tests/e2e/mcp-runner.mjs tool search_photos '{"limit":3,"offset":3}'
```

Photos in the second call must not appear in the first (no overlap). `count` should be identical across both calls. `has_more` true on the first if catalog > 3.

### 10b Parallel calls (advanced, optional)

In one terminal, run two tool calls "at once" by piping the runner with shell `&`:

```sh
node tests/e2e/mcp-runner.mjs tool search_photos '{"limit":1,"offset":0}' &
node tests/e2e/mcp-runner.mjs tool list_collections '{}' &
wait
```

Each spawns its own server (so this is two parallel sessions, not multiplexed in one connection — the plugin only allows one client per port). Both should succeed.

**True multiplexing** (multiple in-flight requests on one connection) — not exercised by the harness today; would require extending it to fire several `callTool` promises before awaiting. If you want, the dispatcher already supports it (`pendingCount()` is exposed), so add a scenario that does `Promise.all([c.callTool(...), c.callTool(...)])` and assert both resolve.

---

## Quick reference

```sh
# happy path, all phases that are auto-runnable
node tests/e2e/mcp-runner.mjs all

# one-shot single tool
node tests/e2e/mcp-runner.mjs tool <name> '<json>'

# inspect server's tool catalog
node tests/e2e/mcp-runner.mjs list-tools

# raw TCP probe (skips MCP entirely)
node manual-test.mjs <action> '<json>'
```

## Unresolved

- harness doesn't auto-cleanup the test collection — intentional, but if you run write phase a lot you'll accumulate `MCP_E2E_*` collections; consider a `--cleanup` flag
- import/export phases need user-supplied test files and aren't part of `all`
- no concurrency assertion in scripted runner; add `Promise.all` scenario when needed
