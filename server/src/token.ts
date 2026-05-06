import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export function tokenFilePath(): string {
  return (
    process.env.LIGHTROOM_MCP_TOKEN_PATH ??
    path.join(os.homedir(), ".config", "lightroom-mcp", "token")
  );
}

export function readToken(): string {
  const p = tokenFilePath();
  let raw: string;
  try {
    raw = fs.readFileSync(p, "utf8");
  } catch {
    throw new Error(
      `Lightroom MCP token file not found at ${p}. ` +
        `Open Lightroom and click 'Start Server' in Plug-in Manager to generate one.`,
    );
  }
  const token = raw.trim();
  if (!token) throw new Error(`Token file ${p} is empty`);
  return token;
}
