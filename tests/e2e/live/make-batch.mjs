#!/usr/bin/env node
import path from "node:path";
import { DEFAULT_BATCH_COUNT, generateBatchImages } from "./lib/batch.mjs";
import { GENERATED_DIR, SAMPLES_DIR } from "./lib/paths.mjs";

const countArgument = process.argv[2];
const count = countArgument ? Number(countArgument) : DEFAULT_BATCH_COUNT;
if (!Number.isInteger(count) || count < 1 || count > 1000) {
  console.error("usage: make-batch.mjs [count 1..1000]");
  process.exit(2);
}

const written = generateBatchImages({
  rawPath: path.join(SAMPLES_DIR, "_DSC0009.ARW"),
  outputDirectory: path.join(GENERATED_DIR, "batch"),
  count,
});
console.log(`${written} distinct crops of the CC0 raw sample written to ${path.join(GENERATED_DIR, "batch")}`);
