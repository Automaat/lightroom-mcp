local PhotoLookup = {}

local function directLocalId(id)
    if type(id) == "number" and id == math.floor(id) then return id end
    if type(id) == "string" and id:match("^%d+$") then return tonumber(id) end
    return nil
end

-- Resolve a list of photo identifiers to photo objects.
-- Each id may be a numeric local identifier (string or number) or a file path.
-- Returns a parallel array:
--   results[i] = { id = inputId, photo = photoOrNil }
--
-- Cost matters: on a large catalog this lookup dominates every handler that
-- resolves ids, so it does the least work it can.
--
-- A path is looked up with catalog:findPhotoByPath instead of reading every
-- photo's path: that was one getRawMetadata call per photo, ~95 s on a large
-- catalog. findPhotoByPath is a catalog query, so like findPhotos it must not
-- run inside withReadAccessDo or withWriteAccessDo; callers resolve first.
--
-- Paths are not unique: a virtual copy reports its master's source path, so a
-- path names a master and all its virtual copies. The LAST of them in catalog
-- order wins, as it did when paths were found by scanning every photo. Only
-- the getAllPhotos pass knows that order, so a path whose master has virtual
-- copies joins the pass, which stops once it has seen all of them.
function PhotoLookup.resolveMany(catalog, photoIds)
    local results = {}
    local canLookUpDirectly = type(catalog.getPhotoByLocalId) == "function"
    local byLocalId = {}
    local unverified = {}
    local keyOf = {}
    -- Local ids the getAllPhotos pass has yet to see.
    local pending = {}
    local remaining = 0
    local function await(key)
        if pending[key] == nil then
            pending[key] = true
            remaining = remaining + 1
        end
    end

    -- Path -> photo, or false when no photo has that exact path.
    local byPath = {}
    -- Local id -> path, for the master and virtual copies sharing a path.
    local sharers = {}

    for i, id in ipairs(photoIds) do
        results[i] = { id = id, photo = nil }
        local direct = canLookUpDirectly and directLocalId(id)
        if direct then
            local key = tostring(id)
            if byLocalId[key] == nil then
                byLocalId[key] = false
                local photo = catalog:getPhotoByLocalId(direct)
                if photo then
                    unverified[#unverified + 1] = photo
                    keyOf[photo] = key
                end
            end
        elseif tonumber(id) ~= nil then
            await(tostring(id))
        elseif byPath[id] == nil then
            byPath[id] = false
            local photo = catalog:findPhotoByPath(id)
            -- Exact, as the scan compared: findPhotoByPath may ignore case.
            if photo and photo:getRawMetadata('path') == id then
                local master = photo:getRawMetadata('masterPhoto') or photo
                byPath[id] = master
                local sharing = { master }
                for _, copy in ipairs(master:getRawMetadata('virtualCopies') or {}) do
                    sharing[#sharing + 1] = copy
                end
                if #sharing > 1 then
                    for _, sharer in ipairs(sharing) do
                        local key = tostring(sharer.localIdentifier)
                        sharers[key] = id
                        await(key)
                    end
                end
            end
        end
    end

    -- localIdentifier is numeric in production but tests pass strings --
    -- normalize via tostring.
    if #unverified > 0 then
        local raw = catalog:batchGetRawMetadata(unverified, { 'uuid' }) or {}
        for _, photo in ipairs(unverified) do
            if (raw[photo] or {}).uuid ~= nil then
                byLocalId[keyOf[photo]] = photo
            end
        end
    end

    if remaining > 0 then
        local seen = {}
        for _, p in ipairs(catalog:getAllPhotos()) do
            local lid = p.localIdentifier
            if lid ~= nil then
                local key = tostring(lid)
                if not seen[key] then
                    seen[key] = true
                    if byLocalId[key] == nil then byLocalId[key] = p end
                    -- Overwritten by each later sharer: the last one wins.
                    if sharers[key] then byPath[sharers[key]] = p end
                    if pending[key] then
                        pending[key] = nil
                        remaining = remaining - 1
                        if remaining <= 0 then break end
                    end
                end
            end
        end
    end

    for i, id in ipairs(photoIds) do
        if tonumber(id) ~= nil then
            results[i].photo = byLocalId[tostring(id)] or nil
        else
            results[i].photo = byPath[id] or nil
        end
    end

    return results
end

function PhotoLookup.resolveOne(catalog, photoId)
    return PhotoLookup.resolveMany(catalog, { photoId })[1].photo
end

return PhotoLookup
