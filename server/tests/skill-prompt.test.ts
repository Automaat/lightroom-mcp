import { describe, it, expect } from '@jest/globals';
import fs from 'node:fs';
import path from 'node:path';
import { SKILL_PROMPT, getSkillPrompt } from '../src/skill-prompt.js';

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

describe('skill prompt vs mcpb manifest', () => {
  it('declares exactly the prompts the server lists', () => {
    expect(readManifestPrompts().map((prompt) => [prompt.name, prompt.description]))
      .toEqual([[SKILL_PROMPT.name, SKILL_PROMPT.description]]);
  });

  it('declares the joined, trimmed text Claude Desktop compares with the served prompt', () => {
    const [declared] = readManifestPrompts();
    const served = getSkillPrompt(SKILL_PROMPT.name).messages
      .map((message) => message.content.text).join('\n').trim();

    expect(declared.arguments).toBeUndefined();
    expect(declared.text).not.toMatch(/\$\{arguments\.\w+\}/);
    expect(declared.text).toBe(served);
  });
});
