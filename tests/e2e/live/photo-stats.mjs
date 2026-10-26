#!/usr/bin/env node
import assert from "node:assert/strict";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";

const { session, marker } = await openLiveSession();
try {
  const rampId = requireFixtureId(marker, "ramp256");
  const plainId = requireFixtureId(marker, "wide_plain");
  const response = await session.toolOrThrow("get_photo_stats", { photo_ids: [rampId, plainId] });
  const [ramp, plain] = response.data.results;
  assert.equal(ramp.photo_id, rampId);
  assert.equal(plain.photo_id, plainId);
  assert.equal(ramp.error, undefined);
  assert.equal(plain.error, undefined);
  const quarters = Array.from({ length: 4 }, (_, quarter) =>
    ramp.histogram.slice(quarter * 16, (quarter + 1) * 16).reduce((sum, mass) => sum + mass, 0));
  for (const mass of quarters) assert.ok(Math.abs(mass - 0.25) <= 0.05, JSON.stringify({ quarters }));
  assert.ok(Math.abs(plain.mean_luminance - 110) <= 4, JSON.stringify(plain));
  assert.equal(plain.shadow_fraction, 0);
  assert.equal(plain.highlight_fraction, 0);
  console.log(JSON.stringify({ quarters, plain, catalogUnchanged: true }, null, 2));
} finally {
  await session.stop();
}
