#!/usr/bin/env node
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { GENERATED_DIR } from "./lib/paths.mjs";
import { injectExifOrientation } from "./lib/exif.mjs";
import { encodeJpegWithSips } from "./lib/jpeg.mjs";
import { encodePng } from "./lib/png.mjs";
import {
  ORIENTATIONS,
  buildChart80,
  buildOrientationPattern,
  buildPano,
  buildRamp256,
  buildWidePlain,
} from "./lib/patterns.mjs";

const skipJpeg = process.argv.includes("--png-only");

fs.mkdirSync(GENERATED_DIR, { recursive: true });
const index = {};

function write(key, fileName, buffer, details) {
  const filePath = path.join(GENERATED_DIR, fileName);
  fs.writeFileSync(filePath, buffer);
  index[key] = {
    file: fileName,
    bytes: buffer.length,
    sha256: createHash("sha256").update(buffer).digest("hex"),
    ...details,
  };
  console.log(`${key}: ${filePath}`);
}

const chart80 = buildChart80();
write("chart80", "chart80.png", encodePng(chart80), { width: chart80.width, height: chart80.height });
const ramp256 = buildRamp256();
write("ramp256", "ramp256.png", encodePng(ramp256), { width: ramp256.width, height: ramp256.height });

if (skipJpeg) {
  fs.writeFileSync(path.join(GENERATED_DIR, "generated.json"), JSON.stringify(index, null, 2) + "\n");
  process.exit(0);
}

const widePlain = buildWidePlain();
write("wide_plain", "wide_plain.jpg", encodeJpegWithSips(widePlain), { width: widePlain.width, height: widePlain.height });
const pano = buildPano();
write("pano", "pano.jpg", encodeJpegWithSips(pano), { width: pano.width, height: pano.height });

const orientationPattern = buildOrientationPattern();
const orientationJpeg = encodeJpegWithSips(orientationPattern);
for (const orientation of ORIENTATIONS) {
  write(`orient_${orientation}`, `orient_${orientation}.jpg`, injectExifOrientation(orientationJpeg, orientation), {
    storedWidth: orientationPattern.width,
    storedHeight: orientationPattern.height,
    exifOrientation: orientation,
  });
}

fs.writeFileSync(path.join(GENERATED_DIR, "generated.json"), JSON.stringify(index, null, 2) + "\n");
