import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { BUNDLE_BACKUPS_DIR, CANDIDATE_BUNDLE_DIR, INSTALLED_BUNDLE_DIR } from "./paths.mjs";

const LATEST_BACKUP_FILE = "latest.json";

export function listLuaFiles(directory) {
  return fs
    .readdirSync(directory, { recursive: true })
    .map((entry) => String(entry))
    .filter((entry) => entry.endsWith(".lua"))
    .sort();
}

export function addedLuaFiles(installedFiles, candidateFiles) {
  const installed = new Set(installedFiles);
  return candidateFiles.filter((file) => !installed.has(file));
}

function realpathThroughExistingAncestor(target) {
  const missing = [];
  let existing = path.resolve(target);
  while (!fs.existsSync(existing)) {
    missing.unshift(path.basename(existing));
    existing = path.dirname(existing);
  }
  return path.join(fs.realpathSync(existing), ...missing);
}

export function assertOutsideTemporaryDirectory(directory, temporaryDirectory = os.tmpdir()) {
  const resolved = realpathThroughExistingAncestor(directory);
  const temporary = realpathThroughExistingAncestor(temporaryDirectory);
  const relative = path.relative(temporary, resolved);
  if (relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative))) {
    throw new Error(`backups must live outside the temporary directory (${temporary}), got ${resolved}`);
  }
}

function syncBundle(sourceDirectory, destinationDirectory) {
  execFileSync("rsync", ["-a", "--delete", `${sourceDirectory}/`, `${destinationDirectory}/`]);
}

export function bundlesIdentical(leftDirectory, rightDirectory) {
  try {
    execFileSync("diff", ["-rq", leftDirectory, rightDirectory], { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

export function installCandidateBundle({
  candidateDirectory = CANDIDATE_BUNDLE_DIR,
  installedDirectory = INSTALLED_BUNDLE_DIR,
  backupsDirectory = BUNDLE_BACKUPS_DIR,
} = {}) {
  assertOutsideTemporaryDirectory(backupsDirectory);
  const stamp = new Date().toISOString().replace(/[-:.TZ]/g, "").slice(0, 14);
  const backupDirectory = path.join(backupsDirectory, `${stamp}`, path.basename(installedDirectory));
  fs.mkdirSync(path.dirname(backupDirectory), { recursive: true });
  syncBundle(installedDirectory, backupDirectory);
  if (!bundlesIdentical(installedDirectory, backupDirectory)) throw new Error("backup does not match the installed bundle");
  fs.writeFileSync(
    path.join(backupsDirectory, LATEST_BACKUP_FILE),
    JSON.stringify({ backupDirectory, installedDirectory, createdAt: new Date().toISOString() }, null, 2) + "\n",
  );

  const newLuaFiles = addedLuaFiles(listLuaFiles(installedDirectory), listLuaFiles(candidateDirectory));
  syncBundle(candidateDirectory, installedDirectory);
  if (!bundlesIdentical(candidateDirectory, installedDirectory)) throw new Error("installed bundle does not match the candidate");
  return { backupDirectory, addedLuaFiles: newLuaFiles, needsFullLightroomRestart: newLuaFiles.length > 0 };
}

export function latestBackup(backupsDirectory = BUNDLE_BACKUPS_DIR) {
  return JSON.parse(fs.readFileSync(path.join(backupsDirectory, LATEST_BACKUP_FILE), "utf8"));
}

export function restoreBundle({ backupDirectory, installedDirectory = INSTALLED_BUNDLE_DIR }) {
  if (!fs.existsSync(backupDirectory)) throw new Error(`backup not found: ${backupDirectory}`);
  syncBundle(backupDirectory, installedDirectory);
  if (!bundlesIdentical(backupDirectory, installedDirectory)) throw new Error("restored bundle does not match the backup");
  return installedDirectory;
}
