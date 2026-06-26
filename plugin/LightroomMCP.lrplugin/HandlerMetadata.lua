local LrApplication = import 'LrApplication'

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
        local keywords = {}
        local photoKeywords = photo:getRawMetadata('keywords')
        if photoKeywords then
            for _, kw in ipairs(photoKeywords) do
                table.insert(keywords, kw:getName())
            end
        end

        -- Get develop settings
        local developSettings = photo:getDevelopSettings()

        -- GPS is a raw {latitude, longitude} table; omit the group when absent.
        local gps = photo:getRawMetadata('gps')
        local gpsData = nil
        if gps then
            gpsData = {
                latitude = gps.latitude,
                longitude = gps.longitude,
                altitude = photo:getRawMetadata('gpsAltitude'),
            }
        end

        photoData = {
            id = photo.localIdentifier,
            path = photo:getRawMetadata('path'),
            filename = photo:getFormattedMetadata('fileName'),
            rating = photo:getRawMetadata('rating'),
            colorLabel = photo:getRawMetadata('colorNameForLabel'),
            pickStatus = photo:getRawMetadata('pickStatus'),
            keywords = keywords,
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
            }
        }
    end)

    Log.info("Retrieved metadata for photo: " .. args.photo_id)

    return photoData
end

return MetadataHandler
