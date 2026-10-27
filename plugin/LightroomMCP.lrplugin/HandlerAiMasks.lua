local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'

local AiMaskParts = require 'AiMaskParts'
local DevelopSession = require 'DevelopSession'
local GuardedMaskWrite = require 'GuardedMaskWrite'
local Log = require 'Log'
local PhotoLookup = require 'PhotoLookup'

local AiMaskHandler = {}

local COMPUTE_TIMEOUT_SECONDS = 120
local COMPUTE_POLL_SECONDS = 0.5
local UPDATE_AI_MINIMUM_VERSION = "Lightroom Classic 13.3"

local function requirePhotoId(value)
    if type(value) == "number" then return tostring(value) end
    if type(value) ~= "string" or value == "" then
        error("photo_id is required")
    end
    return value
end

local function requireUpdateAiApi(toolName, photo)
    if type(photo.updateAISettings) ~= "function" then
        error(toolName .. " needs " .. UPDATE_AI_MINIMUM_VERSION .. " or later")
    end
end

local function newestEntries(entries, keepCount)
    local fresh = {}
    for index = keepCount + 1, #entries do fresh[#fresh + 1] = entries[index] end
    return fresh
end

local function stateOf(entry)
    local component = type(entry) == "table" and type(entry.CorrectionMasks) == "table"
        and entry.CorrectionMasks[1] or nil
    if type(component) ~= "table" then return "pending" end
    if type(component.ErrorReason) == "number" and component.ErrorReason ~= 0 then return "failed" end
    if type(component.MaskDigest) == "string" and component.MaskDigest ~= "" then return "computed" end
    return "pending"
end

local function allSettled(fresh, expectedCount)
    if #fresh ~= expectedCount then return false end
    for _, entry in ipairs(fresh) do
        if stateOf(entry) == "pending" then return false end
    end
    return true
end

local function waitForCompute(catalog, photo, keepCount, expectedCount)
    local fresh = {}
    local waited = 0
    while true do
        fresh = newestEntries(GuardedMaskWrite.readEntries(catalog, photo), keepCount)
        if allSettled(fresh, expectedCount) then return fresh, true end
        if waited >= COMPUTE_TIMEOUT_SECONDS then return fresh, false end
        LrTasks.sleep(COMPUTE_POLL_SECONDS)
        waited = waited + COMPUTE_POLL_SECONDS
    end
end

local function removeNewEntries(catalog, photo, keepCount)
    return GuardedMaskWrite.apply(catalog, photo, {
        description = "Remove AI masks",
        build = function(entries)
            for index = #entries, keepCount + 1, -1 do entries[index] = nil end
            return entries
        end,
    })
end

local function failAndRemove(catalog, photo, keepCount, reason)
    local removed, removeError = LrTasks.pcall(removeNewEntries, catalog, photo, keepCount)
    if not removed then
        reason = reason .. "; the new masks could not be removed, check the photo's masks in Develop: "
            .. tostring(removeError)
    end
    error(reason, 0)
end

local function labelOf(request, index)
    return request.specs[index].name
end

local function listNames(request, fresh, wantedState)
    local names = {}
    for index, entry in ipairs(fresh) do
        if stateOf(entry) == wantedState then names[#names + 1] = labelOf(request, index) end
    end
    return table.concat(names, ", ")
end

local function missingMessage(request, photoId, fresh)
    local missing = listNames(request, fresh, "failed")
    if request.kind == "people" then
        return string.format("Lightroom found no %s on any person in photo %s; no mask was left on the photo",
            missing, photoId)
    end
    return string.format("Lightroom found no %s in photo %s; no mask was left on the photo", missing, photoId)
end

local function appendEntries(entries, request)
    for _, spec in ipairs(request.specs) do
        entries[#entries + 1] = AiMaskParts.newEntry(spec, request)
    end
    return entries
end

local function resultFor(photoId, request, fresh)
    local masks = {}
    for index, entry in ipairs(fresh) do
        masks[index] = {
            mask_id = entry.CorrectionID ~= nil and tostring(entry.CorrectionID) or nil,
            [request.kind == "people" and "part" or "category"] = labelOf(request, index),
        }
    end
    local result = {
        success = true,
        photo_id = photoId,
        type = request.kind,
        mask_id = masks[1].mask_id,
        masks = masks,
    }
    return result
end

local function createAiMasks(toolName, args, request)
    local photoId = requirePhotoId(args.photo_id)
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, photoId)
    if not photo then
        error("Photo not found: " .. photoId)
    end
    requireUpdateAiApi(toolName, photo)

    local fresh = DevelopSession.run(toolName, catalog, false, function()
        local previous = GuardedMaskWrite.preflight(catalog, photo)
        local keepCount = #previous
        local expectedCount = #request.specs

        GuardedMaskWrite.apply(catalog, photo, {
            description = "Create AI masks",
            build = function(entries) return appendEntries(entries, request) end,
        })

        local updated, updateError = LrTasks.pcall(function()
            catalog:withWriteAccessDo("Compute AI masks", function() photo:updateAISettings() end)
        end)
        if not updated then
            failAndRemove(catalog, photo, keepCount,
                "Lightroom could not compute the masks: " .. tostring(updateError))
        end

        local computed, settled = waitForCompute(catalog, photo, keepCount, expectedCount)
        if not settled and #computed == expectedCount then
            error(string.format("Lightroom has not finished computing the %s mask after %d seconds, so it"
                .. " was left on photo %s untouched; writing to a photo while Lightroom still computes can"
                .. " freeze Lightroom. Check the photo's masks in Develop before retrying.",
                request.kind, COMPUTE_TIMEOUT_SECONDS, photoId), 0)
        end
        if #computed ~= expectedCount then
            failAndRemove(catalog, photo, keepCount, string.format(
                "Lightroom kept %d of the %d requested masks on photo %s", #computed, expectedCount, photoId))
        end
        if listNames(request, computed, "failed") ~= "" then
            failAndRemove(catalog, photo, keepCount, missingMessage(request, photoId, computed))
        end
        return computed
    end)

    local result = resultFor(photoId, request, fresh)
    Log.info(string.format("Created %d %s mask(s) on photo %s", #fresh, request.kind, photoId))
    return result
end

function AiMaskHandler.createMask(args)
    local request
    if args.type == "people" then
        request = AiMaskParts.parsePeople(args)
    elseif args.type == "landscape" then
        request = AiMaskParts.parseLandscape(args)
    else
        error("type must be people or landscape")
    end
    return createAiMasks("create_mask", args, request)
end

return AiMaskHandler
