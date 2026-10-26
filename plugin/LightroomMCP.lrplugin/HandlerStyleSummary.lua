local LrApplication = import 'LrApplication'
local JSON = require 'JSON'

local Handler = {}

local function integer(value, fallback, name, minimum, maximum)
    if value == nil then return fallback end
    if type(value) ~= "number" or value ~= value or value % 1 ~= 0
        or value < minimum or value > maximum then
        error(name .. " must be an integer from " .. minimum .. " to " .. maximum, 0)
    end
    return value
end

local function bucket(iso)
    if type(iso) ~= "number" or iso ~= iso or iso <= 0 or iso == math.huge then return "unknown" end
    if iso <= 400 then return "1-400" end
    if iso <= 1600 then return "401-1600" end
    if iso <= 6400 then return "1601-6400" end
    return "6401+"
end

local function summarize(group)
    local values = group.values
    group.values = nil
    group.settings = {}
    group.settings_omitted = 0
    if #JSON:encode(group) > 5900 then error("Camera model exceeds the summary size limit", 0) end
    local keys = {}
    for key in pairs(values) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local list = values[key]
        table.sort(list)
        local count = #list
        local low, high = list[1], list[count]
        if low ~= 0 or high ~= 0 then
            local middle = math.floor((count + 1) / 2)
            local median = list[middle]
            if count % 2 == 0 then median = median / 2 + list[middle + 1] / 2 end
            group.settings[key] = { median = median, min = low, max = high }
            if #JSON:encode(group) > 5900 then
                group.settings[key] = nil
                group.settings_omitted = group.settings_omitted + 1
            end
        end
    end
    return group
end

function Handler.summarize(args)
    local minRating = integer(args.min_rating, 4, "min_rating", 0, 5)
    local maximum = integer(args.max_photos, 200, "max_photos", 1, 200)
    if args.exported_only ~= nil and type(args.exported_only) ~= "boolean" then
        error("exported_only must be a boolean", 0)
    end
    local catalog = LrApplication.activeCatalog()
    local candidates = catalog:findPhotos({ searchDesc = {
        combine = "intersect", { criteria = "rating", operation = ">=", value = minRating },
    } })
    local selected = candidates
    if args.exported_only then
        selected = {}
        local exported = catalog:batchGetRawMetadata(candidates, { "isExported" })
        for _, photo in ipairs(candidates) do
            if (exported[photo] or {}).isExported == true then selected[#selected + 1] = photo end
        end
    end
    local matched = #selected
    local page = {}
    for index = 1, math.min(maximum, matched) do page[index] = selected[index] end
    local groups, byCamera = {}, {}
    if #page > 0 then
        catalog:withReadAccessDo(function()
            local raw = catalog:batchGetRawMetadata(page, { "isoSpeedRating" })
            local formatted = catalog:batchGetFormattedMetadata(page, { "cameraModel" })
            for _, photo in ipairs(page) do
                local camera = (formatted[photo] or {}).cameraModel
                if type(camera) ~= "string" or camera == "" then camera = "unknown" end
                local iso = bucket((raw[photo] or {}).isoSpeedRating)
                byCamera[camera] = byCamera[camera] or {}
                local group = byCamera[camera][iso]
                if not group then
                    group = { camera_model = camera, iso_bucket = iso, count = 0, values = {} }
                    byCamera[camera][iso] = group
                    groups[#groups + 1] = group
                end
                group.count = group.count + 1
                for key, value in pairs(photo:getDevelopSettings()) do
                    if type(key) == "string" and not key:match("^Crop") and not key:match("^Perspective")
                        and key ~= "Temperature" and key ~= "Tint" and type(value) == "number"
                        and value == value and value > -math.huge and value < math.huge then
                        local list = group.values[key] or {}
                        group.values[key] = list
                        list[#list + 1] = value
                    end
                end
            end
        end)
    end
    table.sort(groups, function(a, b)
        if a.camera_model == b.camera_model then return a.iso_bucket < b.iso_bucket end
        return a.camera_model < b.camera_model
    end)
    for _, group in ipairs(groups) do summarize(group) end
    return { groups = groups, scanned = #page, matched = matched, truncated = matched > #page }
end

return Handler
