local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local Log = require 'Log'

local ImportHandler = {}

function ImportHandler.importPhotos(args)
    if not args.source_path then
        error("source_path is required")
    end

    -- LrFileUtils.exists returns 'file' / 'directory' / false. Use it for the
    -- directory check too: LrFileUtils.isDirectory is absent on some Lightroom
    -- Classic runtimes (nil there, e.g. 15.3.1 -- issue #129), whereas exists
    -- is stable across supported versions.
    local sourceKind = LrFileUtils.exists(args.source_path)
    if not sourceKind then
        error("Source path does not exist: " .. args.source_path)
    end

    local catalog = LrApplication.activeCatalog()
    local importedCount = 0

    -- Enumerate source files OUTSIDE any catalog lock; the filesystem walk
    -- needs no catalog access.
    local photosToImport = {}
    if sourceKind == 'directory' then
        -- Import all photos from directory, including nested subfolders.
        -- LrFileUtils.files lists only the immediate directory, so a source
        -- organized as shoot/roll subfolders (the common Lightroom layout)
        -- enumerated nothing and failed with "No photos found to import".
        for file in LrFileUtils.recursiveFiles(args.source_path) do
            -- extension() is on LrPathUtils; LrFileUtils has no such field, so
            -- the previous call was nil and raised "attempt to call field
            -- 'extension' (a nil value)" on every directory import.
            local ext = LrPathUtils.extension(file):lower()
            if ext == 'jpg' or ext == 'jpeg' or ext == 'png' or
               ext == 'tif' or ext == 'tiff' or ext == 'dng' or
               ext == 'cr2' or ext == 'nef' or ext == 'arw' then
                table.insert(photosToImport, file)
            end
        end
    else
        -- Import single photo
        table.insert(photosToImport, args.source_path)
    end

    if #photosToImport == 0 then
        error("No photos found to import")
    end

    -- Add each photo in its OWN write transaction rather than holding the
    -- exclusive catalog write lock across the whole batch. A large import
    -- runs for minutes, and one batch-wide withWriteAccessDo would block
    -- every other handler (reads included) for that entire span -- the same
    -- bridge wedge the export handler was restructured to avoid (issue #128),
    -- and now longer-lived since import_photos was given a 5-minute server
    -- timeout. addPhoto cannot acquire its own isolated access the way
    -- LrExportSession does, so a per-photo lock is the bounded-hold
    -- equivalent: the lock is released between photos, letting queued
    -- handlers interleave.
    local addedPhotos = {}
    for _, filePath in ipairs(photosToImport) do
        catalog:withWriteAccessDo("Import Photo", function()
            local photo = catalog:addPhoto(filePath)
            if photo then
                table.insert(addedPhotos, photo)
                importedCount = importedCount + 1
            end
        end)
    end

    -- Add to collection if specified, in its own short write transaction.
    if args.collection_name and #addedPhotos > 0 then
        catalog:withWriteAccessDo("Add Imported Photos to Collection", function()
            local targetCollection = nil
            local collections = catalog:getChildCollections()

            for _, collection in ipairs(collections) do
                if collection:getName() == args.collection_name then
                    targetCollection = collection
                    break
                end
            end

            if targetCollection then
                targetCollection:addPhotos(addedPhotos)
                Log.info(string.format("Added %d imported photos to collection: %s",
                    #addedPhotos, args.collection_name))
            else
                Log.warn("Collection not found: " .. args.collection_name)
            end
        end)
    end

    Log.info(string.format("Imported %d photos from: %s", importedCount, args.source_path))

    return {
        success = true,
        imported = importedCount,
        message = string.format("Imported %d photos", importedCount)
    }
end

return ImportHandler
