local PhotoLookup = {}

-- Resolve a list of photo identifiers to photo objects.
-- Each id may be a numeric local identifier (string or number) or a file path.
-- Builds the path index AT MOST ONCE per call, and only when at least one id
-- missed local-id lookup. Returns a parallel array:
--   results[i] = { id = inputId, photo = photoOrNil }
function PhotoLookup.resolveMany(catalog, photoIds)
    local results = {}
    for i, id in ipairs(photoIds) do
        results[i] = { id = id, photo = nil }
    end

    -- LrCatalog has no findPhotoByLocalIdentifier; one getAllPhotos pass
    -- builds both id and path indexes. localIdentifier is numeric in
    -- production but tests pass strings — normalize via tostring.
    local byLocalId = {}
    local byPath = {}
    for _, p in ipairs(catalog:getAllPhotos()) do
        local lid = p.localIdentifier
        if lid ~= nil then byLocalId[tostring(lid)] = p end
        local path = p:getRawMetadata('path')
        if path ~= nil then byPath[path] = p end
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
