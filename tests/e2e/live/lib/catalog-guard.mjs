import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  LIGHTROOM_PROCESS_NAME,
  THROWAWAY_CATALOG_ENV,
  THROWAWAY_MARKER_FILE,
} from "./paths.mjs";

const CATALOG_EXTENSION = ".lrcat";

function realCatalogDirectory(home) {
  return path.join(home, "Pictures", "Lightroom");
}

function sameOrInside(candidate, directory) {
  const relative = path.relative(directory.toLowerCase(), candidate.toLowerCase());
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

export function isRealCatalog(catalogPath, home = os.homedir()) {
  return sameOrInside(path.resolve(catalogPath), realCatalogDirectory(home));
}

export function parseOpenCatalogs(lsofFieldOutput) {
  const catalogs = new Set();
  for (const line of lsofFieldOutput.split("\n")) {
    if (line.startsWith("n") && line.endsWith(CATALOG_EXTENSION)) catalogs.add(line.slice(1));
  }
  return [...catalogs];
}

export function isThrowawayCatalog(catalogPath, options = {}) {
  const home = options.home ?? os.homedir();
  const environment = options.environment ?? process.env;
  const fileExists = options.fileExists ?? fs.existsSync;
  const resolved = path.resolve(catalogPath);
  if (isRealCatalog(resolved, home)) return false;
  const declared = environment[THROWAWAY_CATALOG_ENV];
  if (declared && path.resolve(declared) === resolved) return true;
  return fileExists(path.join(path.dirname(resolved), THROWAWAY_MARKER_FILE));
}

export function assertThrowawayCatalog(openCatalogs, options = {}) {
  if (openCatalogs.length !== 1) {
    throw new Error(`expected exactly one open catalog, found ${openCatalogs.length}: ${openCatalogs.join(", ") || "none"}`);
  }
  const [catalogPath] = openCatalogs;
  if (isRealCatalog(catalogPath, options.home)) {
    throw new Error(`refusing to run: the open catalog is the real catalog (${catalogPath})`);
  }
  if (!isThrowawayCatalog(catalogPath, options)) {
    throw new Error(
      `refusing to run: ${catalogPath} is not a throwaway catalog (no ${THROWAWAY_MARKER_FILE} beside it; ` +
        `run setup-catalog.mjs or set ${THROWAWAY_CATALOG_ENV})`,
    );
  }
  return catalogPath;
}

export function lightroomPid() {
  try {
    const out = execFileSync("pgrep", ["-f", `Contents/MacOS/${LIGHTROOM_PROCESS_NAME}$`], { encoding: "utf8" });
    const pid = Number(out.split("\n").find(Boolean));
    return Number.isInteger(pid) ? pid : null;
  } catch {
    return null;
  }
}

export function currentOpenCatalogs() {
  const pid = lightroomPid();
  if (pid === null) return [];
  const out = execFileSync("lsof", ["-p", String(pid), "-Fn"], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  return parseOpenCatalogs(out);
}

export function requireThrowawayCatalog(options = {}) {
  return assertThrowawayCatalog(currentOpenCatalogs(), options);
}
