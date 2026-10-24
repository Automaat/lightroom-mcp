import type { Tool } from "@modelcontextprotocol/sdk/types.js";

type InputSchema = Tool["inputSchema"];

export interface ToolContract {
  name: string;
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
    description: "Radial only: clockwise rotation in degrees around the center, in the photo's pixel space (default 0)",
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
} as const;

const brushStrokeProperties = {
  strokes: {
    type: "array",
    minItems: 1,
    maxItems: 50,
    description:
      "Strokes to paint, in order. Each stroke is a path of points; Lightroom fills dabs along the path. Add strokes only: erase strokes cannot be written",
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
          description: "Brush radius as a fraction of the longer edge of the image (default 0.14, Lightroom's default brush; 0.04 is clearly narrower)",
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
} as const;

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
const photoIdSchema = (description: string) => ({
  oneOf: [{ type: "string", minLength: 1 }, { type: "number" }],
  description,
});

const photoIdArray = (description: string) => ({
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

export const TOOL_CONTRACTS: ToolContract[] = [
  {
    name: "search_photos",
    luaHandler: "HandlerSearch.searchPhotos",
    description:
      "Search for photos in Lightroom catalog by criteria (paginated, default limit 100). Providing at least one filter (filename, keywords, rating, or date) significantly improves performance on large catalogs.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
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
        limit: { type: "number", description: "Max photos to return (default 100)", minimum: 0 },
        offset: { type: "number", description: "Number of photos to skip (default 0)", minimum: 0 },
      },
    },
  },
  {
    name: "get_selected_photos",
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
    name: "get_photo_metadata",
    luaHandler: "HandlerMetadata.getPhotoMetadata",
    description:
      "Get detailed metadata for a specific photo: keywords (names, plus keywordPaths as full hierarchy paths), EXIF, title/caption/headline, GPS (latitude/longitude/altitude), IPTC location (sublocation/city/stateProvince/country/isoCountryCode), copyright, and develop settings",
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
    name: "set_gps",
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
    luaHandler: "HandlerMetadata.setMetadata",
    description:
      "Set IPTC description and rights fields of photos (title, caption, headline, creator, copyright notice, rights usage terms, copyright info URL, creator website), as get_photo_metadata reports them. Fields left out are unchanged; an empty string clears a field. Give at least one field. Copyright status cannot be set.",
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
      },
      required: ["photo_ids"],
    },
  },
  {
    name: "list_collections",
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
    name: "add_to_collection",
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
    name: "list_keywords",
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
    name: "set_rating",
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
    name: "import_photos",
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
    luaHandler: "HandlerExport.exportPhotos",
    description: "Export photos from Lightroom",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_ids: photoIdArray("Array of photo IDs or file paths to export"),
        destination: { type: "string", description: "Export destination folder" },
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
    luaHandler: "HandlerDevelop.getDevelopPreset",
    description:
      "Read the settings and backing-file metadata for one exact Develop preset. Use preset_uuid or provide folder/scope when names are duplicated.",
    inputSchema: presetSelectorSchema,
  },
  {
    name: "compare_develop_presets",
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
          items: { type: "string", enum: DEVELOP_SETTING_KEYS },
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
            enum: DEVELOP_SETTING_KEYS,
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
    name: "apply_denoise",
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
    luaHandler: "HandlerMasks.listMasks",
    description:
      "List the masks on a photo (Lightroom Classic 11+): each mask's id, name and hidden state, and its component tools with id, type, subtype and inverted state. Lightroom's mask API only answers for the photo active in Develop, so this switches to Develop, opens the photo, reads its masks, then puts back the module, view source and selection. A photo without masks returns an empty list. Mask and tool ids stay valid for later calls on the same photo while its masks are unchanged. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
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
    luaHandler: "HandlerBrushMasks.createBrushMask",
    description:
      "Paint a brush mask on a photo from strokes (Lightroom Classic 15.6 with process version 15.4 only). Each stroke is a list of points in normalized coordinates of the full uncropped image as Lightroom shows it: x and y from 0 to 1, origin at the top-left corner of the uncropped photo, y growing downward; a crop does not move the origin, so on a cropped photo convert from the visible area first. A photo that Lightroom shows rotated or mirrored (its orientation is not normal) stores masks in the unrotated frame, so the tool converts your points to it; a photo whose orientation it cannot map is refused. Anything outside 0..1, an empty stroke list or a stroke without points is rejected and nothing is written. Lightroom stamps dabs, so the tool also places dabs along the path between consecutive points, at most half a radius apart. Per stroke: radius is a fraction of the longer edge of the image (default 0.14; the soft edge fades out at roughly 60% of it, so 0.05 on a 1000 px wide photo paints a stroke about 60 px wide) and flow runs 0.01 to 1 (default 1). ADD STROKES ONLY: erase strokes cannot be written, because Lightroom turns the blend mode of a written stroke into add, so there is no erase option and erase, feather and density are rejected. Feather and density are not offered because no stored field for them has been verified. Without mask_id this creates a new mask (optionally named) holding one brush; with mask_id (from list_masks or an earlier call) the brush is added as a component of that mask. To paint more strokes into a brush that already exists, use add_brush_strokes. The mask starts with no adjustments, so it changes nothing visible until adjustments are set on it. This writes Lightroom's undocumented develop-setting format: before writing it checks the Lightroom version, the photo's process version and the format of every mask already on the photo, then writes, reads the masks back (every dab position and the flow), and restores the previous masks if Lightroom kept anything different. On an untested version or format the call fails and the photo is unchanged. It briefly opens the photo in Develop to confirm Lightroom lists a brush tool for the new mask, then puts back the module, view source and selection. Returns mask_id, tool_id (use it with add_brush_strokes), strokes_added and stroke_count. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
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
    luaHandler: "HandlerBrushMasks.addBrushStrokes",
    description:
      "Paint more strokes into an existing brush, found by tool_id (from list_masks or create_brush_mask). The strokes are appended after the strokes already there, which stay as they are. Strokes use the same normalized 0..1 coordinates of the full uncropped image as Lightroom shows it (converted for a rotated or mirrored photo), radius, flow and path filling as create_brush_mask, and the same rules: an empty stroke list or points outside the image are rejected before anything is written. ADD STROKES ONLY: this cannot erase part of a brush, because Lightroom turns the blend mode of a written stroke into add; to remove a painted area, delete the brush with delete_masks (tool_ids) and paint it again. Same safeguards as create_brush_mask: Lightroom Classic 15.6 with process version 15.4 only, the masks are read back and the previous masks are restored if Lightroom kept anything different, and the photo briefly opens in Develop. The tool id, the mask id and the mask's adjustments are kept. Returns mask_id, tool_id, strokes_added and the stroke_count of the brush. One Develop-driving call runs at a time.",
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
    luaHandler: "HandlerRangeMasks.createRangeMask",
    description:
      "Create a luminance or color range mask on a photo (Lightroom Classic 15.6 with process version 15.4 only). A luminance range selects the tones between min and max (0 black to 1 white) at full strength, fading out over falloff on each side; the ramps are clipped at 0 and 1. A color range selects colors near one sample: the sample's red, green and blue (0..1, sRGB, like the 0..255 value divided by 255) and its x and y position. Exactly one sample point is supported; a second one is rejected because Lightroom crashes on it. x and y are normalized coordinates of the full uncropped image (0..1, origin at the top-left corner of the uncropped photo as Lightroom shows it, y growing downward; a crop does not move the origin; the tool converts the position for a rotated or mirrored photo and refuses an orientation it cannot map). Selection follows the sampled color; the position only places the mask's pin. amount (greater than 0, at most 1, default 0.5) is how far from the sampled color still counts: small is narrow, 1 is broad. Depth range masks are not supported. Without mask_id this creates a new mask (optionally named), usually to be refined later; with mask_id (from list_masks or an earlier call) the range is added as a component of that mask with mode add (default) or subtract. Intersect is not supported. invert selects everything outside the range. The mask starts with no adjustments, so it changes nothing visible until adjustments are set on it. This writes Lightroom's undocumented develop-setting format: before writing it checks the Lightroom version, the photo's process version and the format of every mask already on the photo, then writes, reads the masks back, and restores the previous masks if Lightroom kept anything different. On an untested version or format the call fails and the photo is unchanged. It briefly opens the photo in Develop to confirm Lightroom lists the new tool as a rangeMask with subtype luminance or color, then puts back the module, view source and selection. Returns mask_id and tool_id, the type and the stored range. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        photo_id: photoIdSchema("Photo ID or file path"),
        type: { type: "string", enum: ["luminance", "color"], description: "Kind of range mask" },
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
          description: "Luminance only: the tonal range to select",
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
                red: { type: "number", minimum: 0, maximum: 1, description: "Red of the sampled color" },
                green: { type: "number", minimum: 0, maximum: 1, description: "Green of the sampled color" },
                blue: { type: "number", minimum: 0, maximum: 1, description: "Blue of the sampled color" },
              },
              required: ["x", "y", "red", "green", "blue"],
              description: "The single sample point: its position and sampled color",
            },
            amount: {
              type: "number",
              exclusiveMinimum: 0,
              maximum: 1,
              description: "How far from the sampled color still counts, small narrow to 1 broad (default 0.5)",
            },
          },
          required: ["sample"],
          description: "Color only: the sampled color and the refine amount",
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
    luaHandler: "HandlerMaskAdjustments.setMaskAdjustments",
    description:
      "Change local adjustment sliders on an existing mask (Lightroom Classic 11+). Pass the photo, a mask id from list_masks and any subset of local sliders; only those sliders change and every other slider and mask is left alone. Slider names are Lightroom SDK names: local_Exposure (-4 to 4), and local_Contrast, local_Highlights, local_Shadows, local_Whites, local_Blacks, local_Texture, local_Clarity, local_Dehaze, local_Temperature, local_Tint, local_Saturation, local_Sharpness, local_LuminanceNoise, local_Moire, local_Defringe (-100 to 100 each). Lightroom's own range for a slider wins over these figures. A value outside its range is rejected with an error naming the slider and its range before anything is written, and so is an unknown mask id. Lightroom's mask API only answers for the photo active in Develop, so this switches to Develop, opens the photo, selects the mask, writes and reads back each slider, then puts back the previously selected mask, module, view source and selection. Sliders already at the value are skipped. Returns the values read back from Lightroom, the sliders that changed (from, to) and those that were already at the value. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
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
    luaHandler: "HandlerMaskCurves.setMaskCurves",
    description:
      "Set the local tone curve of an existing mask, per channel (Lightroom Classic 12.3+; the SDK lists local_Maincurve, local_Redcurve, local_Greencurve and local_Bluecurve from SDK 12.3). Pass the photo, a mask id from list_masks and curves: any subset of main (RGB), red, green and blue, each a flat array of input/output pairs on the 0 to 255 scale, e.g. [0, 0, 64, 48, 192, 210, 255, 255] (2 to 32 pairs, integers, inputs strictly increasing, starting at input 0 and ending at input 255; [0, 0, 255, 255] is the straight line). Only the listed channels of that mask change; every other channel, every other mask and the global settings are left alone. Each write is read back and the call fails, restoring the channels it already wrote, if Lightroom does not keep the curve. A Lightroom version without local curves returns an error naming the minimum version, and nothing is written. Lightroom's mask API only acts on the photo active in Develop, so this switches to Develop, opens the photo, selects the mask, writes, then puts back the previously selected mask, module, view source and selection. Channels already at the value are skipped. Returns the curves read back, the channels that changed (from, to) and those already at the value. One Develop-driving call runs at a time; a second call is rejected until the first finishes.",
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
