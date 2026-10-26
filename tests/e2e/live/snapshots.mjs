#!/usr/bin/env node
import assert from "node:assert/strict";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";

const { session, marker } = await openLiveSession();
const photo_id = requireFixtureId(marker, "wide_plain");
const otherId = requireFixtureId(marker, "orient_6");
const prefix = `lrmcp-snapshots-${Date.now()}`;
const created = new Set();
const tool = async (name, args) => (await session.toolOrThrow(name, args)).data;
const metadata = await tool("get_photo_metadata", { photo_id });
const initial = metadata.developSettings.exposure;
const before = await tool("list_develop_snapshots", { photo_id });
let failure;
try {
  await tool("set_develop_settings", { photo_id, settings: { Exposure2012: 1 } });
  const first = (await tool("create_develop_snapshot", { photo_id, name: `${prefix}-a` })).snapshot;
  created.add(first.id);
  assert.equal(typeof first.id, "string");
  const second = (await tool("create_develop_snapshot", { photo_id, name: `${prefix}-b` })).snapshot;
  created.add(second.id);
  await tool("set_develop_settings", { photo_id, settings: { Exposure2012: -1 } });
  assert.equal((await session.tool("create_develop_snapshot", { photo_id, name: first.name })).isError, true);
  await tool("apply_develop_snapshot", { photo_id, snapshot_id: first.id });
  const restored = await tool("get_photo_metadata", { photo_id });
  assert.equal(restored.developSettings.exposure, 1);
  for (const key of ["rating", "pickStatus", "keywords", "title", "caption"]) {
    assert.deepEqual(restored[key], metadata[key], `snapshot changed ${key}`);
  }
  await tool("set_develop_settings", { photo_id, settings: { Exposure2012: -1 } });
  const replacement = (await tool("create_develop_snapshot", { photo_id, name: second.name, replace: true })).snapshot;
  created.delete(second.id);
  created.add(replacement.id);
  assert.equal(replacement.name, second.name);
  await tool("apply_develop_snapshot", { photo_id, snapshot_id: replacement.id });
  assert.equal((await tool("get_photo_metadata", { photo_id })).developSettings.exposure, -1);
  for (const action of ["apply", "delete"]) {
    for (const args of [
      { photo_id, snapshot_id: "missing-snapshot" },
      { photo_id: otherId, snapshot_id: first.id },
      { photo_id: "missing-photo", snapshot_id: first.id },
    ]) assert.equal((await session.tool(`${action}_develop_snapshot`, args)).isError, true);
  }
  await tool("delete_develop_snapshot", { photo_id, snapshot_id: first.id });
  created.delete(first.id);
  const listed = (await tool("list_develop_snapshots", { photo_id })).snapshots;
  assert.equal(listed.some((snapshot) => snapshot.id === first.id), false);
  assert.equal(listed.some((snapshot) => snapshot.id === replacement.id), true);
  console.log("PASS snapshot creation, duplicate rejection, replacement, exposure restore, ownership and deletion");
} catch (error) {
  failure = error;
} finally {
  try {
    for (const snapshot_id of created) await tool("delete_develop_snapshot", { photo_id, snapshot_id });
    await tool("set_develop_settings", { photo_id, settings: { Exposure2012: initial } });
    assert.deepEqual((await tool("list_develop_snapshots", { photo_id })).snapshots, before.snapshots);
  } catch (cleanupError) {
    failure = failure ? new AggregateError([failure, cleanupError], "Snapshot test and cleanup failed") : cleanupError;
  } finally {
    await session.stop();
  }
}
if (failure) throw failure;
