local LrApplication = import 'LrApplication'
local LrLogger = import 'LrLogger'

local PhotoLookup = require 'PhotoLookup'

local logger = LrLogger('LightroomMCP')

local CollectionsHandler = {}

function CollectionsHandler.listCollections(args)
    args = args or {}
    local catalog = LrApplication.activeCatalog()
    local all = {}

    local limit = tonumber(args.limit) or 100
    if limit < 0 then limit = 0 end
    local offset = tonumber(args.offset) or 0
    if offset < 0 then offset = 0 end

    catalog:withReadAccessDo(function()
        for _, collection in ipairs(catalog:getChildCollections()) do
            table.insert(all, {
                name = collection:getName(),
                type = collection:type(),
                photoCount = #collection:getPhotos(),
            })
        end

        local function addCollectionsFromSet(collSet, prefix)
            for _, coll in ipairs(collSet:getChildCollections()) do
                table.insert(all, {
                    name = prefix .. coll:getName(),
                    parent = collSet:getName(),
                    type = coll:type(),
                    photoCount = #coll:getPhotos(),
                })
            end
            for _, childSet in ipairs(collSet:getChildCollectionSets()) do
                addCollectionsFromSet(childSet, prefix .. childSet:getName() .. " / ")
            end
        end

        for _, set in ipairs(catalog:getChildCollectionSets()) do
            addCollectionsFromSet(set, set:getName() .. " / ")
        end
    end)

    local total = #all
    local last = math.min(offset + limit, total)
    local slice = {}
    for i = offset + 1, last do
        table.insert(slice, all[i])
    end

    logger:info(string.format("Found %d collections, returning %d (offset=%d, limit=%d)",
        total, #slice, offset, limit))

    return {
        count = total,
        collections = slice,
        has_more = (offset + #slice) < total,
    }
end

function CollectionsHandler.createCollection(args)
    if not args.name then
        error("name is required")
    end

    local catalog = LrApplication.activeCatalog()
    local collectionName = args.name

    catalog:withWriteAccessDo("Create Collection", function()
        catalog:createCollection(collectionName)
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
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                table.insert(photosToAdd, entry.photo)
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
