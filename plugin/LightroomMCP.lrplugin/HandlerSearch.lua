local LrApplication = import 'LrApplication'
local LrLogger = import 'LrLogger'

local logger = LrLogger('LightroomMCP')

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

    local limit = tonumber(args.limit) or 100
    if limit < 0 then limit = 0 end
    local offset = tonumber(args.offset) or 0
    if offset < 0 then offset = 0 end

    local total = 0

    -- When no user filters: use rating>=0 as a universal criterion so findPhotos()
    -- can be used consistently. findPhotos() routes through LR's internal SQL search
    -- engine which is significantly faster than getAllPhotos() on large catalogs.
    if not hasFilters then
        table.insert(searchDesc, { criteria = "rating", operation = ">=", value = 0 })
    end

    catalog:withReadAccessDo(function()
        local matches = catalog:findPhotos{ searchDesc = searchDesc }

        total = #matches
        local last = math.min(offset + limit, total)
        for i = offset + 1, last do
            table.insert(results, buildResult(matches[i]))
        end
    end)

    logger:info(string.format("Search matched %d photos, returning %d (offset=%d, limit=%d)",
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
