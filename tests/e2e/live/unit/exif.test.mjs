import assert from "node:assert/strict";
import { test } from "node:test";
import { buildExifOrientationSegment, injectExifOrientation, readJpegOrientation } from "../lib/exif.mjs";

const SOI = Buffer.from([0xff, 0xd8]);
const JFIF_SEGMENT = Buffer.from([0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x48, 0x00, 0x48, 0x00, 0x00]);
const START_OF_SCAN = Buffer.from([0xff, 0xda, 0x00, 0x02, 0x01, 0x02, 0x03, 0xff, 0xd9]);
const MINIMAL_JPEG = Buffer.concat([SOI, JFIF_SEGMENT, START_OF_SCAN]);

test("orientation written into a JPEG reads back", () => {
  for (let orientation = 1; orientation <= 8; orientation++) {
    assert.equal(readJpegOrientation(injectExifOrientation(MINIMAL_JPEG, orientation)), orientation);
  }
});

test("a JPEG without EXIF has no orientation", () => {
  assert.equal(readJpegOrientation(MINIMAL_JPEG), null);
});

test("injecting twice leaves one EXIF segment with the last value", () => {
  const once = injectExifOrientation(MINIMAL_JPEG, 6);
  const twice = injectExifOrientation(once, 3);
  assert.equal(readJpegOrientation(twice), 3);
  assert.equal(twice.length, once.length);
});

test("injection keeps every other segment and the scan data", () => {
  const injected = injectExifOrientation(MINIMAL_JPEG, 8);
  assert.ok(injected.includes(JFIF_SEGMENT));
  assert.ok(injected.subarray(injected.length - START_OF_SCAN.length).equals(START_OF_SCAN));
});

test("invalid orientation values are rejected", () => {
  assert.throws(() => buildExifOrientationSegment(0));
  assert.throws(() => buildExifOrientationSegment(9));
  assert.throws(() => injectExifOrientation(Buffer.from("not a jpeg"), 1));
});

test("the segment length field matches the payload", () => {
  const segment = buildExifOrientationSegment(6);
  assert.equal(segment.readUInt16BE(2), segment.length - 2);
});
