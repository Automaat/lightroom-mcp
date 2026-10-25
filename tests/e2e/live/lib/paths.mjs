import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const LIVE_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const REPO_ROOT = path.resolve(LIVE_DIR, "..", "..", "..");
export const SERVER_BIN = path.join(REPO_ROOT, "server", "dist", "index.js");
export const CANDIDATE_BUNDLE_DIR = path.join(REPO_ROOT, "plugin", "LightroomMCP.lrplugin");

export const FIXTURES_DIR = process.env.LRMCP_LIVE_FIXTURES_DIR ?? path.join(LIVE_DIR, ".fixtures");
export const GENERATED_DIR = path.join(FIXTURES_DIR, "generated");
export const SAMPLES_DIR = path.join(FIXTURES_DIR, "samples");
export const MANIFEST_PATH = path.join(LIVE_DIR, "manifest.json");

const CACHE_DIR = path.join(os.homedir(), ".cache");
export const SNAPSHOTS_DIR = path.join(CACHE_DIR, "lightroom-mcp-live-snapshots");
export const BUNDLE_BACKUPS_DIR = path.join(CACHE_DIR, "lightroom-mcp-live-backups");

export const LIGHTROOM_PROCESS_NAME = "Adobe Lightroom Classic";
export const REAL_CATALOG_DIR = path.join(os.homedir(), "Pictures", "Lightroom");
export const REAL_CATALOG_PATH = path.join(REAL_CATALOG_DIR, "Lightroom Catalog.lrcat");
export const THROWAWAY_MARKER_FILE = "lrmcp-live-catalog.json";
export const THROWAWAY_CATALOG_ENV = "LRMCP_LIVE_THROWAWAY_CATALOG";

export const PLUGINS_DIR = path.join(os.homedir(), "Library", "Application Support", "Adobe", "Lightroom", "Plugins");
export const INSTALLED_BUNDLE_DIR = path.join(PLUGINS_DIR, "LightroomMCP.lrplugin");
