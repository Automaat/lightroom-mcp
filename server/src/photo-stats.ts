import jpeg from "jpeg-js";
import type { CallOptions, Dispatcher } from "./dispatcher.js";

const BINS = 64;
const LONG_EDGE = 512;
const rounded = (value: number) => Math.round(value * 1e6) / 1e6;

export function photoStats(encoded: string) {
  const image = jpeg.decode(Buffer.from(encoded, "base64"), {
    useTArray: true, formatAsRGBA: false, maxResolutionInMP: 16, maxMemoryUsageInMB: 128,
  });
  const { width, height, data } = image;
  const luma = new Float64Array(width * height);
  const histogram = Array<number>(BINS).fill(0);
  let shadows = 0, highlights = 0, sum = 0;
  for (let i = 0; i < luma.length; i++) {
    const value = 0.2126 * data[i * 3] + 0.7152 * data[i * 3 + 1] + 0.0722 * data[i * 3 + 2];
    luma[i] = value;
    histogram[Math.min(BINS - 1, Math.floor(value / 4))]++;
    if (value <= 1) shadows++;
    if (value >= 254) highlights++;
    sum += value;
  }
  const scale = LONG_EDGE / Math.max(width, height);
  const targetWidth = Math.max(3, Math.round(width * scale));
  const targetHeight = Math.max(3, Math.round(height * scale));
  const resized = new Float64Array(targetWidth * targetHeight);
  const dx = width / targetWidth, dy = height / targetHeight;
  for (let y = 0; y < targetHeight; y++) {
    for (let x = 0; x < targetWidth; x++) {
      let total = 0;
      for (let sy = Math.floor(y * dy); sy < Math.ceil((y + 1) * dy); sy++) {
        const wy = Math.min(sy + 1, (y + 1) * dy) - Math.max(sy, y * dy);
        for (let sx = Math.floor(x * dx); sx < Math.ceil((x + 1) * dx); sx++) {
          const wx = Math.min(sx + 1, (x + 1) * dx) - Math.max(sx, x * dx);
          total += luma[Math.min(height - 1, sy) * width + Math.min(width - 1, sx)] * wx * wy;
        }
      }
      resized[y * targetWidth + x] = total / (dx * dy);
    }
  }
  let laplacianSum = 0, squares = 0, count = 0;
  for (let y = 1; y < targetHeight - 1; y++) {
    for (let x = 1; x < targetWidth - 1; x++) {
      const i = y * targetWidth + x;
      const value = resized[i - 1] + resized[i + 1] + resized[i - targetWidth]
        + resized[i + targetWidth] - 4 * resized[i];
      laplacianSum += value;
      squares += value * value;
      count++;
    }
  }
  return {
    width, height,
    histogram: histogram.map((value) => rounded(value / luma.length)),
    mean_luminance: rounded(sum / luma.length),
    shadow_fraction: rounded(shadows / luma.length),
    highlight_fraction: rounded(highlights / luma.length),
    sharpness: rounded(Math.max(0, squares / count - (laplacianSum / count) ** 2)),
  };
}

export async function getPhotoStats(
  dispatcher: Pick<Dispatcher, "call">,
  photoIds: (string | number)[],
  options?: CallOptions,
) {
  const results = [];
  for (const photoId of photoIds) {
    if (options?.signal?.aborted) throw new Error("Request cancelled");
    try {
      const response = await dispatcher.call("get_photo_stats", { photo_ids: [photoId] }, undefined, options);
      if (response.error) throw new Error(response.error);
      const preview = response.result as { image?: { data?: unknown; mime_type?: unknown } } | undefined;
      if (preview?.image?.mime_type !== "image/jpeg" || typeof preview.image.data !== "string") {
        throw new Error("Plugin returned no JPEG preview");
      }
      results.push({ photo_id: photoId, ...photoStats(preview.image.data) });
    } catch (error) {
      if (options?.signal?.aborted) throw new Error("Request cancelled");
      results.push({ photo_id: photoId, error: error instanceof Error ? error.message : String(error) });
    }
  }
  return { results };
}
