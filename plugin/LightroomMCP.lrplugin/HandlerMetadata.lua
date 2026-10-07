local LrApplication = import 'LrApplication'

local KeywordTree = require 'KeywordTree'
local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'

local MetadataHandler = {}

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

function MetadataHandler.getPhotoMetadata(args)
    if not args.photo_id then
        error("photo_id is required")
    end

    local catalog = LrApplication.activeCatalog()
    local photoData = nil

    catalog:withReadAccessDo(function()
        local photo = PhotoLookup.resolveOne(catalog, args.photo_id)

        if not photo then
            error("Photo not found: " .. args.photo_id)
        end

        -- Get keywords
        -- `keywords` stays leaf names; `keywordPaths` is the same list as
        -- full parent-first paths, which is what tells two keywords of the
        -- same name apart ("Orientation|portrait" vs "Type|portrait").
        local keywords = {}
        local keywordPaths = {}
        local photoKeywords = photo:getRawMetadata('keywords')
        if photoKeywords then
            for _, kw in ipairs(photoKeywords) do
                table.insert(keywords, kw:getName())
                table.insert(keywordPaths, KeywordTree.pathOf(kw))
            end
        end

        -- Get develop settings
        local developSettings = photo:getDevelopSettings()

        -- GPS is a raw {latitude, longitude} table; omit the group when absent
        -- or when present but carrying no coordinates.
        local gps = photo:getRawMetadata('gps')
        local gpsData = nil
        if gps then
            gpsData = nonEmptyGroup({
                latitude = gps.latitude,
                longitude = gps.longitude,
                altitude = photo:getRawMetadata('gpsAltitude'),
            })
        end

        photoData = {
            id = photo.localIdentifier,
            path = photo:getRawMetadata('path'),
            filename = photo:getFormattedMetadata('fileName'),
            rating = photo:getRawMetadata('rating'),
            colorLabel = photo:getRawMetadata('colorNameForLabel'),
            pickStatus = photo:getRawMetadata('pickStatus'),
            keywords = keywords,
            keywordPaths = keywordPaths,
            -- Title / caption / headline (IPTC content description).
            title = photo:getFormattedMetadata('title'),
            caption = photo:getFormattedMetadata('caption'),
            headline = photo:getFormattedMetadata('headline'),
            -- EXIF capture data.
            dateTimeOriginal = photo:getFormattedMetadata('dateTimeOriginal'),
            dateTimeDigitized = photo:getFormattedMetadata('dateTimeDigitized'),
            cameraMake = photo:getFormattedMetadata('cameraMake'),
            cameraModel = photo:getFormattedMetadata('cameraModel'),
            cameraSerialNumber = photo:getFormattedMetadata('cameraSerialNumber'),
            lens = photo:getFormattedMetadata('lens'),
            isoSpeedRating = photo:getFormattedMetadata('isoSpeedRating'),
            focalLength = photo:getFormattedMetadata('focalLength'),
            focalLength35mm = photo:getFormattedMetadata('focalLength35mm'),
            aperture = photo:getFormattedMetadata('aperture'),
            shutterSpeed = photo:getFormattedMetadata('shutterSpeed'),
            exposureBias = photo:getFormattedMetadata('exposureBias'),
            exposureProgram = photo:getFormattedMetadata('exposureProgram'),
            meteringMode = photo:getFormattedMetadata('meteringMode'),
            flash = photo:getFormattedMetadata('flash'),
            dimensions = photo:getFormattedMetadata('dimensions'),
            fileSize = photo:getFormattedMetadata('fileSize'),
            fileFormat = photo:getRawMetadata('fileFormat'),
            artist = photo:getFormattedMetadata('artist'),
            software = photo:getFormattedMetadata('software'),
            gps = gpsData,
            -- IPTC location ("Sublocation" is the SDK `location` field).
            location = nonEmptyGroup({
                sublocation = photo:getFormattedMetadata('location'),
                city = photo:getFormattedMetadata('city'),
                stateProvince = photo:getFormattedMetadata('stateProvince'),
                country = photo:getFormattedMetadata('country'),
                isoCountryCode = photo:getFormattedMetadata('isoCountryCode'),
            }),
            copyright = nonEmptyGroup({
                creator = photo:getFormattedMetadata('creator'),
                notice = photo:getFormattedMetadata('copyright'),
                status = photo:getFormattedMetadata('copyrightState'),
                rightsUsageTerms = photo:getFormattedMetadata('rightsUsageTerms'),
            }),
            developSettings = {
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
            }
        }
    end)

    Log.info("Retrieved metadata for photo: " .. args.photo_id)

    return photoData
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
        latitude = args.latitude,
        longitude = args.longitude,
        altitude = args.altitude,
        altitude_cleared = clearAltitude or nil,
        missing = missingIds,
        message = string.format("Set GPS for %d photos (%d ids not found)",
            updatedCount, missingCount)
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
        message = string.format("Set location for %d photos (%d ids not found)",
            updatedCount, missingCount)
    }
end

return MetadataHandler
