#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { GENERATED_DIR } from "./lib/paths.mjs";
import { readJpegOrientation } from "./lib/exif.mjs";
import { decodePng } from "./lib/png.mjs";
import {
  CHART80_LAYOUT,
  RAMP256_LAYOUT,
  chart80Patches,
  pixelAt,
  ramp256Patches,
} from "./lib/patterns.mjs";

const problems = [];

function expectEqual(label, actual, expected) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    problems.push(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function checkPatchChart(fileName, layout, patches) {
  const filePath = path.join(GENERATED_DIR, fileName);
  if (!fs.existsSync(filePath)) {
    problems.push(`${fileName}: missing, run generate-fixtures.mjs`);
    return;
  }
  const png = decodePng(fs.readFileSync(filePath));
  expectEqual(`${fileName} width`, png.width, layout.columns * layout.patchSize);
  expectEqual(`${fileName} height`, png.height, layout.rows * layout.patchSize);
  patches.forEach((color, index) => {
    const x = (index % layout.columns) * layout.patchSize + layout.patchSize / 2;
    const y = Math.floor(index / layout.columns) * layout.patchSize + layout.patchSize / 2;
    expectEqual(`${fileName} patch ${index}`, pixelAt(png, x, y), color);
  });
}

checkPatchChart("chart80.png", CHART80_LAYOUT, chart80Patches());
checkPatchChart("ramp256.png", RAMP256_LAYOUT, ramp256Patches());

for (const orientation of [1, 2, 3, 4, 5, 6, 7, 8]) {
  const filePath = path.join(GENERATED_DIR, `orient_${orientation}.jpg`);
  if (!fs.existsSync(filePath)) {
    problems.push(`orient_${orientation}.jpg: missing, run generate-fixtures.mjs`);
    continue;
  }
  expectEqual(`orient_${orientation}.jpg exif orientation`, readJpegOrientation(fs.readFileSync(filePath)), orientation);
}

for (const fileName of ["wide_plain.jpg", "pano.jpg"]) {
  if (!fs.existsSync(path.join(GENERATED_DIR, fileName))) problems.push(`${fileName}: missing, run generate-fixtures.mjs`);
}

if (problems.length > 0) {
  console.error(problems.join("\n"));
  process.exit(1);
}
console.log("generated fixtures verified");
