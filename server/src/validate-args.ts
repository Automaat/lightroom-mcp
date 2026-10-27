import { Ajv, type ValidateFunction } from "ajv";
import type { PreviewArgs } from "./preview-region.js";
import {
  deleteMasksValidationSchema,
  developSettingKeysValidationSchema,
  developSettingsValidationSchema,
  TOOL_CONTRACTS,
} from "./tool-contracts.js";
import { PREVIEW_SIZE_ERROR } from "./preview-sizes.js";

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
  TOOL_CONTRACTS.map((contract) => {
    // Published schemas share values; dispatch still enforces each key's type.
    const settings = contract.name === "set_develop_settings"
      ? developSettingsValidationSchema
      : ["copy_develop_settings", "create_develop_preset"].includes(contract.name)
        ? { ...(contract.inputSchema.properties?.settings as object), ...developSettingKeysValidationSchema }
        : null;
    const schema = contract.name === "delete_masks"
      ? { ...contract.inputSchema, ...deleteMasksValidationSchema }
      : settings
        ? { ...contract.inputSchema, properties: { ...contract.inputSchema.properties, settings } }
        : contract.inputSchema;
    return [contract.name, ajv.compile(schema)];
  }),
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
 * Returns null for valid arguments, or a message naming invalid fields.
 * Unknown tool names pass through so the dispatcher keeps reporting them.
 */
export function validateToolArgs(name: string, args: unknown): string | null {
  const validate = validators.get(name);
  if (!validate) return null;
  if (validate(args ?? {})) {
    if (name === "get_photo_preview") {
      const region = (args as PreviewArgs).region;
      if (region && (region.x + region.width > 1 || region.y + region.height > 1)) {
        return "Invalid arguments for get_photo_preview: region must fit within the rendered frame";
      }
    }
    return null;
  }

  const problems = (validate.errors ?? []).map(error =>
    name === "get_photo_preview" && error.instancePath === "/size"
      ? PREVIEW_SIZE_ERROR
      : describe(error));
  const unique = [...new Set(problems)];
  return `Invalid arguments for ${name}: ${unique.join("; ")}`;
}
