#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { execSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "..");
const stage = path.join(repoRoot, "build", "mcpb-stage");
const outDir = path.join(repoRoot, "build");
const outFile = path.join(outDir, "lightroom-mcp.mcpb");

const log = (m) => console.log(`[build-mcpb] ${m}`);

function rm(p) {
  if (fs.existsSync(p)) fs.rmSync(p, { recursive: true, force: true });
}

function run(cmd, cwd) {
  log(`$ ${cmd} (cwd=${path.relative(repoRoot, cwd)})`);
  execSync(cmd, { cwd, stdio: "inherit" });
}

function copyFile(src, dest) {
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.copyFileSync(src, dest);
}

function copyDir(src, dest, opts = {}) {
  const skip = new Set(opts.skip ?? []);
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    if (skip.has(entry.name)) continue;
    const s = path.join(src, entry.name);
    const d = path.join(dest, entry.name);
    if (entry.isDirectory()) copyDir(s, d, opts);
    else if (entry.isSymbolicLink()) {
      const link = fs.readlinkSync(s);
      try {
        fs.symlinkSync(link, d);
      } catch {
        fs.copyFileSync(s, d);
      }
    } else fs.copyFileSync(s, d);
  }
}

log("cleaning previous stage");
rm(stage);
fs.mkdirSync(stage, { recursive: true });
fs.mkdirSync(outDir, { recursive: true });

log("building TypeScript");
run("npm ci", path.join(repoRoot, "server"));
run("npx tsc", path.join(repoRoot, "server"));

log("staging server runtime");
const srcServer = path.join(repoRoot, "server");
const dstServer = path.join(stage, "server");
fs.mkdirSync(dstServer, { recursive: true });
copyDir(path.join(srcServer, "dist"), path.join(dstServer, "dist"));
copyFile(path.join(srcServer, "package.json"), path.join(dstServer, "package.json"));
copyFile(
  path.join(srcServer, "package-lock.json"),
  path.join(dstServer, "package-lock.json"),
);

log("installing production node_modules into stage");
run("npm ci --omit=dev --ignore-scripts", dstServer);

log("staging Lightroom plugin");
copyDir(
  path.join(repoRoot, "plugin", "LightroomMCP.lrplugin"),
  path.join(stage, "LightroomMCP.lrplugin"),
);

log("copying manifest");
copyFile(path.join(repoRoot, "mcpb", "manifest.json"), path.join(stage, "manifest.json"));

const iconSrc = path.join(repoRoot, "mcpb", "icon.png");
if (fs.existsSync(iconSrc)) {
  copyFile(iconSrc, path.join(stage, "icon.png"));
}

log("packing .mcpb via @anthropic-ai/mcpb");
const result = spawnSync(
  "npx",
  ["--yes", "@anthropic-ai/mcpb@latest", "pack", stage, outFile],
  { stdio: "inherit", cwd: repoRoot, shell: process.platform === "win32" },
);
if (result.status !== 0) {
  process.exit(result.status ?? 1);
}

const stat = fs.statSync(outFile);
log(`wrote ${path.relative(repoRoot, outFile)} (${(stat.size / 1024).toFixed(1)} KB)`);
