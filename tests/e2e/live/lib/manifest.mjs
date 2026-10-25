import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const ALLOWED_SAMPLE_LICENSE = "CC0-1.0";

export function loadManifest(manifestPath) {
  return JSON.parse(fs.readFileSync(manifestPath, "utf8"));
}

export function validateManifest(manifest) {
  const problems = [];
  const keys = new Set();
  for (const sample of manifest.samples ?? []) {
    if (keys.has(sample.key)) problems.push(`${sample.key}: duplicate key`);
    keys.add(sample.key);
    if (!SHA256_PATTERN.test(sample.sha256 ?? "")) problems.push(`${sample.key}: sha256 must be 64 lowercase hex characters`);
    if (!String(sample.url ?? "").startsWith("https://")) problems.push(`${sample.key}: url must be https`);
    if (sample.license !== ALLOWED_SAMPLE_LICENSE) problems.push(`${sample.key}: only ${ALLOWED_SAMPLE_LICENSE} samples may be downloaded`);
    if (path.basename(sample.file ?? "") !== sample.file || !sample.file) problems.push(`${sample.key}: file must be a bare file name`);
  }
  for (const supplied of manifest.supplied ?? []) {
    if (!/^LRMCP_LIVE_[A-Z_]+$/.test(supplied.envVar ?? "")) problems.push(`${supplied.key}: envVar must look like LRMCP_LIVE_NAME`);
  }
  return problems;
}

export async function sha256File(filePath) {
  const hash = createHash("sha256");
  await pipeline(fs.createReadStream(filePath), hash);
  return hash.digest("hex");
}

export async function verifySample(sample, directory) {
  const filePath = path.join(directory, sample.file);
  if (!fs.existsSync(filePath)) return { status: "missing", filePath };
  const actual = await sha256File(filePath);
  return { status: actual === sample.sha256 ? "ok" : "mismatch", filePath, actual };
}

export async function downloadSample(sample, directory, fetchImplementation = fetch) {
  fs.mkdirSync(directory, { recursive: true });
  const filePath = path.join(directory, sample.file);
  const partialPath = `${filePath}.partial`;
  const response = await fetchImplementation(sample.url, { redirect: "follow" });
  if (!response.ok || !response.body) throw new Error(`${sample.key}: download failed with HTTP ${response.status}`);
  try {
    await pipeline(Readable.fromWeb(response.body), fs.createWriteStream(partialPath));
    const actual = await sha256File(partialPath);
    if (actual !== sample.sha256) throw new Error(`${sample.key}: sha256 mismatch, expected ${sample.sha256}, got ${actual}`);
    fs.renameSync(partialPath, filePath);
  } finally {
    fs.rmSync(partialPath, { force: true });
  }
  return filePath;
}

export function resolveSuppliedFiles(manifest, environment = process.env) {
  return (manifest.supplied ?? []).map((supplied) => {
    const value = environment[supplied.envVar];
    if (!value) return { ...supplied, status: "not-set" };
    return { ...supplied, status: fs.existsSync(value) ? "present" : "missing-file", filePath: value };
  });
}
