#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { openLiveSession, writeCatalogMarker } from "./lib/live-catalog.mjs";
import { GENERATED_DIR } from "./lib/paths.mjs";

const sourceDirectory = path.join(GENERATED_DIR, "batch");
if (!fs.existsSync(sourceDirectory)) {
  console.error("no batch images; run make-batch.mjs first");
  process.exit(1);
}

const { session, marker, catalogPath } = await openLiveSession();
try {
  const imagesDirectory = path.join(path.dirname(catalogPath), "images", "batch");
  fs.mkdirSync(imagesDirectory, { recursive: true });
  for (const fileName of fs.readdirSync(sourceDirectory)) {
    fs.copyFileSync(path.join(sourceDirectory, fileName), path.join(imagesDirectory, fileName));
  }
  const imported = await session.toolOrThrow("import_photos", { source_path: imagesDirectory }, { timeoutMs: 600_000 });
  console.log(imported.text);
  const found = await session.toolOrThrow("search_photos", { filename: "batch_", limit: 2000 });
  const ids = found.data.photos
    .filter((photo) => /^batch_\d{3}\.jpg$/.test(photo.filename))
    .sort((a, b) => a.filename.localeCompare(b.filename))
    .map((photo) => photo.id);
  writeCatalogMarker(catalogPath, { ...marker, batch: { ids, directory: imagesDirectory } });
  console.log(`${ids.length} batch photos recorded in the catalog marker`);
} finally {
  await session.stop();
}
