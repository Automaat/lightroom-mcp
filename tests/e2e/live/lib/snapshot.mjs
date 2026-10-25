import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { isThrowawayCatalog, lightroomPid, requireThrowawayCatalog } from "./catalog-guard.mjs";
import { SNAPSHOTS_DIR } from "./paths.mjs";

const SIDECAR_SUFFIXES = ["-wal", "-shm"];
const COPY_ATTEMPTS = 3;

function copyCatalogFiles(catalogPath, destinationCatalogPath) {
  fs.copyFileSync(catalogPath, destinationCatalogPath);
  for (const suffix of SIDECAR_SUFFIXES) {
    if (fs.existsSync(catalogPath + suffix)) fs.copyFileSync(catalogPath + suffix, destinationCatalogPath + suffix);
  }
}

function copyPassesQuickCheck(catalogPath) {
  try {
    return execFileSync("sqlite3", [catalogPath, "pragma quick_check"], { encoding: "utf8" }).trim() === "ok";
  } catch {
    return false;
  }
}

export function snapshotThrowawayCatalog(label, options = {}) {
  const catalogPath = options.catalogPath ?? requireThrowawayCatalog();
  const stamp = new Date().toISOString().replace(/[-:.TZ]/g, "").slice(0, 14);
  const directory = path.join(SNAPSHOTS_DIR, `${label}-${stamp}`);
  fs.mkdirSync(directory, { recursive: true });
  const snapshotPath = path.join(directory, path.basename(catalogPath));
  for (let attempt = 0; attempt < COPY_ATTEMPTS; attempt++) {
    for (const suffix of ["", ...SIDECAR_SUFFIXES]) fs.rmSync(snapshotPath + suffix, { force: true });
    copyCatalogFiles(catalogPath, snapshotPath);
    if (copyPassesQuickCheck(snapshotPath)) return { directory, snapshotPath, catalogPath };
  }
  throw new Error(`snapshot of ${catalogPath} failed the sqlite quick_check ${COPY_ATTEMPTS} times`);
}

export function listSnapshots() {
  if (!fs.existsSync(SNAPSHOTS_DIR)) return [];
  return fs.readdirSync(SNAPSHOTS_DIR).sort();
}

export function restoreSnapshot(snapshotDirectoryName, options = {}) {
  const catalogPath = options.catalogPath;
  if (!catalogPath) throw new Error("restore needs the throwaway catalog path");
  if (!isThrowawayCatalog(catalogPath)) throw new Error(`refusing to overwrite ${catalogPath}: not a throwaway catalog`);
  if (lightroomPid() !== null) throw new Error("quit Lightroom before restoring a snapshot");
  const directory = path.join(SNAPSHOTS_DIR, snapshotDirectoryName);
  const snapshotPath = path.join(directory, path.basename(catalogPath));
  if (!fs.existsSync(snapshotPath)) throw new Error(`no ${path.basename(catalogPath)} in ${directory}`);
  for (const suffix of SIDECAR_SUFFIXES) fs.rmSync(catalogPath + suffix, { force: true });
  copyCatalogFiles(snapshotPath, catalogPath);
  return catalogPath;
}
