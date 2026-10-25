import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import {
  DOWNLOADABLE_URLS,
  allowlistedUrl,
  downloadSample,
  loadManifest,
  resolveSuppliedFiles,
  sha256File,
  validateManifest,
  verifySample,
} from "../lib/manifest.mjs";
import { MANIFEST_PATH } from "../lib/paths.mjs";

const PAYLOAD = Buffer.from("raw sample stand-in");
const PAYLOAD_SHA256 = createHash("sha256").update(PAYLOAD).digest("hex");

let server;
let baseUrl;
let workDirectory;

before(async () => {
  workDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "lrmcp-manifest-"));
  server = http.createServer((request, response) => {
    if (request.url === "/missing") {
      response.writeHead(404).end();
      return;
    }
    response.writeHead(200, { "content-type": "application/octet-stream" }).end(PAYLOAD);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  await new Promise((resolve) => server.close(resolve));
  fs.rmSync(workDirectory, { recursive: true, force: true });
});

function localUrls() {
  return [`${baseUrl}/ok`, `${baseUrl}/missing`];
}

function sample(overrides = {}) {
  return { key: "stand_in", file: "stand_in.bin", url: `${baseUrl}/ok`, sha256: PAYLOAD_SHA256, ...overrides };
}

test("the committed manifest is valid and lists only CC0 samples", () => {
  const manifest = loadManifest(MANIFEST_PATH);
  assert.deepEqual(validateManifest(manifest), []);
  assert.ok(manifest.samples.length > 0);
  for (const entry of manifest.samples) assert.equal(entry.license, "CC0-1.0");
});

test("validation reports bad hashes, plain http, other licenses and path traversal", () => {
  const problems = validateManifest({
    samples: [{ key: "bad", file: "../escape", url: "http://example.com/a", sha256: "xyz", license: "CC-BY-4.0" }],
    supplied: [{ key: "lowercase", envVar: "depth" }],
  });
  assert.equal(problems.length, 5);
});

test("validation reports duplicate keys", () => {
  const good = { key: "a", file: "a.bin", url: "https://example.com/a", sha256: PAYLOAD_SHA256, license: "CC0-1.0" };
  assert.match(validateManifest({ samples: [good, good] }).join("\n"), /duplicate key/);
});

test("verify distinguishes missing, ok and mismatch", async () => {
  const directory = path.join(workDirectory, "verify");
  fs.mkdirSync(directory);
  assert.equal((await verifySample(sample(), directory)).status, "missing");
  fs.writeFileSync(path.join(directory, "stand_in.bin"), PAYLOAD);
  assert.equal((await verifySample(sample(), directory)).status, "ok");
  fs.writeFileSync(path.join(directory, "stand_in.bin"), "tampered");
  const result = await verifySample(sample(), directory);
  assert.equal(result.status, "mismatch");
  assert.notEqual(result.actual, PAYLOAD_SHA256);
});

test("download stores a file whose hash matches", async () => {
  const directory = path.join(workDirectory, "download-ok");
  const filePath = await downloadSample(sample(), directory, { allowedUrls: localUrls() });
  assert.equal(await sha256File(filePath), PAYLOAD_SHA256);
  assert.deepEqual(fs.readdirSync(directory), ["stand_in.bin"]);
});

test("download refuses a hash mismatch and leaves nothing behind", async () => {
  const directory = path.join(workDirectory, "download-bad");
  await assert.rejects(downloadSample(sample({ sha256: "0".repeat(64) }), directory, { allowedUrls: localUrls() }), /sha256 mismatch/);
  assert.deepEqual(fs.readdirSync(directory), []);
});

test("download refuses an HTTP error", async () => {
  const directory = path.join(workDirectory, "download-404");
  await assert.rejects(downloadSample(sample({ url: `${baseUrl}/missing` }), directory, { allowedUrls: localUrls() }), /HTTP 404/);
});

test("supplied files are resolved from environment variables", () => {
  const present = path.join(workDirectory, "supplied.heic");
  fs.writeFileSync(present, "x");
  const manifest = {
    supplied: [
      { key: "a", envVar: "LRMCP_LIVE_A" },
      { key: "b", envVar: "LRMCP_LIVE_B" },
      { key: "c", envVar: "LRMCP_LIVE_C" },
    ],
  };
  const resolved = resolveSuppliedFiles(manifest, {
    LRMCP_LIVE_A: present,
    LRMCP_LIVE_B: path.join(workDirectory, "absent.heic"),
  });
  assert.deepEqual(
    resolved.map((entry) => entry.status),
    ["present", "missing-file", "not-set"],
  );
});

test("downloads outside the allowlist are refused before any request", async () => {
  const directory = path.join(workDirectory, "download-foreign");
  await assert.rejects(downloadSample(sample({ url: "https://example.com/a.ARW" }), directory), /not in the downloader allowlist/);
  assert.equal(fs.existsSync(directory), false);
  assert.equal(allowlistedUrl(DOWNLOADABLE_URLS[0], DOWNLOADABLE_URLS), DOWNLOADABLE_URLS[0]);
  assert.throws(() => allowlistedUrl(`${DOWNLOADABLE_URLS[0]}.evil`, DOWNLOADABLE_URLS));
});

test("every manifest sample url is in the downloader allowlist", () => {
  for (const entry of loadManifest(MANIFEST_PATH).samples) assert.ok(DOWNLOADABLE_URLS.includes(entry.url), entry.key);
});
