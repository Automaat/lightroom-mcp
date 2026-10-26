#!/usr/bin/env node
import assert from "node:assert/strict";
import path from "node:path";
import { openLiveSession } from "./lib/live-catalog.mjs";

const { session, marker, catalogPath } = await openLiveSession();
try {
  const folders = [];
  let offset = 0;
  let page;
  const started = performance.now();
  do {
    page = (await session.toolOrThrow("list_folders", { limit: 5, offset })).data;
    folders.push(...page.folders);
    offset += page.folders.length;
    assert.ok(!page.has_more || page.folders.length > 0);
  } while (page.has_more);
  assert.equal(folders.length, page.count);
  assert.equal(new Set(folders.map((folder) => folder.path)).size, folders.length);
  const images = folders.find((folder) => folder.path === path.join(path.dirname(catalogPath), "images"));
  assert.ok(images, "list_folders includes the fixture images folder");
  const photos = [];
  offset = 0;
  do {
    page = (await session.toolOrThrow("get_folder_photos", { folder_path: images.path, limit: 5, offset })).data;
    photos.push(...page.photos);
    offset += page.photos.length;
    assert.ok(!page.has_more || page.photos.length > 0);
  } while (page.has_more);
  const ids = Object.values(marker.fixtures).map((fixture) => String(fixture.id)).sort();
  assert.deepEqual(photos.map((photo) => String(photo.id)).sort(), ids);
  assert.equal(images.photo_count, ids.length);
  const batchIds = marker.batch?.ids ?? [];
  assert.ok(batchIds.length >= 200, "import the 200-photo batch before measuring folder counts");
  const recursive = (await session.toolOrThrow("get_folder_photos", {
    folder_path: images.path, include_subfolders: true, limit: 0,
  })).data;
  assert.ok(recursive.count >= ids.length);
  console.log(JSON.stringify({ passed: true, folders: folders.length, fixturePhotos: ids.length,
    batchPhotos: batchIds.length, elapsedMs: performance.now() - started }));
} finally {
  await session.close();
}
