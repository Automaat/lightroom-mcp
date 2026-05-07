import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export interface InstallResult {
  status: "installed" | "already-present" | "skipped";
  destination: string;
  reason?: string;
}

export function lightroomModulesDir(): string {
  if (process.platform === "darwin") {
    return path.join(
      os.homedir(),
      "Library",
      "Application Support",
      "Adobe",
      "Lightroom",
      "Modules",
    );
  }
  if (process.platform === "win32") {
    const appData = process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming");
    return path.join(appData, "Adobe", "Lightroom", "Modules");
  }
  return path.join(os.homedir(), ".local", "share", "Adobe", "Lightroom", "Modules");
}

export function lightroomPluginsDir(): string {
  if (process.platform === "darwin") {
    return path.join(
      os.homedir(),
      "Library",
      "Application Support",
      "Adobe",
      "Lightroom",
      "Plugins",
    );
  }
  if (process.platform === "win32") {
    const appData = process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming");
    return path.join(appData, "Adobe", "Lightroom", "Plugins");
  }
  return path.join(os.homedir(), ".local", "share", "Adobe", "Lightroom", "Plugins");
}

export function isPluginInstalledAnywhere(): boolean {
  const targets = [
    path.join(lightroomModulesDir(), "LightroomMCP.lrplugin", "Info.lua"),
    path.join(lightroomPluginsDir(), "LightroomMCP.lrplugin", "Info.lua"),
  ];
  return targets.some((p) => {
    try {
      return fs.statSync(p).isFile();
    } catch {
      return false;
    }
  });
}

export function findBundledPlugin(startDir: string): string | null {
  const candidates = [
    path.join(startDir, "LightroomMCP.lrplugin"),
    path.join(startDir, "..", "LightroomMCP.lrplugin"),
    path.join(startDir, "..", "..", "LightroomMCP.lrplugin"),
    path.join(startDir, "..", "..", "..", "LightroomMCP.lrplugin"),
    path.join(startDir, "..", "plugin", "LightroomMCP.lrplugin"),
    path.join(startDir, "..", "..", "plugin", "LightroomMCP.lrplugin"),
    path.join(startDir, "..", "..", "..", "plugin", "LightroomMCP.lrplugin"),
  ];
  for (const c of candidates) {
    try {
      const st = fs.statSync(c);
      if (st.isDirectory() && fs.existsSync(path.join(c, "Info.lua"))) {
        return path.resolve(c);
      }
    } catch {
      // not present, keep looking
    }
  }
  return null;
}

export function installPlugin(opts: {
  source: string;
  destDir?: string;
  force?: boolean;
}): InstallResult {
  const destDir = opts.destDir ?? lightroomModulesDir();
  const destination = path.join(destDir, "LightroomMCP.lrplugin");

  if (!fs.existsSync(opts.source)) {
    return {
      status: "skipped",
      destination,
      reason: `Source plugin not found at ${opts.source}`,
    };
  }
  if (!fs.existsSync(path.join(opts.source, "Info.lua"))) {
    return {
      status: "skipped",
      destination,
      reason: `Source ${opts.source} is not a valid .lrplugin (missing Info.lua)`,
    };
  }

  if (!opts.force && fs.existsSync(destination)) {
    return { status: "already-present", destination };
  }

  fs.mkdirSync(destDir, { recursive: true });
  if (opts.force && fs.existsSync(destination)) {
    fs.rmSync(destination, { recursive: true, force: true });
  }
  copyDirRecursive(opts.source, destination);
  return { status: "installed", destination };
}

export function ensurePluginInstalled(startDir: string, log: (msg: string) => void): void {
  if (isPluginInstalledAnywhere()) return;
  const source = findBundledPlugin(startDir);
  if (!source) return;
  try {
    const result = installPlugin({ source });
    if (result.status === "installed") {
      log(`[install-plugin] copied ${source} → ${result.destination}`);
      log(`[install-plugin] restart Lightroom to load the plugin`);
    }
  } catch (err) {
    log(`[install-plugin] failed: ${(err as Error).message}`);
  }
}

function copyDirRecursive(src: string, dest: string): void {
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, entry.name);
    const d = path.join(dest, entry.name);
    if (entry.isDirectory()) copyDirRecursive(s, d);
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
