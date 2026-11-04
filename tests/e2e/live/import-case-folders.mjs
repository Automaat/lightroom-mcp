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
  console.error("usage: import-case-folders.mjs <folder on a case-sensitive volume>");
  process.exit(2);
}

const { marker, catalogPath, session } = await openLiveSession();
requireFixtureId(marker, "wide_plain");
const source = marker.fixtures.wide_plain.path;
const root = path.join(volume, `case-folders-${randomUUID()}`);
const timeoutMs = 120_000;

function assertCaseSensitive() {
  fs.mkdirSync(path.join(root, "probe"), { recursive: true });
  fs.mkdirSync(path.join(root, "PROBE"));
  assert.equal(fs.readdirSync(root).length, 2, `${volume} is not case-sensitive`);
  fs.rmSync(path.join(root, "probe"), { recursive: true });
  fs.rmSync(path.join(root, "PROBE"), { recursive: true });
}

function catalogRows() {
  const rows = execFileSync("sqlite3", ["-readonly", "-json", catalogPath, `
    select r.absolutePath || d.pathFromRoot as folder, f.idx_filename as file, i.id_local as id
    from AgLibraryFile f
    join AgLibraryFolder d on f.folder = d.id_local
    join AgLibraryRootFolder r on d.rootFolder = r.id_local
    left join Adobe_images i on i.rootFile = f.id_local
    where r.absolutePath || d.pathFromRoot like '${root.replaceAll("'", "''")}%'
    order by 1, 2`], { encoding: "utf8" });
  return rows.trim() ? JSON.parse(rows) : [];
}

async function importFrom(sourcePath) {
  const result = await session.tool("import_photos", { source_path: sourcePath }, { timeoutMs });
  assert.equal(result.isError, false, result.text);
  return result.data;
}

try {
  requireThrowawayCatalog();
  assertCaseSensitive();

  fs.mkdirSync(path.join(root, "Dir2"));
  fs.copyFileSync(source, path.join(root, "Dir2", "a.jpg"));
  const first = await importFrom(path.join(root, "Dir2"));
  assert.equal(first.imported, 1);

  fs.mkdirSync(path.join(root, "dir2"));
  fs.copyFileSync(source, path.join(root, "dir2", "a.jpg"));
  const second = await importFrom(root);
  assert.equal(second.imported, 0);
  assert.equal(second.already_in_catalog, 1);
  assert.equal(second.failed.length, 1);
  assert.equal(second.failed[0].path, path.join(root, "dir2", "a.jpg"));
  assert.match(second.failed[0].error, /differs only in case/);

  const third = await importFrom(root);
  assert.deepEqual(third, second);

  const single = await session.tool("import_photos", { source_path: path.join(root, "dir2", "a.jpg") }, { timeoutMs });
  assert.equal(single.isError, true);
  assert.match(single.text, /differs only in case/);

  fs.mkdirSync(path.join(root, "other"));
  fs.copyFileSync(source, path.join(root, "other", "b.jpg"));
  const later = await importFrom(path.join(root, "other"));
  assert.equal(later.imported, 1);

  const rows = catalogRows();
  assert.deepEqual(
    rows.map((row) => `${path.basename(row.folder)}/${row.file}`),
    ["Dir2/a.jpg", "other/b.jpg"],
  );
  console.log(JSON.stringify({ first, second, third, later, rows }, null, 2));
} finally {
  await session.stop();
}
