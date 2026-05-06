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

    catalog:withReadAccessDo(function()
        local matches
        if hasFilters then
            matches = catalog:findPhotos{ searchDesc = searchDesc }
        else
            matches = catalog:getAllPhotos()
        end

        for _, photo in ipairs(matches) do
            table.insert(results, buildResult(photo))
        end
    end)

    logger:info(string.format("Search found %d photos", #results))

    return {
        count = #results,
        photos = results,
    }
end

return SearchHandler
