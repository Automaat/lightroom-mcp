import { describe, it, expect } from '@jest/globals';
import { LineBuffer } from '../src/line-buffer.js';

function feed(chunks: string[]): { lines: string[]; pending: number } {
  const buf = new LineBuffer();
  const lines: string[] = [];
  for (const chunk of chunks) buf.push(chunk, (line) => lines.push(line));
  return { lines, pending: buf.pendingBytes() };
}

describe('LineBuffer', () => {
  it.each([
    { name: 'one line in one chunk', chunks: ['{"a":1}\n'], lines: ['{"a":1}'], pending: 0 },
    { name: 'several lines in one chunk', chunks: ['a\nb\nc\n'], lines: ['a', 'b', 'c'], pending: 0 },
    { name: 'a line split across chunks', chunks: ['{"a"', ':', '1}\n'], lines: ['{"a":1}'], pending: 0 },
    { name: 'a newline that starts a chunk', chunks: ['abc', '\ndef\n'], lines: ['abc', 'def'], pending: 0 },
    { name: 'blank and whitespace-only lines', chunks: ['\n  \n x \r\n'], lines: ['x'], pending: 0 },
    { name: 'an unterminated tail', chunks: ['done\npart', 'ial'], lines: ['done'], pending: 7 },
    { name: 'a multibyte tail counted in bytes', chunks: ['zażółć'], lines: [], pending: 10 },
  ])('splits $name', ({ chunks, lines, pending }) => {
    expect(feed(chunks)).toEqual({ lines, pending });
  });

  it('reassembles a multi-megabyte line delivered in 64 KiB chunks', () => {
    const payload = 'A'.repeat(5 * 1024 * 1024);
    const text = `${payload}\nnext\n`;
    const chunks: string[] = [];
    for (let i = 0; i < text.length; i += 64 * 1024) chunks.push(text.slice(i, i + 64 * 1024));

    const { lines, pending } = feed(chunks);

    expect(lines.map((l) => l.length)).toEqual([payload.length, 4]);
    expect(pending).toBe(0);
  });

  it('drops the tail on clear', () => {
    const buf = new LineBuffer();
    const lines: string[] = [];
    buf.push('stale', (line) => lines.push(line));
    buf.clear();
    buf.push('fresh\n', (line) => lines.push(line));

    expect(lines).toEqual(['fresh']);
    expect(buf.pendingBytes()).toBe(0);
  });
});
