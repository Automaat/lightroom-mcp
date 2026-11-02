#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { requireThrowawayCatalog } from "./lib/catalog-guard.mjs";

const { marker, catalogPath, session } = await openLiveSession();
requireFixtureId(marker, "arw_12bit");
const rawSource = marker.fixtures.arw_12bit.path;
const jpegSource = marker.fixtures.wide_plain.path;
const dngSample = process.argv[2];
const root = path.join(path.dirname(catalogPath), `raw-jpeg-pairs-${randomUUID()}`);
const folders = [];

function makeFolder(name, files) {
  const folder = path.join(root, name);
  fs.mkdirSync(folder, { recursive: true });
  folders.push(folder);
  for (const [file, source] of Object.entries(files)) fs.copyFileSync(source, path.join(folder, file));
  return folder;
}

function catalogFiles(folder) {
  const rows = execFileSync("sqlite3", ["-readonly", "-json", catalogPath, `
    select f.idx_filename as file, coalesce(f.sidecarExtensions, '') as sidecars, i.id_local as id
    from AgLibraryFile f
    join AgLibraryFolder d on f.folder = d.id_local
    join AgLibraryRootFolder r on d.rootFolder = r.id_local
    left join Adobe_images i on i.rootFile = f.id_local
    where r.absolutePath || d.pathFromRoot = '${folder.replaceAll("'", "''")}/'
    order by f.idx_filename`], { encoding: "utf8" });
  return rows.trim() ? JSON.parse(rows) : [];
}

async function waitForFiles(folder, count) {
  for (let read = 0; read < 20; read++) {
    const files = catalogFiles(folder);
    if (files.length >= count) return files;
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  return catalogFiles(folder);
}

const results = {};
try {
  requireThrowawayCatalog();

  const paired = makeFolder("paired", { "P1.ARW": rawSource, "P1.JPG": jpegSource, "P2.ARW": rawSource, "P2.jpeg": jpegSource, "alone.jpg": jpegSource, "rawonly.ARW": rawSource });
  const folderResult = await session.toolOrThrow("import_photos", { source_path: paired }, { timeoutMs: 300_000 });
  const pairedFiles = await waitForFiles(paired, 4);
  results.folder = { result: folderResult.data, files: pairedFiles };
  assert.equal(folderResult.data.imported, 4);
  assert.equal(folderResult.data.skipped_sidecar_jpegs, 2);
  assert.deepEqual(pairedFiles.map((row) => row.file).sort(), ["P1.ARW", "P2.ARW", "alone.jpg", "rawonly.ARW"].sort());
  assert.match(pairedFiles.find((row) => row.file === "P1.ARW").sidecars, /jpg/i);
  assert.match(pairedFiles.find((row) => row.file === "P2.ARW").sidecars, /jpeg/i);

  fs.copyFileSync(rawSource, path.join(paired, "P3.ARW"));
  fs.copyFileSync(jpegSource, path.join(paired, "P3.JPG"));
  const again = await session.toolOrThrow("import_photos", { source_path: paired }, { timeoutMs: 300_000 });
  const againFiles = await waitForFiles(paired, 5);
  results.reimport = { result: again.data, files: againFiles };
  assert.equal(again.data.imported, 1);
  assert.equal(again.data.already_in_catalog, 4);
  assert.equal(again.data.skipped_sidecar_jpegs, 3);
  assert.equal(againFiles.filter((row) => row.id !== null).length, 5);

  const renamed = makeFolder("renamed", { "A.ARW": rawSource });
  await session.toolOrThrow("import_photos", { source_path: path.join(renamed, "A.ARW") });
  fs.renameSync(path.join(renamed, "A.ARW"), path.join(renamed, "a.tmp"));
  fs.renameSync(path.join(renamed, "a.tmp"), path.join(renamed, "a.ARW"));
  fs.copyFileSync(jpegSource, path.join(renamed, "new.jpg"));
  const renamedResult = await session.toolOrThrow("import_photos", { source_path: renamed }, { timeoutMs: 300_000 });
  results.renamed = renamedResult.data;
  assert.equal(renamedResult.data.imported, 1);
  assert.equal(renamedResult.data.already_in_catalog, 1);

  const caseDiffers = makeFolder("case", { "R.ARW": rawSource, "r.jpg": jpegSource });
  const caseResult = await session.toolOrThrow("import_photos", { source_path: caseDiffers }, { timeoutMs: 300_000 });
  const caseFiles = await waitForFiles(caseDiffers, 2);
  results.caseDiffers = { result: caseResult.data, files: caseFiles };
  assert.equal(caseResult.data.imported, 2);
  assert.equal(caseResult.data.skipped_sidecar_jpegs, undefined);
  assert.equal(caseFiles.filter((row) => row.id !== null).length, 2);

  const single = makeFolder("single", { "S1.ARW": rawSource, "S1.JPG": jpegSource });
  const jpegPath = path.join(single, "S1.JPG");
  const refused = await session.tool("import_photos", { source_path: jpegPath });
  results.singleRefused = refused.text;
  assert.equal(refused.isError, true);
  assert.ok(refused.text.includes("S1.ARW"));
  assert.deepEqual(catalogFiles(single), []);

  const caseSingle = makeFolder("case-single", { "Q.ARW": rawSource, "q.jpg": jpegSource });
  const caseJpeg = await session.toolOrThrow("import_photos", { source_path: path.join(caseSingle, "q.jpg") });
  results.caseSingle = caseJpeg.data;
  assert.equal(caseJpeg.data.imported, 1);

  const unicode = makeFolder("unicode", { "caf\u00e9.ARW": rawSource, "caf\u00e9.jpg": jpegSource });
  const otherForm = await session.tool("import_photos", { source_path: path.join(unicode, "cafe\u0301.jpg") });
  results.unicode = otherForm.text;
  assert.equal(otherForm.isError, true);
  assert.match(otherForm.text, /\.ARW/);
  assert.deepEqual(catalogFiles(unicode), []);

  const separate = await session.toolOrThrow("import_photos", { source_path: jpegPath, separate_jpegs: true });
  assert.equal(separate.data.imported, 1);
  const singleFiles = await waitForFiles(single, 1);
  results.singleSeparate = singleFiles;

  const optOut = makeFolder("optout", { "O1.ARW": rawSource, "O1.JPG": jpegSource });
  const optOutResult = await session.toolOrThrow("import_photos", { source_path: optOut, separate_jpegs: true }, { timeoutMs: 300_000 });
  const optOutFiles = await waitForFiles(optOut, 2);
  results.optOut = { result: optOutResult.data, files: optOutFiles };
  assert.equal(optOutResult.data.imported, 2);
  assert.equal(optOutResult.data.skipped_sidecar_jpegs, undefined);
  assert.equal(optOutFiles.length, 2);

  if (dngSample) {
    const dng = makeFolder("dng", { "D1.DNG": dngSample, "D1.JPG": jpegSource });
    const dngResult = await session.toolOrThrow("import_photos", { source_path: dng }, { timeoutMs: 300_000 });
    const dngFiles = await waitForFiles(dng, 2);
    results.dng = { result: dngResult.data, files: dngFiles };
    assert.equal(dngResult.data.imported, 2);
    assert.equal(dngResult.data.skipped_sidecar_jpegs, undefined);
    assert.equal(dngFiles.filter((row) => row.id !== null).length, 2);
  }

  console.log(JSON.stringify({ passed: true, root, results }, null, 2));
} catch (error) {
  console.log(JSON.stringify({ passed: false, root, results }, null, 2));
  throw error;
} finally {
  requireThrowawayCatalog();
  const ids = folders.flatMap(catalogFiles).map((row) => row.id).filter((id) => id !== null);
  if (ids.length > 0) await session.tool("remove_photos_from_catalog", { photo_ids: ids, confirm: true });
  await session.stop();
}
