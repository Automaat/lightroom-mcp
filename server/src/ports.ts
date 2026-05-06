const DEFAULT_REQUEST_PORT = 58763;
const DEFAULT_RESPONSE_PORT = 58764;

function parsePort(raw: string | undefined, fallback: number, name: string): number {
  if (raw === undefined || raw.trim() === "") return fallback;
  const trimmed = raw.trim();
  if (!/^[0-9]+$/.test(trimmed)) {
    throw new Error(`${name} must be a positive integer 1-65535, got "${raw}"`);
  }
  const n = Number(trimmed);
  if (!Number.isInteger(n) || n < 1 || n > 65535) {
    throw new Error(`${name} must be a positive integer 1-65535, got "${raw}"`);
  }
  return n;
}

export function requestPort(): number {
  return parsePort(
    process.env.LIGHTROOM_MCP_REQUEST_PORT,
    DEFAULT_REQUEST_PORT,
    "LIGHTROOM_MCP_REQUEST_PORT",
  );
}

export function responsePort(): number {
  return parsePort(
    process.env.LIGHTROOM_MCP_RESPONSE_PORT,
    DEFAULT_RESPONSE_PORT,
    "LIGHTROOM_MCP_RESPONSE_PORT",
  );
}
