local LrApplication = import 'LrApplication'

local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'

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

    Log.info(string.format("Found %d collections, returning %d (offset=%d, limit=%d)",
        total, #slice, offset, limit))

    return {
        count = total,
        collections = slice,
        has_more = (offset + #slice) < total,
    }
end

function CollectionsHandler.createCollection(args)
    if type(args.name) ~= "string" or args.name:match("^%s*$") then
        error("name is required")
    end

    local catalog = LrApplication.activeCatalog()
    local collectionName = args.name

    -- add_to_collection addresses collections by name, so a second collection
    -- with the same name makes that lookup ambiguous: photos would silently
    -- land in whichever one enumerates first.
    for _, collection in ipairs(catalog:getChildCollections()) do
        if collection:getName() == collectionName then
            error("Collection already exists: " .. collectionName)
        end
    end

    catalog:withWriteAccessDo("Create Collection", function()
        catalog:createCollection(collectionName)
        Log.info("Created collection: " .. collectionName)
    end)

    return {
        success = true,
        message = "Collection created: " .. collectionName
    }
end

-- Walks the top-level collections and then every collection set, depth first.
-- Cheap: the tree is small next to the photo catalog.
local function findCollection(catalog, name)
    for _, collection in ipairs(catalog:getChildCollections()) do
        if collection:getName() == name then
            return collection
        end
    end

    local function findInSet(collSet)
        for _, coll in ipairs(collSet:getChildCollections()) do
            if coll:getName() == name then
                return coll
            end
        end
        for _, childSet in ipairs(collSet:getChildCollectionSets()) do
            local found = findInSet(childSet)
            if found then
                return found
            end
        end
        return nil
    end

    for _, set in ipairs(catalog:getChildCollectionSets()) do
        local found = findInSet(set)
        if found then
            return found
        end
    end

    return nil
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
    local missingIds = {}
    local missingCount = 0

    -- Reject an unknown collection BEFORE resolving ids. Resolution scans the
    -- whole catalog and costs tens of seconds on a large library; spending that
    -- only to discover a typo'd name pushed the request past the server's
    -- timeout, so the caller got no answer at all instead of "Collection not
    -- found".
    local exists = false
    catalog:withReadAccessDo(function()
        exists = findCollection(catalog, args.collection_name) ~= nil
    end)
    if not exists then
        error("Collection not found: " .. args.collection_name)
    end

    local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)

    catalog:withWriteAccessDo("Add Photos to Collection", function()
        -- Looked up again rather than carried across gates: the check above
        -- only proved the name resolved then, and the write gate is what makes
        -- the result safe to act on.
        local targetCollection = findCollection(catalog, args.collection_name)

        if not targetCollection then
            error("Collection not found: " .. args.collection_name)
        end

        -- Find and add photos
        local photosToAdd = {}
        for _, entry in ipairs(resolved) do
            if entry.photo then
                table.insert(photosToAdd, entry.photo)
            else
                missingCount = missingCount + 1
                missingIds[missingCount] = tostring(entry.id)
            end
        end

        if #photosToAdd > 0 then
            targetCollection:addPhotos(photosToAdd)
            addedCount = #photosToAdd
        end
    end)

    Log.info(string.format("Added %d photos to collection: %s", addedCount, args.collection_name))

    -- Unresolvable ids used to vanish into a "success" with added=0, leaving the
    -- caller no way to tell a typo'd id from an empty add.
    return {
        success = true,
        added = addedCount,
        missing = missingIds,
        message = string.format("Added %d photos to collection (%d ids not found)",
            addedCount, missingCount)
    }
end

return CollectionsHandler
