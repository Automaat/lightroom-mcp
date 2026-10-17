local PhotoSummary = {}

local RAW_KEYS = { 'path', 'rating' }
local FORMATTED_KEYS = { 'fileName', 'dateTimeOriginal' }

function PhotoSummary.rows(catalog, photos)
    local rows = {}
    if #photos == 0 then return rows end
    local raw = catalog:batchGetRawMetadata(photos, RAW_KEYS) or {}
    local formatted = catalog:batchGetFormattedMetadata(photos, FORMATTED_KEYS) or {}
    for i, photo in ipairs(photos) do
        local r = raw[photo] or {}
        local f = formatted[photo] or {}
        rows[i] = {
            id = photo.localIdentifier,
            path = r.path,
            filename = f.fileName,
            rating = r.rating,
            dateTimeOriginal = f.dateTimeOriginal,
        }
    end
    return rows
end

function PhotoSummary.page(catalog, photos, first, last)
    local slice = {}
    for i = first, last do slice[#slice + 1] = photos[i] end
    return PhotoSummary.rows(catalog, slice)
end

return PhotoSummary
