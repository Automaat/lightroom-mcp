import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { batchCropOffsets, batchFileName } from "../lib/batch.mjs";
import { chooseModalButton, parseModalWindows } from "../lib/ax.mjs";
import { maskGroupsText, parseLuaTable, storedMaskGroups, summarizeMaskGroups } from "../lib/catalog-db.mjs";
import { addedLuaFiles, assertOutsideTemporaryDirectory, listLuaFiles } from "../lib/plugin-bundle.mjs";
import {
  bandDeltas,
  decodeBmp,
  ellipseInside,
  intersectionOverUnion,
  patchDeltas,
  rectangleInside,
  regionDeltas,
} from "../lib/preview.mjs";

function solidPixels(w, h, level) {
  const size = w * h;
  const fill = () => new Float32Array(size).fill(level);
  return { w, h, R: fill(), G: fill(), B: fill(), L: fill() };
}

function brightenWhere(pixels, inside, amount) {
  const copy = { ...pixels, L: Float32Array.from(pixels.L), R: Float32Array.from(pixels.R), G: Float32Array.from(pixels.G), B: Float32Array.from(pixels.B) };
  for (let y = 0; y < pixels.h; y++) {
    for (let x = 0; x < pixels.w; x++) {
      if (inside((x + 0.5) / pixels.w, (y + 0.5) / pixels.h, pixels.w, pixels.h)) {
        const i = y * pixels.w + x;
        copy.L[i] += amount;
        copy.R[i] += amount;
      }
    }
  }
  return copy;
}

test("modal windows are parsed and the safe button is chosen", () => {
  const raw = [
    ["", "OK", "No faces detected in this photo"],
    ["Enable address lookup?", "Enable|Not Now", "Lightroom can look up addresses"],
    ["Other", "Save", "Something else"],
  ]
    .map((fields) => fields.join("\u001f"))
    .join("\u001e");
  const windows = parseModalWindows(raw);
  assert.deepEqual(windows.map(chooseModalButton), ["OK", "Not Now", null]);
});

test("the main window and Plug-in Manager are never treated as modals", () => {
  const raw = ["Lightroom Catalog.lrcat - Adobe Photoshop Lightroom Classic - Library", "OK", "x"].join("\u001f");
  assert.deepEqual(parseModalWindows(raw), []);
  assert.deepEqual(parseModalWindows(["Lightroom Plug-in Manager", "Done", ""].join("\u001f")), []);
});

test("address lookup is never enabled", () => {
  assert.equal(chooseModalButton({ title: "", text: "Enable address lookup?", buttons: ["Enable"] }), null);
});

test("region deltas measure the brightened area only", () => {
  const before = solidPixels(100, 100, 0.2);
  const after = brightenWhere(before, rectangleInside({ x0: 0, y0: 0, x1: 1, y1: 0.5 }), 0.3);
  const deltas = regionDeltas(before, after, [
    { name: "top", x0: 0, y0: 0, x1: 1, y1: 0.4 },
    { name: "bottom", x0: 0, y0: 0.6, x1: 1, y1: 1 },
  ]);
  assert.ok(Math.abs(deltas.top - 0.3) < 1e-6);
  assert.ok(Math.abs(deltas.bottom) < 1e-6);
  const bands = bandDeltas(before, after, 10);
  assert.ok(bands.rows[0] > 0.29 && bands.rows[9] === 0);
});

test("patch deltas report per channel changes", () => {
  const before = solidPixels(100, 100, 0.2);
  const after = brightenWhere(before, rectangleInside({ x0: 0, y0: 0, x1: 0.5, y1: 1 }), 0.1);
  const [left, right] = patchDeltas(before, after, [{ x: 0.25, y: 0.5 }, { x: 0.75, y: 0.5 }]);
  assert.ok(Math.abs(left.deltaR - 0.1) < 1e-6);
  assert.equal(left.deltaG, 0);
  assert.equal(right.deltaL, 0);
});

test("IoU is 1 for a perfect ellipse, low for a shifted one", () => {
  const ellipse = { center: { x: 0.5, y: 0.5 }, width: 0.5, height: 0.3, rotationDegrees: 40 };
  const before = solidPixels(200, 120, 0.2);
  const after = brightenWhere(before, ellipseInside(ellipse), 0.3);
  assert.ok(intersectionOverUnion(before, after, ellipseInside(ellipse)) > 0.99);
  const shifted = { ...ellipse, center: { x: 0.85, y: 0.5 } };
  assert.ok(intersectionOverUnion(before, after, ellipseInside(shifted)) < 0.3);
  assert.ok(intersectionOverUnion(before, after, ellipseInside({ ...ellipse, rotationDegrees: -40 })) < 0.9);
});

test("a BMP is decoded bottom-up with BGR order", () => {
  const bmp = Buffer.alloc(54 + 8);
  bmp.writeUInt32LE(54, 10);
  bmp.writeInt32LE(1, 18);
  bmp.writeInt32LE(2, 22);
  bmp.writeUInt16LE(24, 28);
  bmp.set([0, 0, 255], 54);
  bmp.set([255, 0, 0], 58);
  const pixels = decodeBmp(bmp);
  assert.equal(pixels.w, 1);
  assert.equal(pixels.h, 2);
  assert.equal(pixels.B[0], 1);
  assert.equal(pixels.R[1], 1);
});

test("stored mask groups are extracted from a develop settings row", () => {
  const settings = [
    "s = {",
    '  Exposure2012 = 0.5,',
    "  MaskGroupBasedCorrections = {",
    "    {",
    '      CorrectionID = "AB",',
    '      CorrectionName = "Mask 1",',
    "      LocalExposure2012 = 1.5,",
    "      CorrectionMasks = {",
    '        { What = "Mask/Gradient", MaskID = "M1", MaskInverted = false, MaskBlendMode = 0, },',
    "      },",
    "    },",
    "  },",
    "  Other = 1,",
    "}",
  ].join("\n");
  assert.ok(maskGroupsText(settings).startsWith("{"));
  const summary = summarizeMaskGroups(storedMaskGroups(settings));
  assert.deepEqual(summary, [
    {
      id: "AB",
      name: "Mask 1",
      exposure: 1.5,
      contrast: undefined,
      components: [{ id: "M1", what: "Mask/Gradient", inverted: false, blend: 0 }],
    },
  ]);
  assert.deepEqual(storedMaskGroups("s = { Exposure2012 = 0 }"), []);
});

test("lua table parser handles quoted keys, nil and nested arrays", () => {
  assert.deepEqual(parseLuaTable('{ ["a b"] = 1, c = nil, d = { 1, 2, 3 }, e = "x\\"y" }'), {
    "a b": 1,
    c: null,
    d: [1, 2, 3],
    e: 'x"y',
  });
});

test("added Lua files are the ones a reload would not see", () => {
  assert.deepEqual(addedLuaFiles(["A.lua", "B.lua"], ["A.lua", "B.lua", "C.lua", "D.lua"]), ["C.lua", "D.lua"]);
  assert.deepEqual(addedLuaFiles(["A.lua"], ["A.lua"]), []);
});

test("Lua files are listed recursively and sorted", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "lrmcp-bundle-"));
  try {
    fs.mkdirSync(path.join(directory, "sub"));
    fs.writeFileSync(path.join(directory, "b.lua"), "");
    fs.writeFileSync(path.join(directory, "a.lua"), "");
    fs.writeFileSync(path.join(directory, "notes.txt"), "");
    fs.writeFileSync(path.join(directory, "sub", "c.lua"), "");
    assert.deepEqual(listLuaFiles(directory).map((file) => file.split(path.sep).join("/")), ["a.lua", "b.lua", "sub/c.lua"]);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("bundle backups under the temporary directory are refused", () => {
  const temporary = os.tmpdir();
  assert.throws(() => assertOutsideTemporaryDirectory(path.join(temporary, "backups"), temporary), /outside the temporary directory/);
  assert.throws(() => assertOutsideTemporaryDirectory(temporary, temporary), /outside the temporary directory/);
  assert.doesNotThrow(() => assertOutsideTemporaryDirectory(path.join(os.homedir(), ".cache", "x"), temporary));
});

test("deltas compare previews of different sizes by normalized position", () => {
  const before = solidPixels(100, 60, 0.2);
  const after = brightenWhere(solidPixels(200, 120, 0.2), rectangleInside({ x0: 0, y0: 0, x1: 0.5, y1: 1 }), 0.3);
  const deltas = regionDeltas(before, after, [
    { name: "left", x0: 0, y0: 0, x1: 0.4, y1: 1 },
    { name: "right", x0: 0.6, y0: 0, x1: 1, y1: 1 },
  ]);
  assert.ok(Math.abs(deltas.left - 0.3) < 1e-6);
  assert.ok(Math.abs(deltas.right) < 1e-6);
  assert.ok(intersectionOverUnion(before, after, rectangleInside({ x0: 0, y0: 0, x1: 0.5, y1: 1 })) > 0.99);
});

test("batch crops are all distinct and stay inside the base image", () => {
  const offsets = batchCropOffsets(200, 400, 267);
  assert.equal(offsets.length, 200);
  assert.equal(new Set(offsets.map(({ x, y }) => `${x},${y}`)).size, 200);
  for (const { x, y } of offsets) {
    assert.ok(x >= 0 && x <= 400 && y >= 0 && y <= 267);
  }
  assert.deepEqual(batchCropOffsets(1, 400, 267), [{ x: 0, y: 0 }]);
  assert.equal(batchFileName(0), "batch_001.jpg");
  assert.equal(batchFileName(199), "batch_200.jpg");
});
