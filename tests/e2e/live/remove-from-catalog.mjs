#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { requireThrowawayCatalog } from "./lib/catalog-guard.mjs";
import { McpSession } from "./lib/mcp.mjs";
import { REPO_ROOT } from "./lib/paths.mjs";

const { marker, catalogPath, session: initialSession } = await openLiveSession();
let session = initialSession;
const disposableDirectory = path.join(path.dirname(catalogPath), `remove-check-${randomUUID()}`);
const survivorId = requireFixtureId(marker, "wide_plain");
const source = marker.fixtures.wide_plain.path;
const copies = [];
try {
  requireThrowawayCatalog();
  fs.mkdirSync(disposableDirectory);
  for (let i = 0; i < 3; i++) {
    const file = path.join(disposableDirectory, `remove-${i}.jpg`);
    fs.copyFileSync(source, file);
    const imported = await session.toolOrThrow("import_photos", { source_path: file });
    assert.equal(imported.data.imported, 1);
    const found = await session.toolOrThrow("search_photos", { filename: path.basename(file), limit: 100, include_path: true });
    const photo = found.data.photos.find((photo) => photo.path === file);
    assert.ok(photo, `imported copy missing: ${file}`);
    copies.push({ id: photo.id, file });
  }
  await session.stop();
  const output = execFileSync(process.execPath, [path.join(REPO_ROOT, "manual-test.mjs"),
    "set_selection", JSON.stringify({ photo_ids: [survivorId, copies[0].id] })], { encoding: "utf8" });
  const response = JSON.parse(output.slice(output.lastIndexOf("<<<") + 3));
  assert.equal(response.result.selected, 2);
  session = await new McpSession().start();
  const selectionBefore = await session.toolOrThrow("get_selected_photos");
  assert.deepEqual(new Set(selectionBefore.data.photos.map((photo) => String(photo.id))),
    new Set([survivorId, copies[0].id].map(String)));
  const before = await session.toolOrThrow("search_photos", { limit: 1 });
  for (const confirm of [undefined, false, "true"]) {
    const answer = await session.tool("remove_photos_from_catalog", { photo_ids: [copies[0].id], confirm });
    assert.equal(answer.isError, true);
  }
  const selected = await session.toolOrThrow("get_selected_photos");
  assert.deepEqual(selected.data.photos.map((photo) => String(photo.id)),
    selectionBefore.data.photos.map((photo) => String(photo.id)));
  requireThrowawayCatalog();
  const removed = await session.toolOrThrow("remove_photos_from_catalog", {
    photo_ids: [copies[0].id, copies[1].id, copies[0].id], confirm: true,
  });
  assert.equal(removed.data.removed, 2);
  const after = await session.toolOrThrow("search_photos", { limit: 1 });
  assert.equal(after.data.count, before.data.count - 2);
  for (const copy of copies) assert.equal(fs.existsSync(copy.file), true);
  const restored = await session.toolOrThrow("get_selected_photos");
  assert.deepEqual(restored.data.photos.map((photo) => String(photo.id)), [String(survivorId)]);
  for (const fixture of Object.values(marker.fixtures)) {
    await session.toolOrThrow("get_photo_metadata", { photo_id: fixture.id });
  }
  await session.toolOrThrow("get_photo_metadata", { photo_id: copies[2].id });
  requireThrowawayCatalog();
  const cleanup = await session.toolOrThrow("remove_photos_from_catalog", {
    photo_ids: [copies[2].id], confirm: true,
  });
  assert.equal(cleanup.data.removed, 1);
  for (const copy of copies) assert.equal(fs.existsSync(copy.file), true);
  console.log(JSON.stringify({ passed: true, catalogPath, copies, removed: 3,
    checks: ["confirm guard", "two-photo removal", "duplicate IDs", "files remain",
      "unrelated fixtures remain", "surviving selection restored"] }));
} finally {
  await session.stop();
}
