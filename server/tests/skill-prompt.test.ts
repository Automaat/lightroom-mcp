import { describe, it, expect } from '@jest/globals';
import { Client, InMemoryTransport } from '@modelcontextprotocol/client';
import fs from 'node:fs';
import path from 'node:path';
import { createMcpServer } from '../src/create-server.js';

interface ManifestPrompt {
  name: string;
  description?: string;
  arguments?: string[];
  text: string;
}

function readManifestPrompts(): ManifestPrompt[] {
  const manifestPath = path.resolve(process.cwd(), '..', 'mcpb', 'manifest.json');
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8')) as { prompts?: ManifestPrompt[] };
  return manifest.prompts ?? [];
}

async function connect(): Promise<Client> {
  const server = createMcpServer({
    isReady: () => false,
    dispatcher: { call: async () => ({ id: 'x', result: null }) },
  });
  const client = new Client({ name: 'test-client', version: '1.0.0' });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  return client;
}

describe('served prompts vs mcpb manifest', () => {
  it('declares exactly the prompts the server lists', async () => {
    const client = await connect();
    const { prompts } = await client.listPrompts();
    await client.close();

    expect(readManifestPrompts().map((prompt) => [prompt.name, prompt.description]))
      .toEqual(prompts.map((prompt) => [prompt.name, prompt.description]));
  });

  it('declares the joined, trimmed text Claude Desktop compares with each served prompt', async () => {
    const client = await connect();
    const declared = readManifestPrompts();
    const served = await Promise.all(declared.map(async (prompt) => {
      const { messages } = await client.getPrompt({ name: prompt.name });
      return messages.map((message) => (message.content.type === 'text' ? message.content.text : ''))
        .join('\n').trim();
    }));
    await client.close();

    expect(declared.length).toBeGreaterThan(0);
    for (const [index, prompt] of declared.entries()) {
      expect(prompt.arguments).toBeUndefined();
      expect(prompt.text).not.toMatch(/\$\{arguments\.\w+\}/);
      expect(prompt.text).toBe(served[index]);
    }
  });
});
