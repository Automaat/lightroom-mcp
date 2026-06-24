local LrApplication = import 'LrApplication'

local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'

local MetadataHandler = {}

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

        photoData = {
            id = photo.localIdentifier,
            path = photo:getRawMetadata('path'),
            filename = photo:getFormattedMetadata('fileName'),
            rating = photo:getRawMetadata('rating'),
            colorLabel = photo:getRawMetadata('colorNameForLabel'),
            pickStatus = photo:getRawMetadata('pickStatus'),
            keywords = keywords,
            dateTimeOriginal = photo:getFormattedMetadata('dateTimeOriginal'),
            cameraMake = photo:getFormattedMetadata('cameraMake'),
            cameraModel = photo:getFormattedMetadata('cameraModel'),
            lens = photo:getFormattedMetadata('lens'),
            isoSpeedRating = photo:getFormattedMetadata('isoSpeedRating'),
            focalLength = photo:getFormattedMetadata('focalLength'),
            aperture = photo:getFormattedMetadata('aperture'),
            shutterSpeed = photo:getFormattedMetadata('shutterSpeed'),
            dimensions = photo:getFormattedMetadata('dimensions'),
            fileSize = photo:getFormattedMetadata('fileSize'),
            fileFormat = photo:getRawMetadata('fileFormat'),
            developSettings = {
                whiteBalance = developSettings.WhiteBalance,
                exposure = developSettings.Exposure2012,
                contrast = developSettings.Contrast2012,
                highlights = developSettings.Highlights2012,
                shadows = developSettings.Shadows2012,
                whites = developSettings.Whites2012,
                blacks = developSettings.Blacks2012,
                clarity = developSettings.Clarity2012,
                vibrance = developSettings.Vibrance,
                saturation = developSettings.Saturation,
            }
        }
    end)

    Log.info("Retrieved metadata for photo: " .. args.photo_id)

    return photoData
end

return MetadataHandler
