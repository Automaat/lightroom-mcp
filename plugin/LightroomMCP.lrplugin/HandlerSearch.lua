local LrApplication = import 'LrApplication'

local Log = require 'Log'

local SearchHandler = {}

local function buildSearchDesc(args)
    local desc = { combine = "intersect" }

    if args.filename then
        table.insert(desc, { criteria = "filename", operation = "any", value = args.filename })
    end

    if args.rating then
        table.insert(desc, { criteria = "rating", operation = "==", value = args.rating })
    end

    if args.keywords and #args.keywords > 0 then
        for _, kw in ipairs(args.keywords) do
            table.insert(desc, { criteria = "keywords", operation = "all", value = kw })
        end
    end

    if args.start_date and args.end_date then
        table.insert(desc, {
            criteria = "captureTime",
            operation = "inRange",
            value = args.start_date,
            value2 = args.end_date,
        })
    elseif args.start_date then
        table.insert(desc, { criteria = "captureTime", operation = ">=", value = args.start_date })
    elseif args.end_date then
        table.insert(desc, { criteria = "captureTime", operation = "<=", value = args.end_date })
    end

    return desc
end

local function buildResult(photo)
    return {
        id = photo.localIdentifier,
        path = photo:getRawMetadata('path'),
        filename = photo:getFormattedMetadata('fileName'),
        rating = photo:getRawMetadata('rating'),
        dateTimeOriginal = photo:getFormattedMetadata('dateTimeOriginal'),
    }
end

function SearchHandler.searchPhotos(args)
    local catalog = LrApplication.activeCatalog()
    local results = {}
    local searchDesc = buildSearchDesc(args)
    local hasFilters = #searchDesc > 0

    -- floor: the tool schema permits any number, and a fractional offset would
    -- make the page loop index matches[i] with a non-integer key (always nil)
    -- and crash buildResult(nil).
    local limit = math.floor(tonumber(args.limit) or 100)
    if limit < 0 then limit = 0 end
    local offset = math.floor(tonumber(args.offset) or 0)
    if offset < 0 then offset = 0 end

    -- Run the catalog query OUTSIDE withReadAccessDo. findPhotos() runs an
    -- async catalog search that yields; called from inside the read gate on
    -- Windows it deadlocks -- the task never returns and never releases the
    -- gate, wedging the whole bridge until the 30s server timeout (issue #124,
    -- same root cause as #134's getTargetPhotos). Only the per-photo metadata
    -- reads need the gate. getAllPhotos() (no-filter path) is a non-yielding
    -- enumeration, but is hoisted out too for a single, consistent structure.
    Log.info(string.format("searchPhotos: querying (hasFilters=%s)", tostring(hasFilters)))
    -- Unrated photos have nil rating; rating>=0 excludes them, so getAllPhotos()
    -- must be used when no filters are specified.
    local matches = (hasFilters
        and catalog:findPhotos{ searchDesc = searchDesc }
        or catalog:getAllPhotos()) or {}

    local total = #matches
    Log.info(string.format("searchPhotos: query returned %d", total))

    local last = math.min(offset + limit, total)
    catalog:withReadAccessDo(function()
        for i = offset + 1, last do
            table.insert(results, buildResult(matches[i]))
        end
    end)

    Log.info(string.format("Search matched %d photos, returning %d (offset=%d, limit=%d)",
        total, #results, offset, limit))

    local response = {
        count = total,
        photos = results,
        has_more = (offset + #results) < total,
    }

    if not hasFilters then
        response.warning = "No filters applied — scanned full catalog. Provide filename, keywords, rating, or date filters to narrow results and improve performance."
    end

    return response
end

return SearchHandler
