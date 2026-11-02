local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local Log = require 'Log'

local ImportHandler = {}

local JPEG_SIDECAR_RAW_EXTENSIONS = {}
local IMPORTABLE_EXTENSIONS = {}
for ext in ([[
    3fr ari arw bay cap cr2 cr3 crw dcr dcs drf eip erf fff gpr iiq k25 kdc mdc mef mos mrw
    nef nrw orf ori pef ptx pxn raf raw rw2 rwl sr2 srf srw x3f
]]):gmatch("%S+") do
    JPEG_SIDECAR_RAW_EXTENSIONS[ext] = true
    IMPORTABLE_EXTENSIONS[ext] = true
end
for ext in ([[
    dng avif heic heif hif jpe jpeg jpg jxl png psb psd tif tiff
]]):gmatch("%S+") do
    IMPORTABLE_EXTENSIONS[ext] = true
end

local JPEG_EXTENSIONS = { jpe = true, jpeg = true, jpg = true }

local function lowerExtension(path)
    return LrPathUtils.extension(path):lower()
end

local function withoutSidecarJpegs(files)
    local rawStems = {}
    for _, file in ipairs(files) do
        if JPEG_SIDECAR_RAW_EXTENSIONS[lowerExtension(file)] then
            rawStems[LrPathUtils.removeExtension(file)] = true
        end
    end
    local kept = {}
    local sidecarCount = 0
    for _, file in ipairs(files) do
        if JPEG_EXTENSIONS[lowerExtension(file)] and rawStems[LrPathUtils.removeExtension(file)] then
            sidecarCount = sidecarCount + 1
        else
            kept[#kept + 1] = file
        end
    end
    return kept, sidecarCount
end

local function leafSpelledOnDisk(path, entries)
    local leaf = LrPathUtils.leafName(path)
    local spelling = nil
    for _, entry in ipairs(entries) do
        local entryLeaf = LrPathUtils.leafName(entry)
        if entryLeaf == leaf then
            return leaf
        end
        if entryLeaf:lower() == leaf:lower() then
            spelling = entryLeaf
        end
    end
    return spelling
end

local function rawFileProbedBeside(path, entries)
    local stem = LrPathUtils.removeExtension(path)
    local probedExtensions = {}
    for _, entry in ipairs(entries) do
        local ext = LrPathUtils.extension(entry)
        if JPEG_SIDECAR_RAW_EXTENSIONS[ext:lower()] and not probedExtensions[ext] then
            probedExtensions[ext] = true
            local candidate = stem .. "." .. ext
            if LrFileUtils.exists(candidate) == 'file' then
                return candidate
            end
        end
    end
    return nil
end

local function rawFileBeside(path)
    local entries = {}
    for entry in LrFileUtils.directoryEntries(LrPathUtils.parent(path)) do
        entries[#entries + 1] = entry
    end
    local leafOnDisk = leafSpelledOnDisk(path, entries)
    if not leafOnDisk then
        return rawFileProbedBeside(path, entries)
    end
    local stem = LrPathUtils.removeExtension(leafOnDisk)
    for _, entry in ipairs(entries) do
        if JPEG_SIDECAR_RAW_EXTENSIONS[lowerExtension(entry)]
            and LrPathUtils.leafName(LrPathUtils.removeExtension(entry)) == stem
            and LrFileUtils.exists(entry) == 'file' then
            return entry
        end
    end
    return nil
end

local function describeSkipped(skipped)
    local names = {}
    for ext in pairs(skipped) do names[#names + 1] = ext end
    table.sort(names)
    local parts = {}
    for _, ext in ipairs(names) do
        parts[#parts + 1] = string.format("%s: %d", ext == "" and "(none)" or ext, skipped[ext])
    end
    return table.concat(parts, ", ")
end

function ImportHandler.importPhotos(args, context)
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
    local skippedByExtension = {}
    local skippedCount = 0
    local sidecarJpegCount = 0
    if sourceKind == 'directory' then
        -- Import all photos from directory, including nested subfolders.
        -- LrFileUtils.files lists only the immediate directory, so a source
        -- organized as shoot/roll subfolders (the common Lightroom layout)
        -- enumerated nothing and failed with "No photos found to import".
        for file in LrFileUtils.recursiveFiles(args.source_path) do
            -- extension() is on LrPathUtils; LrFileUtils has no such field, so
            -- the previous call was nil and raised "attempt to call field
            -- 'extension' (a nil value)" on every directory import.
            local ext = lowerExtension(file)
            if IMPORTABLE_EXTENSIONS[ext] then
                table.insert(photosToImport, file)
            else
                skippedByExtension[ext] = (skippedByExtension[ext] or 0) + 1
                skippedCount = skippedCount + 1
            end
        end
        if not args.separate_jpegs then
            photosToImport, sidecarJpegCount = withoutSidecarJpegs(photosToImport)
        end
    else
        -- Import single photo
        if not args.separate_jpegs and JPEG_EXTENSIONS[lowerExtension(args.source_path)] then
            local rawFile = rawFileBeside(args.source_path)
            if rawFile then
                error(string.format(
                    "%s has a raw file of the same name. Import %s instead; Lightroom keeps the JPEG as its sidecar. "
                        .. "To add the JPEG as a separate photo, set separate_jpegs to true.",
                    args.source_path, rawFile))
            end
        end
        table.insert(photosToImport, args.source_path)
    end

    if #photosToImport == 0 then
        if skippedCount > 0 then
            error("No photos found to import; skipped files by extension: " .. describeSkipped(skippedByExtension))
        end
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
    local remainingPaths = {}
    local alreadyInCatalogCount = 0
    local processed = 0
    for index, filePath in ipairs(photosToImport) do
        if context and context:isCanceled() then
            for nextIndex = index, #photosToImport do remainingPaths[#remainingPaths + 1] = photosToImport[nextIndex] end
            break
        end
        if context then context:report(processed, #photosToImport, filePath) end
        if catalog:findPhotoByPath(filePath, false) then
            alreadyInCatalogCount = alreadyInCatalogCount + 1
        else
            catalog:withWriteAccessDo("Import Photo", function()
                local photo = catalog:addPhoto(filePath)
                if photo then
                    table.insert(addedPhotos, photo)
                    importedCount = importedCount + 1
                end
            end)
        end
        processed = processed + 1
    end
    if context and processed > 0 then context:report(processed, #photosToImport, photosToImport[processed]) end

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

    Log.info(string.format("Imported %d photos from: %s (skipped %d, sidecar JPEGs %d, already in catalog %d)",
        importedCount, args.source_path, skippedCount, sidecarJpegCount, alreadyInCatalogCount))

    local message
    if skippedCount > 0 then
        message = string.format("Skipped %d files with unsupported extensions (%s)",
            skippedCount, describeSkipped(skippedByExtension))
    end
    return {
        success = true,
        imported = importedCount,
        complete = #remainingPaths == 0,
        remaining_paths = #remainingPaths > 0 and remainingPaths or nil,
        skipped = skippedCount,
        skipped_by_extension = skippedCount > 0 and skippedByExtension or nil,
        skipped_sidecar_jpegs = sidecarJpegCount > 0 and sidecarJpegCount or nil,
        already_in_catalog = alreadyInCatalogCount > 0 and alreadyInCatalogCount or nil,
        message = message,
    }
end

return ImportHandler
