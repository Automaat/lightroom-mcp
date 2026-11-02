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
const extraRaw = process.argv[2];
const root = path.join(path.dirname(catalogPath), `raw-jpeg-pairs-${randomUUID()}`);

function makeFolder(name, files) {
  const folder = path.join(root, name);
  fs.mkdirSync(folder, { recursive: true });
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

const imported = [];
const results = {};
try {
  requireThrowawayCatalog();

  const paired = makeFolder("paired", { "P1.ARW": rawSource, "P1.JPG": jpegSource, "P2.ARW": rawSource, "p2.jpeg": jpegSource, "alone.jpg": jpegSource, "rawonly.ARW": rawSource });
  const folderResult = await session.toolOrThrow("import_photos", { source_path: paired }, { timeoutMs: 300_000 });
  const pairedFiles = await waitForFiles(paired, 4);
  imported.push(...pairedFiles);
  results.folder = { result: folderResult.data, files: pairedFiles };
  assert.equal(folderResult.data.imported, 4);
  assert.equal(folderResult.data.skipped_sidecar_jpegs, 2);
  assert.deepEqual(pairedFiles.map((row) => row.file).sort(), ["P1.ARW", "P2.ARW", "alone.jpg", "rawonly.ARW"].sort());
  assert.match(pairedFiles.find((row) => row.file === "P1.ARW").sidecars, /jpg/i);
  assert.match(pairedFiles.find((row) => row.file === "P2.ARW").sidecars, /jpeg/i);

  const single = makeFolder("single", { "S1.ARW": rawSource, "S1.JPG": jpegSource });
  const jpegPath = path.join(single, "S1.JPG");
  const refused = await session.tool("import_photos", { source_path: jpegPath });
  results.singleRefused = refused.text;
  assert.equal(refused.isError, true);
  assert.ok(refused.text.includes("S1.ARW"));
  assert.deepEqual(catalogFiles(single), []);

  const separate = await session.toolOrThrow("import_photos", { source_path: jpegPath, separate_jpegs: true });
  assert.equal(separate.data.imported, 1);
  const singleFiles = await waitForFiles(single, 1);
  imported.push(...singleFiles);
  results.singleSeparate = singleFiles;

  const optOut = makeFolder("optout", { "O1.ARW": rawSource, "O1.JPG": jpegSource });
  const optOutResult = await session.toolOrThrow("import_photos", { source_path: optOut, separate_jpegs: true }, { timeoutMs: 300_000 });
  const optOutFiles = await waitForFiles(optOut, 2);
  imported.push(...optOutFiles);
  results.optOut = { result: optOutResult.data, files: optOutFiles };
  assert.equal(optOutResult.data.imported, 2);
  assert.equal(optOutResult.data.skipped_sidecar_jpegs, undefined);
  assert.equal(optOutFiles.length, 2);

  if (extraRaw) {
    const name = `X1${path.extname(extraRaw)}`;
    const extra = makeFolder("extra", { [name]: extraRaw, "X1.JPG": jpegSource });
    const extraResult = await session.toolOrThrow("import_photos", { source_path: extra }, { timeoutMs: 300_000 });
    const extraFiles = await waitForFiles(extra, 1);
    imported.push(...extraFiles);
    results.extraRaw = { result: extraResult.data, files: extraFiles };
    assert.equal(extraResult.data.skipped_sidecar_jpegs, 1);
    assert.match(extraFiles.find((row) => row.file === name).sidecars, /jpg/i);
  }

  console.log(JSON.stringify({ passed: true, root, results }, null, 2));
} catch (error) {
  console.log(JSON.stringify({ passed: false, root, results }, null, 2));
  throw error;
} finally {
  requireThrowawayCatalog();
  const ids = imported.map((row) => row.id).filter((id) => id !== null);
  if (ids.length > 0) await session.tool("remove_photos_from_catalog", { photo_ids: ids, confirm: true });
  await session.stop();
}
