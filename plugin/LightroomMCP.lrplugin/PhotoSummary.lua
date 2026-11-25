local PhotoSummary = {}

local RAW_KEYS = { 'path', 'rating', 'pickStatus', 'colorNameForLabel' }
local FORMATTED_KEYS = { 'fileName', 'dateTimeOriginal' }
-- Lightroom Classic 16.0.1 reports an unlabeled photo as "gray" (the photos
-- search_photos finds with color_label "none").
local NO_LABEL = { [""] = true, none = true, gray = true }

function PhotoSummary.rows(catalog, photos, includePath)
    local rows = {}
    if #photos == 0 then return rows end
    local raw = catalog:batchGetRawMetadata(photos, RAW_KEYS) or {}
    local formatted = catalog:batchGetFormattedMetadata(photos, FORMATTED_KEYS) or {}
    for i, photo in ipairs(photos) do
        local r = raw[photo] or {}
        local f = formatted[photo] or {}
        rows[i] = {
            id = photo.localIdentifier,
            filename = f.fileName,
            rating = r.rating,
            dateTimeOriginal = f.dateTimeOriginal,
        }
        -- Flag and label only when set, so a row answers "which are picked or
        -- blue?" without a get_photo_metadata call per photo.
        if r.pickStatus ~= nil and r.pickStatus ~= 0 then rows[i].pickStatus = r.pickStatus end
        if r.colorNameForLabel ~= nil and not NO_LABEL[r.colorNameForLabel] then
            rows[i].colorLabel = r.colorNameForLabel
        end
        if includePath then rows[i].path = r.path end
    end
    return rows
end

function PhotoSummary.page(catalog, photos, first, last, includePath)
    local slice = {}
    for i = first, last do slice[#slice + 1] = photos[i] end
    return PhotoSummary.rows(catalog, slice, includePath)
end

return PhotoSummary
