export function parseReadOnly(raw?: string): boolean {
  const value = raw?.trim() ?? "";
  if (value === "" || value === "false" || value === "0") return false;
  if (value === "true" || value === "1") return true;
  throw new Error(`LIGHTROOM_MCP_READ_ONLY has invalid value "${value}". Accepted values: true, 1, false, 0; unset or empty means false.`);
}
