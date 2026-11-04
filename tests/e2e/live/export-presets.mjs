#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";

const FOLDER = `lrmcp-export-presets-${process.pid}`;
const USER_ROOT = path.join(os.homedir(), "Library", "Application Support", "Adobe", "Lightroom", "Export Presets");
const CONSTRAIN = "size_doConstrain = true, size_userWantsConstrain = true,";

const { session, marker, catalogPath } = await openLiveSession();
const chart = requireFixtureId(marker, "chart80");
const ramp = requireFixtureId(marker, "ramp256");
const wide = requireFixtureId(marker, "wide_plain");

const catalogSettings = path.join(path.dirname(catalogPath), "Lightroom Settings");
const catalogRootExisted = fs.existsSync(catalogSettings);
const catalogRoot = path.join(catalogSettings, "Export Presets");
const output = fs.mkdtempSync(path.join(os.tmpdir(), "lrmcp-export-presets-"));
const failures = [];
let directoryCount = 0;

function writePreset(name, settings, { root = USER_ROOT, title = name } = {}) {
  const directory = path.join(root, FOLDER);
  fs.mkdirSync(directory, { recursive: true });
  const value = `exportServiceProvider = "com.adobe.ag.export.file", format = "JPEG", jpeg_quality = 0.6, collisionHandling = "ask", export_colorSpace = "sRGB", renamingTokensOn = true, tokens = "live_{{image_name}}", ${settings}`;
  const file = path.join(directory, `${name}.lrtemplate`);
  fs.writeFileSync(file, `s = { id = "live-${name}", title = "${title}", type = "Export", value = { ${value} }, version = 0 }`);
  return file;
}

function newDestination() {
  directoryCount += 1;
  return path.join(output, String(directoryCount));
}

function dimensions(file) {
  const report = execFileSync("sips", ["-g", "pixelWidth", "-g", "pixelHeight", file], { encoding: "utf8" });
  return `${report.match(/pixelWidth: (\d+)/)[1]}x${report.match(/pixelHeight: (\d+)/)[1]}`;
}

function filesIn(directory) {
  return fs.existsSync(directory) ? fs.readdirSync(directory).sort() : [];
}

function exportTo(args, timeoutMs = 60000) {
  const destination = newDestination();
  const preset = args.export_preset && !args.export_preset.startsWith("/") ? { export_preset_folder: FOLDER } : {};
  return session.tool("export_photos", { photo_ids: [chart], destination, ...preset, ...args }, { timeoutMs })
    .then((result) => ({ result, destination, files: filesIn(destination) }));
}

function check(label, passed, detail) {
  console.log(`${passed ? "PASS" : "FAIL"} ${label}: ${JSON.stringify(detail)}`);
  if (!passed) failures.push(label);
}

async function checkSize(label, args, expected) {
  const { result, destination, files } = await exportTo(args);
  const actual = files.map((file) => dimensions(path.join(destination, file)));
  check(label, !result.isError && actual.length === 1 && actual[0] === expected, { expected, actual, text: result.isError ? result.text : undefined });
}

async function checkLongEdge(label, args, expected) {
  const { result, destination, files } = await exportTo(args);
  const edge = files.length === 1 ? Math.max(...dimensions(path.join(destination, files[0])).split("x").map(Number)) : null;
  check(label, !result.isError && edge !== null && Math.abs(edge - expected) <= 1, { expected, edge, data: result.data });
}

try {
  writePreset("Seq", `tokens = "live_{{naming_sequenceNumber_3Digits}}", ${CONSTRAIN} size_resizeType = "longEdge", size_maxWidth = 500, size_maxHeight = 500`);
  writePreset("SeqFrom5", `tokens = "live_{{naming_sequenceNumber_3Digits}}", initialSequenceNumber = 5`);
  writePreset("SeqTotal", `tokens = "live_{{naming_sequenceNumber_2Digits}}_of_{{naming_sequenceTotal_2Digits}}"`);
  const three = [chart, ramp, wide];
  const numbered = ["live_001.jpg", "live_002.jpg", "live_003.jpg"];
  for (const onExisting of ["rename", "overwrite", "skip"]) {
    const { result, files } = await exportTo({ photo_ids: three, export_preset: "Seq", on_existing: onExisting });
    check(`sequence with ${onExisting}`, result.data?.exported === 3 && files.join() === numbered.join(), { files, exported: result.data?.exported });
  }
  const from5 = await exportTo({ photo_ids: three, export_preset: "SeqFrom5" });
  check("sequence from start number", from5.files.join() === "live_005.jpg,live_006.jpg,live_007.jpg", from5.files);
  const total = await exportTo({ photo_ids: three, export_preset: "SeqTotal" });
  check("sequence total", total.files.join() === "live_01_of_03.jpg,live_02_of_03.jpg,live_03_of_03.jpg", total.files);

  writePreset("Le500", `${CONSTRAIN} size_resizeType = "longEdge", size_maxWidth = 500, size_maxHeight = 500`);
  writePreset("Wh", `${CONSTRAIN} size_resizeType = "wh", size_maxWidth = 300, size_maxHeight = 600`);
  writePreset("Inch", `${CONSTRAIN} size_resizeType = "longEdge", size_maxWidth = 5, size_maxHeight = 5, size_units = "inch", size_resolution = 72`);
  writePreset("Cm", `${CONSTRAIN} size_resizeType = "longEdge", size_maxWidth = 10, size_maxHeight = 10, size_units = "cm", size_resolution = 72, size_resolutionUnits = "cm"`);
  writePreset("Free", "size_doConstrain = false, size_userWantsConstrain = false");
  writePreset("Enlarge", `${CONSTRAIN} size_resizeType = "longEdge", size_maxWidth = 500, size_maxHeight = 500, size_doNotEnlarge = false`);
  await checkSize("preset long edge alone", { export_preset: "Le500" }, "500x400");
  await checkSize("width over long edge", { export_preset: "Le500", width: 200 }, "200x160");
  await checkSize("height over long edge", { export_preset: "Le500", height: 400 }, "500x400");
  await checkSize("width and height box", { export_preset: "Le500", width: 200, height: 200 }, "200x160");
  await checkSize("height keeps preset width", { export_preset: "Wh", height: 400 }, "300x240");
  await checkSize("width keeps preset height", { export_preset: "Wh", width: 200 }, "200x160");
  await checkSize("height over inches", { export_preset: "Inch", height: 400 }, "500x400");
  await checkSize("height over cm", { export_preset: "Cm", height: 400 }, "500x400");
  await checkSize("width on an unconstrained preset", { export_preset: "Free", width: 200 }, "200x160");
  await checkSize("width never enlarges", { export_preset: "Enlarge", width: 5000 }, "1000x800");
  await checkSize("no preset width", { width: 200 }, "200x160");
  await checkSize("no preset height", { height: 400 }, "500x400");
  await checkSize("no preset never enlarges", { width: 5000 }, "1000x800");

  for (const [megapixels, edge] of [[0.25, 559], [0.5, 791], [0.9, 1061], [1, 1118], [1.5, 1369]]) {
    const name = `Mp${String(megapixels).replace(".", "_")}`;
    writePreset(name, `${CONSTRAIN} size_resizeType = "megapixels", size_megapixels = ${megapixels}`);
    await checkLongEdge(`${megapixels} megapixels`, { export_preset: name }, edge);
  }
  writePreset("Pct25", `${CONSTRAIN} size_resizeType = "percentage", size_percentage = 25`);
  writePreset("Pct50", `${CONSTRAIN} size_resizeType = "percentage", size_percentage = 50`);
  await checkSize("25 percent", { export_preset: "Pct25" }, "250x200");
  await checkSize("50 percent", { export_preset: "Pct50" }, "500x400");

  writePreset("Plain", "");
  const readOnly = newDestination();
  fs.mkdirSync(readOnly, { mode: 0o555 });
  const denied = await session.tool("export_photos", { photo_ids: [chart], export_preset: "Plain", export_preset_folder: FOLDER, destination: readOnly }, { timeoutMs: 60000 });
  fs.chmodSync(readOnly, 0o755);
  check("read-only destination is not counted", denied.isError || (denied.data.exported === 0 && denied.data.success === false), denied.isError ? denied.text : denied.data);
  const first = await exportTo({ export_preset: "Plain" });
  const skipped = await session.tool("export_photos", { photo_ids: [chart], export_preset: "Plain", export_preset_folder: FOLDER, destination: first.destination, on_existing: "skip" }, { timeoutMs: 60000 });
  check("skip is not counted as exported", skipped.data?.exported === 0 && skipped.data?.skipped === 1, skipped.data);

  for (const usePreset of [true, false]) {
    const destination = newDestination();
    const args = usePreset ? { export_preset: "Plain", export_preset_folder: FOLDER } : {};
    const results = await Promise.all(Array.from({ length: 6 }, () => session.tool("export_photos", { photo_ids: [chart], destination, ...args }, { timeoutMs: 120000 })));
    const reported = results.reduce((sum, result) => sum + (result.data?.exported ?? 0), 0);
    const files = filesIn(destination);
    const refused = results.filter((result) => result.isError && result.text.includes("already running")).length;
    check(`parallel exports run one at a time (preset ${usePreset})`, reported >= 1 && reported === files.length && reported + refused === 6, { reported, refused, files: files.length });
  }
  const parallelDestinations = [newDestination(), newDestination()];
  const twoFolders = await Promise.all(parallelDestinations.map((destination) => session.tool("export_photos", { photo_ids: [chart], destination }, { timeoutMs: 120000 })));
  const twoFoldersReported = twoFolders.reduce((sum, result) => sum + (result.data?.exported ?? 0), 0);
  const twoFoldersWritten = parallelDestinations.reduce((sum, destination) => sum + filesIn(destination).length, 0);
  check("parallel exports to two folders", twoFoldersReported === 1 && twoFoldersWritten === 1, { twoFoldersReported, twoFoldersWritten });

  for (const [name, settings, reason] of [
    ["QText", 'jpeg_quality = "high"', "jpeg_quality must be a number"],
    ["QRange", "jpeg_quality = 90", "jpeg_quality must be between 0 and 1"],
    ["WidthText", 'size_maxWidth = "x"', "size_maxWidth must be a number"],
    ["FormatNumber", "format = 5", "format must be a string"],
    ["ConstrainText", 'size_doConstrain = "yes"', "size_doConstrain must be true or false"],
  ]) {
    writePreset(name, settings);
    const listed = (await session.tool("list_export_presets", { folder: FOLDER })).data.presets.find((preset) => preset.name === name);
    const { result, files } = await exportTo({ export_preset: name }, 20000);
    check(`malformed preset ${name} is refused`, listed.usable === false && listed.unusable_reason.includes(reason) && result.isError && files.length === 0, { reason: listed.unusable_reason, text: result.text.slice(0, 120) });
  }

  writePreset("Limit", "jpeg_useLimitSize = true, jpeg_limitSize = 20");
  const low = await exportTo({ export_preset: "Limit", quality: 5 });
  const high = await exportTo({ export_preset: "Limit", quality: 100 });
  const lowBytes = fs.statSync(path.join(low.destination, low.files[0])).size;
  const highBytes = fs.statSync(path.join(high.destination, high.files[0])).size;
  check("quality beats a file size limit", highBytes > lowBytes, { lowBytes, highBytes });

  const userFile = writePreset("Clash", "");
  const catalogFile = writePreset("Clash", "", { root: catalogRoot });
  const ambiguous = await exportTo({ export_preset: "Clash" });
  check("same preset in two scopes explains itself", ambiguous.result.isError && ambiguous.result.text.includes("file path"), ambiguous.result.text);
  for (const [scope, file] of [["user", userFile], ["catalog", catalogFile]]) {
    const { result, files } = await exportTo({ export_preset: file });
    check(`select the ${scope} copy by path`, result.data?.preset?.scope === scope && files.length === 1, result.isError ? result.text : result.data.preset);
  }
  const byFileName = await exportTo({ export_preset: "Plain.lrtemplate" });
  check("file name with extension", byFileName.files.length === 1, byFileName.result.isError ? byFileName.result.text : byFileName.files);

  writePreset("Lodz", "", { title: "ŁÓDŹ" });
  writePreset("Cafe", "", { title: "Café" });
  for (const name of ["łódź", "ŁÓDŹ", "café", "CAFÉ", "plain"]) {
    const { result, files } = await exportTo({ export_preset: name });
    check(`case-insensitive ${name}`, !result.isError && files.length === 1, result.isError ? result.text : files);
  }

  const crlfFile = path.join(USER_ROOT, FOLDER, "Crlf.lrtemplate");
  fs.writeFileSync(crlfFile, 's = {\r\n title = "Crlf\\\r\nName",\r\n type = "Export",\r\n value = { format = "JPEG" },\r\n}\r\n');
  const crlf = (await session.tool("list_export_presets", { folder: FOLDER })).data.presets.find((preset) => preset.file === crlfFile);
  check("Windows line ends", crlf.usable === true && crlf.name === "Crlf\nName", crlf);
} finally {
  await session.stop();
  fs.rmSync(path.join(USER_ROOT, FOLDER), { recursive: true, force: true });
  fs.rmSync(catalogRootExisted ? path.join(catalogRoot, FOLDER) : catalogSettings, { recursive: true, force: true });
  execFileSync("chmod", ["-R", "u+rwx", output]);
  fs.rmSync(output, { recursive: true, force: true });
}

console.log(failures.length === 0 ? "all export preset checks passed" : `FAILED: ${failures.join("; ")}`);
process.exitCode = failures.length === 0 ? 0 : 1;
