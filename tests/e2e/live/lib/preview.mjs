import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export const SETTLE_MS = 3500;
export const STABLE_PIXEL_TOLERANCE = 0.01;

export function decodeBmp(bmp) {
  const dataOffset = bmp.readUInt32LE(10);
  const width = bmp.readInt32LE(18);
  const signedHeight = bmp.readInt32LE(22);
  const topDown = signedHeight < 0;
  const height = Math.abs(signedHeight);
  const bytesPerPixel = bmp.readUInt16LE(28) / 8;
  const stride = Math.ceil((width * bytesPerPixel) / 4) * 4;
  const R = new Float32Array(width * height);
  const G = new Float32Array(width * height);
  const B = new Float32Array(width * height);
  const L = new Float32Array(width * height);
  for (let y = 0; y < height; y++) {
    const row = topDown ? y : height - 1 - y;
    for (let x = 0; x < width; x++) {
      const at = dataOffset + row * stride + x * bytesPerPixel;
      const i = y * width + x;
      B[i] = bmp[at] / 255;
      G[i] = bmp[at + 1] / 255;
      R[i] = bmp[at + 2] / 255;
      L[i] = 0.299 * R[i] + 0.587 * G[i] + 0.114 * B[i];
    }
  }
  return { w: width, h: height, R, G, B, L };
}

export function decodeJpegBase64(base64) {
  if (process.platform !== "darwin") throw new Error("preview decoding uses sips and needs macOS");
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "lrmcp-preview-"));
  try {
    const jpegPath = path.join(scratch, "preview.jpg");
    const bmpPath = path.join(scratch, "preview.bmp");
    fs.writeFileSync(jpegPath, Buffer.from(base64, "base64"));
    execFileSync("sips", ["-s", "format", "bmp", jpegPath, "--out", bmpPath], { stdio: "ignore" });
    return decodeBmp(fs.readFileSync(bmpPath));
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

export async function fetchPixels(session, photoId, size = 512) {
  const answer = await session.tool("get_photo_preview", { photo_id: photoId, size });
  if (answer.isError || !answer.image) throw new Error(`get_photo_preview: ${answer.text}`);
  return decodeJpegBase64(answer.image.data);
}

export function maxLuminanceDifference(a, b, step = 7) {
  let max = 0;
  for (let i = 0; i < a.L.length; i += step) max = Math.max(max, Math.abs(a.L[i] - b.L[i]));
  return max;
}

export function describeSizes(before, after) {
  return { before: `${before.w}x${before.h}`, after: `${after.w}x${after.h}` };
}

export async function fetchStablePixels(session, photoId, { size = 512, tries = 8, pauseMs = 1500 } = {}) {
  let previous = null;
  for (let attempt = 0; attempt < tries; attempt++) {
    const current = await fetchPixels(session, photoId, size);
    if (
      previous &&
      previous.w === current.w &&
      previous.h === current.h &&
      maxLuminanceDifference(previous, current) < STABLE_PIXEL_TOLERANCE
    ) {
      return current;
    }
    previous = current;
    await sleep(pauseMs);
  }
  throw new Error(`preview of ${photoId} did not stabilise in ${tries} fetches`);
}

export async function measureChange(session, photoId, applyChange, { size = 512, settleMs = SETTLE_MS } = {}) {
  const before = await fetchStablePixels(session, photoId, { size });
  await applyChange();
  await sleep(settleMs);
  const after = await fetchStablePixels(session, photoId, { size });
  return { before, after };
}

function nearestIndex(pixels, fx, fy) {
  const x = Math.min(pixels.w - 1, Math.max(0, Math.floor(fx * pixels.w)));
  const y = Math.min(pixels.h - 1, Math.max(0, Math.floor(fy * pixels.h)));
  return y * pixels.w + x;
}

function meanDelta(before, after, channel, { x0, y0, x1, y1 }) {
  let sum = 0;
  let count = 0;
  for (let y = Math.floor(y0 * after.h); y < Math.floor(y1 * after.h); y++) {
    for (let x = Math.floor(x0 * after.w); x < Math.floor(x1 * after.w); x++) {
      const fx = (x + 0.5) / after.w;
      const fy = (y + 0.5) / after.h;
      sum += after[channel][y * after.w + x] - before[channel][nearestIndex(before, fx, fy)];
      count++;
    }
  }
  return count === 0 ? 0 : sum / count;
}

export function regionDeltas(before, after, regions) {
  return Object.fromEntries(regions.map((region) => [region.name, meanDelta(before, after, "L", region)]));
}

export function bandDeltas(before, after, bands = 10) {
  const rows = Array.from({ length: bands }, (_, i) => ({ name: `row${i}`, x0: 0, y0: i / bands, x1: 1, y1: (i + 1) / bands }));
  const columns = Array.from({ length: bands }, (_, i) => ({ name: `col${i}`, x0: i / bands, y0: 0, x1: (i + 1) / bands, y1: 1 }));
  return {
    rows: Object.values(regionDeltas(before, after, rows)),
    columns: Object.values(regionDeltas(before, after, columns)),
  };
}

export function patchDeltas(before, after, centers, halfSizeFraction = 0.02) {
  return centers.map(({ x, y }) => {
    const region = { x0: x - halfSizeFraction, y0: y - halfSizeFraction, x1: x + halfSizeFraction, y1: y + halfSizeFraction };
    return {
      x,
      y,
      deltaL: meanDelta(before, after, "L", region),
      deltaR: meanDelta(before, after, "R", region),
      deltaG: meanDelta(before, after, "G", region),
      deltaB: meanDelta(before, after, "B", region),
    };
  });
}

export function ellipseInside({ center, width, height, rotationDegrees = 0 }) {
  const radians = (rotationDegrees * Math.PI) / 180;
  const cos = Math.cos(radians);
  const sin = Math.sin(radians);
  return (fx, fy, imageWidth, imageHeight) => {
    const dx = (fx - center.x) * imageWidth;
    const dy = (fy - center.y) * imageHeight;
    const localX = dx * cos + dy * sin;
    const localY = -dx * sin + dy * cos;
    const a = (width * imageWidth) / 2;
    const b = (height * imageHeight) / 2;
    return (localX / a) ** 2 + (localY / b) ** 2 <= 1;
  };
}

export function rectangleInside({ x0, y0, x1, y1 }) {
  return (fx, fy) => fx >= x0 && fx < x1 && fy >= y0 && fy < y1;
}

export function intersectionOverUnion(before, after, inside, { threshold = 0.04, direction = "brighter" } = {}) {
  let intersection = 0;
  let union = 0;
  for (let y = 0; y < after.h; y++) {
    for (let x = 0; x < after.w; x++) {
      const fx = (x + 0.5) / after.w;
      const fy = (y + 0.5) / after.h;
      const delta = after.L[y * after.w + x] - before.L[nearestIndex(before, fx, fy)];
      const changed = direction === "brighter" ? delta > threshold : direction === "darker" ? delta < -threshold : Math.abs(delta) > threshold;
      const within = inside(fx, fy, after.w, after.h);
      if (within && changed) intersection++;
      if (within || changed) union++;
    }
  }
  return union === 0 ? 0 : intersection / union;
}
