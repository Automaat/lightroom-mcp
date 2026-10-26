import jpeg from "jpeg-js";
import type { CallOptions, Dispatcher } from "./dispatcher.js";

type PhotoId = string | number;
export interface DuplicateGroupArgs {
  photo_ids: PhotoId[];
  time_window_seconds?: number;
  max_hamming_distance?: number;
}
interface Sample { photo_id: PhotoId; capture_time: number; hash: boolean[] }

function hashPreview(encoded: string): boolean[] {
  const { width, height, data } = jpeg.decode(Buffer.from(encoded, "base64"), {
    useTArray: true, formatAsRGBA: false, maxResolutionInMP: 16, maxMemoryUsageInMB: 128,
  });
  const cells = new Float64Array(72);
  const dx = width / 9, dy = height / 8;
  for (let y = 0; y < 8; y++) {
    for (let x = 0; x < 9; x++) {
      let total = 0;
      for (let sy = Math.floor(y * dy); sy < Math.ceil((y + 1) * dy); sy++) {
        const wy = Math.min(sy + 1, (y + 1) * dy) - Math.max(sy, y * dy);
        for (let sx = Math.floor(x * dx); sx < Math.ceil((x + 1) * dx); sx++) {
          const wx = Math.min(sx + 1, (x + 1) * dx) - Math.max(sx, x * dx);
          const i = (Math.min(height - 1, sy) * width + Math.min(width - 1, sx)) * 3;
          total += (0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2]) * wx * wy;
        }
      }
      cells[y * 9 + x] = total / (dx * dy);
    }
  }
  return Array.from({ length: 64 }, (_, i) => {
    const offset = Math.floor(i / 8) * 9 + i % 8;
    return cells[offset] > cells[offset + 1];
  });
}

export async function findDuplicateGroups(
  dispatcher: Pick<Dispatcher, "call">, args: DuplicateGroupArgs, options?: CallOptions,
) {
  const deadline = performance.now() + 25_000;
  const window = args.time_window_seconds ?? 5;
  const distance = args.max_hamming_distance ?? 10;
  const samples: Sample[][] = [];
  const unprocessed: { photo_id: PhotoId; reason: string }[] = [];
  const ids = [...new Map(args.photo_ids.map(id => [String(id), id])).values()];
  let reached = 0;
  for (; reached < ids.length; reached++) {
    if (options?.signal?.aborted) throw new Error("Request cancelled");
    const remaining = deadline - performance.now();
    if (remaining <= 0) break;
    const photoId = ids[reached];
    try {
      const response = await dispatcher.call("find_duplicate_groups", { photo_ids: [photoId] }, remaining, options);
      if (performance.now() >= deadline) break;
      if (response.error) throw new Error(response.error);
      const result = response.result as { photo_id?: PhotoId; capture_time?: unknown; image?: { data?: unknown; mime_type?: unknown } } | undefined;
      if (typeof result?.capture_time !== "number" || !Number.isFinite(result.capture_time)) {
        throw new Error("No raw capture time");
      }
      if (result.image?.mime_type !== "image/jpeg" || typeof result.image.data !== "string") {
        throw new Error("Plugin returned no JPEG preview");
      }
      const sample: Sample = { photo_id: result.photo_id ?? photoId, capture_time: result.capture_time, hash: hashPreview(result.image.data) };
      if (samples.some(group => group.some(member => String(member.photo_id) === String(sample.photo_id)))) continue;
      const group = samples.find(group => group.every(member =>
        Math.abs(member.capture_time - sample.capture_time) <= window
        && member.hash.reduce((sum, bit, i) => sum + Number(bit !== sample.hash[i]), 0) <= distance));
      if (group) group.push(sample);
      else samples.push([sample]);
    } catch (error) {
      if (options?.signal?.aborted) throw new Error("Request cancelled");
      if (performance.now() >= deadline) break;
      unprocessed.push({ photo_id: photoId, reason: error instanceof Error ? error.message : String(error) });
    }
  }
  return {
    groups: samples.filter(group => group.length >= 2).map(group => ({ photo_ids: group.map(sample => sample.photo_id) })),
    photos: samples.flat().map(({ photo_id, capture_time }) => ({ photo_id, capture_time })),
    unprocessed, complete: reached === ids.length, remaining_ids: ids.slice(reached),
    time_window_seconds: window, max_hamming_distance: distance,
  };
}
