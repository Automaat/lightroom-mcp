#!/usr/bin/env node
import assert from "node:assert/strict";
import { openLiveSession, requireFixtureId, writeCatalogMarker } from "./lib/live-catalog.mjs";

const phase = process.argv[2];
assert.ok(["write", "verify", "clear"].includes(phase), "usage: ai-metadata.mjs write|verify|clear");
const { session, marker, catalogPath } = await openLiveSession();
const photoIds = [requireFixtureId(marker, "orient_1"), requireFixtureId(marker, "wide_plain")];

async function standardMetadata() {
  const values = [];
  for (const photo_id of photoIds) {
    const { data } = await session.toolOrThrow("get_photo_metadata", { photo_id });
    values.push({ keywords: data.keywords ?? [], title: data.title ?? null, caption: data.caption ?? null });
  }
  return values;
}

try {
  if (phase === "write") {
    assert.equal(marker.aiMetadataCheck, undefined, "clear the previous AI metadata check first");
    const before = await standardMetadata();
    const { data: original } = await session.toolOrThrow("get_ai_metadata", { photo_ids: photoIds });
    assert.equal(original.photos.length, 2);
    marker.aiMetadataCheck = { before, original: original.photos };
    writeCatalogMarker(catalogPath, marker);
    const { data } = await session.toolOrThrow("set_ai_metadata", {
      photo_ids: photoIds, score: 72, reason: "eyes closed",
    });
    assert.equal(data.updated, 2);
  }

  assert.ok(marker.aiMetadataCheck, "run the write phase before verify or clear");
  const { data: stored } = await session.toolOrThrow("get_ai_metadata", { photo_ids: photoIds });
  assert.equal(stored.photos.length, 2);
  assert.deepEqual(stored.missing, []);
  for (const photo of stored.photos) {
    assert.equal(photo.score, 72);
    assert.equal(photo.reason, "eyes closed");
  }
  assert.deepEqual(await standardMetadata(), marker.aiMetadataCheck.before);

  if (phase === "clear") {
    await session.toolOrThrow("set_ai_metadata", { photo_ids: photoIds, score: "", reason: "" });
    const { data } = await session.toolOrThrow("get_ai_metadata", { photo_ids: photoIds });
    for (const photo of data.photos) {
      assert.equal(photo.score, undefined);
      assert.equal(photo.reason, undefined);
    }
    for (const photo of marker.aiMetadataCheck.original) {
      await session.toolOrThrow("set_ai_metadata", {
        photo_ids: [photo.photo_id], score: photo.score ?? "", reason: photo.reason ?? "",
      });
    }
    assert.deepEqual(await standardMetadata(), marker.aiMetadataCheck.before);
    delete marker.aiMetadataCheck;
    writeCatalogMarker(catalogPath, marker);
  }
  console.log(`pass AI metadata ${phase}: two photos; standard metadata unchanged`);
} finally {
  await session.stop();
}
