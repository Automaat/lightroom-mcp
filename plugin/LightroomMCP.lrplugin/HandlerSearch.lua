local LrApplication = import 'LrApplication'

local Log = require 'Log'
local PhotoSummary = require 'PhotoSummary'

local SearchHandler = {}
local FLAGS = { pick = 1, reject = -1, none = 0 }
local LABELS = { red = 1, yellow = 2, green = 3, blue = 4, purple = 5, none = "none" }
local FILE_TYPES = { DNG = true, RAW = true, JPG = true, TIFF = true, PNG = true,
    PSD = true, VIDEO = true, PSB = true, AVIF = true, JXL = true }

local function enumValue(value, values, name)
    if type(value) ~= "string" or values[value] == nil then
        error(name .. " has an unsupported value", 0)
    end
    return values[value]
end

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

    for _, field in ipairs({ "camera", "lens", "folder" }) do
        if args[field] ~= nil then
            if type(args[field]) ~= "string" or not args[field]:find("%S") then
                error(field .. " must be a non-empty string", 0)
            end
            table.insert(desc, { criteria = field, operation = field == "folder" and "all" or "==", value = args[field] })
        end
    end
    if args.iso ~= nil then
        if type(args.iso) ~= "number" or args.iso ~= args.iso or args.iso <= 0 or args.iso == math.huge then
            error("iso must be a positive finite number", 0)
        end
        table.insert(desc, { criteria = "isoSpeedRating", operation = "==", value = args.iso })
    end
    if args.flag ~= nil then
        table.insert(desc, { criteria = "pick", operation = "==", value = enumValue(args.flag, FLAGS, "flag") })
    end
    if args.color_label ~= nil then
        table.insert(desc, { criteria = "labelColor", operation = "==", value = enumValue(args.color_label, LABELS, "color_label") })
    end
    if args.edited ~= nil then
        if type(args.edited) ~= "boolean" then error("edited must be a boolean", 0) end
        table.insert(desc, { criteria = "hasAdjustments", operation = args.edited and "isTrue" or "isFalse", value = args.edited })
    end
    if args.file_type ~= nil then
        enumValue(args.file_type, FILE_TYPES, "file_type")
        table.insert(desc, { criteria = "fileFormat", operation = "==", value = args.file_type })
    end

    return desc
end

SearchHandler.buildSearchDesc = buildSearchDesc

function SearchHandler.searchPhotos(args)
    local catalog = LrApplication.activeCatalog()
    local searchDesc = buildSearchDesc(args)
    local hasFilters = #searchDesc > 0

    -- floor: the tool schema permits any number, and a fractional offset would
    -- make the page loop index matches[i] with a non-integer key (always nil)
    -- and crash the row builder.
    local limit = math.floor(tonumber(args.limit) or 100)
    if limit < 0 then limit = 0 end
    local offset = math.floor(tonumber(args.offset) or 0)
    if offset < 0 then offset = 0 end

    -- Run the catalog query OUTSIDE withReadAccessDo. findPhotos() runs an
    -- async catalog search that yields; called from inside the read gate on
    -- Windows it deadlocks -- the task never returns and never releases the
    -- gate, wedging the whole bridge until the 30s server timeout (issue #124,
    -- same root cause as #134's getTargetPhotos).
    Log.info(string.format("searchPhotos: querying (hasFilters=%s)", tostring(hasFilters)))
    -- Unrated photos have nil rating; rating>=0 excludes them, so getAllPhotos()
    -- must be used when no filters are specified.
    local matches = (hasFilters
        and catalog:findPhotos{ searchDesc = searchDesc }
        or catalog:getAllPhotos()) or {}

    local total = #matches
    Log.info(string.format("searchPhotos: query returned %d", total))

    local last = math.min(offset + limit, total)
    local results = PhotoSummary.page(catalog, matches, offset + 1, last)

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
