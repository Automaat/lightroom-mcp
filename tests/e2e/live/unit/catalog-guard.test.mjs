import assert from "node:assert/strict";
import path from "node:path";
import { test } from "node:test";
import {
  assertThrowawayCatalog,
  isRealCatalog,
  isThrowawayCatalog,
  parseOpenCatalogs,
} from "../lib/catalog-guard.mjs";
import { THROWAWAY_CATALOG_ENV, THROWAWAY_MARKER_FILE } from "../lib/paths.mjs";

const HOME = path.resolve("/Users/tester");
const REAL = path.join(HOME, "Pictures", "Lightroom", "Lightroom Catalog.lrcat");
const THROWAWAY = path.join(HOME, "Documents", "lrmcp-live-1", "lrmcp-live-1.lrcat");
const markerFor = (catalog) => path.join(path.dirname(catalog), THROWAWAY_MARKER_FILE);
const options = (extra = {}) => ({ home: HOME, environment: {}, fileExists: () => false, ...extra });

test("the real catalog is recognised, also with different case and nested copies", () => {
  assert.equal(isRealCatalog(REAL, HOME), true);
  assert.equal(isRealCatalog(REAL.toUpperCase(), HOME), true);
  assert.equal(isRealCatalog(path.join(HOME, "Pictures", "Lightroom", "Backups", "x.lrcat"), HOME), true);
  assert.equal(isRealCatalog(THROWAWAY, HOME), false);
  assert.equal(isRealCatalog(path.join(HOME, "Pictures", "LightroomOther", "a.lrcat"), HOME), false);
});

test("relative segments cannot smuggle the real catalog past the check", () => {
  const sneaky = path.join(HOME, "Documents", "..", "Pictures", "Lightroom", "Lightroom Catalog.lrcat");
  assert.equal(isRealCatalog(sneaky, HOME), true);
});

test("open catalogs are parsed from lsof field output and sidecar files are ignored", () => {
  const output = [
    "p123",
    "fcwd",
    "n/",
    "f20",
    `n${THROWAWAY}`,
    `n${THROWAWAY}-wal`,
    `n${THROWAWAY}-shm`,
    `n${path.dirname(THROWAWAY)}/lrmcp-live-1.lrcat-data/LOG`,
    `n${THROWAWAY}`,
  ].join("\n");
  assert.deepEqual(parseOpenCatalogs(output), [THROWAWAY]);
});

test("a catalog is throwaway only with its marker file or an explicit environment declaration", () => {
  assert.equal(isThrowawayCatalog(THROWAWAY, options()), false);
  assert.equal(isThrowawayCatalog(THROWAWAY, options({ fileExists: (file) => file === markerFor(THROWAWAY) })), true);
  assert.equal(isThrowawayCatalog(THROWAWAY, options({ environment: { [THROWAWAY_CATALOG_ENV]: THROWAWAY } })), true);
  assert.equal(isThrowawayCatalog(THROWAWAY, options({ environment: { [THROWAWAY_CATALOG_ENV]: "/elsewhere.lrcat" } })), false);
});

test("a marker beside the real catalog never makes it throwaway", () => {
  const withMarker = options({ fileExists: () => true, environment: { [THROWAWAY_CATALOG_ENV]: REAL } });
  assert.equal(isThrowawayCatalog(REAL, withMarker), false);
});

test("the guard refuses the real catalog, an unmarked catalog, none and several", () => {
  assert.throws(() => assertThrowawayCatalog([REAL], options({ fileExists: () => true })), /real catalog/);
  assert.throws(() => assertThrowawayCatalog([THROWAWAY], options()), /not a throwaway catalog/);
  assert.throws(() => assertThrowawayCatalog([], options()), /exactly one/);
  assert.throws(() => assertThrowawayCatalog([THROWAWAY, REAL], options({ fileExists: () => true })), /exactly one/);
});

test("the guard returns the throwaway catalog path when it is marked", () => {
  assert.equal(assertThrowawayCatalog([THROWAWAY], options({ fileExists: () => true })), THROWAWAY);
});
