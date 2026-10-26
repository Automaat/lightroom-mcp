import type { JSONObject, Tool } from "@modelcontextprotocol/server";

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
}

const MAX_BULK_PHOTO_IDS = 1000;
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
  oneOf: [{ type: "string", minLength: 1 }, { type: "number" }],
  description,
});

const photoIdArray = (description: string): JSONObject => ({
  type: "array",
  items: { oneOf: [{ type: "string", minLength: 1 }, { type: "number" }] },
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
    title: "Search photos",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerSearch.searchPhotos",
    description:
      "Search photos using intersecting Library filters (paginated, default limit 100): filename, keywords, rating, capture date, camera, lens, ISO, focal length, flag, color label, edited status, file type and folder. Provide at least one filter to improve performance on large catalogs.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
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
      "Summarize numeric Develop settings by camera model and ISO bucket (1-400, 401-1600, 1601-6400, 6401+, unknown). Select rating >= min_rating (default 4); exported_only additionally requires raw isExported true. Set min_rating 0 for all ratings. Read at most max_photos Develop settings (default and maximum 200); exported selection reads batched flags for all rating matches. Returns groups with count and SDK setting keys mapped to median/min/max, plus scanned, matched and truncated. Excludes crop, perspective, Temperature, Tint, non-numeric/non-finite and all-zero settings. Each group fits 6000 characters; settings are considered alphabetically and settings_omitted counts those excluded by the size limit. Read-only; does not apply a style.",
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
      "Get detailed metadata for a specific photo: keywords (names, plus keywordPaths as full hierarchy paths), EXIF, title/caption/headline, GPS (latitude/longitude/altitude), IPTC location (sublocation/city/stateProvince/country/isoCountryCode), copyright, accessibility (alt_text/extended_description, Lightroom Classic 13.2+, omitted when empty or unsupported), and develop settings. isVirtualCopy identifies copies; virtualCopy has masterPhotoId for a copy or copyIds for a master with copies. Folder stack metadata is in stack (position, top is 1; isCollapsed; topPhotoId; ordered memberIds). All photo ids are catalog local identifiers. The virtualCopy and stack groups are omitted when absent. developSettings reads back every key set_develop_settings writes. The basic panel, tone curves and parametric curve use camelCase names (exposure, toneCurve, parametricShadows, ...). The hsl, lens, transform, crop, detail (sharpening, noise reduction), effects (vignette, grain) and parametricSplits groups use the SDK names set_develop_settings takes, and a group is omitted when the photo has none of its settings",
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
    name: "get_photo_preview",
    title: "Get photo preview",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerPreview.getPhotoPreview",
    description:
      "Get a JPEG preview of a photo, returned as an image, so you can see what it shows. Lightroom renders it with the photo's current develop settings, so raw files work. size is the smallest longest edge you will accept: Lightroom returns the smallest preview it has at least that big, so the image is often larger. An image over 3.5 MB or 2000px is replaced by the next smaller preview. width and height report what came back.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        size: {
          type: "number",
          description: "Minimum longest edge in pixels (64-2048, default 512)",
          minimum: 64,
          maximum: 2048,
        },
      },
      required: ["photo_id"],
    },
  },
  {
    name: "find_duplicate_groups",
    title: "Find duplicate groups",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerPreview.findDuplicateGroups",
    description:
      "Find near-duplicate or burst groups in up to 100 photo IDs or paths, without changing the catalog. Uses a 64-bit dHash of current JPEG previews (minimum edge 64), plus raw capture time. Defaults: time_window_seconds=5 and max_hamming_distance=10; both are inclusive and must hold between every pair in a group. Groups are built in input order, exclude singletons, and report resolved photo IDs; repeated photos are ignored. Hash similarity is approximate and does not select the best frame. photos reports each processed ID and raw capture_time in Lightroom seconds; times have second precision and no timezone normalization. No hashes are cached. Stops after a 25-second budget and returns groups found so far, complete=false and remaining_ids; preview failures or missing times appear in unprocessed with a reason. A group can grow when remaining IDs are retried together with the original set.",
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
      "Read rendered-preview statistics for up to 20 photos with current develop settings. Returns one result or error per input id. histogram has 64 normalized bins of Rec.709 luma (0-255, four levels per bin); mean_luminance uses that same scale. shadow_fraction counts luma <=1 and highlight_fraction counts luma >=254. sharpness is four-neighbor Laplacian variance after area resampling to a fixed 512-pixel long edge; higher means sharper. These are JPEG preview measures, not raw sensor clipping or full-resolution focus measurements. Small previews are enlarged. Catalog contents are unchanged.",
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
      "Set the GPS position of photos in decimal degrees, replacing any position they already have. Altitude is left unchanged unless altitude is given or clear_altitude is true.",
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
      "Set the IPTC location fields of photos (sublocation, city, state/province, country, ISO country code), as get_photo_metadata reports them. Fields left out are unchanged; an empty string clears a field. Give at least one field. GPS is not touched (use set_gps).",
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
      "Set IPTC description, rights and accessibility fields of photos (title, caption, headline, creator, copyright notice, rights usage terms, copyright info URL, creator website, alt text, extended description), as get_photo_metadata reports them. Accessibility text requires Lightroom Classic 13.2 or later. Fields left out are unchanged; an empty string clears a field. Give at least one field. Copyright status cannot be set.",
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
    description: "Create a new collection",
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
    description: "Save intersecting search_photos filters as a smart collection that updates as photos change. Requires at least one filter. Missing parent collection sets are created; an existing sibling name is rejected.",
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
      "Add photos to a collection. Use a path from list_collections when names repeat; an ambiguous bare name is rejected.",
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
      "Remove photos from a collection. They stay in the catalog and in any other collection. Smart collections cannot be edited this way. removed counts unique photos that were in the collection. Use a path from list_collections when names repeat.",
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
      "Delete a collection. Its photos stay in the catalog. Use a path from list_collections when names repeat; an ambiguous bare name is rejected.",
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
      "Add or remove keywords from photos. A keyword is a plain name, or a parent-first hierarchy path with '|' between levels (e.g. 'Places|Europe|Paris') to address a nested keyword; see list_keywords for the paths that exist. A plain name is created at the top level if it does not exist, and a path creates any missing levels, unless create_missing is false. Names and paths match existing keywords ignoring case.",
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
      "Detach a parent keyword and every descendant from photos, preserving unrelated keywords, including same-named keywords elsewhere. Use a dedicated parent such as 'AI Keywords' with set_keywords to undo a tagging batch. The parent path matches ignoring case; an unknown parent fails without changes. Specify photo_ids or explicitly request catalog_wide=true to affect every photo carrying the subtree. Keyword nodes stay in the catalog and remain visible in list_keywords; this tool does not delete keywords. Returns updated (photos changed), removed (assignments detached), and missing photo IDs.",
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
      "List the catalog's keyword hierarchy as full parent-first paths ('Places|Europe|Paris') with synonyms and the include-on-export flag (paginated, default limit 100). The paths can be passed to set_keywords. For a large hierarchy, narrow with parent or query, or use paths_only for a much smaller response.",
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
      "Rename a keyword in place: every photo tagged with it shows the new name, and its parent, children and synonyms are unchanged. keyword is a plain name, which must match exactly one keyword, or a 'Parent|Child' path (see list_keywords). Fails if a sibling already has the new name, ignoring case, since keywords cannot be merged; a change of case alone is allowed.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        keyword: {
          type: "string",
          minLength: 1,
          description: "Keyword to rename: a plain name or a 'Parent|Child' path",
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
      "Undo exactly one step from Lightroom's shared history. Requires confirm: true. This can undo a user action or another plug-in's action made after your last edit; it does not identify who made the last change. Call only when you accept undoing whatever Lightroom currently considers its last history step. Returns undone and can_undo (whether another undo is available after this call).",
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
    name: "set_rating",
    title: "Set rating",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerOrganization.setRating",
    description: "Set star rating for photos",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        rating: {
          type: "number",
          description: "Star rating (0-5)",
          minimum: 0,
          maximum: 5,
        },
      },
      required: ["photo_ids", "rating"],
    },
  },
  {
    name: "set_flag",
    title: "Set flag",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerOrganization.setFlag",
    description:
      "Set the pick flag of photos: pick, reject, or none to remove the flag. get_photo_metadata reports it as pickStatus (1, -1 or 0).",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths"),
        flag: {
          type: "string",
          enum: ["pick", "reject", "none"],
          description: "pick, reject, or none (unflagged)",
        },
      },
      required: ["photo_ids", "flag"],
    },
  },
  {
    name: "set_color_label",
    title: "Set color label",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerOrganization.setColorLabel",
    description:
      "Set the color label of photos to red, yellow, green, blue, purple, or none to clear it. get_photo_metadata reports it as colorLabel.",
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
      "Remove exactly the given photos from the catalog, losing their catalog edits and metadata. Requires confirm: true and Lightroom Classic 14.3+. Files stay on disk. Maximum 100 IDs or paths; duplicates count once and missing IDs are reported. Include every virtual copy when removing its master. Temporarily opens Library grid and All Photographs; restores the module, sources and surviving selection. Library remains in grid view.",
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
      "Import a photo, or every photo in a folder and its subfolders, into the Lightroom catalog. Folder imports take camera raw (CR3, RAF, ORF, RW2, NEF, ARW, DNG and other Camera Raw formats), JPEG, HEIC/HEIF, AVIF, JPEG XL, TIFF, PNG and PSD/PSB files; other files are skipped and counted by extension in the reply.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        source_path: { type: "string", description: "Path to photo or folder to import" },
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
    description: "Export photos from Lightroom",
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
      "Write catalog metadata for many photos to a JSON file on disk: file, capture time, dimensions, rating, title/caption, GPS, location, keywords and keywordPaths (no develop settings). Exports the given photos, or the current selection (the filmstrip if nothing is selected) when photo_ids is omitted; at most 1000 photos per call. Use instead of calling get_photo_metadata once per photo.",
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
    description: "List Lightroom-visible Develop presets and plugin-managed preset checkpoints",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {},
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
      "Create a versioned plugin-managed Develop preset checkpoint from selected settings on one photo. The checkpoint is hidden from the Develop panel; export it for handoff.",
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
          items: { type: "string", enum: [...DEVELOP_SETTING_KEYS] },
          minItems: 1,
          maxItems: DEVELOP_SETTING_KEYS.length,
          uniqueItems: true,
          description: "Explicit Lightroom SDK setting keys to capture from the source photo",
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
      "Apply one exact Develop preset to one or more photos. When the preset contains AI masks (Subject, Sky, Background, ...), Lightroom Classic 13.3+ recomputes each mask for every target photo after applying; ai_updated counts the photos recomputed and ai_update_failed lists the ids where the recompute failed. Earlier versions, and presets without AI masks, are applied as before.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
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
      "Copy Develop settings from one photo to others. When the copied settings contain AI masks (copied when settings is omitted), Lightroom Classic 13.3+ recomputes each mask for every target photo after copying; ai_updated counts the photos recomputed and ai_update_failed lists the ids where the recompute failed. Earlier versions, and copies without AI masks, behave as before.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        source_id: photoIdSchema("Source photo ID or file path"),
        target_ids: photoIdArray("Target photo IDs or file paths"),
        settings: {
          type: "array",
          items: {
            type: "string",
            enum: [...DEVELOP_SETTING_KEYS],
          },
          minItems: 1,
          maxItems: DEVELOP_SETTING_KEYS.length,
          description:
            "Optional whitelist of SDK setting keys (e.g., Exposure2012, Contrast2012, HueAdjustmentOrange). Omit to copy all.",
        },
      },
      required: ["source_id", "target_ids"],
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
          properties: developSettingsProperties,
          additionalProperties: false,
          minProperties: 1,
          description:
            "Allowlisted SDK setting key/value pairs (e.g., {\"Exposure2012\": 0.5, \"SaturationAdjustmentOrange\": -10})",
        },
      },
      required: ["photo_id", "settings"],
    },
  },
  {
    name: "set_process_version",
    title: "Set process version",
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    luaHandler: "HandlerDevelop.setProcessVersion",
    description:
      "Change photos to Lightroom's Version 1 through Version 6 process versions. Requires confirm: true because changing versions can change a photo's look. Downgrades on photos with masks are refused and reported as skipped to preserve guarded mask editing. Drives Develop photo by photo and restores the module, view source and selection by default. Returns previous_version, new_version and changed, unchanged, skipped or failed status per photo. Missing and duplicate photos are skipped. Up to 100 photos; stops after about 240 seconds and returns remaining_ids for another call.",
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
    description: "Create one virtual copy per distinct photo, up to 25 photos per call. Optional copy_name names each copy. Returns copies with photo_id, master_id and copy_id, plus missing IDs. Use copy_id for subsequent edits. Restores the previous photo selection and view source. Repeating the call creates additional copies; an error can leave copies created before the failure.",
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
      "Apply Lightroom's Auto Tone, Auto White Balance, or both to up to 100 photos. Set tone or white_balance to true; omitted flags are false. Opens each photo in Develop and waits for its settings to settle, then restores the user's module, view source and selection. Reports applied, unchanged, skipped or failed per photo, with a reason for each non-applied result. Missing and duplicate photos are skipped. One Develop-driving call runs at a time. Stops after about 240 seconds with complete false and remaining_ids to retry.",
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
      "Reset all develop adjustments on up to 100 photos through Lightroom's Reset command. Requires confirm: true. Discards edits, including crop and masks; recover previous edits through Lightroom History. Opens each photo in Develop and restores the user's module, view source and selection. Reports reset, skipped or failed per photo; missing and duplicate photos are skipped. Stops after about 240 seconds or cancellation and returns remaining_ids for another call. One Develop-driving call runs at a time.",
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
      "Turn on AI Denoise at a given amount, or change its amount, on photos (Lightroom Classic 15+). Denoise is not a plain develop key, so this drives the Develop module: it switches to Develop, makes each photo active in turn, applies Denoise through Lightroom's own panel, then puts back the module, view source and selection. Lightroom computes the result in the background (Activity Center). Photos already at that amount are left alone; other develop settings are untouched. One call runs at a time; a second call is rejected until the first finishes. Up to 100 photos per call; a call stops after about 240 s, sets complete to false and lists the ids it did not reach in remaining_ids, so call again with those.",
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
    name: "list_masks",
    title: "List masks",
    annotations: { readOnlyHint: true, openWorldHint: false },
    luaHandler: "HandlerMasks.listMasks",
    description:
      "List the masks on a photo (Lightroom Classic 11+): each mask's id, name and hidden state, and its component tools with id, type, subtype and inverted state; a range mask tool also carries its stored range (luminance and depth: min, max and the two falloffs; color: sample with x, y and Lightroom's l, a and b, plus amount), which is where the l, a and b for create_range_mask come from. A range made in the Lightroom interface only appears once Lightroom has saved it to the catalog, so it can be missing right after the click. Lightroom's mask API only answers for the photo active in Develop, so this switches to Develop, opens the photo, reads its masks, then puts back the module, view source and selection. A photo without masks returns an empty list. Mask and tool ids stay valid for later calls on the same photo while its masks are unchanged. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
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
      "Place a linear or radial gradient mask on a photo (Lightroom Classic 15.6 with process version 15.4 only). All positions are normalized coordinates of the full uncropped image: x and y from 0 to 1, origin at the top-left corner of the uncropped photo, y growing downward; a crop does not move the origin, so on a cropped photo convert from the visible area first. Positions, width, height and rotation are as Lightroom shows the photo: a photo it shows rotated or mirrored (its orientation is not normal) stores masks in the unrotated frame, so the tool converts the geometry, and a photo whose orientation it cannot map is refused. Anything outside 0..1 is rejected and nothing is written. Linear: the effect is full strength at start and fades to nothing at end, like dragging the Linear Gradient tool from start to end. Radial: center is the middle of the ellipse, width and height are fractions of the image width and height (not pixels), rotation is clockwise degrees around the center, applied in the photo's pixel space so the ellipse keeps its width and height, feather runs 0 (hard) to 100 (soft), and area picks the inside or outside of the ellipse. Without mask_id this creates a new mask (optionally named); with mask_id (from list_masks or an earlier call) the gradient is added as a component of that mask, with mode add (default) or subtract. Intersect is not supported. The mask starts with no adjustments, so it changes nothing visible until adjustments are set on it. This writes Lightroom's undocumented develop-setting format: before writing it checks the Lightroom version, the photo's process version and the format of every mask already on the photo, then writes, reads the masks back, and restores the previous masks if Lightroom kept anything different. On an untested version or format the call fails and the photo is unchanged. It briefly opens the photo in Develop to confirm Lightroom lists the new tool, then puts back the module, view source and selection. Returns mask_id and tool_id (use tool_id with update_gradient_mask), the shape and the stored geometry. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
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
      "Move or reshape an existing linear or radial gradient, found by tool_id (from list_masks or create_gradient_mask). Give only the fields to change; the rest keep their values. Linear gradients take start and end, radial gradients take center, width, height, rotation, feather and area; a field of the other shape is rejected. Coordinates use the same normalized 0..1 system of the full uncropped image as create_gradient_mask, positioned as Lightroom displays the photo (converted for a rotated or mirrored photo), and anything outside it is rejected before anything is written. The tool id, the mask id and the mask's adjustments are kept. Same safeguards as create_gradient_mask: Lightroom Classic 15.6 with process version 15.4 only, the full mask list is read back after the write and the previous masks are restored if Lightroom kept anything different, and the photo briefly opens in Develop. One Develop-driving call runs at a time.",
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
      "Paint a brush mask on a photo from strokes (Lightroom Classic 15.6 with process version 15.4 only). Each stroke is a list of points in normalized coordinates of the full uncropped image as Lightroom shows it: x and y from 0 to 1, origin at the top-left corner of the uncropped photo, y growing downward; a crop does not move the origin, so on a cropped photo convert from the visible area first. A photo that Lightroom shows rotated or mirrored (its orientation is not normal) stores masks in the unrotated frame, so the tool converts your points to it; a photo whose orientation it cannot map is refused. Anything outside 0..1, an empty stroke list or a stroke without points is rejected and nothing is written. Lightroom stamps dabs, so the tool also places dabs along the path between consecutive points, at most half a radius apart. Per stroke: radius is a fraction of the longer edge of the image (default 0.14; the soft edge fades out at roughly 60% of it, so 0.05 on a 1000 px wide photo paints a stroke about 60 px wide), flow runs 0.01 to 1 (default 1), feather runs 0 (hard) to 100 (soft, default), density runs 0.01 to 1 (default 1) and erase (default false) removes the paint of earlier strokes of the same brush instead of adding. Lightroom's own Size slider is a screen size, so the radius it stores depends on the zoom of the Develop view and size is not an option: use radius. Without mask_id this creates a new mask (optionally named) holding one brush; with mask_id (from list_masks or an earlier call) the brush is added as a component of that mask. To paint more strokes into a brush that already exists, use add_brush_strokes. The mask starts with no adjustments, so it changes nothing visible until adjustments are set on it. This writes Lightroom's undocumented develop-setting format: before writing it checks the Lightroom version, the photo's process version and the format of every mask already on the photo, then writes, reads the masks back (every dab position and the flow), and restores the previous masks if Lightroom kept anything different. On an untested version or format the call fails and the photo is unchanged. It briefly opens the photo in Develop to confirm Lightroom lists a brush tool for the new mask, then puts back the module, view source and selection. Returns mask_id, tool_id (use it with add_brush_strokes), strokes_added and stroke_count. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
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
      "Paint more strokes into an existing brush, found by tool_id (from list_masks or create_brush_mask). The strokes are appended after the strokes already there, which stay as they are. Strokes use the same normalized 0..1 coordinates of the full uncropped image as Lightroom shows it (converted for a rotated or mirrored photo), radius, flow, feather, density, erase and path filling as create_brush_mask, and the same rules: an empty stroke list or points outside the image are rejected before anything is written. To remove a painted area, append a stroke with erase over it, or delete the brush with delete_masks (tool_ids) and paint it again. Same safeguards as create_brush_mask: Lightroom Classic 15.6 with process version 15.4 only, the masks are read back and the previous masks are restored if Lightroom kept anything different, and the photo briefly opens in Develop. The tool id, the mask id and the mask's adjustments are kept. Returns mask_id, tool_id, strokes_added and the stroke_count of the brush. One Develop-driving call runs at a time.",
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
      "Create a luminance, color or depth range mask on a photo (Lightroom Classic 15.6 with process version 15.4 only). A luminance range selects the tones between min and max (0 black to 1 white) at full strength, fading out over falloff on each side; the ramps are clipped at 0 and 1. A depth range does the same on the photo's device depth map, where 0 is the nearest and 1 the farthest point of the scene; it needs a photo that carries depth, such as an iPhone Portrait HEIC, and on any other photo the call fails and the photo is unchanged. A depth range of exactly 0 to 1 is refused because it covers the whole scene. A luminance or depth band must be at least 0.01 wide (max minus min), because Lightroom replaces a narrower one with its default; falloff may be 0. A color range selects colors near one sample, given as l, a and b (0..1) plus an x and y position. l, a and b are Lightroom's own stored coordinates, not sRGB: Lightroom ranks the sampled color against the photo's own pixels, so l is the sample's lightness (0 darkest, 1 brightest), a its green-to-red position (0 greenest, 1 reddest) and b its blue-to-yellow position (0 bluest, 1 yellowest), and the same color gets different numbers in different photos (changing the photo's develop settings does not change them). They cannot be computed from an RGB value. To select a color, take the l, a and b Lightroom stored for it: list_masks returns them in the range of a color range mask made in Lightroom (click the color with Tools > Create New Mask > Color Range), or pass your own ranking, for example l 0.9 with a 0.95 for the brightest reds in the photo. Selection follows the l, a and b triple; the position only places the mask's pin. Exactly one sample point is supported; a second one is rejected because Lightroom crashes on it. To reuse a color range without knowing its l, a and b, pass copy_sample_from with the mask_id and tool_id of an existing color range (from list_masks, typically one clicked in Lightroom with Tools > Create New Mask > Color Range) instead of color.sample: the new range gets that range's stored sample and, unless color.amount is given, its amount, and invert, mode, mask_id and name are yours to set, so you can replicate the range, subtract it or invert it. Add photo_id to copy from another photo. The source must be a color range with exactly one sample point; a luminance or depth range, any other mask type, an unknown mask or a tool that is not in that mask is refused and nothing is written. The copy keeps the source's pin at the same displayed position, and the l, a and b are copied verbatim: because Lightroom ranks the sample against each photo's own pixels, a copy onto another photo selects the pixels of that photo that rank like the source sample, which is the same colors only when the two photos have the same pixel content (for example a duplicate); on a different photo it can select different colors. The result lists copied_from. x and y are normalized coordinates of the full uncropped image (0..1, origin at the top-left corner of the uncropped photo as Lightroom shows it, y growing downward; a crop does not move the origin; the tool converts the position for a rotated or mirrored photo and refuses an orientation it cannot map). amount (greater than 0, at most 1, default 0.5) is how far from the sampled color still counts: small is narrow, 1 is broad. Without mask_id this creates a new mask (optionally named), usually to be refined later; with mask_id (from list_masks or an earlier call) the range is added as a component of that mask with mode add (default) or subtract. Intersect is not supported. invert selects everything outside the range. The mask starts with no adjustments, so it changes nothing visible until adjustments are set on it. This writes Lightroom's undocumented develop-setting format: before writing it checks the Lightroom version, the photo's process version and the format of every mask already on the photo, then writes, reads the masks back, and restores the previous masks if Lightroom kept anything different. On an untested version or format the call fails and the photo is unchanged. It briefly opens the photo in Develop to confirm Lightroom lists the new tool as a rangeMask with subtype luminance, color or depth, then puts back the module, view source and selection. Returns mask_id and tool_id, the type and the stored range. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
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
      "Delete masks from one photo (Lightroom Classic 11+). Pass exactly one of: mask_ids (delete those masks), tool_ids (delete those component tools; a mask whose last tool is deleted is removed, as in Lightroom) or all=true (delete every mask on the photo). Ids come from list_masks. Every id is checked before anything is deleted: an unknown mask or tool id returns an error and the photo is left unchanged. Lightroom's mask API only acts on the photo active in Develop, so this switches to Develop, opens the photo and its masking tool, deletes, checks that Lightroom applied and saved the change, then puts back the module, view source and selection. Ids of the remaining masks can change afterwards, so call list_masks again. Returns the deleted mask and tool ids and the number of masks left. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
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
      "Delete all empty masks (masks with no component tools) from a list of photos (Lightroom Classic 14+). Uses the catalog, so it does not open the photos in Develop and leaves the module and selection alone. Returns photos_changed, the number of photos that lost at least one mask, photos_checked, and missing for ids that match no photo. Up to 1000 photos per call.",
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
      "Change local adjustment sliders on an existing mask (Lightroom Classic 11+). Pass the photo, a mask id from list_masks and any subset of local sliders; only those sliders change and every other slider and mask is left alone. Slider names are Lightroom SDK names: local_Exposure (-4 to 4), and local_Contrast, local_Highlights, local_Shadows, local_Whites, local_Blacks, local_Texture, local_Clarity, local_Dehaze, local_Temperature, local_Tint, local_Saturation, local_Sharpness, local_LuminanceNoise, local_Moire, local_Defringe (-100 to 100 each). Lightroom's own range for a slider wins over these figures. A value outside its range is rejected with an error naming the slider and its range before anything is written, and so is an unknown mask id. Lightroom's mask API only answers for the photo active in Develop, so this switches to Develop, opens the photo, selects the mask, writes and reads back each slider, waits until Lightroom has saved the change to the photo's settings (up to 8 seconds, otherwise the call fails), then puts back the previously selected mask, module, view source and selection. Sliders already at the value are skipped. Returns the values read back from Lightroom, the sliders that changed (from, to) and those that were already at the value. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
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
      "Read the current local adjustment values of an existing mask (Lightroom Classic 11+): every slider that set_mask_adjustments can write, keyed by its SDK name. A slider Lightroom does not expose for this photo is listed under unavailable. Like set_mask_adjustments, this switches to Develop, opens the photo and selects the mask, then puts back the previously selected mask, module, view source and selection. An unknown mask id returns an error. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
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
      "Invert a mask on a photo (Lightroom Classic 11.4+), chosen by its mask id from list_masks, never by the current selection. mode \"in_place\" inverts the mask itself. mode \"copy\" leaves the original untouched and creates an inverted copy, returning the copy's id as mask_id and the original's as source_mask_id. Lightroom's own duplicate resets the copy's local sliders to 0, so the tool copies the original's local sliders onto the copy in the same call (Lightroom folds this into the Duplicate and Invert history step; adjustments_copied counts the sliders written) and removes the copy and fails if a value does not stick. mode \"in_place\" on a mask with several components inverts only one of them; the result lists every tool with its inverted flag. Use the returned mask_id for later calls: Lightroom can regenerate mask ids when a mask is written through develop settings. An unknown mask id returns an error and changes nothing. Lightroom's mask API only answers for the photo active in Develop, so this switches to Develop, opens the photo, inverts, then puts back the module, view source and selection. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
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
      "Create a Subject, Sky or Background mask on a photo (Lightroom Classic 11+) and return the new mask id. Lightroom detects the area itself. Optional adjustments set the mask's local sliders in the same call; every slider you leave out is set to 0, so the mask never inherits the values last used in the Masking panel. If Lightroom finds nothing to select (for example no sky), the call fails after about 30 seconds and the photo gets no new mask, but Lightroom shows an alert such as \"No sky detected\" that stays up until someone clicks OK in Lightroom, and until then every Develop call sees no masks. Masks already on the photo are left unchanged. Lightroom records the new mask as one \"Add Subject\", \"Add Sky\" or \"Add Background\" history step; adjustments other than 0 add one more history step that groups all the sliders. A Background mask is listed with tool type aiSelection and subtype object. Exposure is limited to the -4 to 4 range Lightroom allows for local masks. Lightroom's mask API only answers for the photo active in Develop, so this switches to Develop, opens the photo, creates the mask, then puts back the module, view source and selection. Detection can take several seconds. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
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
      "Add the same Subject, Sky or Background mask, with the same local adjustments, to many photos in one call (Lightroom Classic 15.6 only, the version the guarded mask write is tested on). Lightroom computes the mask for each photo itself; nothing is copied from another photo's mask shape. How it works: the first photo is opened in Develop and gets the mask exactly as create_mask would make it (up to about 30 seconds); every other photo is then given that mask with its computed data removed and Lightroom recomputes it for that photo, without opening it in Develop. The module, view source and selection are put back afterwards. Masks already on a photo are kept. Returns per photo in results: status created, failed or not_attempted, created true or false, the new mask_id and a reason on failure, plus created/failed/not_attempted counts, missing for ids that match no photo, and complete. A photo where Lightroom finds nothing to select is reported failed and its added mask is removed, and the rest of the batch continues. The exception is the first photo: if Lightroom finds nothing there, it shows an alert such as \"No sky detected\" that stays up until someone clicks OK in Lightroom and blocks every Develop call, so the call stops, reports the remaining photos as not_attempted and you must have the alert dismissed (and best drop that photo from the list) before calling again. A call stops after about 230 s, sets complete to false and lists the unreached ids in remaining_ids; call again with those. Up to 200 photos per call. Photos with masks Lightroom's mask format check rejects are reported failed untouched. Exposure is limited to -4 to 4. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
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
      "Create People masks on a photo, one mask per requested part, and return their ids (Lightroom Classic 15.6 with process version 15.4, which also needs the AI mask update of Lightroom Classic 13.3+). parts lists what to select: face_skin, body_skin, hair, facial_hair, eyebrows, eye_sclera, iris_and_pupil, lips, teeth, clothes, and entire_person. Every part covers all people in the photo. Choosing a single person is not supported: Lightroom ignores the person of a written mask and always masks the first one, so the tool offers no person option. mask_id is the first mask; masks lists every mask with its part. If the photo has no person or no region of a requested part, the call fails and none of the new masks is left on the photo. An unknown or duplicate part is rejected before anything is read or written. This writes Lightroom's undocumented develop-setting format through the same guarded write as create_gradient_mask (version check, format check of every existing mask, read-back, restore on mismatch), then asks Lightroom to compute the selection and waits for it, up to 120 seconds. It does not use the Develop module, but if the photo's masks are open in Develop Lightroom can show an \"AI process is running\" alert that stays up until someone clicks OK in Lightroom. The new masks carry no adjustments; set them with set_mask_adjustments. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
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
      "Create Landscape masks on a photo, one mask per requested category, and return their ids (Lightroom Classic 15.6 with process version 15.4, which also needs the AI mask update of Lightroom Classic 13.3+). categories lists what to select: architecture, mountains, artificial_ground, natural_ground, vegetation, sky, water, snow. mask_id is the first mask; masks lists every mask with its category. If the photo has no region of a requested category, the call fails and none of the new masks is left on the photo. An unknown or duplicate category is rejected before anything is read or written. This writes Lightroom's undocumented develop-setting format through the same guarded write as create_gradient_mask (version check, format check of every existing mask, read-back, restore on mismatch), then asks Lightroom to compute the selection and waits for it, up to 120 seconds; a Landscape selection can take about 15 seconds. It does not use the Develop module, but if the photo's masks are open in Develop Lightroom can show an \"AI process is running\" alert that stays up until someone clicks OK in Lightroom. The new masks carry no adjustments; set them with set_mask_adjustments. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
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
      "Set the local tone curve of an existing mask, per channel (Lightroom Classic 12.3+; the SDK lists local_Maincurve, local_Redcurve, local_Greencurve and local_Bluecurve from SDK 12.3). Pass the photo, a mask id from list_masks and curves: any subset of main (RGB), red, green and blue, each a flat array of input/output pairs on the 0 to 255 scale, e.g. [0, 0, 64, 48, 192, 210, 255, 255] (2 to 32 pairs, integers, inputs strictly increasing, starting at input 0 and ending at input 255; [0, 0, 255, 255] is the straight line). Only the listed channels of that mask change; every other channel, every other mask and the global settings are left alone. Each write is read back and the call fails, restoring the channels it already wrote, if Lightroom does not keep the curve. A Lightroom version without local curves returns an error naming the minimum version, and nothing is written. Lightroom's mask API only acts on the photo active in Develop, so this switches to Develop, opens the photo, selects the mask, writes, waits until Lightroom has saved the change to the photo's settings (up to 8 seconds, otherwise the call fails), then puts back the previously selected mask, module, view source and selection. Channels already at the value are skipped. Returns the curves read back, the channels that changed (from, to) and those already at the value. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
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
      "Read the local tone curve of an existing mask (Lightroom Classic 12.3+): main (RGB), red, green and blue as flat input/output arrays, exactly as Lightroom returns them. A channel Lightroom does not return is listed under unavailable; if none is returned the call fails and names the minimum version. Like set_mask_curves, this switches to Develop, opens the photo and selects the mask, then puts back the previously selected mask, module, view source and selection. An unknown mask id returns an error. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
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
      "Add, update or delete the local Point Color swatches of an existing mask (Lightroom Classic 13.2+, the first SDK version with the Point Color calls). A mask holds up to 8 swatches, numbered from 1 in the order get_mask_point_colors lists them. action \"add\" needs swatch with SrcHue (0 to 6), SrcSat and SrcLum (0 to 1) plus optional HueShift, SatScale, LumScale (-1 to 1), RangeAmount (0 to 1) and HueRange, SatRange, LumRange (objects with LowerNone, LowerFull, UpperFull, UpperNone, each 0 to 1); a swatch with the same source color as an existing one is refused. action \"update\" needs index and a swatch holding only the fields to change; the rest keep their values. action \"delete\" needs index. action \"clear\" deletes every swatch of the mask. Only the targeted mask changes; other masks, the mask's sliders and the global Point Color settings are left alone. Each change is read back, and a swatch update that does not stick is restored. Mask ids come from list_masks. A Lightroom version without local Point Color returns an error naming the minimum version, and nothing is written. Lightroom's mask API only acts on the photo active in Develop, so this switches to Develop, opens the photo, selects the mask, edits, then puts back the previously selected mask and swatch, module, view source and selection. Returns the action, the affected index, whether anything changed and the swatches now on the mask. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
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
      "Read the local Point Color swatches of an existing mask (Lightroom Classic 13.2+). Returns the swatches in Lightroom's order, each with its index (from 1, the number edit_mask_point_colors takes) and the fields SrcHue, SrcSat, SrcLum, HueShift, SatScale, LumScale, RangeAmount, HueRange, SatRange and LumRange Lightroom reports; the list is empty when the mask has none. Like edit_mask_point_colors, this switches to Develop, opens the photo and selects the mask, then puts back the previously selected mask, module, view source and selection. An unknown mask id returns an error. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
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
      "Add, subtract or intersect a Subject, Sky or Background component on an existing mask (Lightroom Classic 11+) and return the new component's id as tool_id. The mask is chosen by its id from list_masks, never by the current selection: the tool selects that mask in Lightroom and checks the selection before it changes anything. operation \"add\" widens the mask by the detected area, \"subtract\" removes it (for example sky minus subject), \"intersect\" keeps only the overlap with the mask's existing area; Lightroom stores it as a subtracted, inverted component, so list_masks shows that new component with inverted true. The type values are the same ones create_mask accepts, and mask types added later become available here too. Lightroom detects the area itself and can take several seconds. If Lightroom finds nothing to select (for example no sky), the call fails after about 30 seconds and the mask keeps its components, but Lightroom shows an alert such as \"No sky detected\" that stays up until someone clicks OK in Lightroom, and until then every Develop call sees no masks. An unknown mask id returns an error before anything changes. Lightroom records the new component as one history step. A Background component is listed with tool type aiSelection and subtype object. Lightroom's mask API only answers for the photo active in Develop, so this switches to Develop, opens the photo, combines, then puts back the previously selected mask, tool, module, view source and selection. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
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
