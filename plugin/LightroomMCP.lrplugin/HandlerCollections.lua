local LrApplication = import 'LrApplication'

local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'
local PhotoSummary = require 'PhotoSummary'

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
                collection = collection,
                name = collection:getName(),
                type = collection:type(),
            })
        end

        local function addCollectionsFromSet(collSet, prefix)
            for _, coll in ipairs(collSet:getChildCollections()) do
                table.insert(all, {
                    collection = coll,
                    name = prefix .. coll:getName(),
                    parent = collSet:getName(),
                    type = coll:type(),
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
        local entry = all[i]
        entry.photoCount = #(entry.collection:getPhotos() or {})
        entry.collection = nil
        table.insert(slice, entry)
    end

    Log.info(string.format("Found %d collections, returning %d (offset=%d, limit=%d)",
        total, #slice, offset, limit))

    return {
        count = total,
        collections = slice,
        has_more = (offset + #slice) < total,
    }
end

-- Splits a collection set path on the " / " separator listCollections uses.
local function splitSetPath(path)
    local names = {}
    local rest = path
    while true do
        local first, last = rest:find(" / ", 1, true)
        local name = first and rest:sub(1, first - 1) or rest
        if name:match("^%s*$") then
            error("parent contains an empty collection set name: " .. path)
        end
        -- Edge spaces or slashes come from a malformed separator ("A /",
        -- "A / /B"); the set would exist but its path could not be read back.
        if name:match("^[%s/]") or name:match("[%s/]$") then
            error(string.format(
                "parent has a malformed collection set name '%s'; separate sets with ' / ': %s",
                name, path))
        end
        table.insert(names, name)
        if not first then
            return names
        end
        rest = rest:sub(last + 1)
    end
end

-- Lightroom compares sibling names ignoring case, and collections and
-- collection sets under one parent share those names.
local function findNamed(items, name)
    local wanted = name:lower()
    for _, item in ipairs(items) do
        if item:getName():lower() == wanted then
            return item
        end
    end
    return nil
end

function CollectionsHandler.createCollection(args)
    if type(args.name) ~= "string" or args.name:match("^%s*$") then
        error("name is required")
    end
    if args.parent ~= nil and type(args.parent) ~= "string" then
        error("parent must be a collection set path")
    end

    local catalog = LrApplication.activeCatalog()
    local collectionName = args.name
    local setNames = args.parent and splitSetPath(args.parent) or {}
    local parentSet = nil
    local existingLevels = 0

    -- Existing sets are reused under their stored names: asking Lightroom to
    -- create "trips" beside "Trips" fails with "name is not unique".
    if setNames[1] then
        catalog:withReadAccessDo(function()
            local sets = catalog:getChildCollectionSets()
            local collections = catalog:getChildCollections()
            for i, setName in ipairs(setNames) do
                local found = findNamed(sets, setName)
                if not found then
                    if findNamed(collections, setName) then
                        error(string.format("parent '%s' names a collection, not a collection set",
                            setName))
                    end
                    break
                end
                setNames[i] = found:getName()
                parentSet = found
                existingLevels = i
                sets = found:getChildCollectionSets()
                collections = found:getChildCollections()
            end
        end)
    end

    local parentPath = table.concat(setNames, " / ")
    local path = setNames[1] and (parentPath .. " / " .. collectionName) or collectionName

    -- Lightroom refuses to read a collection set in the withWriteAccessDo that
    -- created it ("Can't get collection information after creating collection
    -- inside the same withWriteAccessDo function"), so the collection goes in
    -- a second gate, where the new set can be read.
    if existingLevels < #setNames then
        catalog:withWriteAccessDo("Create Collection Sets", function()
            for i = existingLevels + 1, #setNames do
                local set = catalog:createCollectionSet(setNames[i], parentSet, true)
                -- A name clash returns nil instead of raising; the failed gate
                -- rolls back the sets created before it.
                if not set then
                    error("Lightroom did not create collection set: " .. setNames[i])
                end
                parentSet = set
            end
        end)
    end

    catalog:withWriteAccessDo("Create Collection", function()
        -- Checked inside the gate that creates, so a concurrent create cannot
        -- slip in between. A same-named collection would also make
        -- add_to_collection's bare-name lookup ambiguous.
        local collections = parentSet and parentSet:getChildCollections() or catalog:getChildCollections()
        local sets = parentSet and parentSet:getChildCollectionSets() or catalog:getChildCollectionSets()
        if findNamed(collections, collectionName) then
            error("Collection already exists: " .. path)
        end
        local clash = findNamed(sets, collectionName)
        if clash then
            error(string.format("A collection set named '%s' already exists %s",
                clash:getName(), parentSet and ("in " .. parentPath) or "at the top level"))
        end

        if not catalog:createCollection(collectionName, parentSet, false) then
            error("Lightroom did not create collection: " .. path)
        end
        Log.info("Created collection: " .. path)
    end)

    return {
        success = true,
        path = path,
        message = "Collection created: " .. path
    }
end

-- Match the paths returned by listCollections, then bare names of nested
-- collections. A listed path wins: a top-level "City" beside "Trips / City"
-- has no other name to be addressed by.
local function findAllCollections(catalog, name)
    local byPath = {}
    local byName = {}
    for _, collection in ipairs(catalog:getChildCollections()) do
        if collection:getName() == name then
            table.insert(byPath, collection)
        end
    end

    local function findInSet(collSet, prefix)
        for _, coll in ipairs(collSet:getChildCollections()) do
            if prefix .. coll:getName() == name then
                table.insert(byPath, coll)
            elseif coll:getName() == name then
                table.insert(byName, coll)
            end
        end
        for _, childSet in ipairs(collSet:getChildCollectionSets()) do
            findInSet(childSet, prefix .. childSet:getName() .. " / ")
        end
    end

    for _, set in ipairs(catalog:getChildCollectionSets()) do
        findInSet(set, set:getName() .. " / ")
    end

    if byPath[1] then
        return byPath
    end
    return byName
end

-- Resolves a bare name or listed path to exactly one collection. A bare name
-- shared by several collections is rejected rather than resolved to whichever
-- enumerates first.
local function findOneCollection(catalog, name)
    local matches = findAllCollections(catalog, name)
    if #matches == 0 then
        error("Collection not found: " .. name)
    end
    if #matches > 1 then
        error(string.format("%d collections are named '%s'; use a collection path", #matches, name))
    end
    return matches[1]
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
    catalog:withReadAccessDo(function()
        findOneCollection(catalog, args.collection_name)
    end)

    local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)

    catalog:withWriteAccessDo("Add Photos to Collection", function()
        -- Looked up again rather than carried across gates: the check above
        -- only proved the name resolved then, and the write gate is what makes
        -- the result safe to act on.
        local targetCollection = findOneCollection(catalog, args.collection_name)

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

-- Removes photos from a collection only; they stay in the catalog.
function CollectionsHandler.removeFromCollection(args)
    if not args.collection_name then
        error("collection_name is required")
    end

    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    local catalog = LrApplication.activeCatalog()
    local removedCount = 0
    local notInCollection = 0
    local missingIds = {}
    local missingCount = 0

    -- Checked before resolving ids, as add_to_collection does: resolution scans
    -- the catalog, too slow to spend on a typo'd name.
    local problem = nil
    catalog:withReadAccessDo(function()
        local matches = findAllCollections(catalog, args.collection_name)
        if #matches == 0 then
            problem = "Collection not found: " .. args.collection_name
        elseif #matches > 1 then
            problem = string.format("%d collections are named '%s'; use a collection path",
                #matches, args.collection_name)
        elseif matches[1]:isSmartCollection() then
            problem = "Cannot remove photos from a smart collection: " .. args.collection_name
        end
    end)
    if problem then
        error(problem)
    end

    local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)

    catalog:withWriteAccessDo("Remove Photos from Collection", function()
        local matches = findAllCollections(catalog, args.collection_name)
        if #matches == 0 then
            error("Collection not found: " .. args.collection_name)
        end
        if #matches > 1 then
            error(string.format("%d collections are named '%s'; use a collection path",
                #matches, args.collection_name))
        end
        local targetCollection = matches[1]
        if targetCollection:isSmartCollection() then
            error("Cannot remove photos from a smart collection: " .. args.collection_name)
        end

        local members = {}
        for _, photo in ipairs(targetCollection:getPhotos()) do
            members[photo] = true
        end

        -- Only members count as removed, so `removed` says what changed rather
        -- than echoing how many ids were sent.
        local photosToRemove = {}
        local selected = {}
        for _, entry in ipairs(resolved) do
            if not entry.photo then
                missingCount = missingCount + 1
                missingIds[missingCount] = tostring(entry.id)
            elseif members[entry.photo] then
                if not selected[entry.photo] then
                    table.insert(photosToRemove, entry.photo)
                    selected[entry.photo] = true
                end
            else
                notInCollection = notInCollection + 1
            end
        end

        if #photosToRemove > 0 then
            targetCollection:removePhotos(photosToRemove)
            removedCount = #photosToRemove
        end
    end)

    Log.info(string.format("Removed %d photos from collection: %s", removedCount, args.collection_name))

    return {
        success = true,
        removed = removedCount,
        not_in_collection = notInCollection,
        missing = missingIds,
        message = string.format("Removed %d photos from collection (%d not in it, %d ids not found)",
            removedCount, notInCollection, missingCount)
    }
end

-- Returns a page of a collection's photos, regular or smart, in the shape
-- search_photos uses.
function CollectionsHandler.getCollectionPhotos(args)
    args = args or {}
    if type(args.collection_name) ~= "string" or args.collection_name == "" then
        error("collection_name is required")
    end

    -- floor: a fractional offset would index photos[i] with a non-integer key
    -- (always nil) and crash the row builder.
    local limit = math.floor(tonumber(args.limit) or 100)
    if limit < 0 then limit = 0 end
    local offset = math.floor(tonumber(args.offset) or 0)
    if offset < 0 then offset = 0 end

    local catalog = LrApplication.activeCatalog()

    local collection = nil
    local problem = nil
    catalog:withReadAccessDo(function()
        local matches = findAllCollections(catalog, args.collection_name)
        if #matches == 0 then
            problem = "Collection not found: " .. args.collection_name
        elseif #matches > 1 then
            problem = string.format("%d collections are named '%s'; use a collection path",
                #matches, args.collection_name)
        else
            collection = matches[1]
        end
    end)
    if problem then
        error(problem)
    end

    -- OUTSIDE withReadAccessDo: a smart collection's getPhotos() runs a
    -- catalog search, and a query that yields inside the read gate deadlocks
    -- on Windows (#134/#124), as getTargetPhotos and findPhotos do.
    local photos = collection:getPhotos() or {}
    local total = #photos

    local last = math.min(offset + limit, total)
    local results = PhotoSummary.page(catalog, photos, offset + 1, last)

    Log.info(string.format("Collection %s has %d photos, returning %d (offset=%d, limit=%d)",
        args.collection_name, total, #results, offset, limit))

    return {
        count = total,
        photos = results,
        has_more = (offset + #results) < total,
    }
end

-- Deletes the collection itself; its photos stay in the catalog.
function CollectionsHandler.deleteCollection(args)
    if type(args.collection_name) ~= "string" or args.collection_name == "" then
        error("collection_name is required")
    end

    local catalog = LrApplication.activeCatalog()
    local photoCount = 0

    catalog:withWriteAccessDo("Delete Collection", function()
        local matches = findAllCollections(catalog, args.collection_name)
        if #matches == 0 then
            error("Collection not found: " .. args.collection_name)
        end
        if #matches > 1 then
            error(string.format("%d collections are named '%s'; use a collection path",
                #matches, args.collection_name))
        end

        photoCount = #matches[1]:getPhotos()
        matches[1]:delete()
    end)

    Log.info(string.format("Deleted collection: %s (%d photos, still in the catalog)",
        args.collection_name, photoCount))

    return {
        success = true,
        photo_count = photoCount,
        message = string.format("Deleted collection '%s' (%d photos stay in the catalog)",
            args.collection_name, photoCount)
    }
end

return CollectionsHandler
