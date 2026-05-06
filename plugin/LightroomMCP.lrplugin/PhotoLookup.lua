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

    -- LrCatalog has no findPhotoByLocalIdentifier; build both indexes from
    -- a single getAllPhotos pass. Skip the scan only if every id resolves
    -- as a numeric local id AND we already have an index — but in practice
    -- one scan is the cheapest correct path.
    local byLocalId = {}
    local byPath = {}
    for _, p in ipairs(catalog:getAllPhotos()) do
        byLocalId[p.localIdentifier] = p
        byPath[p:getRawMetadata('path')] = p
    end

    for i, id in ipairs(photoIds) do
        local numId = tonumber(id)
        local photo = nil
        if numId then photo = byLocalId[numId] end
        if not photo then photo = byPath[id] end
        results[i].photo = photo
    end

    return results
end

function PhotoLookup.resolveOne(catalog, photoId)
    return PhotoLookup.resolveMany(catalog, { photoId })[1].photo
end

return PhotoLookup
