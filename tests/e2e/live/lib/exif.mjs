const SOI = 0xffd8;
const APP1 = 0xffe1;
const SOS = 0xffda;
const EXIF_HEADER = Buffer.from("Exif\0\0", "ascii");
const ORIENTATION_TAG = 0x0112;
const SHORT_TYPE = 3;

export function buildExifOrientationSegment(orientation) {
  if (!Number.isInteger(orientation) || orientation < 1 || orientation > 8) {
    throw new Error(`orientation must be 1..8, got ${orientation}`);
  }
  const tiff = Buffer.alloc(26);
  tiff.write("MM", 0, "ascii");
  tiff.writeUInt16BE(42, 2);
  tiff.writeUInt32BE(8, 4);
  tiff.writeUInt16BE(1, 8);
  tiff.writeUInt16BE(ORIENTATION_TAG, 10);
  tiff.writeUInt16BE(SHORT_TYPE, 12);
  tiff.writeUInt32BE(1, 14);
  tiff.writeUInt16BE(orientation, 18);
  const payload = Buffer.concat([EXIF_HEADER, tiff]);
  const head = Buffer.alloc(4);
  head.writeUInt16BE(APP1, 0);
  head.writeUInt16BE(payload.length + 2, 2);
  return Buffer.concat([head, payload]);
}

function* segments(jpeg) {
  if (jpeg.readUInt16BE(0) !== SOI) throw new Error("not a JPEG");
  let offset = 2;
  while (offset + 4 <= jpeg.length) {
    const marker = jpeg.readUInt16BE(offset);
    if (marker === SOS) return;
    const length = jpeg.readUInt16BE(offset + 2);
    yield { marker, start: offset, end: offset + 2 + length };
    offset += 2 + length;
  }
}

function isExifSegment(jpeg, segment) {
  return segment.marker === APP1 && jpeg.subarray(segment.start + 4, segment.start + 10).equals(EXIF_HEADER);
}

export function injectExifOrientation(jpeg, orientation) {
  const kept = [];
  let cursor = 2;
  for (const segment of segments(jpeg)) {
    if (!isExifSegment(jpeg, segment)) continue;
    kept.push(jpeg.subarray(cursor, segment.start));
    cursor = segment.end;
  }
  kept.push(jpeg.subarray(cursor));
  return Buffer.concat([jpeg.subarray(0, 2), buildExifOrientationSegment(orientation), ...kept]);
}

export function readJpegOrientation(jpeg) {
  for (const segment of segments(jpeg)) {
    if (!isExifSegment(jpeg, segment)) continue;
    const tiff = jpeg.subarray(segment.start + 10, segment.end);
    const littleEndian = tiff.toString("ascii", 0, 2) === "II";
    const u16 = (at) => (littleEndian ? tiff.readUInt16LE(at) : tiff.readUInt16BE(at));
    const u32 = (at) => (littleEndian ? tiff.readUInt32LE(at) : tiff.readUInt32BE(at));
    const entryCount = u16(u32(4));
    for (let i = 0; i < entryCount; i++) {
      const entry = u32(4) + 2 + i * 12;
      if (u16(entry) === ORIENTATION_TAG) return u16(entry + 8);
    }
  }
  return null;
}
