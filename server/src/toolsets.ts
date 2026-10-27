export const TOOLSET_NAMES = ["core", "develop", "masks"] as const;
export type Toolset = typeof TOOLSET_NAMES[number];

export function parseToolsets(raw?: string): readonly Toolset[] {
  if (raw === undefined || raw.trim() === "") return ["core"];
  const requested = raw.split(",").map((name) => name.trim());
  for (const name of requested) {
    if (name !== "all" && !TOOLSET_NAMES.some((valid) => valid === name)) {
      throw new Error(`LIGHTROOM_MCP_TOOLSETS has unknown toolset "${name}". Valid names: core, develop, masks, all.`);
    }
  }
  return TOOLSET_NAMES.filter((name) => name === "core" || requested.includes("all") || requested.includes(name));
}
