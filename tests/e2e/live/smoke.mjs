#!/usr/bin/env node
import { ensureLightroomFrontmost, closePluginManager, dismissBlockingModals } from "./lib/ax.mjs";
import { requireThrowawayCatalog } from "./lib/catalog-guard.mjs";
import { readFlushedSettings, storedMaskGroups, summarizeMaskGroups } from "./lib/catalog-db.mjs";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { ORIENTATIONS, classifyOrientation, sampleCorners } from "./lib/patterns.mjs";
import {
  describeSizes,
  ellipseInside,
  fetchStablePixels,
  intersectionOverUnion,
  measureChange,
  regionDeltas,
} from "./lib/preview.mjs";

const MIN_EXPECTED_BRIGHTENING = 0.05;
const MAX_EXPECTED_UNTOUCHED_CHANGE = 0.01;
const MIN_RADIAL_IOU = 0.8;
const EXPOSURE_STOPS = 2;

const failures = [];
function check(label, passed, detail) {
  console.log(`${passed ? "pass" : "FAIL"} ${label} ${JSON.stringify(detail)}`);
  if (!passed) failures.push(label);
}

requireThrowawayCatalog();
await ensureLightroomFrontmost();
await dismissBlockingModals();
await closePluginManager();

const { session, marker } = await openLiveSession();
const rotatedId = requireFixtureId(marker, "orient_6");
const wideId = requireFixtureId(marker, "wide_plain");

async function addExposureMask(photoId, create) {
  const created = await session.toolOrThrow("create_gradient_mask", { photo_id: photoId, ...create });
  await session.toolOrThrow("set_mask_adjustments", {
    photo_id: photoId,
    mask_id: created.data.mask_id,
    adjustments: { local_Exposure: EXPOSURE_STOPS },
  });
  return created.data;
}

try {
  await session.toolOrThrow("delete_masks", { photo_id: rotatedId, all: true });
  await session.toolOrThrow("delete_masks", { photo_id: wideId, all: true });

  const shown = {};
  for (const orientation of ORIENTATIONS) {
    const pixels = await fetchStablePixels(session, requireFixtureId(marker, `orient_${orientation}`));
    shown[orientation] = classifyOrientation(sampleCorners(pixels)).orientation;
  }
  check(
    "previews show orient_1..8 with the orientation of their EXIF tag",
    ORIENTATIONS.every((orientation) => shown[orientation] === orientation),
    shown,
  );

  const listed = await session.toolOrThrow("list_masks", { photo_id: rotatedId });
  check("list_masks answers on the rotated photo", Array.isArray(listed.data.masks), { masks: listed.data.masks?.length });

  const rotated = await measureChange(session, rotatedId, () =>
    addExposureMask(rotatedId, { shape: "linear", start: { x: 0.5, y: 0.05 }, end: { x: 0.5, y: 0.45 } }),
  );
  const rotatedDeltas = regionDeltas(rotated.before, rotated.after, [
    { name: "top", x0: 0.3, y0: 0, x1: 0.7, y1: 0.08 },
    { name: "bottom", x0: 0.3, y0: 0.6, x1: 0.7, y1: 1 },
  ]);
  check(
    "linear gradient on orient_6 brightens the displayed top only",
    rotatedDeltas.top > MIN_EXPECTED_BRIGHTENING && Math.abs(rotatedDeltas.bottom) < MAX_EXPECTED_UNTOUCHED_CHANGE,
    { ...rotatedDeltas, ...describeSizes(rotated.before, rotated.after) },
  );

  const radial = { center: { x: 0.5, y: 0.5 }, width: 0.4, height: 0.3, rotation: 30, feather: 0 };
  const wide = await measureChange(session, wideId, () => addExposureMask(wideId, { shape: "radial", ...radial }));
  const iou = intersectionOverUnion(
    wide.before,
    wide.after,
    ellipseInside({ center: radial.center, width: radial.width, height: radial.height, rotationDegrees: radial.rotation }),
  );
  check("radial gradient on wide_plain matches the analytic ellipse", iou >= MIN_RADIAL_IOU, { iou: Number(iou.toFixed(3)), ...describeSizes(wide.before, wide.after) });

  const stored = await readFlushedSettings(session, rotatedId, wideId);
  const groups = summarizeMaskGroups(storedMaskGroups(stored.text));
  check("stored develop row holds the gradient mask", groups.length === 1 && groups[0].components.length === 1, groups);
} finally {
  await session.tool("delete_masks", { photo_id: rotatedId, all: true });
  await session.tool("delete_masks", { photo_id: wideId, all: true });
  await session.stop();
}

if (failures.length > 0) {
  console.error(`failed: ${failures.join("; ")}`);
  process.exit(1);
}
console.log("kit smoke passed");
