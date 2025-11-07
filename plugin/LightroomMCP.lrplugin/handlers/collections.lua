local LrApplication = import 'LrApplication'
local LrLogger = import 'LrLogger'

local logger = LrLogger('LightroomMCP')

local CollectionsHandler = {}

function CollectionsHandler.listCollections(args)
    local catalog = LrApplication.activeCatalog()
    local collectionsList = {}

    catalog:withReadAccessDo(function()
        local collections = catalog:getChildCollections()

        for _, collection in ipairs(collections) do
            table.insert(collectionsList, {
                name = collection:getName(),
                type = collection:type(),
                photoCount = #collection:getPhotos()
            })
        end

        -- Also get collection sets
        local collectionSets = catalog:getChildCollectionSets()
        for _, set in ipairs(collectionSets) do
            local function addCollectionsFromSet(collSet, prefix)
                local setCollections = collSet:getChildCollections()
                for _, coll in ipairs(setCollections) do
                    table.insert(collectionsList, {
                        name = prefix .. coll:getName(),
                        parent = collSet:getName(),
                        type = coll:type(),
                        photoCount = #coll:getPhotos()
                    })
                end

                local childSets = collSet:getChildCollectionSets()
                for _, childSet in ipairs(childSets) do
                    addCollectionsFromSet(childSet, prefix .. childSet:getName() .. " / ")
                end
            end

            addCollectionsFromSet(set, set:getName() .. " / ")
        end
    end)

    logger:info(string.format("Found %d collections", #collectionsList))

    return {
        count = #collectionsList,
        collections = collectionsList
    }
end

function CollectionsHandler.createCollection(args)
    if not args.name then
        error("name is required")
    end

    local catalog = LrApplication.activeCatalog()
    local collectionName = args.name

    catalog:withWriteAccessDo("Create Collection", function()
        local collection = catalog:createCollection(collectionName)
        logger:info("Created collection: " .. collectionName)
    end)

    return {
        success = true,
        message = "Collection created: " .. collectionName
    }
end

function CollectionsHandler.addToCollection(args)
    if not args.collection_name then
        error("collection_name is required")
    end

    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    local catalog = LrApplication.activeCatalog()
    local addedCount = 0

    catalog:withWriteAccessDo("Add Photos to Collection", function()
        -- Find the collection
        local targetCollection = nil
        local collections = catalog:getChildCollections()

        for _, collection in ipairs(collections) do
            if collection:getName() == args.collection_name then
                targetCollection = collection
                break
            end
        end

        -- Also search in collection sets
        if not targetCollection then
            local collectionSets = catalog:getChildCollectionSets()
            local function findInSet(collSet)
                local setCollections = collSet:getChildCollections()
                for _, coll in ipairs(setCollections) do
                    if coll:getName() == args.collection_name then
                        return coll
                    end
                end

                local childSets = collSet:getChildCollectionSets()
                for _, childSet in ipairs(childSets) do
                    local found = findInSet(childSet)
                    if found then
                        return found
                    end
                end

                return nil
            end

            for _, set in ipairs(collectionSets) do
                targetCollection = findInSet(set)
                if targetCollection then
                    break
                end
            end
        end

        if not targetCollection then
            error("Collection not found: " .. args.collection_name)
        end

        -- Find and add photos
        local photosToAdd = {}
        for _, photoId in ipairs(args.photo_ids) do
            local photo = catalog:findPhotoByLocalIdentifier(photoId)

            if not photo then
                -- Try finding by path
                local allPhotos = catalog:getAllPhotos()
                for _, p in ipairs(allPhotos) do
                    if p:getRawMetadata('path') == photoId then
                        photo = p
                        break
                    end
                end
            end

            if photo then
                table.insert(photosToAdd, photo)
            end
        end

        if #photosToAdd > 0 then
            targetCollection:addPhotos(photosToAdd)
            addedCount = #photosToAdd
        end
    end)

    logger:info(string.format("Added %d photos to collection: %s", addedCount, args.collection_name))

    return {
        success = true,
        added = addedCount,
        message = string.format("Added %d photos to collection", addedCount)
    }
end

return CollectionsHandler
