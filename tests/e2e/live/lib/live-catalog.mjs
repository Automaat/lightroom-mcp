import fs from "node:fs";
import path from "node:path";
import { requireThrowawayCatalog } from "./catalog-guard.mjs";
import { McpSession } from "./mcp.mjs";
import { THROWAWAY_MARKER_FILE } from "./paths.mjs";

export function markerPathFor(catalogPath) {
  return path.join(path.dirname(catalogPath), THROWAWAY_MARKER_FILE);
}

export function readCatalogMarker(catalogPath) {
  return JSON.parse(fs.readFileSync(markerPathFor(catalogPath), "utf8"));
}

export function writeCatalogMarker(catalogPath, marker) {
  fs.writeFileSync(markerPathFor(catalogPath), JSON.stringify(marker, null, 2) + "\n");
}

export function fixtureIdOrNull(marker, key) {
  return marker.fixtures?.[key]?.id ?? null;
}

export function requireFixtureId(marker, key) {
  const id = fixtureIdOrNull(marker, key);
  if (id === null) throw new Error(`fixture ${key} is not in the throwaway catalog; run setup-catalog.mjs`);
  return id;
}

export async function openLiveSession() {
  const catalogPath = requireThrowawayCatalog();
  const marker = readCatalogMarker(catalogPath);
  const session = await new McpSession().start();
  return { session, marker, catalogPath };
}
