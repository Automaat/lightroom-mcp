local LrApplication = import 'LrApplication'
local LrLogger = import 'LrLogger'

local logger = LrLogger('LightroomMCP')

local SelectionHandler = {}

local function buildResult(photo)
    return {
        id = photo.localIdentifier,
        path = photo:getRawMetadata('path'),
        filename = photo:getFormattedMetadata('fileName'),
        rating = photo:getRawMetadata('rating'),
        dateTimeOriginal = photo:getFormattedMetadata('dateTimeOriginal'),
    }
end

function SelectionHandler.getSelectedPhotos(args)
    args = args or {}
    local catalog = LrApplication.activeCatalog()

    local limit = tonumber(args.limit) or 100
    if limit < 0 then limit = 0 end
    local offset = tonumber(args.offset) or 0
    if offset < 0 then offset = 0 end

    local results = {}
    local total = 0

    catalog:withReadAccessDo(function()
        local matches = catalog:getTargetPhotos() or {}
        total = #matches
        local last = math.min(offset + limit, total)
        for i = offset + 1, last do
            table.insert(results, buildResult(matches[i]))
        end
    end)

    logger:info(string.format("getTargetPhotos returned %d, paged %d (offset=%d, limit=%d)",
        total, #results, offset, limit))

    return {
        count = total,
        photos = results,
        has_more = (offset + #results) < total,
    }
end

return SelectionHandler
