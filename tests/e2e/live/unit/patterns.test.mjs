import assert from "node:assert/strict";
import { test } from "node:test";
import {
  CHART80_LAYOUT,
  CORNER_COLORS,
  ORIENTATIONS,
  RAMP256_LAYOUT,
  applyOrientation,
  buildChart80,
  buildOrientationPattern,
  buildPano,
  buildRamp256,
  buildWidePlain,
  chart80Patches,
  classifyOrientation,
  displayedSize,
  expectedDisplayedCorners,
  hsvToRgb,
  patchCenterFraction,
  pixelAt,
  sampleCorners,
} from "../lib/patterns.mjs";
import { decodePng, encodePng } from "../lib/png.mjs";

function toFloatPixels(canvas, jitter = 0) {
  const count = canvas.width * canvas.height;
  const R = new Float32Array(count);
  const G = new Float32Array(count);
  const B = new Float32Array(count);
  for (let i = 0; i < count; i++) {
    R[i] = Math.min(1, Math.max(0, canvas.rgb[i * 3] / 255 + jitter));
    G[i] = Math.min(1, Math.max(0, canvas.rgb[i * 3 + 1] / 255 - jitter));
    B[i] = canvas.rgb[i * 3 + 2] / 255;
  }
  return { w: canvas.width, h: canvas.height, R, G, B };
}

test("png encoder round trips pixels exactly", () => {
  const canvas = buildChart80();
  const decoded = decodePng(encodePng(canvas));
  assert.equal(decoded.width, canvas.width);
  assert.equal(decoded.height, canvas.height);
  assert.deepEqual(decoded.rgb, canvas.rgb);
});

test("png decoder rejects a corrupted chunk", () => {
  const png = encodePng(buildWidePlain(8, 8));
  png[png.length - 20] ^= 0xff;
  assert.throws(() => decodePng(png), /bad crc/);
});

test("generators are deterministic", () => {
  assert.deepEqual(buildWidePlain().rgb, buildWidePlain().rgb);
  assert.deepEqual(buildPano().rgb, buildPano().rgb);
  assert.deepEqual(buildOrientationPattern().rgb, buildOrientationPattern().rgb);
});

test("wide_plain and pano have the documented sizes", () => {
  const wide = buildWidePlain();
  assert.deepEqual([wide.width, wide.height], [1000, 600]);
  const pano = buildPano();
  assert.equal(pano.width / pano.height, 10);
});

test("chart80 has 80 distinct patches with known colors", () => {
  const patches = chart80Patches();
  assert.equal(patches.length, 80);
  assert.equal(new Set(patches.map((patch) => patch.join(","))).size, 80);
  assert.deepEqual(patches[0], [255, 0, 0]);
  assert.deepEqual(patches[4], [0, 255, 0]);
  const canvas = buildChart80();
  patches.forEach((color, index) => {
    const center = patchCenterFraction(CHART80_LAYOUT, index);
    assert.deepEqual(pixelAt(canvas, Math.floor(center.x * canvas.width), Math.floor(center.y * canvas.height)), color);
  });
});

test("ramp256 patch i is gray level i", () => {
  const canvas = buildRamp256();
  for (const index of [0, 1, 127, 128, 254, 255]) {
    const center = patchCenterFraction(RAMP256_LAYOUT, index);
    assert.deepEqual(
      pixelAt(canvas, Math.floor(center.x * canvas.width), Math.floor(center.y * canvas.height)),
      [index, index, index],
    );
  }
});

test("hsv conversion hits the primaries", () => {
  assert.deepEqual(hsvToRgb(0, 1, 1), [255, 0, 0]);
  assert.deepEqual(hsvToRgb(120, 1, 1), [0, 255, 0]);
  assert.deepEqual(hsvToRgb(240, 1, 1), [0, 0, 255]);
  assert.deepEqual(hsvToRgb(360, 0, 0.5), [128, 128, 128]);
});

test("orientation 6 swaps the size and moves the stored top-left corner to the top-right", () => {
  assert.deepEqual(displayedSize(1000, 600, 6), { width: 600, height: 1000 });
  assert.deepEqual(displayedSize(1000, 600, 3), { width: 1000, height: 600 });
  const displayed = expectedDisplayedCorners(6);
  assert.deepEqual(displayed.topRight, CORNER_COLORS.topLeft);
  assert.deepEqual(displayed.bottomRight, CORNER_COLORS.topRight);
  assert.deepEqual(displayed.topLeft, CORNER_COLORS.bottomLeft);
});

test("orientations 2 and 4 mirror, 3 turns by 180 degrees", () => {
  assert.deepEqual(expectedDisplayedCorners(2).topLeft, CORNER_COLORS.topRight);
  assert.deepEqual(expectedDisplayedCorners(4).topLeft, CORNER_COLORS.bottomLeft);
  assert.deepEqual(expectedDisplayedCorners(3).topLeft, CORNER_COLORS.bottomRight);
});

test("all eight orientations show a different corner arrangement", () => {
  const arrangements = ORIENTATIONS.map((orientation) => JSON.stringify(expectedDisplayedCorners(orientation)));
  assert.equal(new Set(arrangements).size, 8);
});

test("a turned or mirrored result is never classified as the right orientation", () => {
  const pattern = buildOrientationPattern();
  for (const orientation of ORIENTATIONS) {
    const displayed = applyOrientation(pattern, orientation);
    const result = classifyOrientation(sampleCorners(toFloatPixels(displayed)));
    assert.equal(result.orientation, orientation);
    assert.ok(result.distance < result.runnerUpDistance / 4);
  }
});

test("classification survives preview color noise", () => {
  const pattern = buildOrientationPattern();
  for (const orientation of ORIENTATIONS) {
    const displayed = applyOrientation(pattern, orientation);
    assert.equal(classifyOrientation(sampleCorners(toFloatPixels(displayed, 0.03))).orientation, orientation);
  }
});

test("the F glyph breaks mirror symmetry inside the pattern", () => {
  const pattern = buildOrientationPattern();
  const mirrored = applyOrientation(pattern, 2);
  assert.notDeepEqual(mirrored.rgb, pattern.rgb);
  const turned = applyOrientation(applyOrientation(pattern, 3), 3);
  assert.deepEqual(turned.rgb, pattern.rgb);
});
