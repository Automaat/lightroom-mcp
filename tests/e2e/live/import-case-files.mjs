#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { requireThrowawayCatalog } from "./lib/catalog-guard.mjs";

const volume = process.argv[2];
if (!volume) {
  console.error("usage: import-case-files.mjs <folder on a case-sensitive volume>");
  process.exit(2);
}

const { marker, catalogPath, session } = await openLiveSession();
requireFixtureId(marker, "wide_plain");
const source = marker.fixtures.wide_plain.path;
const root = path.join(volume, `case-files-${randomUUID()}`);
const timeoutMs = 120_000;

function assertCaseSensitive() {
  fs.mkdirSync(path.join(root, "probe"), { recursive: true });
  fs.mkdirSync(path.join(root, "PROBE"));
  assert.equal(fs.readdirSync(root).length, 2, `${volume} is not case-sensitive`);
  fs.rmSync(path.join(root, "probe"), { recursive: true });
  fs.rmSync(path.join(root, "PROBE"), { recursive: true });
}

function catalogFiles() {
  const rows = execFileSync("sqlite3", ["-readonly", "-json", catalogPath, `
    select r.absolutePath || d.pathFromRoot as folder, f.idx_filename as file
    from AgLibraryFile f
    join AgLibraryFolder d on f.folder = d.id_local
    join AgLibraryRootFolder r on d.rootFolder = r.id_local
    where r.absolutePath || d.pathFromRoot like '${root.replaceAll("'", "''")}%'
    order by 1, 2`], { encoding: "utf8" });
  return rows.trim() ? JSON.parse(rows).map((row) => `${path.basename(row.folder)}/${row.file}`) : [];
}

async function importFrom(sourcePath) {
  return session.tool("import_photos", { source_path: sourcePath }, { timeoutMs });
}

try {
  requireThrowawayCatalog();
  assertCaseSensitive();

  fs.mkdirSync(path.join(root, "one"));
  fs.copyFileSync(source, path.join(root, "one", "A.jpg"));
  const first = await importFrom(path.join(root, "one", "A.jpg"));
  assert.equal(first.isError, false, first.text);
  assert.equal(first.data.imported, 1);

  fs.copyFileSync(source, path.join(root, "one", "a.jpg"));
  const single = await importFrom(path.join(root, "one", "a.jpg"));
  assert.equal(single.isError, true);
  assert.match(single.text, /differs only in case from .*A\.jpg/);

  const folder = await importFrom(path.join(root, "one"));
  assert.equal(folder.isError, false, folder.text);
  assert.equal(folder.data.imported, 0);
  assert.equal(folder.data.already_in_catalog, 1);
  assert.equal(folder.data.failed.length, 1);
  assert.equal(folder.data.failed[0].path, path.join(root, "one", "a.jpg"));
  assert.match(folder.data.failed[0].error, /differs only in case from .*A\.jpg/);

  fs.mkdirSync(path.join(root, "two"));
  fs.copyFileSync(source, path.join(root, "two", "B.jpg"));
  fs.copyFileSync(source, path.join(root, "two", "b.jpg"));
  const fresh = await importFrom(path.join(root, "two"));
  assert.equal(fresh.isError, false, fresh.text);
  assert.equal(fresh.data.imported, 1);
  assert.equal(fresh.data.failed.length, 1);

  const again = await importFrom(path.join(root, "two"));
  assert.equal(again.isError, false, again.text);
  assert.equal(again.data.imported, 0);

  const exact = await importFrom(path.join(root, "one", "A.jpg"));
  assert.equal(exact.isError, false, exact.text);
  assert.equal(exact.data.already_in_catalog, 1);

  const files = catalogFiles();
  assert.equal(files.filter((file) => file.startsWith("one/")).length, 1);
  assert.equal(files.filter((file) => file.startsWith("two/")).length, 1);
  console.log(JSON.stringify({ single: single.text, folder: folder.data, fresh: fresh.data, files }, null, 2));
} finally {
  await session.stop();
}
