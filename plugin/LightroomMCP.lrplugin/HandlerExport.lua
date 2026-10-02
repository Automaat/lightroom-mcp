local LrApplication = import 'LrApplication'
local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local JSON = require 'JSON'
local KeywordTree = require 'KeywordTree'
local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'

local ExportHandler = {}

-- Lightroom's default collision handling is "ask", which opens a modal
-- ("The following files already exist") and blocks the export task until a
-- human clicks. Over the bridge that hangs the request until the server
-- timeout and queues every later request behind it, so re-exporting the same
-- photo to the same folder wedged the plugin. Never prompt.
local COLLISION_HANDLING = {
    rename = 'rename',
    overwrite = 'overwrite',
    skip = 'skip',
}
local DEFAULT_COLLISION_HANDLING = 'rename'

local EXPORT_FORMATS = {
    jpeg = 'JPEG',
    png = 'PNG',
    tiff = 'TIFF',
    original = 'ORIGINAL',
}

function ExportHandler.exportPhotos(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    if not args.destination then
        error("destination is required")
    end

    local catalog = LrApplication.activeCatalog()

    -- Resolve photos under read access, then RELEASE the lock before
    -- exporting. doExportOnCurrentTask() can run for minutes on a large
    -- batch; holding catalog read access for that whole span blocks every
    -- other handler (list_collections, get_selected_photos, ...) and on
    -- macOS wedged the bridge until a manual restart (issue #128).
    -- LrExportSession acquires its own catalog access during rendering, so
    -- the lock is only needed for the lookup itself.
    local photosToExport = {}
    catalog:withReadAccessDo(function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                table.insert(photosToExport, entry.photo)
            end
        end
    end)

    if #photosToExport == 0 then
        error("No photos found to export")
    end

    -- destinationType=specificFolder makes LR honour
    -- LR_export_destinationPathPrefix; sourceFolder ignores it and
    -- writes next to the original. LR_format is set in the
    -- format-specific block below.
    local collisionHandling = args.on_existing or DEFAULT_COLLISION_HANDLING
    if not COLLISION_HANDLING[collisionHandling] then
        error("on_existing must be one of: rename, overwrite, skip")
    end

    local exportSettings = {
        LR_export_destinationType = 'specificFolder',
        LR_export_destinationPathPrefix = args.destination,
        LR_export_useSubfolder = false,
        LR_jpeg_quality = args.quality or 90,
        LR_collisionHandling = COLLISION_HANDLING[collisionHandling],
    }

    -- Set dimensions if specified
    if args.width or args.height then
        exportSettings.LR_size_doConstrain = true
        exportSettings.LR_size_maxWidth = args.width
        exportSettings.LR_size_maxHeight = args.height
        exportSettings.LR_size_resizeType = 'longEdge'
    end

    -- Handle different formats
    local requestedFormat = args.format
    if requestedFormat ~= nil and type(requestedFormat) ~= "string" then
        error("format must be one of: jpeg, png, tiff, original")
    end

    local formatKey = requestedFormat and requestedFormat:lower() or 'jpeg'
    local resolvedFormat = EXPORT_FORMATS[formatKey]
    if not resolvedFormat then
        error("format must be one of: jpeg, png, tiff, original")
    end

    exportSettings.LR_format = resolvedFormat
    if resolvedFormat == 'JPEG' then
        exportSettings.LR_export_colorSpace = 'sRGB'
    elseif resolvedFormat == 'TIFF' then
        exportSettings.LR_tiff_compressionMethod = 'compressionMethod_LZW'
    end

    -- Create export session
    local exportSession = LrExportSession {
        photosToExport = photosToExport,
        exportSettings = exportSettings,
    }

    -- Execute export (outside the read-access block above)
    exportSession:doExportOnCurrentTask()
    local exportedCount = #photosToExport

    Log.info(string.format("Exported %d photos to: %s", exportedCount, args.destination))

    return {
        success = true,
        exported = exportedCount,
        destination = args.destination,
        message = string.format("Exported %d photos to %s", exportedCount, args.destination)
    }
end

-- Only groups that carry a value are written, as get_photo_metadata does.
local function nonEmptyGroup(fields)
    for _, v in pairs(fields) do
        if v ~= nil and v ~= "" then return fields end
    end
    return nil
end

local function sizeOf(dimensions)
    if type(dimensions) ~= "table" then return nil end
    return { width = dimensions.width, height = dimensions.height }
end

-- Writes the catalog metadata of many photos to one JSON file.
--
-- get_photo_metadata answers for a single photo and carries its develop
-- settings, so reading a few hundred photos means a few hundred large replies.
-- This writes the organisational metadata (file, capture time, dimensions,
-- rating, title/caption, GPS, location, keywords and keyword paths) for the
-- given photos -- or the current selection / filmstrip when photo_ids is
-- omitted -- to disk, where a script can read it without it passing through
-- the client.
function ExportHandler.exportPhotoMetadata(args)
    args = args or {}

    local destination = args.destination
    if type(destination) ~= "string" or destination:match("^%s*$") then
        error("destination is required")
    end
    if not destination:lower():match("%.json$") then
        error("destination must be a .json file path")
    end
    if args.photo_ids ~= nil and (type(args.photo_ids) ~= "table" or #args.photo_ids == 0) then
        error("photo_ids must be a non-empty array when given")
    end

    local catalog = LrApplication.activeCatalog()

    -- Both lookups run OUTSIDE the read gate: getTargetPhotos() yields to the
    -- UI thread and deadlocks inside it on Windows (#124/#134).
    local photos = {}
    local missingIds = {}
    if args.photo_ids then
        for _, entry in ipairs(PhotoLookup.resolveMany(catalog, args.photo_ids)) do
            if entry.photo then
                table.insert(photos, entry.photo)
            else
                table.insert(missingIds, tostring(entry.id))
            end
        end
    else
        photos = catalog:getTargetPhotos() or {}
    end

    if #photos == 0 then
        error("No photos found to export metadata for")
    end

    local records = {}
    catalog:withReadAccessDo(function()
        for _, photo in ipairs(photos) do
            local keywords = {}
            local keywordPaths = {}
            for _, kw in ipairs(photo:getRawMetadata('keywords') or {}) do
                table.insert(keywords, kw:getName())
                table.insert(keywordPaths, KeywordTree.pathOf(kw))
            end

            local gps = photo:getRawMetadata('gps')
            local gpsData = nil
            if gps then
                gpsData = nonEmptyGroup({
                    latitude = gps.latitude,
                    longitude = gps.longitude,
                    altitude = photo:getRawMetadata('gpsAltitude'),
                })
            end

            table.insert(records, {
                id = photo.localIdentifier,
                uuid = photo:getRawMetadata('uuid'),
                path = photo:getRawMetadata('path'),
                filename = photo:getFormattedMetadata('fileName'),
                fileFormat = photo:getRawMetadata('fileFormat'),
                isVirtualCopy = photo:getRawMetadata('isVirtualCopy'),
                captureTime = photo:getRawMetadata('dateTimeOriginalISO8601'),
                dimensions = sizeOf(photo:getRawMetadata('dimensions')),
                croppedDimensions = sizeOf(photo:getRawMetadata('croppedDimensions')),
                rating = photo:getRawMetadata('rating'),
                colorLabel = photo:getRawMetadata('colorNameForLabel'),
                pickStatus = photo:getRawMetadata('pickStatus'),
                title = photo:getFormattedMetadata('title'),
                caption = photo:getFormattedMetadata('caption'),
                gps = gpsData,
                location = nonEmptyGroup({
                    sublocation = photo:getFormattedMetadata('location'),
                    city = photo:getFormattedMetadata('city'),
                    stateProvince = photo:getFormattedMetadata('stateProvince'),
                    country = photo:getFormattedMetadata('country'),
                    isoCountryCode = photo:getFormattedMetadata('isoCountryCode'),
                }),
                keywords = keywords,
                keywordPaths = keywordPaths,
            })
        end
    end)

    local parent = LrPathUtils.parent(destination)
    if parent and not LrFileUtils.exists(parent) then
        LrFileUtils.createAllDirectories(parent)
    end

    local file, openError = io.open(destination, "w")
    if not file then
        error("Could not write " .. destination .. ": " .. tostring(openError))
    end
    file:write(JSON:encode({ version = 1, count = #records, photos = records }))
    file:close()

    Log.info(string.format("Exported metadata for %d photos to: %s", #records, destination))

    return {
        success = true,
        exported = #records,
        destination = destination,
        missing = missingIds,
        message = string.format("Exported metadata for %d photos to %s (%d ids not found)",
            #records, destination, #missingIds)
    }
end

return ExportHandler
