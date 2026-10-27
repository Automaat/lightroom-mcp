import { describe, it, expect } from '@jest/globals';
import fs from 'node:fs';
import path from 'node:path';
import { parseToolsets } from '../src/toolsets.js';

describe('toolset parser', () => {
  it.each([undefined, '', '   ', '\t\n'])('defaults %p to core', (raw) => {
    expect(parseToolsets(raw)).toEqual(['core']);
  });

  it.each([
    ['core', ['core']],
    ['develop', ['core', 'develop']],
    ['masks', ['core', 'masks']],
    ['masks, develop,core,develop', ['core', 'develop', 'masks']],
    ['all', ['core', 'develop', 'masks']],
    ['all,develop', ['core', 'develop', 'masks']],
  ])('parses %s', (raw, expected) => {
    expect(parseToolsets(raw)).toEqual(expected);
  });

  it.each(['develp', 'Develop', 'all,typo', ',', 'develop,', '${user_config.toolsets}'])('rejects %s with valid names', (raw) => {
    expect(() => parseToolsets(raw)).toThrow('LIGHTROOM_MCP_TOOLSETS');
    expect(() => parseToolsets(raw)).toThrow('Valid names: core, develop, masks, all');
  });

  it('wires every bundle environment reference to a defined setting with a default', () => {
    const manifest = JSON.parse(fs.readFileSync(path.resolve(process.cwd(), '..', 'mcpb/manifest.json'), 'utf8')) as {
      user_config: Record<string, { default: string }>;
      server: { mcp_config: { env: Record<string, string> } };
    };
    const env = manifest.server.mcp_config.env;
    expect(env.LIGHTROOM_MCP_TOOLSETS).toBe('${user_config.toolsets}');
    expect(manifest.user_config.toolsets.default).toBe('core');
    for (const value of Object.values(env)) {
      for (const match of value.matchAll(/\$\{user_config\.([^}]+)\}/g)) {
        expect(manifest.user_config).toHaveProperty(match[1]);
        expect(manifest.user_config[match[1]].default).toBeDefined();
      }
    }
  });
});
