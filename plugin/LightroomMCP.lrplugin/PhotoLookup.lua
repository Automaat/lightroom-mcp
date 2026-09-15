local PhotoLookup = {}

-- Resolve a list of photo identifiers to photo objects.
-- Each id may be a numeric local identifier (string or number) or a file path.
-- Builds the path index AT MOST ONCE per call, and only when at least one id
-- missed local-id lookup. Returns a parallel array:
--   results[i] = { id = inputId, photo = photoOrNil }
--
-- Cost matters: on a large catalog this scan dominates every handler that
-- resolves ids, so it does the least work it can. `getRawMetadata('path')` is
-- one call per photo and is skipped entirely when every requested id is
-- numeric, and such a batch stops as soon as the last id is found instead of
-- indexing the whole catalog.
--
-- A batch containing a path cannot take either shortcut. Paths are not unique:
-- a virtual copy reports its master's source path, so the same path can name
-- several photos. The resolution order is therefore part of the contract --
-- the LAST photo in catalog order wins -- and that cannot be known before the
-- scan ends. An id that matches nothing costs a full pass for the same reason.
function PhotoLookup.resolveMany(catalog, photoIds)
    local results = {}
    local pending = {}
    local remaining = 0
    local needPathIndex = false

    for i, id in ipairs(photoIds) do
        results[i] = { id = id, photo = nil }
        local key = tostring(id)
        if pending[key] == nil then
            pending[key] = true
            remaining = remaining + 1
        end
        -- a non-numeric id can only be satisfied by the path index
        if tonumber(id) == nil then needPathIndex = true end
    end

    -- LrCatalog has no findPhotoByLocalIdentifier; one getAllPhotos pass
    -- builds both id and path indexes. localIdentifier is numeric in
    -- production but tests pass strings — normalize via tostring.
    local byLocalId = {}
    local byPath = {}
    for _, p in ipairs(catalog:getAllPhotos()) do
        local lid = p.localIdentifier
        if lid ~= nil then
            local key = tostring(lid)
            if byLocalId[key] == nil then
                byLocalId[key] = p
                if pending[key] then
                    pending[key] = nil
                    remaining = remaining - 1
                end
            end
        end

        if needPathIndex then
            -- Last match wins: overwrite unconditionally. Stopping early here
            -- would freeze the first match instead, which for a
            -- { master, virtual copy } pair sharing one source path resolves a
            -- different photo than the caller expects.
            local path = p:getRawMetadata('path')
            if path ~= nil then byPath[path] = p end
        end

        -- Only a pure-id batch may exit early; local identifiers are unique.
        if not needPathIndex and remaining <= 0 then break end
    end

    for i, id in ipairs(photoIds) do
        local photo = byLocalId[tostring(id)]
        if not photo then photo = byPath[id] end
        results[i].photo = photo
    end

    return results
end

function PhotoLookup.resolveOne(catalog, photoId)
    return PhotoLookup.resolveMany(catalog, { photoId })[1].photo
end

return PhotoLookup
