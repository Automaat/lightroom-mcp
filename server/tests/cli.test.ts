import { describe, it, expect } from '@jest/globals';
import { parseCli } from '../src/cli.js';

describe('parseCli', () => {
  function p(...args: string[]) {
    return parseCli(['node', 'index.js', ...args]);
  }

  it('defaults to stdio with no args', () => {
    expect(p().command).toBe('stdio');
  });

  it('parses explicit stdio', () => {
    expect(p('stdio').command).toBe('stdio');
  });

  it('parses install-plugin command', () => {
    expect(p('install-plugin').command).toBe('install-plugin');
  });

  it('parses help', () => {
    expect(p('--help').command).toBe('help');
    expect(p('-h').command).toBe('help');
  });

  it('parses version', () => {
    expect(p('--version').command).toBe('version');
    expect(p('-v').command).toBe('version');
  });

  it('throws on unknown command', () => {
    expect(() => p('frobnicate')).toThrow(/Unknown command/);
  });
});
