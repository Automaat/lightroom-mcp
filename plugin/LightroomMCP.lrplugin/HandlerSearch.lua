local LrApplication = import 'LrApplication'

local Log = require 'Log'

local SearchHandler = {}

local function parseDate(value, name)
    if type(value) ~= "string" then
        error(name .. " must be a string in YYYY-MM-DD format", 0)
    end

    local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not year then
        error(name .. " must use YYYY-MM-DD format", 0)
    end

    year = tonumber(year)
    month = tonumber(month)
    day = tonumber(day)

    if month < 1 or month > 12 then
        error(name .. " must use a valid calendar date", 0)
    end

    local timestamp = os.time({ year = year, month = month, day = day, hour = 12 })
    local normalized = os.date("*t", timestamp)
    if normalized.year ~= year or normalized.month ~= month or normalized.day ~= day then
        error(name .. " must use a valid calendar date", 0)
    end

    return value, timestamp
end

local function addDays(timestamp, days)
    return os.date("%Y-%m-%d", timestamp + (days * 86400))
end

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
        local startDate, startTimestamp = parseDate(args.start_date, "start_date")
        local endDate, endTimestamp = parseDate(args.end_date, "end_date")
        if startTimestamp > endTimestamp then
            error("start_date must be on or before end_date", 0)
        end
        table.insert(desc, {
            criteria = "captureTime",
            operation = "in",
            value = startDate,
            value2 = endDate,
        })
    elseif args.start_date then
        local _, startTimestamp = parseDate(args.start_date, "start_date")
        table.insert(desc, { criteria = "captureTime", operation = ">", value = addDays(startTimestamp, -1) })
    elseif args.end_date then
        local _, endTimestamp = parseDate(args.end_date, "end_date")
        table.insert(desc, { criteria = "captureTime", operation = "<", value = addDays(endTimestamp, 1) })
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
