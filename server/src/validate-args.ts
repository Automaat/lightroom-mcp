import { Ajv, type ValidateFunction } from "ajv";
import { TOOL_CONTRACTS } from "./tool-contracts.js";

/**
 * The tool contracts publish a JSON Schema per tool, but nothing enforced it:
 * malformed arguments travelled to Lightroom and came back as raw Lua errors
 * ("attempt to concatenate field 'photo_id'"), and a typo'd filter name was
 * accepted in silence, quietly turning a filtered search into a full-catalog
 * scan. Validate here so a bad call fails immediately, with a message naming
 * the offending field.
 */
const ajv = new Ajv({ strict: false, allErrors: true });

const validators = new Map<string, ValidateFunction>(
  TOOL_CONTRACTS.map((contract) => [contract.name, ajv.compile(contract.inputSchema)]),
);

function describe(error: { instancePath?: string; message?: string; params?: unknown }): string {
  const field = error.instancePath ? error.instancePath.replace(/^\//, "").replace(/\//g, ".") : "";
  const params = error.params as { additionalProperty?: string } | undefined;
  const extra = params?.additionalProperty;
  if (extra) return `unknown property "${extra}"`;
  const what = error.message ?? "is invalid";
  return field ? `${field} ${what}` : what;
}

/**
 * Returns null when the arguments satisfy the tool's published schema, or a
 * human-readable message listing what is wrong. Unknown tool names pass
 * through so the dispatcher keeps reporting them.
 */
export function validateToolArgs(name: string, args: unknown): string | null {
  const validate = validators.get(name);
  if (!validate) return null;
  if (validate(args ?? {})) return null;

  const problems = (validate.errors ?? []).map(describe);
  const unique = [...new Set(problems)];
  return `Invalid arguments for ${name}: ${unique.join("; ")}`;
}
