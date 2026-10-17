/**
 * Splits a text stream into `\n`-terminated lines. Each chunk is scanned once
 * and an unterminated tail is kept as pieces, so a multi-megabyte line (a
 * preview's base64) costs linear time instead of a rescan per chunk.
 */
export class LineBuffer {
  private parts: string[] = [];
  private bytes = 0;

  push(chunk: string, onLine: (line: string) => void): void {
    let start = 0;
    let idx: number;
    while ((idx = chunk.indexOf("\n", start)) !== -1) {
      this.parts.push(chunk.slice(start, idx));
      const line = this.parts.join("").trim();
      this.parts = [];
      this.bytes = 0;
      start = idx + 1;
      if (line) onLine(line);
    }
    if (start < chunk.length) {
      const rest = start === 0 ? chunk : chunk.slice(start);
      this.parts.push(rest);
      this.bytes += Buffer.byteLength(rest);
    }
  }

  /** UTF-8 size of the unterminated tail. */
  pendingBytes(): number {
    return this.bytes;
  }

  clear(): void {
    this.parts = [];
    this.bytes = 0;
  }
}
