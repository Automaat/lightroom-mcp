import { describe, it, expect, beforeEach, afterEach } from '@jest/globals';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { findBundledPlugin, installPlugin, lightroomModulesDir } from '../src/install-plugin.js';

describe('lightroomModulesDir', () => {
  it('returns a darwin path on macOS', () => {
    if (process.platform !== 'darwin') return;
    expect(lightroomModulesDir()).toMatch(/Library\/Application Support\/Adobe\/Lightroom\/Modules$/);
  });

  it('returns a Windows path on win32', () => {
    if (process.platform !== 'win32') return;
    expect(lightroomModulesDir()).toMatch(/Adobe[\\/]+Lightroom[\\/]+Modules$/);
  });
});

describe('installPlugin', () => {
  let tmp: string;

  beforeEach(() => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lrmcp-install-'));
  });

  afterEach(() => {
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  function makeFakePlugin(parent: string): string {
    const src = path.join(parent, 'LightroomMCP.lrplugin');
    fs.mkdirSync(src, { recursive: true });
    fs.writeFileSync(path.join(src, 'Info.lua'), '-- fake');
    fs.writeFileSync(path.join(src, 'Handler.lua'), '-- handler');
    return src;
  }

  it('copies the plugin into destDir on first install', () => {
    const sourceParent = fs.mkdtempSync(path.join(os.tmpdir(), 'lrmcp-src-'));
    try {
      const source = makeFakePlugin(sourceParent);
      const result = installPlugin({ source, destDir: tmp });
      expect(result.status).toBe('installed');
      expect(fs.existsSync(path.join(result.destination, 'Info.lua'))).toBe(true);
      expect(fs.existsSync(path.join(result.destination, 'Handler.lua'))).toBe(true);
    } finally {
      fs.rmSync(sourceParent, { recursive: true, force: true });
    }
  });

  it('reports already-present without overwriting on second call', () => {
    const sourceParent = fs.mkdtempSync(path.join(os.tmpdir(), 'lrmcp-src-'));
    try {
      const source = makeFakePlugin(sourceParent);
      installPlugin({ source, destDir: tmp });
      const dest = path.join(tmp, 'LightroomMCP.lrplugin', 'Info.lua');
      fs.writeFileSync(dest, '-- modified');
      const result = installPlugin({ source, destDir: tmp });
      expect(result.status).toBe('already-present');
      expect(fs.readFileSync(dest, 'utf8')).toBe('-- modified');
    } finally {
      fs.rmSync(sourceParent, { recursive: true, force: true });
    }
  });

  it('overwrites with force=true', () => {
    const sourceParent = fs.mkdtempSync(path.join(os.tmpdir(), 'lrmcp-src-'));
    try {
      const source = makeFakePlugin(sourceParent);
      installPlugin({ source, destDir: tmp });
      fs.writeFileSync(path.join(tmp, 'LightroomMCP.lrplugin', 'Info.lua'), '-- stale');
      const result = installPlugin({ source, destDir: tmp, force: true });
      expect(result.status).toBe('installed');
      expect(fs.readFileSync(path.join(tmp, 'LightroomMCP.lrplugin', 'Info.lua'), 'utf8')).toBe(
        '-- fake',
      );
    } finally {
      fs.rmSync(sourceParent, { recursive: true, force: true });
    }
  });

  it('skips when source missing', () => {
    const result = installPlugin({ source: path.join(tmp, 'nope'), destDir: tmp });
    expect(result.status).toBe('skipped');
    expect(result.reason).toMatch(/not found/);
  });

  it('skips when source is not a real .lrplugin (no Info.lua)', () => {
    const fake = path.join(tmp, 'Bogus.lrplugin');
    fs.mkdirSync(fake);
    const result = installPlugin({ source: fake, destDir: tmp });
    expect(result.status).toBe('skipped');
    expect(result.reason).toMatch(/Info\.lua/);
  });
});

describe('findBundledPlugin', () => {
  it('returns null when no plugin directory found', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lrmcp-find-'));
    try {
      expect(findBundledPlugin(dir)).toBeNull();
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  it('finds plugin one level up', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lrmcp-find-'));
    try {
      const plug = path.join(root, 'LightroomMCP.lrplugin');
      fs.mkdirSync(plug);
      fs.writeFileSync(path.join(plug, 'Info.lua'), '-- fake');
      const child = path.join(root, 'server', 'dist');
      fs.mkdirSync(child, { recursive: true });
      const found = findBundledPlugin(child);
      expect(found).not.toBeNull();
      expect(path.resolve(found!)).toBe(path.resolve(plug));
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
});
