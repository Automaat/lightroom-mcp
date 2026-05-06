local PhotoLookup = {}

-- Resolve a list of photo identifiers to photo objects.
-- Each id may be a numeric local identifier (string or number) or a file path.
-- Builds the path index AT MOST ONCE per call, and only when at least one id
-- missed local-id lookup. Returns a parallel array:
--   results[i] = { id = inputId, photo = photoOrNil }
function PhotoLookup.resolveMany(catalog, photoIds)
    local results = {}
    local missingIdx = {}

    for i, id in ipairs(photoIds) do
        local photo = nil
        local numId = tonumber(id)
        if numId then
            photo = catalog:findPhotoByLocalIdentifier(numId)
        end
        results[i] = { id = id, photo = photo }
        if not photo then
            table.insert(missingIdx, i)
        end
    end

    if #missingIdx > 0 then
        local byPath = {}
        for _, p in ipairs(catalog:getAllPhotos()) do
            byPath[p:getRawMetadata('path')] = p
        end
        for _, idx in ipairs(missingIdx) do
            results[idx].photo = byPath[results[idx].id]
        end
    end

    return results
end

function PhotoLookup.resolveOne(catalog, photoId)
    return PhotoLookup.resolveMany(catalog, { photoId })[1].photo
end

return PhotoLookup
