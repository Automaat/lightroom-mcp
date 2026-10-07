import type { Dispatcher } from "./dispatcher.js";
import { validateToolArgs } from "./validate-args.js";

export interface ToolHandlerDeps {
  dispatcher: Pick<Dispatcher, "call">;
  isReady: () => boolean;
  notReadyMessage?: () => string;
  settleReadiness?: () => Promise<void>;
}

interface TextBlock {
  type: "text";
  text: string;
}

interface ImageBlock {
  type: "image";
  data: string;
  mimeType: string;
}

export interface ToolResponse {
  // The first block is always text, so callers can read content[0].text.
  content: [TextBlock, ...(TextBlock | ImageBlock)[]];
  isError?: boolean;
  [key: string]: unknown;
}

interface ImagePayload {
  image: { data: string; mime_type: string };
  [key: string]: unknown;
}

function isImagePayload(result: unknown): result is ImagePayload {
  if (typeof result !== "object" || result === null || !("image" in result)) return false;
  const { image } = result;
  return typeof image === "object" && image !== null
    && "data" in image && typeof image.data === "string"
    && "mime_type" in image && typeof image.mime_type === "string";
}

// A plugin result carrying `image` (get_photo_preview) becomes an MCP image
// block. The rest of the result still comes first as JSON text, as for every
// other tool, without the base64 data repeated in it.
function successContent(result: unknown): ToolResponse["content"] {
  if (isImagePayload(result)) {
    const { image, ...rest } = result;
    return [
      { type: "text", text: JSON.stringify(rest, null, 2) },
      { type: "image", data: image.data, mimeType: image.mime_type },
    ];
  }
  return [{ type: "text", text: JSON.stringify(result, null, 2) }];
}

export const NOT_CONNECTED_MESSAGE =
  "Lightroom plugin not connected. Open Lightroom and click 'Start Server' in Plug-in Manager.";

export function createCallToolHandler(deps: ToolHandlerDeps) {
  return async (name: string, args: unknown): Promise<ToolResponse> => {
    const invalid = validateToolArgs(name, args);
    if (invalid) {
      return {
        content: [{ type: "text", text: invalid }],
        isError: true,
      };
    }

    await deps.settleReadiness?.();

    if (!deps.isReady()) {
      return {
        content: [{ type: "text", text: deps.notReadyMessage?.() ?? NOT_CONNECTED_MESSAGE }],
        isError: true,
      };
    }

    try {
      const resp = await deps.dispatcher.call(name, args);
      if (resp.error) {
        return {
          content: [{ type: "text", text: `Error: ${resp.error}` }],
          isError: true,
        };
      }
      return { content: successContent(resp.result) };
    } catch (e) {
      return {
        content: [{ type: "text", text: e instanceof Error ? e.message : String(e) }],
        isError: true,
      };
    }
  };
}
