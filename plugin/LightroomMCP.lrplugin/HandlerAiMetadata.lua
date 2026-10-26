local LrApplication = import 'LrApplication'
local PhotoLookup = require 'PhotoLookup'

local Handler = {}
local FIELD_IDS = { 'aiScore', 'aiReason' }

local function validateIds(ids)
    if type(ids) ~= 'table' or #ids == 0 or #ids > 1000 then
        error('photo_ids must contain between 1 and 1000 photo IDs or paths')
    end
    for _, id in ipairs(ids) do
        if (type(id) ~= 'string' or id == '') and
            (type(id) ~= 'number' or id ~= math.floor(id) or id < 1 or id == math.huge) then
            error('photo_ids must contain photo IDs or paths')
        end
    end
end

function Handler.setAiMetadata(args)
    validateIds(args.photo_ids)
    local score, reason = args.score, args.reason
    if score == nil and reason == nil then error('give at least one of score or reason') end
    if score ~= nil and score ~= '' and
        (type(score) ~= 'number' or score ~= score or score < 0 or score > 100 or score ~= math.floor(score)) then
        error('score must be an integer between 0 and 100, or an empty string to clear')
    end
    if reason ~= nil then
        if type(reason) ~= 'string' then error('reason must be a string') end
        -- JSON supplies UTF-8; count characters rather than continuation bytes.
        local _, characters = reason:gsub('[^\128-\191]', '')
        if characters > 1024 then error('reason must contain at most 1024 characters') end
    end

    local catalog = LrApplication.activeCatalog()
    local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
    local updated, missing = 0, {}
    catalog:withWriteAccessDo('Set AI Metadata', function()
        for _, entry in ipairs(resolved) do
            if entry.photo then
                if score ~= nil then
                    local value
                    if score ~= '' then value = tostring(score) end
                    entry.photo:setPropertyForPlugin(_PLUGIN, 'aiScore', value)
                end
                if reason ~= nil then
                    local value
                    if reason ~= '' then value = reason end
                    entry.photo:setPropertyForPlugin(_PLUGIN, 'aiReason', value)
                end
                updated = updated + 1
            else
                missing[#missing + 1] = tostring(entry.id)
            end
        end
    end)
    return { success = true, updated = updated, missing = missing }
end

function Handler.getAiMetadata(args)
    validateIds(args.photo_ids)
    local catalog = LrApplication.activeCatalog()
    local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
    local photos, seen, missing = {}, {}, {}
    for _, entry in ipairs(resolved) do
        if entry.photo then
            if not seen[entry.photo] then
                seen[entry.photo] = true
                photos[#photos + 1] = entry.photo
            end
        else
            missing[#missing + 1] = tostring(entry.id)
        end
    end
    local values = {}
    if #photos > 0 then values = catalog:batchGetPropertyForPlugin(photos, _PLUGIN, FIELD_IDS) end
    local results = {}
    for _, entry in ipairs(resolved) do
        if entry.photo then
            local fields = values[entry.photo] or {}
            results[#results + 1] = {
                photo_id = tostring(entry.photo.localIdentifier),
                score = tonumber(fields.aiScore),
                reason = fields.aiReason,
            }
        end
    end
    return { photos = results, missing = missing }
end

return Handler
