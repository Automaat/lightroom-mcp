local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local JSON = require 'JSON'
local KeywordTree = require 'KeywordTree'
local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'
local ExportPresets = require 'ExportPresets'

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
local DEFAULT_JPEG_QUALITY = 90
-- Lightroom's largest exported edge; leaves an edge nobody limited unconstrained.
local MAX_EXPORT_EDGE = 65000

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

local function requireFormat(requestedFormat)
    if requestedFormat ~= nil and type(requestedFormat) ~= "string" then
        error("format must be one of: jpeg, png, tiff, original")
    end
    local resolvedFormat = EXPORT_FORMATS[requestedFormat and requestedFormat:lower() or 'jpeg']
    if not resolvedFormat then
        error("format must be one of: jpeg, png, tiff, original")
    end
    return resolvedFormat
end

-- Lightroom's jpeg_quality is 0-1; the tool's quality is 0-100.
local function jpegQuality(quality)
    if type(quality) ~= "number" or quality ~= quality or quality < 0 or quality > 100 then
        error("quality must be a number between 0 and 100")
    end
    return quality / 100
end

-- Export settings when no preset is given: the tool's own defaults.
local function defaultSettings(args)
    local settings = {
        LR_jpeg_quality = jpegQuality(args.quality or DEFAULT_JPEG_QUALITY),
    }
    local format = requireFormat(args.format)
    settings.LR_format = format
    if format == 'JPEG' then
        settings.LR_export_colorSpace = 'sRGB'
    elseif format == 'TIFF' then
        settings.LR_tiff_compressionMethod = 'compressionMethod_LZW'
    end
    return settings
end

-- Export settings from a saved preset, with only the arguments the caller
-- passed layered on top: the preset's sharpening, renaming, metadata and
-- watermark settings survive a quality or size override.
local function presetSettings(preset, args)
    local settings = preset.settings
    if args.format ~= nil then
        settings.LR_format = requireFormat(args.format)
    end
    if args.quality ~= nil then
        settings.LR_jpeg_quality = jpegQuality(args.quality)
        -- Lightroom ignores the quality while a file size limit is on.
        settings.LR_jpeg_useLimitSize = false
    end
    -- Opening another application would leave it waiting for a user.
    settings.LR_export_postProcessing = 'doNothing'
    return settings
end

-- width and height limit each edge in pixels. 'wh' is the only resize type that
-- reads them that way: 'longEdge' ignores width and treats height as the long
-- edge. A preset's other edge survives only if it already means the same thing.
local function applySizeLimit(settings, args)
    if not args.width and not args.height then return end
    local keepsOtherEdge = settings.LR_size_doConstrain
        and settings.LR_size_resizeType == 'wh'
        and (settings.LR_size_units == nil or settings.LR_size_units == 'pixels')
    settings.LR_size_maxWidth = args.width or (keepsOtherEdge and settings.LR_size_maxWidth) or MAX_EXPORT_EDGE
    settings.LR_size_maxHeight = args.height or (keepsOtherEdge and settings.LR_size_maxHeight) or MAX_EXPORT_EDGE
    settings.LR_size_doConstrain = true
    settings.LR_size_resizeType = 'wh'
    settings.LR_size_units = 'pixels'
    settings.LR_size_doNotEnlarge = true
end

-- Lightroom's export session ignores size_percentage and truncates
-- size_megapixels to a whole number (0.5 writes no file), so these sizes are
-- turned into a long edge for each photo.
local function scaleForPhoto(settings, dimensions)
    if settings.LR_size_resizeType == 'percentage' then
        return settings.LR_size_percentage / 100
    end
    return math.sqrt(settings.LR_size_megapixels * 1000000 / (dimensions.width * dimensions.height))
end

local function needsProportionalSize(settings)
    if not settings.LR_size_doConstrain then return false end
    local megapixels = settings.LR_size_megapixels
    return settings.LR_size_resizeType == 'percentage'
        or (settings.LR_size_resizeType == 'megapixels' and megapixels ~= math.floor(megapixels))
end

-- Each photo gets its own session so a batch can be cancelled between photos,
-- so what Lightroom would count across one session is set for each photo here.
-- Returns nil and a reason when the photo's size cannot be worked out.
local function settingsForPhoto(baseSettings, photo, index, total)
    local settings = {}
    for key, value in pairs(baseSettings) do settings[key] = value end
    settings.LR_initialSequenceNumber = (settings.LR_initialSequenceNumber or 1) + index - 1
    if type(settings.LR_tokens) == "string" then
        settings.LR_tokens = settings.LR_tokens:gsub("{{naming_sequenceTotal_(%d)Digits?}}", function(digits)
            return string.format("%0" .. digits .. "d", total)
        end)
    end
    if needsProportionalSize(settings) then
        local dimensions = photo:getRawMetadata('croppedDimensions')
        if type(dimensions) ~= "table" or not dimensions.width or not dimensions.height then
            return nil, "Lightroom reported no dimensions for this photo"
        end
        local edge = math.max(dimensions.width, dimensions.height) * scaleForPhoto(settings, dimensions)
        edge = math.max(1, math.floor(edge + 0.5))
        settings.LR_size_resizeType = 'longEdge'
        settings.LR_size_units = 'pixels'
        settings.LR_size_maxWidth = edge
        settings.LR_size_maxHeight = edge
    end
    return settings
end

local function runExport(args, context, run)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    local preset
    if args.export_preset ~= nil then
        preset = ExportPresets.resolve(args.export_preset, args.export_preset_folder)
    elseif args.export_preset_folder ~= nil then
        error("export_preset_folder requires export_preset")
    end

    local destination
    if args.destination ~= nil then
        if type(args.destination) ~= "string" or args.destination:match("^%s*$") then
            error("destination is required")
        end
        if args.destination:find("[%z\1-\31]") then
            error("destination must not contain control characters")
        end
        destination = absolutePath(args.destination)
    elseif not preset then
        error("destination is required")
    else
        local destinationType = preset.settings.LR_export_destinationType
        if not ExportPresets.FIXED_DESTINATION_TYPES[destinationType]
            or (destinationType == 'specificFolder' and not preset.settings.LR_export_destinationPathPrefix) then
            error("Export preset '" .. preset.name .. "' has no fixed destination ("
                .. tostring(destinationType) .. "); pass destination")
        end
    end

    -- Every argument is checked before the folder is created, so a rejected
    -- call leaves nothing behind.
    local collisionHandling = args.on_existing or DEFAULT_COLLISION_HANDLING
    if not COLLISION_HANDLING[collisionHandling] then
        error("on_existing must be one of: rename, overwrite, skip")
    end

    local exportSettings = preset and presetSettings(preset, args) or defaultSettings(args)
    exportSettings.LR_collisionHandling = COLLISION_HANDLING[collisionHandling]

    applySizeLimit(exportSettings, args)

    local catalog = LrApplication.activeCatalog()

    -- Resolved without read access: the lookup runs catalog queries, which
    -- must not nest inside withReadAccessDo. Never hold read access across
    -- the export either: doExportOnCurrentTask() can run for minutes on a
    -- large batch, and holding it for that span blocks every other handler
    -- (list_collections, get_selected_photos, ...) and on macOS wedged the
    -- bridge until a manual restart (issue #128). LrExportSession acquires
    -- its own catalog access during rendering.
    local photosToExport = {}
    local missingIds = {}
    for _, entry in ipairs(PhotoLookup.resolveMany(catalog, args.photo_ids)) do
        if entry.photo then
            table.insert(photosToExport, entry.photo)
        else
            missingIds[#missingIds + 1] = tostring(entry.id)
        end
    end

    if #photosToExport == 0 then
        error("No photos found to export")
    end

    local presetFolder
    if not destination and exportSettings.LR_export_destinationType == 'specificFolder' then
        presetFolder = ExportPresets.specificFolderPath(exportSettings.LR_export_destinationPathPrefix,
            exportSettings.LR_export_useSubfolder, exportSettings.LR_export_destinationPathSuffix)
    end

    local exportFolder = destination or presetFolder
    if exportFolder then
        -- Lightroom refuses a missing folder with its own error, in the UI
        -- language; create it as export_photo_metadata and export_develop_preset do.
        local existing = LrFileUtils.exists(exportFolder)
        if existing == false then
            LrFileUtils.createAllDirectories(exportFolder)
            if LrFileUtils.exists(exportFolder) ~= "directory" then
                error("could not create destination folder: " .. exportFolder)
            end
        elseif existing ~= "directory" then
            error("destination is not a directory: " .. exportFolder)
        end
    end

    -- destinationType=specificFolder makes LR honour
    -- LR_export_destinationPathPrefix; sourceFolder ignores it and
    -- writes next to the original. Without a destination argument the
    -- preset's own destination (type, folder, subfolder) is kept.
    if destination then
        exportSettings.LR_export_destinationType = 'specificFolder'
        exportSettings.LR_export_destinationPathPrefix = destination
        exportSettings.LR_export_useSubfolder = false
    else
        destination = presetFolder or exportSettings.LR_export_destinationType
    end

    local exportedCount = 0
    local skippedCount = 0
    local failed = {}
    local remainingIds = {}
    local lastName
    for index, photo in ipairs(photosToExport) do
        if context and context:isCanceled() then
            for nextIndex = index, #photosToExport do
                remainingIds[#remainingIds + 1] = tostring(photosToExport[nextIndex].localIdentifier)
            end
            break
        end
        run.lastPhotoAt = LrDate.currentTime()
        local name = photo:getFormattedMetadata("fileName") or tostring(photo.localIdentifier)
        if context then context:report(exportedCount, #photosToExport, name) end
        local photoSettings, settingsError = exportSettings, nil
        if preset then
            photoSettings, settingsError = settingsForPhoto(exportSettings, photo, index, #photosToExport)
        end
        if photoSettings then
            local exportSession = LrExportSession {
                photosToExport = { photo },
                exportSettings = photoSettings,
            }
            exportSession:doExportOnCurrentTask()
            local renditionCount = 0
            for _, rendition in exportSession:renditions() do
                renditionCount = renditionCount + 1
                local rendered, pathOrMessage = rendition:waitForRender()
                if rendered and LrFileUtils.exists(pathOrMessage) then
                    exportedCount = exportedCount + 1
                else
                    failed[#failed + 1] = {
                        id = tostring(photo.localIdentifier),
                        reason = rendered and "Lightroom wrote no file" or tostring(pathOrMessage),
                    }
                end
            end
            if renditionCount == 0 then
                if collisionHandling == 'skip' then
                    skippedCount = skippedCount + 1
                else
                    failed[#failed + 1] = { id = tostring(photo.localIdentifier), reason = "Lightroom rendered no file" }
                end
            end
        else
            failed[#failed + 1] = { id = tostring(photo.localIdentifier), reason = settingsError }
        end
        lastName = name
    end
    if context and lastName then context:report(exportedCount, #photosToExport, lastName) end

    Log.info(string.format("Exported %d photos to: %s (skipped %d, failed %d)",
        exportedCount, destination, skippedCount, #failed))

    return {
        success = #failed == 0,
        exported = exportedCount,
        skipped = skippedCount,
        failed = #failed > 0 and failed or nil,
        missing = missingIds,
        complete = #remainingIds == 0,
        remaining_ids = #remainingIds > 0 and remainingIds or nil,
        destination = destination,
        preset = preset and {
            name = preset.name, folder = preset.folder, scope = preset.scope, file = preset.file,
        } or nil,
    }
end

-- Parallel export sessions wrote no file at all (6 calls, empty folder, LrC 15.6).
local currentRun = nil
-- An export session can hang without an error and never return. Without a limit
-- that one call would refuse every later export until the plug-in reloads.
local STALE_PHOTO_SECONDS = 300

function ExportHandler.exportPhotos(args, context)
    local now = LrDate.currentTime()
    if currentRun and now - currentRun.lastPhotoAt < STALE_PHOTO_SECONDS then
        error("export_photos is already running; wait for it to finish, then call again")
    end
    local run = { lastPhotoAt = now }
    currentRun = run
    local ok, result = LrTasks.pcall(runExport, args, context, run)
    if currentRun == run then currentRun = nil end
    if not ok then error(result, 0) end
    return result
end

-- Lists the export presets saved on disk, including ones that cannot run over
-- the bridge (other export services) with the reason, so a failed lookup in
-- export_photos can be explained.
function ExportHandler.listExportPresets(args)
    args = args or {}
    if args.folder ~= nil and (type(args.folder) ~= "string" or args.folder:match("^%s*$")) then
        error("folder must be a non-empty string")
    end
    local presets = ExportPresets.list(args.folder)
    return {
        presets = presets,
        count = #presets,
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
