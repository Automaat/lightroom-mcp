import { describe, it, expect } from '@jest/globals';
import fs from 'node:fs';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { VERSION } from '../src/version.js';
import { createMcpServer } from '../src/create-server.js';

// Jest runs with cwd = server/; the repo root is one level up.
const repoRoot = path.resolve(process.cwd(), '..');
const readJson = (...rel: string[]): { version: string } =>
  JSON.parse(fs.readFileSync(path.join(repoRoot, ...rel), 'utf8')) as { version: string };

describe('version sources', () => {
  it('server/src/version.ts matches server/package.json', () => {
    expect(VERSION).toBe(readJson('server', 'package.json').version);
  });

  it('mcpb manifest matches package.json', () => {
    expect(readJson('mcpb', 'manifest.json').version).toBe(VERSION);
  });

  it('plugin Info.lua matches package.json', () => {
    const lua = fs.readFileSync(
      path.join(repoRoot, 'plugin', 'LightroomMCP.lrplugin', 'Info.lua'),
      'utf8',
    );
    const m = lua.match(/VERSION = \{ major=(\d+), minor=(\d+), revision=(\d+), build=\d+ \}/);
    expect(m).not.toBeNull();
    expect(`${m![1]}.${m![2]}.${m![3]}`).toBe(VERSION);
  });

  it('MCP server reports the shared version', async () => {
    const server = createMcpServer({
      isReady: () => true,
      dispatcher: { call: async () => ({ id: 'x', result: null }) },
    });
    const client = new Client({ name: 'test-client', version: '1.0.0' });
    const [clientT, serverT] = InMemoryTransport.createLinkedPair();
    await Promise.all([server.connect(serverT), client.connect(clientT)]);
    expect(client.getServerVersion()?.version).toBe(VERSION);
    await client.close();
  });
});
