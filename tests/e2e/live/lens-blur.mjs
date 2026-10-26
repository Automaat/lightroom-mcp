#!/usr/bin/env node
import assert from "node:assert/strict";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { measureChange, maxLuminanceDifference } from "./lib/preview.mjs";

const { session, marker } = await openLiveSession();
let copyId;

async function tool(name, args) {
  const answer = await session.tool(name, args);
  assert.equal(answer.isError, false, answer.text);
  return answer.data;
}

try {
  const initialSelection = await tool("get_selected_photos", {});
  const copies = await tool("create_virtual_copies", {
    photo_ids: [requireFixtureId(marker, "arw_14bit")], copy_name: "LRMCP Lens Blur live test",
  });
  copyId = copies.copies[0].copy_id;
  await tool("set_lens_blur", { photo_id: copyId, active: false });
  const off = await tool("get_lens_blur", { photo_id: copyId });
  assert.equal(off.active, false);
  const pixels = await measureChange(session, copyId, async () => {
    const enabled = await tool("set_lens_blur", { photo_id: copyId, amount: 50 });
    assert.equal(enabled.active, true);
    assert.equal(enabled.amount, 50);
  });
  const difference = maxLuminanceDifference(pixels.before, pixels.after);
  assert.ok(difference > 0.01, `Lens Blur preview did not change: ${difference}`);
  await tool("get_lens_blur", { photo_id: requireFixtureId(marker, "wide_plain") });
  const saved = await tool("get_lens_blur", { photo_id: copyId });
  assert.equal(saved.active, true);
  assert.equal(saved.amount, 50);
  const adjusted = await tool("set_lens_blur", { photo_id: copyId, cat_eye: 20,
    highlights_boost: 30, focal_range: { near: 10, far: 30 }, bokeh: "Ring" });
  assert.equal(adjusted.cat_eye, 20);
  assert.equal(adjusted.highlights_boost, 30);
  assert.deepEqual(adjusted.focal_range, { near: 10, far: 30 });
  assert.equal(adjusted.bokeh, "Ring");
  const selection = await tool("get_selected_photos", {});
  assert.deepEqual(selection, initialSelection);
  console.log(JSON.stringify({ copyId, off, saved, adjusted, difference }));
} finally {
  try {
    if (copyId) await tool("remove_photos_from_catalog", { photo_ids: [copyId], confirm: true });
  } finally {
    await session.stop();
  }
}
