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

-- Expands a leading ~/ and refuses a relative path: one resolves against
-- Lightroom's working directory ("/" on macOS), which fails with an unhelpful
-- "Read-only file system".
local function absolutePath(destination)
    if destination:match("^~[/\\]") then
        destination = LrPathUtils.child(LrPathUtils.getStandardFilePath("home"), destination:sub(3))
    end
    local absolute
    if WIN_ENV then
        absolute = destination:match("^%a:[/\\]") or destination:match("^\\\\")
    else
        absolute = destination:match("^/")
    end
    if not absolute then
        error("destination must be an absolute path")
    end
    return destination
end

function ExportHandler.exportPhotos(args, context)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    if type(args.destination) ~= "string" or args.destination:match("^%s*$") then
        error("destination is required")
    end
    if args.destination:find("[%z\1-\31]") then
        error("destination must not contain control characters")
    end
    local destination = absolutePath(args.destination)

    -- Every argument is checked before the folder is created, so a rejected
    -- call leaves nothing behind.
    local collisionHandling = args.on_existing or DEFAULT_COLLISION_HANDLING
    if not COLLISION_HANDLING[collisionHandling] then
        error("on_existing must be one of: rename, overwrite, skip")
    end

    local requestedFormat = args.format
    if requestedFormat ~= nil and type(requestedFormat) ~= "string" then
        error("format must be one of: jpeg, png, tiff, original")
    end
    local formatKey = requestedFormat and requestedFormat:lower() or 'jpeg'
    local resolvedFormat = EXPORT_FORMATS[formatKey]
    if not resolvedFormat then
        error("format must be one of: jpeg, png, tiff, original")
    end

    local catalog = LrApplication.activeCatalog()

    -- Resolved without read access: the lookup runs catalog queries, which
    -- must not nest inside withReadAccessDo. Never hold read access across
    -- the export either: doExportOnCurrentTask() can run for minutes on a
    -- large batch, and holding it for that span blocks every other handler
    -- (list_collections, get_selected_photos, ...) and on macOS wedged the
    -- bridge until a manual restart (issue #128). LrExportSession acquires
    -- its own catalog access during rendering.
    local photosToExport = {}
    for _, entry in ipairs(PhotoLookup.resolveMany(catalog, args.photo_ids)) do
        if entry.photo then
            table.insert(photosToExport, entry.photo)
        end
    end

    if #photosToExport == 0 then
        error("No photos found to export")
    end

    -- Lightroom refuses a missing folder with its own error, in the UI
    -- language; create it as export_photo_metadata and export_develop_preset do.
    local existing = LrFileUtils.exists(destination)
    if existing == false then
        LrFileUtils.createAllDirectories(destination)
        if LrFileUtils.exists(destination) ~= "directory" then
            error("could not create destination folder: " .. destination)
        end
    elseif existing ~= "directory" then
        error("destination is not a directory: " .. destination)
    end

    -- destinationType=specificFolder makes LR honour
    -- LR_export_destinationPathPrefix; sourceFolder ignores it and
    -- writes next to the original. LR_format is set in the
    -- format-specific block below.
    local exportSettings = {
        LR_export_destinationType = 'specificFolder',
        LR_export_destinationPathPrefix = destination,
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
    exportSettings.LR_format = resolvedFormat
    if resolvedFormat == 'JPEG' then
        exportSettings.LR_export_colorSpace = 'sRGB'
    elseif resolvedFormat == 'TIFF' then
        exportSettings.LR_tiff_compressionMethod = 'compressionMethod_LZW'
    end

    local exportedCount = 0
    local remainingIds = {}
    local lastName
    for index, photo in ipairs(photosToExport) do
        if context and context:isCanceled() then
            for nextIndex = index, #photosToExport do
                remainingIds[#remainingIds + 1] = tostring(photosToExport[nextIndex].localIdentifier)
            end
            break
        end
        local name = photo:getFormattedMetadata("fileName") or tostring(photo.localIdentifier)
        if context then context:report(exportedCount, #photosToExport, name) end
        local exportSession = LrExportSession {
            photosToExport = { photo },
            exportSettings = exportSettings,
        }
        exportSession:doExportOnCurrentTask()
        exportedCount = exportedCount + 1
        lastName = name
    end
    if context and lastName then context:report(exportedCount, #photosToExport, lastName) end

    Log.info(string.format("Exported %d photos to: %s", exportedCount, destination))

    return {
        success = true,
        exported = exportedCount,
        complete = #remainingIds == 0,
        remaining_ids = #remainingIds > 0 and remainingIds or nil,
        destination = destination,
    }
end

-- Same cap as an explicit photo_ids list. The selection has none of its own:
-- with nothing selected getTargetPhotos() is the whole filmstrip, which can
-- outlast the server timeout and hold the read gate throughout.
local MAX_METADATA_PHOTOS = 1000
local RECORD_RAW_KEYS = {
    'keywords', 'gps', 'gpsAltitude', 'uuid', 'path', 'fileFormat', 'isVirtualCopy',
    'dateTimeOriginalISO8601', 'dimensions', 'croppedDimensions', 'rating',
    'colorNameForLabel', 'pickStatus',
}
local RECORD_FORMATTED_KEYS = {
    'fileName', 'title', 'caption', 'location', 'city', 'stateProvince', 'country', 'isoCountryCode',
}

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
    -- io.open stops at a NUL byte, so "/x/.zshrc\0.json" would pass the .json
    -- check and write to ".zshrc".
    if destination:find("[%z\1-\31]") then
        error("destination must not contain control characters")
    end
    if not destination:lower():match("%.json$") then
        error("destination must be a .json file path")
    end
    destination = absolutePath(destination)
    if args.photo_ids ~= nil and (type(args.photo_ids) ~= "table" or #args.photo_ids == 0) then
        error("photo_ids must be a non-empty array when given")
    end
    if args.overwrite ~= nil and type(args.overwrite) ~= "boolean" then
        error("overwrite must be a boolean")
    end
    -- Refuse to replace a file unless asked, like export_photos: the path can
    -- come from text an attacker controls (a caption), and any .json the
    -- Lightroom process can write would otherwise be clobbered.
    local function checkDestination()
        local existing = LrFileUtils.exists(destination)
        if existing == "directory" then
            error("destination is a directory: " .. destination)
        end
        if existing and args.overwrite ~= true then
            error("destination already exists: " .. destination .. " (pass overwrite: true to replace it)")
        end
        return existing
    end
    checkDestination()

    local catalog = LrApplication.activeCatalog()

    -- Both lookups run OUTSIDE the read gate: getTargetPhotos() yields to the
    -- UI thread and deadlocks inside it on Windows (#124/#134).
    local photos = {}
    local missingIds = {}
    if args.photo_ids then
        -- The same photo can be named twice, by id and by path.
        local seen = {}
        for _, entry in ipairs(PhotoLookup.resolveMany(catalog, args.photo_ids)) do
            if entry.photo then
                if not seen[entry.photo] then
                    seen[entry.photo] = true
                    table.insert(photos, entry.photo)
                end
            else
                table.insert(missingIds, tostring(entry.id))
            end
        end
    else
        photos = catalog:getTargetPhotos() or {}
        if #photos > MAX_METADATA_PHOTOS then
            error(string.format("%d photos are selected (or in the filmstrip); export at most %d "
                .. "at a time by selecting fewer or passing photo_ids", #photos, MAX_METADATA_PHOTOS))
        end
    end

    if #photos == 0 then
        if #missingIds > 0 then
            error("No photos found to export metadata for (not found: "
                .. table.concat(missingIds, ", ") .. ")")
        end
        error("No photos found to export metadata for")
    end

    local raw = catalog:batchGetRawMetadata(photos, RECORD_RAW_KEYS) or {}
    local formatted = catalog:batchGetFormattedMetadata(photos, RECORD_FORMATTED_KEYS) or {}
    local records = {}
    catalog:withReadAccessDo(function()
        local pathOfKeyword = {}
        for _, photo in ipairs(photos) do
            local r = raw[photo] or {}
            local f = formatted[photo] or {}
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

            local gpsData = nil
            if r.gps then
                gpsData = nonEmptyGroup({
                    latitude = r.gps.latitude,
                    longitude = r.gps.longitude,
                    altitude = r.gpsAltitude,
                })
            end

            table.insert(records, {
                id = photo.localIdentifier,
                uuid = r.uuid,
                path = r.path,
                filename = f.fileName,
                fileFormat = r.fileFormat,
                isVirtualCopy = r.isVirtualCopy,
                captureTime = r.dateTimeOriginalISO8601,
                dimensions = sizeOf(r.dimensions),
                croppedDimensions = sizeOf(r.croppedDimensions),
                rating = r.rating,
                colorLabel = r.colorNameForLabel,
                pickStatus = r.pickStatus,
                title = f.title,
                caption = f.caption,
                gps = gpsData,
                location = nonEmptyGroup({
                    sublocation = f.location,
                    city = f.city,
                    stateProvince = f.stateProvince,
                    country = f.country,
                    isoCountryCode = f.isoCountryCode,
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

    -- Encoded before the file is opened, so an encoding error leaves nothing
    -- behind, and checked again: a file may have appeared while photos were read.
    local text = JSON:encode({ version = 1, count = #records, photos = records })
    local existedBefore = checkDestination()

    local file, openError = io.open(destination, "w")
    if not file then
        error("Could not write " .. destination .. ": " .. tostring(openError))
    end
    local written, writeError = file:write(text)
    local closed, closeError = file:close()
    if not written or not closed then
        -- A partial file this call created would make every retry fail with
        -- "already exists"; one it replaced was given up by overwrite: true.
        if not existedBefore then
            LrFileUtils.delete(destination)
        end
        error("Could not write " .. destination .. " (the file may be incomplete): "
            .. tostring(writeError or closeError))
    end

    Log.info(string.format("Exported metadata for %d photos to: %s", #records, destination))

    return {
        success = true,
        exported = #records,
        destination = destination,
        missing = missingIds,
    }
end

return ExportHandler
