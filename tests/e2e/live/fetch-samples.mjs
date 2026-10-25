#!/usr/bin/env node
import { MANIFEST_PATH, SAMPLES_DIR } from "./lib/paths.mjs";
import {
  downloadSample,
  loadManifest,
  resolveSuppliedFiles,
  validateManifest,
  verifySample,
} from "./lib/manifest.mjs";

const verifyOnly = process.argv.includes("--verify");
const manifest = loadManifest(MANIFEST_PATH);

const problems = validateManifest(manifest);
if (problems.length > 0) {
  console.error(problems.join("\n"));
  process.exit(2);
}

let failed = 0;
for (const sample of manifest.samples) {
  let result = await verifySample(sample, SAMPLES_DIR);
  if (result.status !== "ok" && !verifyOnly) {
    if (result.status === "mismatch") console.log(`${sample.key}: hash mismatch, downloading again`);
    else console.log(`${sample.key}: downloading ${sample.url}`);
    await downloadSample(sample, SAMPLES_DIR);
    result = await verifySample(sample, SAMPLES_DIR);
  }
  console.log(`${sample.key}: ${result.status} ${result.filePath}`);
  if (result.status !== "ok") failed++;
}

for (const supplied of resolveSuppliedFiles(manifest)) {
  const detail = supplied.filePath ? ` ${supplied.filePath}` : "";
  console.log(`${supplied.key}: ${supplied.status}${detail} (${supplied.envVar})`);
}

process.exit(failed === 0 ? 0 : 1);
