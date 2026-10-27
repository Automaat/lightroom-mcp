import type { JSONObject, Tool } from "@modelcontextprotocol/server";
import { PREVIEW_SIZES } from "./preview-sizes.js";

type InputSchema = Tool["inputSchema"];

export interface ToolContract {
  name: string;
  title: string;
  annotations: {
    readOnlyHint: boolean;
    destructiveHint?: boolean;
    openWorldHint: false;
  };
  description: string;
  luaHandler: string;
  inputSchema: InputSchema;
  alwaysLoad?: true;
}

const MAX_BULK_PHOTO_IDS = 1000;
const MAX_METADATA_PHOTO_IDS = 100;
const MAX_DENOISE_PHOTO_IDS = 100;
const MAX_KEYWORDS = 1000;
const MAX_MASK_DELETE_IDS = 100;
const MAX_MASK_BATCH_PHOTO_IDS = 200;

const MASK_TYPES = ["subject", "sky", "background"] as const;
const MASK_COMBINE_OPERATIONS = ["add", "subtract", "intersect"] as const;

const PEOPLE_MASK_PARTS = [
  "face_skin",
  "iris_and_pupil",
  "body_skin",
  "hair",
  "lips",
  "facial_hair",
  "eye_sclera",
  "eyebrows",
  "clothes",
  "teeth",
  "entire_person",
] as const;

const LANDSCAPE_MASK_CATEGORIES = [
  "architecture",
  "mountains",
  "artificial_ground",
  "natural_ground",
  "vegetation",
  "sky",
  "water",
  "snow",
] as const;

const maskAdjustmentSlider = (description: string, minimum = -100, maximum = 100) => ({
  type: "number",
  minimum,
  maximum,
  description: `${description} (${minimum} to ${maximum})`,
});

const MASK_ADJUSTMENT_PROPERTIES = {
  exposure: maskAdjustmentSlider("Exposure in stops", -4, 4),
  contrast: maskAdjustmentSlider("Contrast"),
  highlights: maskAdjustmentSlider("Highlights"),
  shadows: maskAdjustmentSlider("Shadows"),
  whites: maskAdjustmentSlider("Whites"),
  blacks: maskAdjustmentSlider("Blacks"),
  texture: maskAdjustmentSlider("Texture"),
  clarity: maskAdjustmentSlider("Clarity"),
  dehaze: maskAdjustmentSlider("Dehaze"),
  temperature: maskAdjustmentSlider("Temperature"),
  tint: maskAdjustmentSlider("Tint"),
  saturation: maskAdjustmentSlider("Saturation"),
  sharpness: maskAdjustmentSlider("Sharpness"),
  noise: maskAdjustmentSlider("Noise reduction"),
};

const normalizedPoint = (description: string) => ({
  type: "object",
  additionalProperties: false,
  properties: {
    x: { type: "number", minimum: 0, maximum: 1, description: "Horizontal position, 0 = left edge, 1 = right edge" },
    y: { type: "number", minimum: 0, maximum: 1, description: "Vertical position, 0 = top edge, 1 = bottom edge" },
  },
  required: ["x", "y"],
  description,
});

const gradientGeometryProperties = {
  start: normalizedPoint("Linear only: where the effect is full strength"),
  end: normalizedPoint("Linear only: where the effect has faded to nothing"),
  center: normalizedPoint("Radial only: center of the ellipse"),
  width: {
    type: "number",
    exclusiveMinimum: 0,
    maximum: 2,
    description: "Radial only: ellipse width as a fraction of the image width (not pixels), measured before rotation",
  },
  height: {
    type: "number",
    exclusiveMinimum: 0,
    maximum: 2,
    description: "Radial only: ellipse height as a fraction of the image height (not pixels), measured before rotation",
  },
  rotation: {
    type: "number",
    minimum: -360,
    maximum: 360,
    description:
      "Radial only: clockwise rotation in degrees around the center, in the photo's pixel space (default 0). Lightroom keeps a turn past 45 degrees as the same ellipse with width and height swapped and the rotation turned back by 90 degrees, so results report that form",
  },
  feather: {
    type: "number",
    minimum: 0,
    maximum: 100,
    description: "Radial only: edge softness, 0 hard to 100 soft (default 50)",
  },
  area: {
    type: "string",
    enum: ["inside", "outside"],
    description: "Radial only: apply the effect inside (default) or outside the ellipse",
  },
} satisfies JSONObject;

const brushStrokeProperties = {
  strokes: {
    type: "array",
    minItems: 1,
    maxItems: 50,
    description:
      "Strokes to paint, in order. Each stroke is a path of points; Lightroom fills dabs along the path. A stroke adds paint unless it sets erase, which removes the paint earlier strokes of the same brush left under it",
    items: {
      type: "object",
      additionalProperties: false,
      properties: {
        points: {
          type: "array",
          minItems: 1,
          maxItems: 1000,
          items: normalizedPoint("A point on the stroke path, in normalized image coordinates"),
          description: "Path of the stroke, at least one point; a single point is one dab",
        },
        radius: {
          type: "number",
          exclusiveMinimum: 0,
          maximum: 1,
          description: "Brush size as a fraction of the longer edge of the image (default 0.14, Lightroom's default brush; 0.04 is clearly narrower). It is the radius of the brush at feather 100: a lower feather keeps the brush size and the tool stores the smaller radius Lightroom stores for it",
        },
        feather: {
          type: "number",
          minimum: 0,
          maximum: 100,
          description: "Edge softness like Lightroom's Feather slider: 0 is a hard edge, 100 the default soft brush. Intermediate values interpolate between brushes authored in Lightroom (accurate within a fraction of a percent)",
        },
        density: {
          type: "number",
          minimum: 0.01,
          maximum: 1,
          description: "Density, 0.01 to 1 (default 1): the most opacity the stroke can reach however often it is stamped. Not allowed together with erase",
        },
        erase: {
          type: "boolean",
          description: "Erase instead of add (default false): the stroke removes the paint that earlier strokes of the same brush left under it. It is stored as a stroke with density 0, so it cannot erase a different brush or mask, and a stroke over unpainted area changes nothing",
        },
        flow: {
          type: "number",
          minimum: 0.01,
          maximum: 1,
          description: "Flow, 0.01 to 1 (default 1); each stroke can carry its own",
        },
      },
      required: ["points"],
    },
  },
} satisfies JSONObject;

export const POINT_CURVE_SETTING_KEYS = [
  "ToneCurvePV2012",
  "ToneCurvePV2012Red",
  "ToneCurvePV2012Green",
  "ToneCurvePV2012Blue",
] as const;

export const DEVELOP_SETTING_KEYS = [
  "WhiteBalance",
  "Temperature",
  "Tint",
  "Exposure2012",
  "Contrast2012",
  "Highlights2012",
  "Shadows2012",
  "Whites2012",
  "Blacks2012",
  "Texture",
  "Clarity2012",
  "Dehaze",
  "Vibrance",
  "Saturation",
  "SaturationAdjustmentRed",
  "SaturationAdjustmentOrange",
  "SaturationAdjustmentYellow",
  "SaturationAdjustmentGreen",
  "SaturationAdjustmentAqua",
  "SaturationAdjustmentBlue",
  "SaturationAdjustmentPurple",
  "SaturationAdjustmentMagenta",
  "HueAdjustmentRed",
  "HueAdjustmentOrange",
  "HueAdjustmentYellow",
  "HueAdjustmentGreen",
  "HueAdjustmentAqua",
  "HueAdjustmentBlue",
  "HueAdjustmentPurple",
  "HueAdjustmentMagenta",
  "LuminanceAdjustmentRed",
  "LuminanceAdjustmentOrange",
  "LuminanceAdjustmentYellow",
  "LuminanceAdjustmentGreen",
  "LuminanceAdjustmentAqua",
  "LuminanceAdjustmentBlue",
  "LuminanceAdjustmentPurple",
  "LuminanceAdjustmentMagenta",
  "ParametricShadows",
  "ParametricDarks",
  "ParametricLights",
  "ParametricHighlights",
  "ParametricShadowSplit",
  "ParametricMidtoneSplit",
  "ParametricHighlightSplit",
  ...POINT_CURVE_SETTING_KEYS,
  "ToneCurveName2012",
  "ConvertToGrayscale",
  "Sharpness",
  "SharpenRadius",
  "SharpenDetail",
  "SharpenEdgeMasking",
  "LuminanceSmoothing",
  "LuminanceNoiseReductionDetail",
  "LuminanceNoiseReductionContrast",
  "ColorNoiseReduction",
  "ColorNoiseReductionDetail",
  "ColorNoiseReductionSmoothness",
  "LensProfileEnable",
  "LensManualDistortionAmount",
  "PerspectiveVertical",
  "PerspectiveHorizontal",
  "PerspectiveRotate",
  "PerspectiveScale",
  "PerspectiveAspect",
  "PerspectiveUpright",
  "PostCropVignetteAmount",
  "PostCropVignetteMidpoint",
  "PostCropVignetteRoundness",
  "PostCropVignetteFeather",
  "PostCropVignetteStyle",
  "GrainAmount",
  "GrainSize",
  "GrainFrequency",
  "CropTop",
  "CropLeft",
  "CropBottom",
  "CropRight",
  "CropAngle",
] as const;

export const LOCAL_ADJUSTMENT_KEYS = [
  "local_Exposure",
  "local_Contrast",
  "local_Highlights",
  "local_Shadows",
  "local_Whites",
  "local_Blacks",
  "local_Texture",
  "local_Clarity",
  "local_Dehaze",
  "local_Temperature",
  "local_Tint",
  "local_Saturation",
  "local_Sharpness",
  "local_LuminanceNoise",
  "local_Moire",
  "local_Defringe",
] as const;

const localAdjustmentProperties = Object.fromEntries(
  LOCAL_ADJUSTMENT_KEYS.map((key) => [key, { type: "number" }]),
);

const maskIdSchema = (description: string) => ({
  type: "string",
  minLength: 1,
  description,
});

export const MASK_CURVE_CHANNELS = ["main", "red", "green", "blue"] as const;

const MASK_CURVE_MIN_PAIRS = 2;
const MASK_CURVE_MAX_PAIRS = 32;

const maskCurveSchema = (description: string) => ({
  type: "array",
  items: { type: "integer", minimum: 0, maximum: 255 },
  minItems: MASK_CURVE_MIN_PAIRS * 2,
  maxItems: MASK_CURVE_MAX_PAIRS * 2,
  description,
});

const maskCurveProperties = Object.fromEntries(
  MASK_CURVE_CHANNELS.map((channel) => [
    channel,
    maskCurveSchema(
      channel === "main"
        ? "Flat input/output pairs for the RGB (luminance) curve, e.g. [0, 0, 64, 48, 192, 210, 255, 255]"
        : `Flat input/output pairs for the ${channel} channel curve`,
    ),
  ]),
);

const swatchNumber = (description: string, minimum: number, maximum: number) => ({
  type: "number",
  minimum,
  maximum,
  description,
});

const swatchRange = (description: string) => ({
  type: "object",
  additionalProperties: false,
  properties: {
    LowerNone: swatchNumber("Outer left limit", 0, 1),
    LowerFull: swatchNumber("Inner left limit", 0, 1),
    UpperFull: swatchNumber("Inner right limit", 0, 1),
    UpperNone: swatchNumber("Outer right limit", 0, 1),
  },
  required: ["LowerNone", "LowerFull", "UpperFull", "UpperNone"],
  description,
});

const pointColorSwatchProperties = {
  SrcHue: swatchNumber("Source color hue, 0 to 6", 0, 6),
  SrcSat: swatchNumber("Source color saturation, 0 to 1", 0, 1),
  SrcLum: swatchNumber("Source color luminance, 0 to 1", 0, 1),
  HueShift: swatchNumber("Hue shift, -1 to 1 (default 0)", -1, 1),
  SatScale: swatchNumber("Saturation shift, -1 to 1 (default 0)", -1, 1),
  LumScale: swatchNumber("Luminance shift, -1 to 1 (default 0)", -1, 1),
  RangeAmount: swatchNumber("Range amount, 0 to 1 (default 0.5)", 0, 1),
  HueRange: swatchRange("Hue range limits, each 0 to 1"),
  SatRange: swatchRange("Saturation range limits, each 0 to 1"),
  LumRange: swatchRange("Luminance range limits, each 0 to 1"),
};

const stringArray = (description: string, maxItems?: number) => ({
  type: "array",
  items: { type: "string" },
  minItems: 1,
  ...(maxItems ? { maxItems } : {}),
  description,
});

/**
 * Photo ids come back from the catalog as numbers (`localIdentifier`), so a
 * caller piping search/selection output straight into a write tool sends
 * numbers. Accept both rather than making every caller stringify.
 */
const photoIdSchema = (description: string): JSONObject => ({
  type: ["string", "number"], minLength: 1,
  description,
});

const photoIdArray = (description: string): JSONObject => ({
  type: "array",
  items: { type: ["string", "number"], minLength: 1 },
  minItems: 1,
  maxItems: MAX_BULK_PHOTO_IDS,
  description,
});

const dateStringSchema = (description: string) => ({
  type: "string",
  pattern: "^\\d{4}-\\d{2}-\\d{2}$",
  description,
});

const scalarDevelopSettingValueSchema = {
  oneOf: [{ type: "number" }, { type: "string" }, { type: "boolean" }],
};

const POINT_CURVE_MIN_PAIRS = 2;
const POINT_CURVE_MAX_PAIRS = 32;

const evenLengthSchemas = Array.from(
  { length: POINT_CURVE_MAX_PAIRS - POINT_CURVE_MIN_PAIRS + 1 },
  (_, index) => {
    const length = (POINT_CURVE_MIN_PAIRS + index) * 2;
    return { minItems: length, maxItems: length };
  },
);

const pointCurveDevelopSettingValueSchema = {
  type: "array",
  items: { type: "integer", minimum: 0, maximum: 255 },
  minItems: POINT_CURVE_MIN_PAIRS * 2,
  maxItems: POINT_CURVE_MAX_PAIRS * 2,
  anyOf: evenLengthSchemas,
  description:
    "Flat input/output pairs for a Lightroom point curve, e.g. [0, 0, 64, 48, 192, 210, 255, 255]. Values are integers from 0 to 255 and the array holds 2 to 32 pairs, so its length is always even. Inputs must be strictly increasing and the curve must start at input 0 and end at input 255.",
};

const pointCurveSettingKeySet = new Set<string>(POINT_CURVE_SETTING_KEYS);

const developSettingsProperties = Object.fromEntries(
  DEVELOP_SETTING_KEYS.map((key) => [
    key,
    pointCurveSettingKeySet.has(key)
      ? pointCurveDevelopSettingValueSchema
      : scalarDevelopSettingValueSchema,
  ]),
);

export const developSettingsValidationSchema = {
  type: "object",
  properties: developSettingsProperties,
  additionalProperties: false,
  minProperties: 1,
};

export const developSettingKeysValidationSchema = {
  type: "array",
  items: { type: "string", enum: [...DEVELOP_SETTING_KEYS] },
};

const presetSelectorProperties = {
  preset_name: { type: "string", minLength: 1, description: "Develop preset name" },
  preset_uuid: { type: "string", minLength: 1, description: "Develop preset UUID (preferred)" },
  preset_folder: { type: "string", minLength: 1, description: "Preset folder for disambiguation" },
  preset_scope: {
    type: "string",
    enum: ["lightroom", "plugin"],
    description: "Lightroom-visible preset or plugin-managed checkpoint",
  },
};

const presetSelectorSchema: InputSchema = {
  type: "object",
  additionalProperties: false,
  properties: presetSelectorProperties,
  anyOf: [{ required: ["preset_uuid"] }, { required: ["preset_name"] }],
};

const searchFilterProperties = {
  filename: { type: "string", description: "Search by filename (partial match)" },
  keywords: stringArray("Search by keywords"),
  rating: {
    type: "number",
    description: "Filter by star rating (0-5)",
    minimum: 0,
    maximum: 5,
  },
  start_date: dateStringSchema("Start date (YYYY-MM-DD)"),
  end_date: dateStringSchema("End date (YYYY-MM-DD)"),
  camera: { type: "string", minLength: 1, pattern: "\\S", description: "Exact camera name indexed by Lightroom" },
  lens: { type: "string", minLength: 1, pattern: "\\S", description: "Exact lens name indexed by Lightroom" },
  iso: { type: "number", exclusiveMinimum: 0, maximum: Number.MAX_VALUE, description: "Exact ISO speed rating" },
  focal_length: { type: "number", exclusiveMinimum: 0, maximum: Number.MAX_VALUE, description: "Exact focal length in millimeters (not the 35mm equivalent)" },
  flag: { type: "string", enum: ["pick", "reject", "none"], description: "Filter by pick flag" },
  color_label: { type: "string", enum: ["red", "yellow", "green", "blue", "purple", "none"], description: "Filter by Library color label" },
  edited: { type: "boolean", description: "Whether the photo has develop adjustments" },
  file_type: { type: "string", enum: ["DNG", "RAW", "JPG", "TIFF", "PNG", "PSD", "VIDEO", "PSB", "AVIF", "JXL"], description: "Lightroom file format; camera raw formats use RAW" },
  folder: { type: "string", minLength: 1, pattern: "\\S", description: "Folder text, including parent folders shown in Lightroom's Folders panel (contains all words)" },
};

export const TOOL_CONTRACTS: ToolContract[] = [
  {
    name: "search_photos",
    alwaysLoad: true,
    title: "Search photos",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerSearch.searchPhotos",
    description:
      "Search photos using intersecting Library filters (paginated, default limit 100): filename, keywords, rating, capture date, camera, lens, ISO, focal length, flag, color label, edited status, file type and folder. Provide at least one filter to improve performance on large catalogs.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        include_path: { type: "boolean", description: "Include each photo file path (default false). Rows always include id, filename, rating and dateTimeOriginal." },
        ...searchFilterProperties,
        limit: { type: "number", description: "Max photos to return (default 100)", minimum: 0 },
        offset: { type: "number", description: "Number of photos to skip (default 0)", minimum: 0 },
      },
    },
  },
  {
    name: "get_selected_photos",
    title: "Get selected photos",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerSelection.getSelectedPhotos",
    description: "Get currently selected photos in Lightroom (or filmstrip if no selection). Paginated, default limit 100.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        include_path: { type: "boolean", description: "Include each photo file path (default false). Rows always include id, filename, rating and dateTimeOriginal." },
        limit: { type: "number", description: "Max photos to return (default 100)", minimum: 0 },
        offset: { type: "number", description: "Number of photos to skip (default 0)", minimum: 0 },
      },
    },
  },
  {
    name: "summarize_develop_settings",
    title: "Summarize develop settings",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerStyleSummary.summarize",
    description:
      "Summarize numeric Develop settings by camera model and ISO (1-400, 401-1600, 1601-6400, 6401+, unknown). Select rating >= min_rating (default 4; 0=all); exported_only requires raw isExported true. Reads at most max_photos settings (default/max 200); export filtering batches flags for all rating matches. Returns count and SDK-key median/min/max per group, scanned/matched/truncated. Excludes crop, perspective, Temperature/Tint, nonfinite/nonnumeric/all-zero settings. Alphabetical keys fill 6000 characters/group; settings_omitted counts size exclusions. Read-only.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        min_rating: { type: "integer", minimum: 0, maximum: 5, default: 4, description: "Minimum star rating, inclusive" },
        exported_only: { type: "boolean", default: false, description: "Require an exported photo as well as the minimum rating" },
        max_photos: { type: "integer", minimum: 1, maximum: 200, default: 200, description: "Maximum photos whose Develop settings are read" },
      },
    },
  },
  {
    name: "get_photo_metadata",
    title: "Get photo metadata",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerMetadata.getPhotoMetadata",
    description:
      "Read 1-100 photos: keywords/nested keywordPaths, EXIF, title/caption/headline, GPS latitude/longitude/altitude, IPTC sublocation/city/stateProvince/country/isoCountryCode, copyright, accessibility alt_text/extended_description (LrC 13.2+, omitted empty/unsupported), and optional developSettings. IDs are catalog local. isVirtualCopy marks copies; optional virtualCopy contains masterPhotoId or master copyIds. Optional folder stack contains position (top=1), isCollapsed, topPhotoId and ordered memberIds. developSettings is absent by default; request sections: [\"developSettings\"] to read it. Empty sections omits it; duplicates are accepted. developSettings covers every set_develop_settings key: basic/tone/parametric curves use camelCase; hsl/lens/transform/crop/detail/effects/parametricSplits use SDK names; empty groups are omitted.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("One photo ID or file path; supply photo_id or photo_ids, never both"),
        photo_ids: {
          ...photoIdArray("1 to 100 photo IDs or file paths; returns photos in request order and missing identifiers separately. Repeated identifiers produce repeated entries."),
          maxItems: MAX_METADATA_PHOTO_IDS,
        },
        sections: {
          type: "array",
          items: { type: "string", enum: ["developSettings"] },
          description: "Optional metadata sections to include for each photo. Omitted or empty returns all standard metadata without developSettings. Duplicates are accepted.",
        },
      },
    },
  },
  {
    name: "get_photo_preview",
    alwaysLoad: true,
    title: "Get photo preview",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerPreview.getPhotoPreview",
    description:
      "Lightroom-rendered JPEG with Develop edits (raw supported). region crops the rendered frame after develop crop/rotation: normalized x/y/width/height, origin top-left, x right, y down. width/height/bytes are actual; requested_size is the source request. See size for cost/edge rules.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        size: {
          description: "Minimum longest edge: cull requests 512 (about 900px on the tested raw), detail requests 1024 (about 1800px); numeric 64-2048, default 512. Lightroom returns its smallest cached preview meeting the edge, often larger. Over 3.5 MB or 2000px retries smaller. cull is for culling (about 650 tokens), detail for inspecting details (about 2.5k tokens): earlier Claude estimates, varying by image/model and repeated each turn in history.",
          oneOf: [
            { type: "number", minimum: 64, maximum: 2048 },
            { type: "string", enum: Object.keys(PREVIEW_SIZES) },
          ],
        },
        region: {
          type: "object",
          additionalProperties: false,
          description: "Rectangle within the rendered preview, including its develop crop and displayed orientation. Pixel bounds round outward. Region calls request a larger source by dividing size by the longest normalized side, capped at 2048; requested_size reports that source request.",
          properties: {
            x: { type: "number", minimum: 0, exclusiveMaximum: 1 },
            y: { type: "number", minimum: 0, exclusiveMaximum: 1 },
            width: { type: "number", exclusiveMinimum: 0, maximum: 1 },
            height: { type: "number", exclusiveMinimum: 0, maximum: 1 },
          },
          required: ["x", "y", "width", "height"],
        },
      },
      required: ["photo_id"],
    },
  },
  {
    name: "get_photo_previews",
    title: "Get batch photo previews",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerPreview.getPhotoPreviews",
    description:
      "Get JPEG thumbnails for 1–20 photos in input order for culling. Maps requested_id/photo_id to 1-based image_index; errors have no image and do not fail the batch. Default size 256; max edge 2000px; total budget 8 MiB. After 20 s returns complete:false and remaining_ids to retry. Catalog unchanged.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: {
          type: "array", items: photoIdSchema("Photo ID or file path"), minItems: 1, maxItems: 20,
          description: "Between 1 and 20 IDs or paths, in image order",
        },
        size: { type: "number", minimum: 64, maximum: 2048, description: "Minimum longest edge (64–2048, default 256)" },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "find_duplicate_groups",
    title: "Find duplicate groups",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerPreview.findDuplicateGroups",
    description:
      "Group near-duplicates/bursts from up to 100 IDs/paths using 64-bit dHash of current JPEG previews (minimum edge 64) and raw capture time. Every pair must meet inclusive time_window_seconds (default 5) and max_hamming_distance (default 10). Input-order groups omit singletons and repeated photos; IDs are resolved. Approximate similarity does not rank frames. photos gives raw capture_time in Lightroom seconds (second precision, no timezone normalization). No hash cache or catalog changes. At 25 s returns partial groups, complete=false, remaining_ids; preview/missing-time failures are unprocessed with reasons. Retry remaining IDs with originals to grow groups.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: { type: "array", items: photoIdSchema("Photo ID or file path"), minItems: 1, maxItems: 100, description: "Between 1 and 100 IDs or paths" },
        time_window_seconds: { type: "number", minimum: 0, maximum: 86400, description: "Maximum capture gap in seconds (default 5)" },
        max_hamming_distance: { type: "integer", minimum: 0, maximum: 64, description: "Maximum differing dHash bits (default 10)" },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "get_photo_stats",
    title: "Get photo statistics",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerPreview.getPhotoStats",
    description:
      "Measure current rendered JPEG previews for up to 20 photos; result/error per input ID. histogram: 64 normalized Rec.709 luma bins (0-255, four levels/bin); mean_luminance same scale; shadow_fraction <=1, highlight_fraction >=254. sharpness: four-neighbor Laplacian variance after area resampling to 512px long edge (enlarges small previews); higher=sharper. These measure JPEG previews, not raw clipping/full-resolution focus. Catalog unchanged.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: {
          type: "array",
          items: photoIdSchema("Photo ID or file path"),
          minItems: 1,
          maxItems: 20,
          description: "Between 1 and 20 photo IDs or file paths, in result order",
        },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "set_gps",
    title: "Set GPS",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerMetadata.setGps",
    description:
      "Replace GPS coordinates in decimal degrees. Altitude stays unless altitude or clear_altitude is given. Returns success, updated and missing IDs.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        latitude: {
          type: "number",
          minimum: -90,
          maximum: 90,
          description: "Latitude in decimal degrees (north positive)",
        },
        longitude: {
          type: "number",
          minimum: -180,
          maximum: 180,
          description: "Longitude in decimal degrees (east positive)",
        },
        altitude: {
          type: "number",
          minimum: -20000,
          maximum: 100000,
          description: "Altitude in metres (optional)",
        },
        clear_altitude: {
          type: "boolean",
          description: "Remove the photos' altitude (default false). Cannot be combined with altitude.",
        },
      },
      required: ["photo_ids", "latitude", "longitude"],
    },
  },
  {
    name: "set_location",
    title: "Set location",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerMetadata.setLocation",
    description:
      "Set IPTC location fields from get_photo_metadata; at least one is required. Omitted fields stay, empty strings clear. GPS stays (use set_gps). Returns success, updated, fields and missing IDs.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        sublocation: {
          type: "string",
          description: "Sublocation: a venue, landmark or neighbourhood (e.g. 'Sydney Opera House')",
        },
        city: { type: "string", description: "City" },
        state_province: { type: "string", description: "State or province" },
        country: { type: "string", description: "Country name" },
        iso_country_code: {
          type: "string",
          description: "ISO 3166 country code (e.g. 'US', 'AU')",
        },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "set_metadata",
    title: "Set metadata",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerMetadata.setMetadata",
    description:
      "Set IPTC text from get_photo_metadata. Accessibility needs LrC 13.2+. At least one field; omitted fields stay, empty strings clear. Copyright status is unwritable. Returns success, updated, fields and missing IDs.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        title: { type: "string", description: "Title" },
        caption: { type: "string", description: "Caption (IPTC description)" },
        headline: { type: "string", description: "Headline" },
        creator: { type: "string", description: "Creator (photographer)" },
        copyright: { type: "string", description: "Copyright notice, e.g. '© 2026 Jane Doe'" },
        rights_usage_terms: { type: "string", description: "Rights usage terms" },
        copyright_info_url: { type: "string", description: "Copyright info URL, e.g. a licensing page" },
        creator_url: { type: "string", description: "Creator's website (IPTC creator contact info)" },
        alt_text: { type: "string", description: "Short accessibility description (Lightroom Classic 13.2+)" },
        extended_description: { type: "string", description: "Extended accessibility description (Lightroom Classic 13.2+)" },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "set_ai_metadata",
    title: "Set AI metadata",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerAiMetadata.setAiMetadata",
    description:
      "Store an AI score and reason in private per-photo plug-in metadata in this catalog. Score is an integer from 0 to 100; reason is at most 1024 characters. Omitted fields stay unchanged; an empty string clears a field. Does not change IPTC, XMP, keywords, or export metadata.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        score: { oneOf: [{ type: "integer", minimum: 0, maximum: 100 }, { const: "" }] },
        reason: { type: "string", maxLength: 1024 },
      },
      required: ["photo_ids"],
      anyOf: [{ required: ["score"] }, { required: ["reason"] }],
    },
  },
  {
    name: "get_ai_metadata",
    title: "Get AI metadata",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerAiMetadata.getAiMetadata",
    description:
      "Read private per-photo AI scores and reasons in one batch (up to 1000 IDs or paths). Returns photos with photo_id, numeric score and reason; unset fields are omitted. Missing IDs are reported separately.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: { photo_ids: photoIdArray("Array of photo IDs or file paths") },
      required: ["photo_ids"],
    },
  },
  {
    name: "list_folders",
    title: "List folders",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerFolders.listFolders",
    description: "List catalog folders in tree order as a paginated flat list of full paths, names and photo_count (direct photos only, excluding subfolders). Default limit 100.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        limit: { type: "integer", minimum: 0, description: "Max folders to return (default 100)" },
        offset: { type: "integer", minimum: 0, description: "Folders to skip (default 0)" },
      },
    },
  },
  {
    name: "get_folder_photos",
    title: "Get folder photos",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerFolders.getFolderPhotos",
    description: "List photos in a catalog folder by its full path from list_folders (paginated, default limit 100). Subfolders are excluded by default.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        folder_path: { type: "string", minLength: 1, description: "Full folder path from list_folders" },
        include_subfolders: { type: "boolean", description: "Include photos in subfolders (default false)" },
        limit: { type: "integer", minimum: 0, description: "Max photos to return (default 100)" },
        offset: { type: "integer", minimum: 0, description: "Photos to skip (default 0)" },
      },
      required: ["folder_path"],
    },
  },
  {
    name: "list_collections",
    title: "List collections",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerCollections.listCollections",
    description: "List all collections in Lightroom catalog (paginated, default limit 100)",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        limit: { type: "number", description: "Max collections to return (default 100)", minimum: 0 },
        offset: { type: "number", description: "Number of collections to skip (default 0)", minimum: 0 },
      },
    },
  },
  {
    name: "create_collection",
    title: "Create collection",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    luaHandler: "HandlerCollections.createCollection",
    description: "Create a collection; returns success and its path.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        name: { type: "string", description: "Collection name" },
        parent: {
          type: "string",
          description:
            "Parent collection set path (optional), levels separated by ' / ' as in list_collections (e.g. 'Trips / 2026'). Missing sets are created; existing ones are reused, matching names ignoring case as Lightroom does. Omit it for a top-level collection; an empty level or a level with leading or trailing spaces or slashes is rejected.",
        },
      },
      required: ["name"],
    },
  },
  {
    name: "create_smart_collection",
    title: "Create smart collection",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    luaHandler: "HandlerCollections.createSmartCollection",
    description: "Save intersecting search_photos filters as an auto-updating smart collection; at least one filter. Creates missing parent sets; rejects existing sibling names. Returns success and path.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        name: { type: "string", minLength: 1, pattern: "\\S", description: "Smart collection name" },
        parent: { type: "string", description: "Parent collection set path, with levels separated by ' / ' (e.g. 'Trips / 2026')" },
        ...searchFilterProperties,
      },
      required: ["name"],
      anyOf: Object.keys(searchFilterProperties).map((key) => ({ required: [key] })),
    },
  },
  {
    name: "add_to_collection",
    title: "Add to collection",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    luaHandler: "HandlerCollections.addToCollection",
    description:
      "Add photos to a collection; returns success, added count and missing IDs.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        collection_name: {
          type: "string",
          description:
            "Collection path from list_collections, or a bare name. A listed path always picks that collection; a bare name of a nested collection must be unique.",
        },
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
      },
      required: ["collection_name", "photo_ids"],
    },
  },
  {
    name: "get_collection_photos",
    title: "Get collection photos",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerCollections.getCollectionPhotos",
    description:
      "List the photos in a collection, regular or smart (paginated, default limit 100). Use a path from list_collections when names repeat; an ambiguous bare name is rejected.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        include_path: { type: "boolean", description: "Include each photo file path (default false). Rows always include id, filename, rating and dateTimeOriginal." },
        collection_name: {
          type: "string",
          description:
            "Collection path from list_collections, or a bare name. A listed path always picks that collection; a bare name of a nested collection must be unique.",
        },
        limit: { type: "number", description: "Max photos to return (default 100)", minimum: 0 },
        offset: { type: "number", description: "Number of photos to skip (default 0)", minimum: 0 },
      },
      required: ["collection_name"],
    },
  },
  {
    name: "remove_from_collection",
    title: "Remove from collection",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerCollections.removeFromCollection",
    description:
      "Remove photos from a regular collection; catalog and other memberships stay. Returns success, removed (unique members), not_in_collection and missing IDs.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        collection_name: {
          type: "string",
          description:
            "Collection path from list_collections, or a bare name. A listed path always picks that collection; a bare name of a nested collection must be unique.",
        },
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
      },
      required: ["collection_name", "photo_ids"],
    },
  },
  {
    name: "delete_collection",
    title: "Delete collection",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerCollections.deleteCollection",
    description:
      "Delete a collection; photos stay in the catalog. Returns success, photo_count and that reminder.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        collection_name: {
          type: "string",
          description:
            "Collection path from list_collections, or a bare name. A listed path always picks that collection; a bare name of a nested collection must be unique.",
        },
      },
      required: ["collection_name"],
    },
  },
  {
    name: "set_keywords",
    title: "Set keywords",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerOrganization.setKeywords",
    description:
      "Add/remove keyword names or parent-first '|' paths from list_keywords, ignoring case. Missing names create top-level keywords; paths create missing levels unless create_missing=false. Returns success and updated count.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        add_keywords: stringArray(
          "Keywords to add: plain names or 'Parent|Child' hierarchy paths",
          MAX_KEYWORDS,
        ),
        remove_keywords: stringArray(
          "Keywords to remove: a plain name removes every keyword with that name, a 'Parent|Child' path removes only that one",
          MAX_KEYWORDS,
        ),
        create_missing: {
          type: "boolean",
          description:
            "Default true. When false, nothing is created: every keyword to add must already exist, a plain name must match exactly one keyword anywhere in the hierarchy, and the call fails without changing anything if any keyword is unknown or ambiguous.",
        },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "remove_keyword_subtree",
    title: "Remove keyword subtree",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerOrganization.removeKeywordSubtree",
    description:
      "Detach a parent keyword and every descendant from photo_ids, or all tagged photos with catalog_wide=true. Matches paths ignoring case; unknown parent fails unchanged. Preserves unrelated and same-named keywords elsewhere. Keyword nodes stay in the catalog and list_keywords. Use a dedicated parent such as 'AI Keywords' with set_keywords to undo a tagging batch. Returns updated photo count, removed assignment count and missing IDs.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        parent: {
          type: "string",
          minLength: 1,
          description: "Parent-first keyword path, for example 'AI Keywords' or 'Tags|AI Keywords'",
        },
        photo_ids: photoIdArray("Photos to detach the subtree from; omit when catalog_wide is true"),
        catalog_wide: {
          type: "boolean",
          description: "Explicitly detach the subtree from every photo in the catalog; cannot accompany photo_ids",
        },
      },
      required: ["parent"],
    },
  },
  {
    name: "list_keywords",
    title: "List keywords",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerKeywords.listKeywords",
    description:
      "List paginated parent-first keyword paths ('Places|Europe|Paris'), synonyms and include-on-export (limit default 100). Pass paths to set_keywords; narrow large trees with parent/query or request paths_only.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        parent: {
          type: "string",
          minLength: 1,
          description: "Only list keywords below this keyword path (optional)",
        },
        query: {
          type: "string",
          minLength: 1,
          description: "Only list keywords whose name or a synonym contains this text, ignoring case (optional)",
        },
        paths_only: {
          type: "boolean",
          description: "Return each keyword as just its path string instead of an object (default false)",
        },
        limit: { type: "number", description: "Max keywords to return (default 100)", minimum: 0 },
        offset: { type: "number", description: "Number of keywords to skip (default 0)", minimum: 0 },
      },
    },
  },
  {
    name: "rename_keyword",
    title: "Rename keyword",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerKeywords.renameKeyword",
    description:
      "Rename in place; tagged photos update, parent/children/synonyms stay. Case-insensitive sibling conflicts fail; case-only renames work. Returns success, old_path, new_path and photo_count.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        keyword: {
          type: "string",
          minLength: 1,
          description: "Keyword from list_keywords: a unique plain name or a 'Parent|Child' path",
        },
        new_name: {
          type: "string",
          minLength: 1,
          description: "New name for that keyword (a single name, not a path)",
        },
      },
      required: ["keyword", "new_name"],
    },
  },
  {
    name: "undo_last_step",
    title: "Undo last step",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerUndo.undoLastStep",
    description:
      "Undo one shared Lightroom history step (confirm:true), including a user/other plug-in action after your edit. Ownership is unknown: call only if undoing the current last step is acceptable. Returns undone and can_undo for another undo.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        confirm: {
          type: "boolean",
          const: true,
          description: "Accept undoing the latest step in Lightroom's shared history",
        },
      },
      required: ["confirm"],
    },
  },
  {
    name: "set_rating_and_flag",
    alwaysLoad: true,
    title: "Set rating and flag",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerOrganization.setRatingAndFlag",
    description: "Set rating, flag, or both in one write. Returns success, updated and missing; get_photo_metadata reports rating and pickStatus (pick 1, reject -1, none 0).",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        rating: {
          type: "number",
          description: "Star rating (0-5); supply rating, flag, or both",
          minimum: 0,
          maximum: 5,
        },
        flag: {
          type: "string",
          enum: ["pick", "reject", "none"],
          description: "pick, reject, or none (unflagged)",
        },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "set_color_label",
    title: "Set color label",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerOrganization.setColorLabel",
    description:
      "Set a color label or none to clear; get_photo_metadata reports colorLabel. Returns success, updated and missing IDs.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        label: {
          type: "string",
          enum: ["red", "yellow", "green", "blue", "purple", "none"],
          description: "Color name, or none to clear the label",
        },
      },
      required: ["photo_ids", "label"],
    },
  },
  {
    name: "remove_photos_from_catalog",
    title: "Remove photos from catalog",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerRemoveFromCatalog.removePhotos",
    description:
      "Remove up to 100 IDs/paths from catalog, losing catalog edits/metadata; files remain on disk (LrC 14.3+, confirm:true). Include every virtual copy with its master. Deduplicates; reports missing IDs. Opens Library grid/All Photographs, restores module/sources/surviving selection; Library stays in grid view.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: { ...photoIdArray("Photo IDs or file paths to remove from the catalog"), maxItems: 100 },
        confirm: { type: "boolean", enum: [true], description: "Explicit consent to lose these photos' catalog edits and metadata" },
      },
      required: ["photo_ids", "confirm"],
    },
  },
  {
    name: "import_photos",
    title: "Import photos",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    luaHandler: "HandlerImport.importPhotos",
    description:
      "Import a photo or a folder recursively. Returns success, imported/skipped counts, skipped_by_extension, complete and remaining_paths. Only unsupported-extension notes remain in message.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        source_path: { type: "string", description: "Photo or folder to import. Folder imports accept camera raw (CR3, RAF, ORF, RW2, NEF, ARW, DNG and other Camera Raw formats), JPEG, HEIC/HEIF, AVIF, JPEG XL, TIFF, PNG and PSD/PSB; other files are skipped by extension." },
        collection_name: {
          type: "string",
          description: "Collection to add imported photos to (optional)",
        },
        copy_to: {
          type: "string",
          description: "Destination folder for copying files (optional)",
        },
      },
      required: ["source_path"],
    },
  },
  {
    name: "export_photos",
    title: "Export photos",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerExport.exportPhotos",
    description: "Export photos; returns success, exported count, destination, complete and remaining_ids to retry.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths to export"),
        destination: { type: "string", description: "Absolute path of the export folder, created if missing; ~/ is expanded" },
        format: {
          type: "string",
          description: "Export format (jpeg, png, tiff, original)",
          enum: ["jpeg", "png", "tiff", "original"],
        },
        quality: {
          type: "number",
          description: "JPEG quality (0-100)",
          minimum: 0,
          maximum: 100,
        },
        width: { type: "number", description: "Max width in pixels (optional)" },
        height: { type: "number", description: "Max height in pixels (optional)" },
        on_existing: {
          type: "string",
          description:
            "What to do when the destination already holds a file with that name (default rename). Lightroom never prompts.",
          enum: ["rename", "overwrite", "skip"],
        },
      },
      required: ["photo_ids", "destination"],
    },
  },
  {
    name: "export_photo_metadata",
    title: "Export photo metadata",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerExport.exportPhotoMetadata",
    description:
      "Export up to 1000 photos to disk JSON: file/capture time/dimensions/rating/title/caption/GPS/location/keywords/keywordPaths, no develop settings. Omitted photo_ids uses selection, or filmstrip if none. Prefer over per-photo get_photo_metadata. Returns success, exported, destination and missing IDs.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths (default: current selection)"),
        destination: {
          type: "string",
          pattern: "^[^\\u0000-\\u001f]*\\.[jJ][sS][oO][nN]$",
          description: "Absolute path of the .json file to write; ~/ is expanded",
        },
        overwrite: {
          type: "boolean",
          description: "Replace the file if it already exists (default false: fail instead)",
        },
      },
      required: ["destination"],
    },
  },
  {
    name: "list_develop_presets",
    title: "List develop presets",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerDevelop.listDevelopPresets",
    description: "List Lightroom-visible Develop presets and plugin-managed checkpoints (paginated, default limit 100). Filter by name or folder before paging. Returns name, folder, scope and uuid; use get_develop_preset for backing-file metadata. count is the total matches; has_more indicates another page.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        limit: { type: "number", minimum: 0, description: "Max presets to return (default 100; floored)" },
        offset: { type: "number", minimum: 0, description: "Number of matching presets to skip (default 0; floored)" },
        query: { type: "string", minLength: 1, description: "Keep presets whose name contains this text, ignoring case" },
        folder: { type: "string", minLength: 1, description: "Exact, case-sensitive folder name, including Plugin Develop Presets for checkpoints" },
      },
    },
  },
  {
    name: "get_develop_preset",
    title: "Get develop preset",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerDevelop.getDevelopPreset",
    description:
      "Read the settings and backing-file metadata for one exact Develop preset. Use preset_uuid or provide folder/scope when names are duplicated.",
    inputSchema: presetSelectorSchema,
  },
  {
    name: "compare_develop_presets",
    title: "Compare develop presets",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerDevelop.compareDevelopPresets",
    description:
      "Compare two Develop presets and return a deterministic per-setting diff for iterative style matching",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        base: { ...presetSelectorSchema, description: "Approved historical/base preset" },
        candidate: { ...presetSelectorSchema, description: "Candidate preset checkpoint" },
      },
      required: ["base", "candidate"],
    },
  },
  {
    name: "create_develop_preset",
    title: "Create develop preset",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    luaHandler: "HandlerDevelop.createDevelopPreset",
    description:
      "Capture selected settings as a versioned plugin Develop checkpoint, hidden from Develop; export for handoff. Returns success, preset identity/file, visible_in_develop:false and a checkpoint note.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Source photo ID or file path"),
        preset_name: {
          type: "string",
          minLength: 1,
          description: "Unique versioned checkpoint name; existing plugin names are refused",
        },
        settings: {
          type: "array",
          items: { type: "string" },
          minItems: 1,
          maxItems: DEVELOP_SETTING_KEYS.length,
          uniqueItems: true,
          description: "Explicit SDK setting keys from set_develop_settings to capture from the source photo",
        },
      },
      required: ["photo_id", "preset_name", "settings"],
    },
  },
  {
    name: "export_develop_preset",
    title: "Export develop preset",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    luaHandler: "HandlerDevelop.exportDevelopPreset",
    description:
      "Copy one exact custom or plugin-managed Develop preset backing file to a destination directory. Existing files are never overwritten; built-in presets without backing files cannot be exported.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        ...presetSelectorProperties,
        destination_dir: {
          type: "string",
          minLength: 1,
          description: "Destination directory; created when missing",
        },
        filename: {
          type: "string",
          minLength: 1,
          description: "Optional leaf filename. Extension must match the Lightroom backing file.",
        },
      },
      required: ["destination_dir"],
      anyOf: [{ required: ["preset_uuid"] }, { required: ["preset_name"] }],
    },
  },
  {
    name: "apply_develop_preset",
    title: "Apply develop preset",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerDevelop.applyDevelopPreset",
    description:
      "Apply an exact Develop preset; returns success, applied, resolved preset identity, missing IDs, ai_updated and ai_update_failed. AI masks recompute per target on LrC 13.3+; earlier versions or non-AI presets apply normally. message holds AI warnings only.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        dry_run: {
          type: "boolean",
          default: false,
          description: "Preview without writes or AI recomputation. Returns setting_totals across all targets and details for at most 5 targets within a 12,000-character detail budget; detail_truncated marks omitted detail. Missing path detail has a 4,000-character budget and is trimmed further to keep the reply within 20,000 characters: missing_count and one-based missing_indices identify all missing inputs, and missing_truncated flags an incomplete missing list. Tables are summarized by entry count and strings over 128 characters by length and prefix. Preset previews compare only declared settings whose current values the SDK exposes. preview_scope is readable_declared_preset_settings; unknown_current_totals counts unreadable values per key, which are excluded from changes and setting_totals. unknown_effects explicitly excludes SDK-generated values including GrainSeed and preset bookkeeping. These effects are not predicted.",
        },
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        preset_name: {
          type: "string",
          description: "Preset name",
        },
        preset_uuid: { type: "string", description: "Preset UUID (preferred)" },
        preset_folder: { type: "string", description: "Preset folder for disambiguation" },
        preset_scope: { type: "string", enum: ["lightroom", "plugin"] },
      },
      required: ["photo_ids"],
      anyOf: [{ required: ["preset_uuid"] }, { required: ["preset_name"] }],
    },
  },
  {
    name: "copy_develop_settings",
    title: "Copy develop settings",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerDevelop.copyDevelopSettings",
    description:
      "Copy Develop settings; omitted settings includes AI masks. LrC 13.3+ recomputes each AI mask per target; earlier versions and non-AI copies behave normally. Returns success, copied, missing IDs, ai_updated count, ai_update_failed IDs and AI warning message only.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        dry_run: {
          type: "boolean",
          default: false,
          description: "Preview without writes or AI recomputation. Returns setting_totals across all targets and details for at most 5 targets within a 12,000-character detail budget; detail_truncated marks omitted detail. Missing path detail has a 4,000-character budget and is trimmed further to keep the reply within 20,000 characters: missing_count and one-based missing_indices identify all missing inputs, and missing_truncated flags an incomplete missing list. Tables are summarized by entry count and strings over 128 characters by length and prefix.",
        },
        source_id: photoIdSchema("Source photo ID or file path"),
        target_ids: photoIdArray("Target photo IDs or file paths"),
        settings: {
          type: "array",
          items: {
            type: "string",
          },
          minItems: 1,
          maxItems: DEVELOP_SETTING_KEYS.length,
          description:
            "Optional whitelist of SDK setting keys from set_develop_settings. Omit to copy all.",
        },
      },
      required: ["source_id", "target_ids"],
    },
  },
  {
    name: "match_photo_style",
    title: "Match reference photo style",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerDevelop.matchPhotoStyle",
    description:
      "Apply allowlisted reference global tone/color/curves/detail/noise/grain/vignette after confirming a Develop snapshot per target. Excludes crop, perspective, WhiteBalance/Temperature/Tint, lens corrections and local adjustments/AI masks. Reference cannot be a target, including path aliases. No pixel adaptation. Results: photo_id, snapshot id/name, settings_changed (differing keys); failures have reasons; missing IDs listed. Restore with apply_develop_snapshot.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        reference_id: photoIdSchema("Reference photo ID or file path"),
        target_ids: photoIdArray("Target photo IDs or file paths"),
      },
      required: ["reference_id", "target_ids"],
    },
  },
  {
    name: "set_develop_settings",
    title: "Set develop settings",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerDevelop.setDevelopSettings",
    description:
      "Set Develop settings directly on a photo. Keys use allowlisted Lightroom SDK names (Exposure2012, WhiteBalance, Contrast2012, Highlights2012, Shadows2012, Whites2012, Blacks2012, Clarity2012, Vibrance, Saturation, HueAdjustmentRed, SaturationAdjustmentOrange, LuminanceAdjustmentYellow, etc.), plus RGB composite and per-channel point curves via ToneCurvePV2012, ToneCurvePV2012Red, ToneCurvePV2012Green, and ToneCurvePV2012Blue.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        settings: {
          type: "object",
          propertyNames: { enum: [...DEVELOP_SETTING_KEYS] },
          additionalProperties: {
            oneOf: [...scalarDevelopSettingValueSchema.oneOf, pointCurveDevelopSettingValueSchema],
          },
          minProperties: 1,
          description:
            "Allowlisted SDK setting key/value pairs (e.g., {\"Exposure2012\": 0.5, \"SaturationAdjustmentOrange\": -10})",
        },
      },
      required: ["photo_id", "settings"],
    },
  },
  {
    name: "get_lens_blur",
    title: "Get Lens Blur",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerLensBlur.get",
    description: "Read Lens Blur active/amount/cat_eye/highlights_boost/focal_range near/far/focal_range_raw (four SDK values)/bokeh (LrC 13.3+, Process Version 3+). No computed blur returns active:false and unavailable controls. Opens Develop; shared restoration rules apply.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: { photo_id: photoIdSchema("Photo ID or file path") },
      required: ["photo_id"],
    },
  },
  {
    name: "set_lens_blur",
    title: "Set Lens Blur",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerLensBlur.set",
    description: "Set any subset of Lens Blur active/amount/cat_eye/highlights_boost/focal_range/bokeh (LrC 13.3+, Process Version 3+). Enables first to compute depth; active:false disables after adjustments. Validates runtime numeric ranges before writing. focal_range near/far: 0..100, near<=far; Lightroom supplies outer falloff. Returns readback; unsaved values stop with earlier changes retained. Shared Develop restoration rules apply.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      minProperties: 2,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        active: { type: "boolean" },
        amount: { type: "number", minimum: 0, maximum: 100 },
        cat_eye: { type: "number", minimum: 0, maximum: 100 },
        highlights_boost: { type: "number", minimum: 0, maximum: 100 },
        focal_range: {
          type: "object",
          additionalProperties: false,
          properties: {
            near: { type: "number", minimum: 0, maximum: 100 },
            far: { type: "number", minimum: 0, maximum: 100 },
          },
          required: ["near", "far"],
        },
        bokeh: { type: "string", enum: ["Circle", "SoapBubble", "Blade", "Ring", "Anamorphic"] },
      },
      required: ["photo_id"],
    },
  },
  {
    name: "set_process_version",
    title: "Set process version",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerDevelop.setProcessVersion",
    description:
      "Set Version 1–6 (confirm:true; appearance can change). Downgrades with masks are skipped to preserve guarded editing. Opens each in Develop; restore_selection defaults true. Returns previous_version/new_version and changed/unchanged/skipped/failed per photo. Missing/duplicate photos skipped. Max 100; stops near 240 s with remaining_ids to retry.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: { ...photoIdArray("Photo IDs or file paths"), maxItems: 100 },
        version: { type: "string", enum: ["Version 1", "Version 2", "Version 3", "Version 4", "Version 5", "Version 6"] },
        confirm: { type: "boolean", const: true },
        restore_selection: { type: "boolean", description: "Restore module, view source and selection (default true)" },
      },
      required: ["photo_ids", "version", "confirm"],
    },
  },
  {
    name: "create_virtual_copies",
    title: "Create virtual copies",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    luaHandler: "HandlerVirtualCopies.create",
    description: "Create one virtual copy per distinct photo (max 25); copy_name optionally names each. Returns copies with photo_id/master_id/copy_id and missing IDs; edit via copy_id. Restores selection/source. Repeats create more; failures can leave earlier copies.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: { ...photoIdArray("Photo IDs or file paths"), maxItems: 25 },
        copy_name: { type: "string", minLength: 1, pattern: "\\S", description: "Name for each new virtual copy" },
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "list_develop_snapshots",
    title: "List develop snapshots",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerSnapshots.list",
    description: "List a photo develop snapshots with their ids and names.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
      },
      required: ["photo_id"],
    },
  },
  {
    name: "create_develop_snapshot",
    title: "Create develop snapshot",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerSnapshots.create",
    description: "Save the current develop settings as a named snapshot. Duplicate names are rejected unless replace is true.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        name: { type: "string", minLength: 1, pattern: "\\S", description: "Snapshot name" },
        replace: { type: "boolean", description: "Replace the existing snapshot with this name (default false)" },
      },
      required: ["photo_id", "name"],
    },
  },
  {
    name: "apply_develop_snapshot",
    title: "Apply develop snapshot",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerSnapshots.apply",
    description: "Restore a photo develop settings from one of its snapshots.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        snapshot_id: { type: "string", minLength: 1, description: "Snapshot id returned for this photo" },
      },
      required: ["photo_id", "snapshot_id"],
    },
  },
  {
    name: "delete_develop_snapshot",
    title: "Delete develop snapshot",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerSnapshots.delete",
    description: "Delete one snapshot belonging to the photo.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        snapshot_id: { type: "string", minLength: 1, description: "Snapshot id returned for this photo" },
      },
      required: ["photo_id", "snapshot_id"],
    },
  },
  {
    name: "apply_auto_adjustments",
    title: "Apply auto adjustments",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerDevelop.applyAutoAdjustments",
    description:
      "Apply Auto Tone, Auto White Balance or both to up to 100 photos. Set tone or white_balance true (omitted=false). Opens each in Develop and waits for settled settings; shared restoration rules apply. Returns applied/unchanged/skipped/failed with non-applied reasons; missing/duplicates skipped. Stops near 240 s with complete:false and remaining_ids to retry.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: { ...photoIdArray("Photo IDs or file paths"), maxItems: 100 },
        tone: { type: "boolean", description: "Apply Lightroom Auto Tone (default false)" },
        white_balance: { type: "boolean", description: "Apply Lightroom Auto White Balance (default false)" },
      },
      required: ["photo_ids"],
      anyOf: [
        { required: ["tone"], properties: { tone: { const: true } } },
        { required: ["white_balance"], properties: { white_balance: { const: true } } },
      ],
    },
  },
  {
    name: "reset_develop_adjustments",
    title: "Reset develop adjustments",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerDevelop.resetDevelopAdjustments",
    description:
      "Reset all Develop edits, including crop/masks, on up to 100 photos (confirm:true); recover through Lightroom History. Opens each in Develop; shared restoration rules apply. Returns reset/skipped/failed; missing/duplicates skipped. Stops near 240 s or cancellation with remaining_ids to retry.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: { ...photoIdArray("Photo IDs or file paths"), maxItems: 100 },
        confirm: { type: "boolean", enum: [true], description: "Confirm discarding all develop adjustments" },
      },
      required: ["photo_ids", "confirm"],
    },
  },
  {
    name: "apply_denoise",
    title: "Apply denoise",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerDevelop.applyDenoise",
    description:
      "Enable/change AI Denoise through Develop (LrC 15+), not a develop key. Activates each photo; shared restoration rules apply. Activity Center computes in background. Same amount skips; other settings stay. Max 100 photos; stops near 240 s. Returns success, counts, per-photo results, seconds, complete/remaining_ids and progress/retry guidance.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: {
          ...photoIdArray("Photo IDs or file paths"),
          maxItems: MAX_DENOISE_PHOTO_IDS,
        },
        amount: {
          type: "integer",
          minimum: 1,
          maximum: 100,
          description: "Denoise amount, as on the Develop panel slider (Lightroom's default is 50)",
        },
        restore_selection: {
          type: "boolean",
          description:
            "Put the user's module, view source and selection back afterwards (default true). Pass false when calling in back-to-back batches: restoring loads one more photo per call.",
        },
      },
      required: ["photo_ids", "amount"],
    },
  },
  {
    name: "list_spots",
    title: "List Remove spots",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerSpots.list",
    description: "List Remove spots (LrC 14.1+): count, 1-based index and complete SDK params including nested fields. Indices shift after deletion. Opens Develop, preserves active tool; shared restoration rules apply.",
    inputSchema: {
      type: "object", additionalProperties: false,
      properties: { photo_id: photoIdSchema("Photo ID or file path") },
      required: ["photo_id"],
    },
  },
  {
    name: "update_spot",
    title: "Update Remove spot opacity",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerSpots.update",
    description: "Set one Heal spot params.Opacity (uppercase, 0..1) by 1-based list_spots index (LrC 14.1+). Preserves other fields/spots; sends complete selected-spot table and reads back. Returns index/changed/SDK params. Opens Remove if needed; restores previous tool and shared Develop state.",
    inputSchema: {
      type: "object", additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        index: { type: "integer", minimum: 1 },
        params: { type: "object", additionalProperties: false,
          properties: { Opacity: { type: "number", minimum: 0, maximum: 1 } }, required: ["Opacity"] },
      },
      required: ["photo_id", "index", "params"],
    },
  },
  {
    name: "delete_spot",
    title: "Delete Remove spot",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerSpots.delete",
    description: "Delete Remove spot by 1-based list_spots index (LrC 14.1+, confirm:true). Returns deleted_index, remaining count/spots; later indices shift. Invalid index fails unchanged. Opens Remove if needed; restores previous tool and shared Develop state.",
    inputSchema: {
      type: "object", additionalProperties: false,
      properties: { photo_id: photoIdSchema("Photo ID or file path"),
        index: { type: "integer", minimum: 1 }, confirm: { type: "boolean", const: true } },
      required: ["photo_id", "index", "confirm"],
    },
  },
  {
    name: "list_masks",
    title: "List masks",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerMasks.listMasks",
    description:
      "List masks (Lightroom Classic 11+): id/name/hidden and tools with id/type/subtype/inverted. Range tools include stored luminance/depth min/max/falloffs or color x/y/l/a/b/amount; use these color rankings with create_range_mask. UI-created ranges appear only after Lightroom saves them to the catalog. No masks returns an empty list. Ids remain valid on that photo while masks stay unchanged. Shared Develop restoration rules apply.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
      },
      required: ["photo_id"],
    },
  },
  {
    name: "create_gradient_mask",
    title: "Create gradient mask",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerGradientMasks.createGradientMask",
    description:
      "Place a linear or radial gradient (Lightroom Classic 15.6 only; shared guarded-write and coordinate rules apply). Linear: full strength at start, fading to zero at end. Radial: center, width, height, clockwise rotation, feather 0 hard to 100 soft, area inside or outside. Omit mask_id for a new optionally named mask; supply it to add a component with mode add (default) or subtract. Intersect is unsupported. New masks start neutral. Returns mask_id, tool_id for update_gradient_mask, shape and stored geometry.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        adjustments: {
          type: "object",
          additionalProperties: false,
          minProperties: 1,
          properties: MASK_ADJUSTMENT_PROPERTIES,
          description: "Sliders for a new mask, using unprefixed names such as exposure; not allowed with mask_id",
        },
        shape: { type: "string", enum: ["linear", "radial"], description: "Gradient type" },
        ...gradientGeometryProperties,
        mask_id: {
          type: "string",
          minLength: 1,
          description: "Add the gradient to this existing mask instead of creating a new one",
        },
        mode: {
          type: "string",
          enum: ["add", "subtract"],
          description: "How a component combines with the mask (default add); subtract needs mask_id",
        },
        name: {
          type: "string",
          minLength: 1,
          description: "Name of a new mask; not allowed together with mask_id",
        },
      },
      required: ["photo_id", "shape"],
    },
  },
  {
    name: "update_gradient_mask",
    title: "Update gradient mask",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerGradientMasks.updateGradientMask",
    description:
      "Reshape a gradient by tool_id from list_masks or create_gradient_mask (Lightroom Classic 15.6 only; shared guarded-write and coordinate rules apply). Supply only changed fields: start/end for linear, center/width/height/rotation/feather/area for radial; fields of the other shape are rejected. Preserves tool id, mask id and adjustments.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        tool_id: { type: "string", minLength: 1, description: "Tool id of the gradient to change" },
        ...gradientGeometryProperties,
      },
      required: ["photo_id", "tool_id"],
    },
  },
  {
    name: "create_brush_mask",
    title: "Create brush mask",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    luaHandler: "HandlerBrushMasks.createBrushMask",
    description:
      "Paint strokes into a new optionally named brush mask, or supply mask_id to add a brush component (Lightroom Classic 15.6 only; shared guarded-write and coordinate rules apply). Each nonempty stroke has points; dabs fill consecutive points at most half a radius apart. radius defaults to 0.14; its soft edge fades near 60% (0.05 on a 1000 px photo gives about 60 px width). Lightroom's Size slider depends on Develop zoom; use radius. Per-stroke flow/density default to 1, feather to 100, erase to false; erase removes only earlier paint of that brush. Empty strokes are rejected. New masks start neutral. Use add_brush_strokes for an existing brush. Read-back checks every dab position and flow. Returns mask_id, tool_id, strokes_added and stroke_count.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        adjustments: {
          type: "object",
          additionalProperties: false,
          minProperties: 1,
          properties: MASK_ADJUSTMENT_PROPERTIES,
          description: "Sliders for a new mask, using unprefixed names such as exposure; not allowed with mask_id",
        },
        ...brushStrokeProperties,
        mask_id: {
          type: "string",
          minLength: 1,
          description: "Add the brush to this existing mask instead of creating a new one",
        },
        name: {
          type: "string",
          minLength: 1,
          description: "Name of a new mask; not allowed together with mask_id",
        },
      },
      required: ["photo_id", "strokes"],
    },
  },
  {
    name: "add_brush_strokes",
    title: "Add brush strokes",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerBrushMasks.addBrushStrokes",
    description:
      "Append strokes to a brush by tool_id from list_masks or create_brush_mask (Lightroom Classic 15.6 only; shared guarded-write and coordinate rules apply). Uses create_brush_mask stroke settings and path filling; existing strokes, ids and adjustments stay unchanged. Empty strokes are rejected. Append erase strokes to remove paint, or delete the brush with delete_masks tool_ids and repaint. Returns mask_id, tool_id, strokes_added and stroke_count.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        tool_id: { type: "string", minLength: 1, description: "Tool id of the brush to add strokes to" },
        ...brushStrokeProperties,
      },
      required: ["photo_id", "tool_id", "strokes"],
    },
  },
  {
    name: "create_range_mask",
    title: "Create range mask",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerRangeMasks.createRangeMask",
    description:
      "Create a luminance, color or depth range (Lightroom Classic 15.6 only; shared guarded-write and coordinate rules apply). Luminance selects min..max (0 black, 1 white), fading over falloff on each side, clipped at 0 and 1. Depth uses device depth (0 nearest, 1 farthest), requires a depth photo such as iPhone Portrait HEIC and refuses the full 0..1 scene. Luminance/depth bands must be at least 0.01 wide; falloff may be 0. Color takes exactly one sample: l, a, b in 0..1 plus x, y for the pin. A second sample point is rejected because Lightroom crashes on it. l, a, b are per-photo Lightroom rankings, not sRGB or computable from RGB: lightness darkest to brightest, green to red, blue to yellow. The same color has different rankings in different photos; develop edits leave them unchanged. Selection follows l, a, b, not the pin. Obtain them through list_masks after clicking Tools > Create New Mask > Color Range in Lightroom, or supply your own ranking (e.g. l 0.9, a 0.95 for brightest reds). Instead of color.sample, copy_sample_from takes mask_id, tool_id and optional photo_id: copies one color sample verbatim, preserving its displayed pin and amount unless color.amount overrides it. Other range types, unknown ids, a tool outside that mask or multiple samples fail unchanged. Cross-photo copies select similarly ranked pixels, which match colors only for identical pixel content; different photos can select different colors. Returns copied_from. amount is >0 to 1 (default 0.5), narrow to broad. Omit mask_id for a new optionally named mask; supply it to add a component with mode add (default) or subtract; intersect is unsupported. invert selects outside the range. New masks start neutral. Returns mask_id, tool_id, type and stored range; verifies a rangeMask with the requested subtype.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        adjustments: {
          type: "object",
          additionalProperties: false,
          minProperties: 1,
          properties: MASK_ADJUSTMENT_PROPERTIES,
          description: "Sliders for a new mask, using unprefixed names such as exposure; not allowed with mask_id",
        },
        type: { type: "string", enum: ["luminance", "color", "depth"], description: "Kind of range mask" },
        luminance: {
          type: "object",
          additionalProperties: false,
          properties: {
            min: { type: "number", minimum: 0, maximum: 1, description: "Darkest tone selected at full strength" },
            max: { type: "number", minimum: 0, maximum: 1, description: "Brightest tone selected at full strength" },
            falloff: {
              type: "number",
              minimum: 0,
              maximum: 1,
              description: "Width of the fade on each side of min and max (default 0.1); 0 gives hard edges",
            },
          },
          required: ["min", "max"],
          description: "Luminance only: the tonal range to select; max must be at least 0.01 above min",
        },
        depth: {
          type: "object",
          additionalProperties: false,
          properties: {
            min: { type: "number", minimum: 0, maximum: 1, description: "Nearest depth selected at full strength (0 is the nearest point of the scene)" },
            max: { type: "number", minimum: 0, maximum: 1, description: "Farthest depth selected at full strength (1 is the farthest point of the scene)" },
            falloff: {
              type: "number",
              minimum: 0,
              maximum: 1,
              description: "Width of the fade on each side of min and max (default 0.1); 0 gives hard edges",
            },
          },
          required: ["min", "max"],
          description: "Depth only: the depth range to select; max must be at least 0.01 above min",
        },
        color: {
          type: "object",
          additionalProperties: false,
          properties: {
            sample: {
              type: "object",
              additionalProperties: false,
              properties: {
                x: { type: "number", minimum: 0, maximum: 1, description: "Horizontal position of the sample, 0 = left edge" },
                y: { type: "number", minimum: 0, maximum: 1, description: "Vertical position of the sample, 0 = top edge" },
                l: { type: "number", minimum: 0, maximum: 1, description: "Lightness rank among the photo's pixels, 0 darkest, 1 brightest (Lightroom's stored value, not sRGB)" },
                a: { type: "number", minimum: 0, maximum: 1, description: "Green-to-red rank among the photo's pixels, 0 greenest, 1 reddest (Lightroom's stored value, not sRGB)" },
                b: { type: "number", minimum: 0, maximum: 1, description: "Blue-to-yellow rank among the photo's pixels, 0 bluest, 1 yellowest (Lightroom's stored value, not sRGB)" },
              },
              required: ["x", "y", "l", "a", "b"],
              description: "The single sample point: its pin position and Lightroom's stored l, a and b for the color",
            },
            amount: {
              type: "number",
              exclusiveMinimum: 0,
              maximum: 1,
              description: "How far from the sampled color still counts, small narrow to 1 broad (default 0.5)",
            },
          },
          description: "Color only: the sample (required unless copy_sample_from is given, then not allowed) and the refine amount (with copy_sample_from, defaults to the source's amount)",
        },
        copy_sample_from: {
          type: "object",
          additionalProperties: false,
          properties: {
            mask_id: { type: "string", minLength: 1, description: "Mask id from list_masks that holds the color range to copy" },
            tool_id: { type: "string", minLength: 1, description: "Tool id of the color range inside that mask" },
            photo_id: photoIdSchema("Photo to copy from; defaults to photo_id"),
          },
          required: ["mask_id", "tool_id"],
          description: "Color only: copy the stored l, a, b sample and pin of an existing color range instead of giving color.sample",
        },
        invert: { type: "boolean", description: "Select everything outside the range (default false)" },
        mask_id: {
          type: "string",
          minLength: 1,
          description: "Add the range to this existing mask instead of creating a new one",
        },
        mode: {
          type: "string",
          enum: ["add", "subtract"],
          description: "How a component combines with the mask (default add); subtract needs mask_id",
        },
        name: {
          type: "string",
          minLength: 1,
          description: "Name of a new mask; not allowed together with mask_id",
        },
      },
      required: ["photo_id", "type"],
    },
  },
  {
    name: "delete_masks",
    title: "Delete masks",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerMaskDelete.deleteMasks",
    description:
      "Delete masks on one photo (Lightroom Classic 11+). Exactly one of mask_ids, tool_ids or all=true; ids from list_masks. Removing a last component removes its mask. All ids validated before deletion; unknown ids fail unchanged. Opens Develop/Masking and verifies applied/saved deletion; shared restoration rules apply. Remaining mask ids can change: call list_masks again. Returns deleted mask/tool ids and remaining mask count.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_ids: {
          type: "array",
          items: { type: "string", minLength: 1 },
          minItems: 1,
          maxItems: MAX_MASK_DELETE_IDS,
          description: "Mask ids from list_masks to delete",
        },
        tool_ids: {
          type: "array",
          items: { type: "string", minLength: 1 },
          minItems: 1,
          maxItems: MAX_MASK_DELETE_IDS,
          description: "Component tool ids from list_masks to delete",
        },
        all: {
          type: "boolean",
          enum: [true],
          description: "Pass true to delete every mask on the photo",
        },
      },
      required: ["photo_id"],
      oneOf: [{ required: ["mask_ids"] }, { required: ["tool_ids"] }, { required: ["all"] }],
    },
  },
  {
    name: "delete_empty_masks",
    title: "Delete empty masks",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerMaskDelete.deleteEmptyMasks",
    description:
      "Delete tool-less masks on up to 1000 photos (LrC 14+). Catalog-only: preserves module/selection without opening Develop. Returns photos_changed (lost a mask), photos_checked and missing IDs.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Photo IDs or file paths"),
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "set_mask_adjustments",
    title: "Set mask adjustments",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerMaskAdjustments.setMaskAdjustments",
    description:
      "Change any subset of local SDK sliders on a mask_id from list_masks (Lightroom Classic 11+); other sliders stay unchanged. Schema lists slider names/ranges; Lightroom actual ranges win. Unknown mask or invalid value fails before writing. Shared slider read-back, save wait and Develop restoration rules apply. Returns values read back, changed sliders (from/to) and unchanged sliders.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_id: maskIdSchema("Mask id from list_masks"),
        adjustments: {
          type: "object",
          properties: localAdjustmentProperties,
          additionalProperties: false,
          minProperties: 1,
          description:
            "Local slider names and the numbers to set (e.g., {\"local_Exposure\": 0.5, \"local_Shadows\": -20})",
        },
      },
      required: ["photo_id", "mask_id", "adjustments"],
    },
  },
  {
    name: "get_mask_adjustments",
    title: "Get mask adjustments",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerMaskAdjustments.getMaskAdjustments",
    description:
      "Read local SDK slider values by mask_id from list_masks (Lightroom Classic 11+), for every slider set_mask_adjustments supports. Unexposed sliders appear in unavailable. Unknown ids fail. Shared Develop restoration rules apply.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_id: maskIdSchema("Mask id from list_masks"),
      },
      required: ["photo_id", "mask_id"],
    },
  },
  {
    name: "invert_mask",
    title: "Invert mask",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerMaskInvert.invertMask",
    description:
      "Invert by mask_id from list_masks (Lightroom Classic 11.4+). in_place flips only one component of a multi-component mask; result lists every tool/inverted flag. copy keeps the source and copies its local sliders onto an inverted duplicate; read-back mismatch removes the copy and fails. Returns mask_id and source_mask_id, with adjustments_copied counting slider writes in the Duplicate and Invert history step. Use returned mask_id: develop writes can regenerate ids. Unknown ids fail unchanged. Shared Develop restoration rules apply.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_id: {
          type: "string",
          minLength: 1,
          description: "ID of the mask to invert, from list_masks",
        },
        mode: {
          type: "string",
          enum: ["in_place", "copy"],
          description: "in_place inverts the mask; copy keeps it and creates an inverted copy",
        },
      },
      required: ["photo_id", "mask_id", "mode"],
    },
  },
  {
    name: "create_mask",
    title: "Create mask",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    luaHandler: "HandlerMaskCreate.createMask",
    description:
      "Create a detected Subject, Sky or Background mask (Lightroom Classic 11+) and return mask_id; existing masks stay unchanged. Optional local adjustments default every omitted slider to 0, never inheriting the Masking panel. Exposure is -4 to 4. Nothing found fails after about 30 s without a new mask, but a \"No sky detected\" modal alert blocks all Develop calls until someone clicks OK in Lightroom. Shared Develop restoration and history rules apply.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        type: {
          type: "string",
          enum: [...MASK_TYPES],
          description: "What Lightroom should select: subject, sky or background",
        },
        adjustments: {
          type: "object",
          additionalProperties: false,
          properties: MASK_ADJUSTMENT_PROPERTIES,
          description: "Local adjustment sliders for the new mask. Omitted sliders start at 0.",
        },
      },
      required: ["photo_id", "type"],
    },
  },
  {
    name: "create_mask_batch",
    title: "Create mask batch",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    luaHandler: "HandlerMaskBatch.createMaskBatch",
    description:
      "Create Subject, Sky or Background masks with the same adjustments on up to 200 photos (Lightroom Classic 15.6 only; shared guarded-write rules apply). Opens the first photo in Develop as create_mask does; strips computed data and recomputes on each later photo without opening Develop. Existing masks stay unchanged. Returns results with status created/failed/not_attempted, created boolean, mask_id or reason; counts, missing ids and complete. Nothing found removes the added mask and continues, except on the first photo: a \"No sky detected\" modal alert blocks Develop until OK is clicked in Lightroom, stops the batch and leaves the rest not_attempted; dismiss it and drop that photo before retrying. Stops near 230 s with complete false and remaining_ids to retry. Rejected mask formats fail untouched. Exposure is -4 to 4.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: {
          ...photoIdArray("Photo IDs or file paths"),
          maxItems: MAX_MASK_BATCH_PHOTO_IDS,
        },
        type: {
          type: "string",
          enum: [...MASK_TYPES],
          description: "What Lightroom should select on each photo: subject, sky or background",
        },
        adjustments: {
          type: "object",
          additionalProperties: false,
          properties: MASK_ADJUSTMENT_PROPERTIES,
          description: "Local adjustment sliders for each new mask. Omitted sliders start at 0.",
        },
      },
      required: ["photo_ids", "type"],
    },
  },
  {
    name: "create_people_mask",
    title: "Create people mask",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    luaHandler: "HandlerAiMasks.createPeopleMask",
    description:
      "Create one People mask per part (Lightroom Classic 15.6; shared guarded-write rules apply). Parts are listed in the schema; each covers all people. No single-person option: Lightroom ignores written person ids and masks the first person. Returns mask_id for the first mask and masks with each part/id. Missing person or part fails and removes all new masks; unknown/duplicate parts fail before access. Computes selection for up to 120 s without opening Develop. If masks are open in Develop, an \"AI process is running\" alert can require clicking OK in Lightroom. New masks have no adjustments; use set_mask_adjustments.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        parts: {
          type: "array",
          items: { type: "string", enum: [...PEOPLE_MASK_PARTS] },
          minItems: 1,
          maxItems: PEOPLE_MASK_PARTS.length,
          uniqueItems: true,
          description: "Parts of a person to select; each part becomes its own mask",
        },
      },
      required: ["photo_id", "parts"],
    },
  },
  {
    name: "create_landscape_mask",
    title: "Create landscape mask",
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    luaHandler: "HandlerAiMasks.createLandscapeMask",
    description:
      "Create one Landscape mask per category (Lightroom Classic 15.6; shared guarded-write rules apply). Categories are listed in the schema. Returns mask_id for the first mask and masks with each category/id. Any missing region fails and removes all new masks; unknown/duplicate categories fail before access. Computes selection without opening Develop, up to 120 s (often about 15 s). If masks are open in Develop, an \"AI process is running\" alert can require clicking OK in Lightroom. New masks have no adjustments; use set_mask_adjustments.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        categories: {
          type: "array",
          items: { type: "string", enum: [...LANDSCAPE_MASK_CATEGORIES] },
          minItems: 1,
          maxItems: LANDSCAPE_MASK_CATEGORIES.length,
          uniqueItems: true,
          description: "Landscape categories to select; each category becomes its own mask",
        },
      },
      required: ["photo_id", "categories"],
    },
  },
  {
    name: "set_mask_curves",
    title: "Set mask curves",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerMaskCurves.setMaskCurves",
    description:
      "Set local tone curves by mask_id from list_masks (Lightroom Classic 12.3+). curves takes any subset of main (RGB), red, green, blue; flat input/output arrays on 0..255, 2..32 integer pairs with strictly increasing inputs from 0 to 255. [0,0,255,255] is straight. Other channels stay unchanged. Shared curve read-back, rollback, save wait and Develop restoration rules apply. Unsupported versions fail naming the minimum version. Returns read-back curves, changed channels (from/to) and unchanged channels.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_id: maskIdSchema("Mask id from list_masks"),
        curves: {
          type: "object",
          additionalProperties: false,
          minProperties: 1,
          properties: maskCurveProperties,
          description: "Channel names and the point arrays to set (e.g., {\"main\": [0, 0, 128, 140, 255, 255]})",
        },
      },
      required: ["photo_id", "mask_id", "curves"],
    },
  },
  {
    name: "get_mask_curves",
    title: "Get mask curves",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerMaskCurves.getMaskCurves",
    description:
      "Read local main (RGB), red, green and blue tone curves by mask_id from list_masks (Lightroom Classic 12.3+), as Lightroom flat input/output arrays. Missing channels appear in unavailable; none returned fails naming the minimum version. Unknown ids fail. Shared Develop restoration rules apply.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_id: maskIdSchema("Mask id from list_masks"),
      },
      required: ["photo_id", "mask_id"],
    },
  },
  {
    name: "edit_mask_point_colors",
    title: "Edit mask point colors",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerMaskPointColors.editMaskPointColors",
    description:
      "Edit local Point Color swatches by mask_id from list_masks (Lightroom Classic 13.2+). Up to 8 swatches, indexed from 1 as in get_mask_point_colors. add requires swatch SrcHue (0..6), SrcSat/SrcLum (0..1); duplicate source color fails. Optional shift/scale/range fields and limits are in the schema. update needs index and changed swatch fields; delete needs index; clear removes all swatches. Preserves mask sliders and other/global settings. Read-back mismatch restores a swatch update. Restores previous mask and swatch after Develop. Unsupported versions fail naming the minimum version. Returns action, affected index, changed flag and resulting swatches.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_id: maskIdSchema("Mask id from list_masks"),
        action: {
          type: "string",
          enum: ["add", "update", "delete", "clear"],
          description: "What to do with the mask's Point Color swatches",
        },
        index: {
          type: "integer",
          minimum: 1,
          maximum: 8,
          description: "Swatch number, from 1; required for update and delete",
        },
        swatch: {
          type: "object",
          additionalProperties: false,
          minProperties: 1,
          properties: pointColorSwatchProperties,
          description: "Swatch fields; add needs SrcHue, SrcSat and SrcLum, update takes any subset",
        },
      },
      required: ["photo_id", "mask_id", "action"],
    },
  },
  {
    name: "get_mask_point_colors",
    title: "Get mask point colors",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerMaskPointColors.getMaskPointColors",
    description:
      "Read local Point Color swatches by mask_id from list_masks (Lightroom Classic 13.2+), in Lightroom order, indexed from 1 for edit_mask_point_colors. Returns SrcHue, SrcSat, SrcLum, HueShift, SatScale, LumScale, RangeAmount, HueRange, SatRange and LumRange as reported; no swatches returns an empty list. Unknown ids fail. Shared Develop restoration rules apply.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_id: maskIdSchema("Mask id from list_masks"),
      },
      required: ["photo_id", "mask_id"],
    },
  },
  {
    name: "combine_mask",
    title: "Combine mask",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerMaskCombine.combineMask",
    description:
      "Add, subtract or intersect a detected Subject, Sky or Background component on a mask (Lightroom Classic 11+). Selects and verifies mask_id from list_masks before changes; unknown ids fail unchanged. Returns new tool_id. add widens, subtract removes, intersect keeps overlap; Lightroom stores intersect as subtracted/inverted, shown inverted true in list_masks. Nothing found fails after about 30 s, keeps existing components and shows a \"No sky detected\" modal alert blocking Develop until OK in Lightroom. Restores prior mask, tool, module, view source and selection; shared detection/history rules apply.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        mask_id: maskIdSchema("ID of the mask to combine into, from list_masks"),
        operation: {
          type: "string",
          enum: [...MASK_COMBINE_OPERATIONS],
          description: "add widens the mask, subtract removes the area from it, intersect keeps only the overlap",
        },
        type: {
          type: "string",
          enum: [...MASK_TYPES],
          description: "What Lightroom should select for the component: subject, sky or background",
        },
      },
      required: ["photo_id", "mask_id", "operation", "type"],
    },
  },
];
