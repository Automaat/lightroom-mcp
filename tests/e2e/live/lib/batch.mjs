import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const DEFAULT_BATCH_COUNT = 200;
export const BATCH_BASE_LONG_EDGE = 1600;
export const BATCH_CROP_WIDTH = 1200;
export const BATCH_CROP_HEIGHT = 800;

export function batchFileName(index) {
  return `batch_${String(index + 1).padStart(3, "0")}.jpg`;
}

export function batchCropOffsets(count, maxOffsetX, maxOffsetY) {
  const columns = Math.ceil(Math.sqrt((count * (maxOffsetX + 1)) / (maxOffsetY + 1)));
  const rows = Math.ceil(count / columns);
  const offsets = [];
  for (let row = 0; row < rows && offsets.length < count; row++) {
    for (let column = 0; column < columns && offsets.length < count; column++) {
      offsets.push({
        x: columns === 1 ? 0 : Math.round((column * maxOffsetX) / (columns - 1)),
        y: rows === 1 ? 0 : Math.round((row * maxOffsetY) / (rows - 1)),
      });
    }
  }
  return offsets;
}

export function generateBatchImages({ rawPath, outputDirectory, count = DEFAULT_BATCH_COUNT }) {
  if (process.platform !== "darwin") throw new Error("batch images are cut with sips and need macOS");
  fs.mkdirSync(outputDirectory, { recursive: true });
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "lrmcp-batch-"));
  try {
    const basePath = path.join(scratch, "base.jpg");
    execFileSync(
      "sips",
      ["-Z", String(BATCH_BASE_LONG_EDGE), "-s", "format", "jpeg", "-s", "formatOptions", "85", rawPath, "--out", basePath],
      { stdio: "ignore" },
    );
    const info = execFileSync("sips", ["-g", "pixelWidth", "-g", "pixelHeight", basePath], { encoding: "utf8" });
    const baseWidth = Number(/pixelWidth: (\d+)/.exec(info)[1]);
    const baseHeight = Number(/pixelHeight: (\d+)/.exec(info)[1]);
    const offsets = batchCropOffsets(count, baseWidth - BATCH_CROP_WIDTH, baseHeight - BATCH_CROP_HEIGHT);
    offsets.forEach(({ x, y }, index) => {
      execFileSync(
        "sips",
        [
          "-c", String(BATCH_CROP_HEIGHT), String(BATCH_CROP_WIDTH),
          "--cropOffset", String(y), String(x),
          basePath,
          "--out", path.join(outputDirectory, batchFileName(index)),
        ],
        { stdio: "ignore" },
      );
    });
    return offsets.length;
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}
