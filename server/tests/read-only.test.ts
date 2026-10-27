import { describe, expect, it } from '@jest/globals';
import { parseReadOnly } from '../src/read-only.js';

describe('read-only parser', () => {
  it.each([undefined, '', '   ', '\t\n', 'false', '0', ' false '])('disables for %p', (raw) => {
    expect(parseReadOnly(raw)).toBe(false);
  });
  it.each(['true', '1', ' true ', '\t1\n'])('enables for %p', (raw) => {
    expect(parseReadOnly(raw)).toBe(true);
  });
  it.each(['TRUE', 'False', 'yes', '2', 'true,false', '${user_config.read_only}'])('rejects %s with accepted values', (raw) => {
    expect(() => parseReadOnly(raw)).toThrow('LIGHTROOM_MCP_READ_ONLY');
    expect(() => parseReadOnly(raw)).toThrow('Accepted values: true, 1, false, 0');
  });
});
