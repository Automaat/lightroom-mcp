#!/usr/bin/env node
import assert from "node:assert/strict";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";

const { session, marker } = await openLiveSession();
try {
  const ids = ["arw_14bit", "arw_12bit", "wide_plain"].map(key => requireFixtureId(marker, key));
  const readState = async () => Promise.all(ids.map(async photo_id => {
    const { data } = await session.toolOrThrow("get_photo_metadata", { photo_id });
    return { id: data.id, rating: data.rating, flag: data.pickStatus, keywords: data.keywordPaths, collections: data.collections };
  }));
  const before = await readState();
  const initial = await session.toolOrThrow("find_duplicate_groups", { photo_ids: ids, time_window_seconds: 86400 });
  assert.equal(initial.data.complete, true, initial.text);
  const times = ids.slice(0, 2).map(id => initial.data.photos.find(photo => String(photo.photo_id) === String(id))?.capture_time);
  assert.ok(times.every(Number.isFinite), initial.text);
  const gap = Math.abs(times[1] - times[0]);
  assert.ok(gap <= 86400, JSON.stringify({ times, gap }));
  const grouped = await session.toolOrThrow("find_duplicate_groups", { photo_ids: ids, time_window_seconds: gap });
  assert.equal(grouped.data.complete, true, grouped.text);
  const group = grouped.data.groups.find(group => ids.slice(0, 2).every(id => group.photo_ids.some(member => String(member) === String(id))));
  assert.ok(group, grouped.text);
  assert.ok(!group.photo_ids.some(id => String(id) === String(ids[2])), grouped.text);
  assert.deepEqual(await readState(), before);
  console.log(JSON.stringify({ gap, rawCaptureTimes: times, ...grouped.data, catalogUnchanged: true }, null, 2));
} finally {
  await session.stop();
}
