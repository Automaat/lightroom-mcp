#!/usr/bin/env node
import assert from "node:assert/strict";
import { isDeepStrictEqual } from "node:util";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { developHistory, parseLuaTable, readFlushedSettings } from "./lib/catalog-db.mjs";

const { session, marker, catalogPath } = await openLiveSession();
const source_id = requireFixtureId(marker, "arw_14bit");
const target_ids = ["wide_plain", "pano"].map((key) => requireFixtureId(marker, key));
const keys = ["Exposure2012", "Contrast2012"];
const tool = async (name, args) => (await session.toolOrThrow(name, args)).data;
const read = async (id) => {
  const row = await readFlushedSettings(session, id, source_id);
  return { row, settings: parseLuaTable(row.text.slice(row.text.indexOf("{"))) };
};
const originals = new Map();
let failure;
try {
  for (const id of [source_id, ...target_ids]) {
    const metadata = await tool("get_photo_metadata", { photo_id: id, sections: ["developSettings"] });
    originals.set(id, {
      Exposure2012: metadata.developSettings.exposure,
      Contrast2012: metadata.developSettings.contrast,
    });
  }
  await tool("set_develop_settings", { photo_id: source_id, settings: { Exposure2012: 0.5, Contrast2012: 10 } });
  for (const photo_id of target_ids) {
    await tool("set_develop_settings", { photo_id, settings: { Exposure2012: 0, Contrast2012: 0 } });
  }
  const before = new Map();
  for (const id of target_ids) before.set(id, { ...await read(id), history: developHistory(catalogPath, id) });
  const args = { source_id, target_ids, settings: keys };
  const preview = await tool("copy_develop_settings", { ...args, dry_run: true });
  assert.equal(preview.dry_run, true);
  assert.equal(preview.detail_truncated, false);
  for (const id of target_ids) {
    assert.deepEqual((await read(id)).row, before.get(id).row, "dry run changed stored row");
    assert.deepEqual(developHistory(catalogPath, id), before.get(id).history, "dry run changed History");
    const detail = preview.details.find((entry) => entry.id === String(id));
    assert.deepEqual(detail.changes.map((change) => change.key).sort(), [...keys].sort());
  }
  await tool("copy_develop_settings", args);
  for (const id of target_ids) {
    const after = (await read(id)).settings;
    const prior = before.get(id).settings;
    const changed = [...new Set([...Object.keys(prior), ...Object.keys(after)])]
      .filter((key) => !isDeepStrictEqual(prior[key], after[key])).sort();
    const detail = preview.details.find((entry) => entry.id === String(id));
    assert.deepEqual(changed, detail.changes.map((change) => change.key).sort(), "real copy differs from preview");
    for (const change of detail.changes) {
      assert.deepEqual(prior[change.key], change.before);
      assert.deepEqual(after[change.key], change.after);
    }
  }
  console.log("PASS dry-run stored rows and History unchanged; real copy matches every listed setting");
} catch (error) {
  failure = error;
} finally {
  try {
    for (const [photo_id, settings] of originals) await tool("set_develop_settings", { photo_id, settings });
    for (const photo_id of target_ids) {
      const restored = (await read(photo_id)).settings;
      for (const key of keys) assert.deepEqual(restored[key], originals.get(photo_id)[key]);
    }
  } catch (cleanupError) {
    failure = failure ? new AggregateError([failure, cleanupError], "Dry-run check and cleanup failed") : cleanupError;
  } finally {
    await session.stop();
  }
}
if (failure) throw failure;
