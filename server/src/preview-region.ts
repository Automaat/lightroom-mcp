import jpeg from "jpeg-js";

export interface PreviewRegion {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface PreviewArgs {
  photo_id: string | number;
  size?: number;
  region?: PreviewRegion;
}

const MAX_BYTES = 3.5 * 1024 * 1024;
const MAX_EDGE = 2000;

export function regionRenderArgs({ region, ...args }: PreviewArgs): Omit<PreviewArgs, "region"> {
  if (!region) return args;
  return { ...args, size: Math.min(2048, Math.ceil((args.size ?? 512) / Math.max(region.width, region.height))) };
}

export function cropPreview(result: unknown, region: PreviewRegion): unknown {
  const preview = result as { image?: { data?: unknown; mime_type?: unknown } } | null;
  if (preview?.image?.mime_type !== "image/jpeg" || typeof preview.image.data !== "string") {
    throw new Error("Region preview requires a JPEG from Lightroom");
  }
  const encoded = Buffer.from(preview.image.data, "base64");
  if (encoded.length > MAX_BYTES) throw new Error("Region source preview exceeds the 3.5 MiB byte limit");
  const source = jpeg.decode(encoded, {
    useTArray: true, formatAsRGBA: true, maxResolutionInMP: 4, maxMemoryUsageInMB: 128,
  });
  if (Math.max(source.width, source.height) > MAX_EDGE) {
    throw new Error("Region source preview exceeds the 2000 pixel edge limit");
  }
  const left = Math.floor(region.x * source.width);
  const top = Math.floor(region.y * source.height);
  const right = Math.min(source.width, Math.max(left + 1, Math.ceil((region.x + region.width) * source.width)));
  const bottom = Math.min(source.height, Math.max(top + 1, Math.ceil((region.y + region.height) * source.height)));
  const width = right - left, height = bottom - top;
  const data = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y++) {
    const start = ((top + y) * source.width + left) * 4;
    data.set(source.data.subarray(start, start + width * 4), y * width * 4);
  }
  for (const quality of [90, 80, 70, 60, 50, 40, 30]) {
    const cropped = jpeg.encode({ width, height, data }, quality).data;
    if (cropped.length <= MAX_BYTES) {
      return { ...preview, width, height, bytes: cropped.length,
        image: { mime_type: "image/jpeg", data: cropped.toString("base64") } };
    }
  }
  throw new Error("Region preview exceeds the 3.5 MiB byte limit");
}
