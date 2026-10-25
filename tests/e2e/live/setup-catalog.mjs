#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  assertThrowawayCatalog,
  currentOpenCatalogs,
  isRealCatalog,
  lightroomPid,
} from "./lib/catalog-guard.mjs";
import {
  dismissBlockingModals,
  ensureLightroomFrontmost,
  openNewCatalogDialog,
  sleep,
  submitNewCatalogDialog,
} from "./lib/ax.mjs";
import { markerPathFor, writeCatalogMarker } from "./lib/live-catalog.mjs";
import { loadManifest, resolveSuppliedFiles, verifySample } from "./lib/manifest.mjs";
import { McpSession } from "./lib/mcp.mjs";
import { GENERATED_DIR, MANIFEST_PATH, SAMPLES_DIR } from "./lib/paths.mjs";

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const at = args.indexOf(name);
  return at === -1 ? fallback : args[at + 1];
};
const adoptOpenCatalog = args.includes("--adopt-open-catalog");
const parentDirectory = path.resolve(option("--parent-dir", path.join(os.homedir(), "Documents")));
const stamp = new Date().toISOString().replace(/[-:.TZ]/g, "").slice(0, 14);
const catalogName = option("--name", `lrmcp-live-${stamp}`);

const NEW_CATALOG_RELAUNCH_TIMEOUT_MS = 240_000;
const PLUGIN_READY_TIMEOUT_MS = 180_000;

function collectFixtureFiles() {
  const manifest = loadManifest(MANIFEST_PATH);
  const files = [];
  const generated = JSON.parse(fs.readFileSync(path.join(GENERATED_DIR, "generated.json"), "utf8"));
  for (const [key, entry] of Object.entries(generated)) files.push({ key, source: path.join(GENERATED_DIR, entry.file) });
  for (const sample of manifest.samples) files.push({ key: sample.key, source: path.join(SAMPLES_DIR, sample.file) });
  for (const supplied of resolveSuppliedFiles(manifest)) {
    if (supplied.status === "present") {
      files.push({ key: supplied.key, source: supplied.filePath, extension: path.extname(supplied.filePath) });
    }
  }
  return { files, manifest };
}

async function assertFixturesReady(manifest) {
  for (const sample of manifest.samples) {
    const result = await verifySample(sample, SAMPLES_DIR);
    if (result.status !== "ok") throw new Error(`${sample.key} is ${result.status}; run mise run live:fixtures`);
  }
  if (!fs.existsSync(path.join(GENERATED_DIR, "generated.json"))) {
    throw new Error("generated fixtures are missing; run mise run live:fixtures");
  }
}

async function createCatalogThroughMenu(expectedCatalogPath) {
  if (lightroomPid() === null) throw new Error("Lightroom is not running; start it and bring it to the front");
  if (fs.existsSync(path.dirname(expectedCatalogPath))) throw new Error(`${path.dirname(expectedCatalogPath)} already exists`);
  await ensureLightroomFrontmost();
  await dismissBlockingModals();
  await openNewCatalogDialog();
  await submitNewCatalogDialog(path.basename(path.dirname(expectedCatalogPath)), path.basename(parentDirectory));
  const deadline = Date.now() + NEW_CATALOG_RELAUNCH_TIMEOUT_MS;
  while (Date.now() < deadline) {
    await sleep(3000);
    if (currentOpenCatalogs().some((open) => path.resolve(open) === expectedCatalogPath)) return;
  }
  throw new Error(`Lightroom did not open ${expectedCatalogPath} within ${NEW_CATALOG_RELAUNCH_TIMEOUT_MS / 1000}s`);
}

async function startSessionWhenPluginAnswers() {
  const deadline = Date.now() + PLUGIN_READY_TIMEOUT_MS;
  let lastError = null;
  while (Date.now() < deadline) {
    await ensureLightroomFrontmost();
    const dismissed = await dismissBlockingModals();
    for (const entry of dismissed) console.log(`dismissed "${entry.title}" with ${entry.button}: ${entry.text}`);
    const session = new McpSession();
    try {
      return await session.start();
    } catch (error) {
      lastError = error;
      await session.stop();
      await sleep(3000);
    }
  }
  throw new Error(`plugin did not answer (${lastError?.message}); open Plug-in Manager, Stop Server, Start Server, rerun with --adopt-open-catalog`);
}

async function importFixtures(session, catalogPath, files) {
  const imagesDirectory = path.join(path.dirname(catalogPath), "images");
  fs.mkdirSync(imagesDirectory, { recursive: true });
  const fixtures = {};
  for (const { key, source, extension } of files) {
    const fileName = extension ? `${key}${extension}` : path.basename(source);
    const target = path.join(imagesDirectory, fileName);
    fs.copyFileSync(source, target);
    const imported = await session.toolOrThrow("import_photos", { source_path: target }, { timeoutMs: 180_000 });
    if (imported.data.imported !== 1) throw new Error(`${key}: import_photos reported ${JSON.stringify(imported.data)}`);
    const found = await session.toolOrThrow("search_photos", { filename: fileName, limit: 10 });
    const match = found.data.photos.find((photo) => photo.filename === fileName);
    if (!match) throw new Error(`${key}: ${fileName} not found after import`);
    fixtures[key] = { id: match.id, file: fileName, path: target };
    console.log(`${key}: photo ${match.id}`);
  }
  return fixtures;
}

const { files, manifest } = collectFixtureFiles();
await assertFixturesReady(manifest);

let catalogPath;
if (adoptOpenCatalog) {
  const open = currentOpenCatalogs();
  if (open.length !== 1) throw new Error(`expected one open catalog, found ${open.length}`);
  catalogPath = path.resolve(open[0]);
  if (isRealCatalog(catalogPath)) throw new Error(`refusing to adopt the real catalog ${catalogPath}`);
  if (fs.existsSync(markerPathFor(catalogPath))) throw new Error(`${catalogPath} is already set up`);
} else {
  const targetDirectory = path.join(parentDirectory, catalogName);
  catalogPath = path.join(targetDirectory, `${catalogName}.lrcat`);
  if (isRealCatalog(catalogPath)) throw new Error("the throwaway catalog must not live under the real catalog folder");
  await createCatalogThroughMenu(catalogPath);
}

const session = await startSessionWhenPluginAnswers();
try {
  if (adoptOpenCatalog) {
    const existing = await session.toolOrThrow("search_photos", { limit: 1 });
    if ((existing.data.photos ?? []).length > 0) throw new Error("refusing to adopt a catalog that already holds photos");
  }
  writeCatalogMarker(catalogPath, { createdAt: new Date().toISOString(), catalogPath, fixtures: {} });
  assertThrowawayCatalog(currentOpenCatalogs());
  const fixtures = await importFixtures(session, catalogPath, files);
  writeCatalogMarker(catalogPath, { createdAt: new Date().toISOString(), catalogPath, fixtures });
  console.log(`throwaway catalog ready: ${catalogPath}`);
} finally {
  await session.stop();
}
