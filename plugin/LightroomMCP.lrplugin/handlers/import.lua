local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrLogger = import 'LrLogger'
local LrFileUtils = import 'LrFileUtils'

local logger = LrLogger('LightroomMCP')

local ImportHandler = {}

function ImportHandler.importPhotos(args)
    if not args.source_path then
        error("source_path is required")
    end

    if not LrFileUtils.exists(args.source_path) then
        error("Source path does not exist: " .. args.source_path)
    end

    local catalog = LrApplication.activeCatalog()
    local importedCount = 0

    -- Import photos
    catalog:withWriteAccessDo("Import Photos", function()
        local photosToImport = {}

        if LrFileUtils.isDirectory(args.source_path) then
            -- Import all photos from directory
            for file in LrFileUtils.files(args.source_path) do
                local ext = LrFileUtils.extension(file):lower()
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

        -- Use catalog:addPhoto for each file
        local addedPhotos = {}
        for _, filePath in ipairs(photosToImport) do
            local photo = catalog:addPhoto(filePath)
            if photo then
                table.insert(addedPhotos, photo)
                importedCount = importedCount + 1
            end
        end

        -- Add to collection if specified
        if args.collection_name and #addedPhotos > 0 then
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
                logger:info(string.format("Added %d imported photos to collection: %s",
                    #addedPhotos, args.collection_name))
            else
                logger:warn("Collection not found: " .. args.collection_name)
            end
        end
    end)

    logger:info(string.format("Imported %d photos from: %s", importedCount, args.source_path))

    return {
        success = true,
        imported = importedCount,
        message = string.format("Imported %d photos", importedCount)
    }
end

return ImportHandler
