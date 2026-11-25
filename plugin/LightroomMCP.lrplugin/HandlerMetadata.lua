local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'

local KeywordTree = require 'KeywordTree'
local MaskState = require 'MaskState'
local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'

local MetadataHandler = {}

-- Fields read for every photo in two batched calls instead of one SDK getter
-- each (about 46 per photo). Virtual copy and stack details stay per photo:
-- they are read only for the photos that have them.
local RAW_KEYS = {
    'keywords', 'gps', 'gpsAltitude', 'isVirtualCopy', 'isInStackInFolder',
    'path', 'rating', 'colorNameForLabel', 'pickStatus', 'fileFormat',
}
local FORMATTED_KEYS = {
    'fileName', 'title', 'caption', 'headline',
    'dateTimeOriginal', 'dateTimeDigitized', 'cameraMake', 'cameraModel', 'cameraSerialNumber',
    'lens', 'isoSpeedRating', 'focalLength', 'focalLength35mm', 'aperture', 'shutterSpeed',
    'exposureBias', 'exposureProgram', 'meteringMode', 'flash', 'dimensions', 'fileSize',
    'artist', 'software',
    'location', 'city', 'stateProvince', 'country', 'isoCountryCode',
    'creator', 'copyright', 'copyrightState', 'rightsUsageTerms', 'copyrightInfoUrl', 'creatorUrl',
}
-- Lightroom before 13.2 throws on these keys, so they get their own guarded
-- batch: one failure leaves accessibility out and keeps everything else.
local ACCESSIBILITY_KEYS = { 'altTextAccessibility', 'extDescrAccessibility' }

local function accessibilityTexts(catalog, photos)
    local ok, values = LrTasks.pcall(function()
        return catalog:batchGetRawMetadata(photos, ACCESSIBILITY_KEYS)
    end)
    if ok and values then return values end
    return {}
end

local function nonEmptyText(value)
    if value ~= "" then return value end
    return nil
end

-- Return the group only when it carries at least one value, so empty IPTC
-- sections are omitted from the response (consistent with the gps group)
-- instead of surfacing a table full of empty strings.
local function nonEmptyGroup(fields)
    for _, v in pairs(fields) do
        if v ~= nil and v ~= "" then return fields end
    end
    return nil
end

local function hslDevelopSettings(developSettings)
    return nonEmptyGroup({
        SaturationAdjustmentRed = developSettings.SaturationAdjustmentRed,
        SaturationAdjustmentOrange = developSettings.SaturationAdjustmentOrange,
        SaturationAdjustmentYellow = developSettings.SaturationAdjustmentYellow,
        SaturationAdjustmentGreen = developSettings.SaturationAdjustmentGreen,
        SaturationAdjustmentAqua = developSettings.SaturationAdjustmentAqua,
        SaturationAdjustmentBlue = developSettings.SaturationAdjustmentBlue,
        SaturationAdjustmentPurple = developSettings.SaturationAdjustmentPurple,
        SaturationAdjustmentMagenta = developSettings.SaturationAdjustmentMagenta,
        HueAdjustmentRed = developSettings.HueAdjustmentRed,
        HueAdjustmentOrange = developSettings.HueAdjustmentOrange,
        HueAdjustmentYellow = developSettings.HueAdjustmentYellow,
        HueAdjustmentGreen = developSettings.HueAdjustmentGreen,
        HueAdjustmentAqua = developSettings.HueAdjustmentAqua,
        HueAdjustmentBlue = developSettings.HueAdjustmentBlue,
        HueAdjustmentPurple = developSettings.HueAdjustmentPurple,
        HueAdjustmentMagenta = developSettings.HueAdjustmentMagenta,
        LuminanceAdjustmentRed = developSettings.LuminanceAdjustmentRed,
        LuminanceAdjustmentOrange = developSettings.LuminanceAdjustmentOrange,
        LuminanceAdjustmentYellow = developSettings.LuminanceAdjustmentYellow,
        LuminanceAdjustmentGreen = developSettings.LuminanceAdjustmentGreen,
        LuminanceAdjustmentAqua = developSettings.LuminanceAdjustmentAqua,
        LuminanceAdjustmentBlue = developSettings.LuminanceAdjustmentBlue,
        LuminanceAdjustmentPurple = developSettings.LuminanceAdjustmentPurple,
        LuminanceAdjustmentMagenta = developSettings.LuminanceAdjustmentMagenta,
    })
end

local SDK_DEVELOP_GROUPS = {
    { field = "lens", keys = { "LensProfileEnable", "LensManualDistortionAmount" } },
    {
        field = "transform",
        keys = {
            "PerspectiveUpright",
            "PerspectiveVertical",
            "PerspectiveHorizontal",
            "PerspectiveRotate",
            "PerspectiveScale",
            "PerspectiveAspect",
        },
    },
    { field = "crop", keys = { "CropTop", "CropLeft", "CropBottom", "CropRight", "CropAngle" } },
    {
        field = "detail",
        keys = {
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
        },
    },
    {
        field = "effects",
        keys = {
            "PostCropVignetteAmount",
            "PostCropVignetteMidpoint",
            "PostCropVignetteRoundness",
            "PostCropVignetteFeather",
            "PostCropVignetteStyle",
            "GrainAmount",
            "GrainSize",
            "GrainFrequency",
        },
    },
    {
        field = "parametricSplits",
        keys = { "ParametricShadowSplit", "ParametricMidtoneSplit", "ParametricHighlightSplit" },
    },
}

-- Lens Corrections values Lightroom saves that set_develop_settings does not
-- write: the profile in use, its scales and automatic chromatic aberration.
local READ_ONLY_DEVELOP_GROUPS = {
    {
        field = "lensProfile",
        keys = {
            "LensProfileSetup", "LensProfileName", "LensProfileFilename", "LensProfileDigest",
            "LensProfileIsEmbedded", "LensProfileDistortionScale", "LensProfileVignettingScale", "AutoLateralCA",
        },
    },
}

-- Saved Guided Upright guides, read only: how many are in use, each as
-- "x1,y1,x2,y2" in the unrotated stored frame (not as displayed), and whether
-- Lightroom saved the Guided correction for them. Omitted without guides.
-- Bracket access keeps these out of the settable-key list a Jest test scans.
local function uprightGroup(developSettings)
    local count = developSettings["UprightFourSegmentsCount"]
    if type(count) ~= "number" or count < 1 then return nil end
    local guides = {}
    for i = 0, math.min(count, 4) - 1 do
        local segment = developSettings["UprightFourSegments_" .. i]
        if type(segment) == "string" then guides[#guides + 1] = segment end
    end
    return {
        guideCount = count,
        guides = guides,
        guidedCorrection = type(developSettings["UprightTransform_5"]) == "string",
    }
end

local function addSdkDevelopGroups(target, developSettings)
    for _, groups in ipairs({ SDK_DEVELOP_GROUPS, READ_ONLY_DEVELOP_GROUPS }) do
        for _, group in ipairs(groups) do
            local values = {}
            for _, key in ipairs(group.keys) do
                values[key] = developSettings[key]
            end
            target[group.field] = nonEmptyGroup(values)
        end
    end
    target.upright = uprightGroup(developSettings)
    return target
end

local function photoIds(photos)
    if not photos or #photos == 0 then return nil end
    local ids = {}
    for i, photo in ipairs(photos) do
        ids[i] = photo.localIdentifier
    end
    return ids
end

local function virtualCopyMetadata(photo, isVirtualCopy)
    if isVirtualCopy then
        local master = photo:getRawMetadata('masterPhoto')
        return nonEmptyGroup({ masterPhotoId = master and master.localIdentifier })
    end
    return nonEmptyGroup({ copyIds = photoIds(photo:getRawMetadata('virtualCopies')) })
end

local function stackMetadata(photo, isInStack)
    if not isInStack then return nil end
    local top = photo:getRawMetadata('topOfStackInFolderContainingPhoto')
    return nonEmptyGroup({
        position = photo:getRawMetadata('stackPositionInFolder'),
        isCollapsed = photo:getRawMetadata('stackInFolderIsCollapsed'),
        topPhotoId = top and top.localIdentifier,
        memberIds = photoIds(photo:getRawMetadata('stackInFolderMembers')),
    })
end

local function readPhotoMetadata(photo, sections, r, f, a, pathOfKeyword)
    -- `keywords` stays leaf names; `keywordPaths` is the same list as
    -- full parent-first paths, which is what tells two keywords of the
    -- same name apart ("Orientation|portrait" vs "Type|portrait").
    -- A keyword's path is built once per call, however many photos share it.
    local keywords = {}
    local keywordPaths = {}
    for _, kw in ipairs(r.keywords or {}) do
        local path = pathOfKeyword[kw]
        if not path then
            path = KeywordTree.pathOf(kw)
            pathOfKeyword[kw] = path
        end
        table.insert(keywords, kw:getName())
        table.insert(keywordPaths, path)
    end

    -- Get develop settings once, for whichever sections need them.
    local settings = (sections.developSettings or sections.masks) and photo:getDevelopSettings() or nil
    local developSettings = sections.developSettings and settings or nil

    -- GPS is a raw {latitude, longitude} table; omit the group when absent
    -- or when present but carrying no coordinates.
    local gps = r.gps
    local gpsData = nil
    if gps then
        gpsData = nonEmptyGroup({
            latitude = gps.latitude,
            longitude = gps.longitude,
            altitude = r.gpsAltitude,
        })
    end

    local isVirtualCopy = r.isVirtualCopy == true
    return {
        id = photo.localIdentifier,
        isVirtualCopy = isVirtualCopy,
        virtualCopy = virtualCopyMetadata(photo, isVirtualCopy),
        stack = stackMetadata(photo, r.isInStackInFolder),
        path = r.path,
        filename = f.fileName,
        rating = r.rating,
        colorLabel = r.colorNameForLabel,
        pickStatus = r.pickStatus,
        keywords = keywords,
        keywordPaths = keywordPaths,
        -- Title / caption / headline (IPTC content description).
        title = f.title,
        caption = f.caption,
        headline = f.headline,
        accessibility = nonEmptyGroup({
            alt_text = nonEmptyText(a.altTextAccessibility),
            extended_description = nonEmptyText(a.extDescrAccessibility),
        }),
        -- EXIF capture data.
        dateTimeOriginal = f.dateTimeOriginal,
        dateTimeDigitized = f.dateTimeDigitized,
        cameraMake = f.cameraMake,
        cameraModel = f.cameraModel,
        cameraSerialNumber = f.cameraSerialNumber,
        lens = f.lens,
        isoSpeedRating = f.isoSpeedRating,
        focalLength = f.focalLength,
        focalLength35mm = f.focalLength35mm,
        aperture = f.aperture,
        shutterSpeed = f.shutterSpeed,
        exposureBias = f.exposureBias,
        exposureProgram = f.exposureProgram,
        meteringMode = f.meteringMode,
        flash = f.flash,
        dimensions = f.dimensions,
        fileSize = f.fileSize,
        fileFormat = r.fileFormat,
        artist = f.artist,
        software = f.software,
        gps = gpsData,
        -- IPTC location ("Sublocation" is the SDK `location` field).
        location = nonEmptyGroup({
            sublocation = f.location,
            city = f.city,
            stateProvince = f.stateProvince,
            country = f.country,
            isoCountryCode = f.isoCountryCode,
        }),
        copyright = nonEmptyGroup({
            creator = f.creator,
            notice = f.copyright,
            status = f.copyrightState,
            rightsUsageTerms = f.rightsUsageTerms,
            infoUrl = f.copyrightInfoUrl,
            creatorUrl = f.creatorUrl,
        }),
        developSettings = developSettings and addSdkDevelopGroups({
            whiteBalance = developSettings.WhiteBalance,
            temperature = developSettings.Temperature,
            tint = developSettings.Tint,
            exposure = developSettings.Exposure2012,
            contrast = developSettings.Contrast2012,
            highlights = developSettings.Highlights2012,
            shadows = developSettings.Shadows2012,
            whites = developSettings.Whites2012,
            blacks = developSettings.Blacks2012,
            texture = developSettings.Texture,
            clarity = developSettings.Clarity2012,
            dehaze = developSettings.Dehaze,
            vibrance = developSettings.Vibrance,
            saturation = developSettings.Saturation,
            hsl = hslDevelopSettings(developSettings),
            convertToGrayscale = developSettings.ConvertToGrayscale,
            toneCurveName = developSettings.ToneCurveName2012,
            toneCurve = developSettings.ToneCurvePV2012,
            toneCurveRed = developSettings.ToneCurvePV2012Red,
            toneCurveGreen = developSettings.ToneCurvePV2012Green,
            toneCurveBlue = developSettings.ToneCurvePV2012Blue,
            parametricShadows = developSettings.ParametricShadows,
            parametricDarks = developSettings.ParametricDarks,
            parametricLights = developSettings.ParametricLights,
            parametricHighlights = developSettings.ParametricHighlights,
        }, developSettings),
        masks = sections.masks and MaskState.summarize(settings) or nil,
    }
end

local MAX_METADATA_PHOTO_IDS = 100

function MetadataHandler.getPhotoMetadata(args)
    if (args.photo_id ~= nil) == (args.photo_ids ~= nil) then
        error("Give exactly one of photo_id or photo_ids")
    end
    if args.photo_ids ~= nil and (type(args.photo_ids) ~= "table"
        or #args.photo_ids == 0 or #args.photo_ids > MAX_METADATA_PHOTO_IDS) then
        error("photo_ids must contain 1 to 100 photo IDs or file paths")
    end

    local sections = {}
    for _, section in ipairs(args.sections or {}) do
        if section ~= "developSettings" and section ~= "masks" then
            error("Unknown sections entry: " .. tostring(section))
        end
        sections[section] = true
    end

    local catalog = LrApplication.activeCatalog()
    -- Path resolution runs yielding catalog queries, outside the read gate.
    local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids or { args.photo_id })
    if args.photo_id ~= nil and not resolved[1].photo then
        error("Photo not found: " .. tostring(args.photo_id))
    end

    -- Batched reads run outside the read gate, as in PhotoSummary.
    local found = {}
    for _, entry in ipairs(resolved) do
        if entry.photo then found[#found + 1] = entry.photo end
    end
    local raw, formatted, accessibility = {}, {}, {}
    if #found > 0 then
        raw = catalog:batchGetRawMetadata(found, RAW_KEYS) or {}
        formatted = catalog:batchGetFormattedMetadata(found, FORMATTED_KEYS) or {}
        accessibility = accessibilityTexts(catalog, found)
    end

    local photos, missing = {}, {}
    catalog:withReadAccessDo(function()
        local pathOfKeyword = {}
        for _, entry in ipairs(resolved) do
            local photo = entry.photo
            if photo then
                photos[#photos + 1] = readPhotoMetadata(photo, sections, raw[photo] or {},
                    formatted[photo] or {}, accessibility[photo] or {}, pathOfKeyword)
            else
                missing[#missing + 1] = tostring(entry.id)
            end
        end
    end)

    if args.photo_id ~= nil then
        Log.info("Retrieved metadata for photo: " .. tostring(args.photo_id))
        return photos[1]
    end
    Log.info(string.format("Retrieved metadata for %d photos (%d ids not found)", #photos, #missing))
    return { photos = photos, missing = missing }
end

local function requireCoordinate(value, name, limit)
    -- Comparing a string to a number raises a raw Lua type error that leaks
    -- the handler's file and line to the client, so check the type first.
    if type(value) ~= "number" or value ~= value or value < -limit or value > limit then
        error(string.format("%s must be a number between -%d and %d", name, limit, limit))
    end
end

-- Bounds the schema enforces too; also rule out Infinity, which JSON carries
-- to the plugin as null and would otherwise drop silently.
local MIN_ALTITUDE = -20000
local MAX_ALTITUDE = 100000

-- Writes a GPS position (decimal degrees) to photos, replacing any position
-- they already have. Altitude is only touched when given or cleared.
function MetadataHandler.setGps(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end
    requireCoordinate(args.latitude, "latitude", 90)
    requireCoordinate(args.longitude, "longitude", 180)
    if args.altitude ~= nil and (type(args.altitude) ~= "number" or args.altitude ~= args.altitude
        or args.altitude < MIN_ALTITUDE or args.altitude > MAX_ALTITUDE) then
        error(string.format("altitude must be a number between %d and %d (metres)",
            MIN_ALTITUDE, MAX_ALTITUDE))
    end
    if args.clear_altitude ~= nil and type(args.clear_altitude) ~= "boolean" then
        error("clear_altitude must be a boolean")
    end
    local clearAltitude = args.clear_altitude == true
    if clearAltitude and args.altitude ~= nil then
        error("altitude and clear_altitude cannot be used together")
    end

    local catalog = LrApplication.activeCatalog()
    local updatedCount = 0
    local missingIds = {}
    local missingCount = 0

    local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)

    catalog:withWriteAccessDo("Set GPS", function()
        for _, entry in ipairs(resolved) do
            if entry.photo then
                entry.photo:setRawMetadata('gps', {
                    latitude = args.latitude,
                    longitude = args.longitude,
                })
                if args.altitude ~= nil then
                    entry.photo:setRawMetadata('gpsAltitude', args.altitude)
                elseif clearAltitude then
                    entry.photo:setRawMetadata('gpsAltitude', nil)
                end
                updatedCount = updatedCount + 1
            else
                missingCount = missingCount + 1
                missingIds[missingCount] = tostring(entry.id)
            end
        end
    end)

    Log.info(string.format("Set GPS to %s, %s for %d photos",
        tostring(args.latitude), tostring(args.longitude), updatedCount))

    return {
        success = true,
        updated = updatedCount,
        missing = missingIds,
    }
end

-- Tool argument -> SDK field, in the order get_photo_metadata reports them.
-- "Sublocation" is the SDK `location` field.
local LOCATION_FIELDS = {
    { arg = "sublocation", key = "location" },
    { arg = "city", key = "city" },
    { arg = "state_province", key = "stateProvince" },
    { arg = "country", key = "country" },
    { arg = "iso_country_code", key = "isoCountryCode" },
}

-- Writes the IPTC location fields of photos. Fields left out are unchanged;
-- an empty string clears a field. GPS is set_gps's job and is not touched.
function MetadataHandler.setLocation(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    local changes = {}
    for _, field in ipairs(LOCATION_FIELDS) do
        local value = args[field.arg]
        if value ~= nil then
            if type(value) ~= "string" then
                error(field.arg .. " must be a string")
            end
            -- An empty string is passed through: it is what clears the
            -- field. Lightroom stores nil on these fields as the text "nil".
            changes[#changes + 1] = { arg = field.arg, key = field.key, value = value }
        end
    end
    if #changes == 0 then
        error("give at least one of sublocation, city, state_province, country, iso_country_code")
    end

    local catalog = LrApplication.activeCatalog()
    local updatedCount = 0
    local missingIds = {}
    local missingCount = 0

    local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)

    catalog:withWriteAccessDo("Set Location", function()
        for _, entry in ipairs(resolved) do
            if entry.photo then
                for _, change in ipairs(changes) do
                    entry.photo:setRawMetadata(change.key, change.value)
                end
                updatedCount = updatedCount + 1
            else
                missingCount = missingCount + 1
                missingIds[missingCount] = tostring(entry.id)
            end
        end
    end)

    local fields = {}
    for i, change in ipairs(changes) do fields[i] = change.arg end

    Log.info(string.format("Set location (%s) for %d photos", table.concat(fields, ", "), updatedCount))

    return {
        success = true,
        updated = updatedCount,
        fields = fields,
        missing = missingIds,
    }
end

-- Tool argument -> SDK field, in the order get_photo_metadata reports them.
local TEXT_FIELDS = {
    { arg = "title", key = "title" },
    { arg = "caption", key = "caption" },
    { arg = "headline", key = "headline" },
    { arg = "creator", key = "creator" },
    { arg = "copyright", key = "copyright" },
    { arg = "rights_usage_terms", key = "rightsUsageTerms" },
    { arg = "copyright_info_url", key = "copyrightInfoUrl" },
    { arg = "creator_url", key = "creatorUrl" },
    { arg = "alt_text", key = "altTextAccessibility", accessibility = true },
    { arg = "extended_description", key = "extDescrAccessibility", accessibility = true },
}

-- Writes IPTC description and rights fields of photos. Fields left out are
-- unchanged; an empty string clears a field. Copyright status is left out on
-- purpose: Lightroom accepted "copyrighted" for copyrightState but rolled the
-- whole write back for "unknown" and "public domain", after reporting success.
function MetadataHandler.setMetadata(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    local changes = {}
    local fields = {}
    for _, field in ipairs(TEXT_FIELDS) do
        local value = args[field.arg]
        if value ~= nil then
            if type(value) ~= "string" then
                error(field.arg .. " must be a string")
            end
            -- An empty string is passed through: it is what clears the
            -- field. Lightroom stores nil on these fields as the text "nil".
            changes[#changes + 1] = { key = field.key, value = value, accessibility = field.accessibility }
            fields[#fields + 1] = field.arg
        end
    end

    if #changes == 0 then
        error("give at least one of title, caption, headline, creator, copyright, rights_usage_terms, "
            .. "copyright_info_url, creator_url, alt_text, extended_description")
    end

    local catalog = LrApplication.activeCatalog()
    local updatedCount = 0
    local missingIds = {}
    local missingCount = 0

    local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)

    for _, entry in ipairs(resolved) do
        if entry.photo then
            for _, change in ipairs(changes) do
                if change.accessibility then
                    local ok, err = LrTasks.pcall(function() return entry.photo:getRawMetadata(change.key) end)
                    if not ok then
                        Log.warn("Accessibility metadata preflight failed: " .. tostring(err))
                        error("Accessibility text requires Lightroom Classic 13.2 or later")
                    end
                end
            end
        end
    end

    catalog:withWriteAccessDo("Set Metadata", function()
        for _, entry in ipairs(resolved) do
            if entry.photo then
                for _, change in ipairs(changes) do
                    if change.accessibility then
                        local ok, err = LrTasks.pcall(function()
                            entry.photo:setRawMetadata(change.key, change.value)
                        end)
                        if not ok then
                            error("Accessibility text requires Lightroom Classic 13.2 or later: " .. tostring(err))
                        end
                    else
                        entry.photo:setRawMetadata(change.key, change.value)
                    end
                end
                updatedCount = updatedCount + 1
            else
                missingCount = missingCount + 1
                missingIds[missingCount] = tostring(entry.id)
            end
        end
    end)

    Log.info(string.format("Set metadata (%s) for %d photos", table.concat(fields, ", "), updatedCount))

    return {
        success = true,
        updated = updatedCount,
        fields = fields,
        missing = missingIds,
    }
end

return MetadataHandler
