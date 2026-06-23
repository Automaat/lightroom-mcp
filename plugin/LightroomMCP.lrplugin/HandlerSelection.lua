local LrApplication = import 'LrApplication'

local Log = require 'Log'

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

    -- Acquire the target set OUTSIDE withReadAccessDo. getTargetPhotos() reads
    -- the live view selection, which yields to the UI thread; called from
    -- inside the read gate on Windows it deadlocks -- the task never returns
    -- and never releases the gate, so the whole bridge wedges until the 30s
    -- server timeout (issues #134, #124). Only the per-photo metadata reads
    -- need the gate; getTargetPhotos() does not. This mirrors get_photo_metadata,
    -- which works because it only does a non-yielding getAllPhotos() pass.
    Log.info("getSelectedPhotos: requesting target photos")
    local matches = catalog:getTargetPhotos() or {}
    local total = #matches
    Log.info(string.format("getSelectedPhotos: getTargetPhotos returned %d", total))

    local last = math.min(offset + limit, total)
    local results = {}
    catalog:withReadAccessDo(function()
        for i = offset + 1, last do
            table.insert(results, buildResult(matches[i]))
        end
    end)

    Log.info(string.format("getSelectedPhotos: returning %d (offset=%d, limit=%d)",
        #results, offset, limit))

    return {
        count = total,
        photos = results,
        has_more = (offset + #results) < total,
    }
end

return SelectionHandler
