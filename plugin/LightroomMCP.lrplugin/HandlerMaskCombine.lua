local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local Log = require 'Log'
local MaskTypes = require 'MaskTypes'
local PhotoLookup = require 'PhotoLookup'

local MaskCombineHandler = {}

local OPERATION_NAMES = { "add", "subtract", "intersect" }
local SDK_FUNCTION_OF_OPERATION = {
    add = "addToCurrentMask",
    subtract = "subtractFromCurrentMask",
    intersect = "intersectWithCurrentMask",
}
local VERB_OF_OPERATION = {
    add = "add to",
    subtract = "subtract from",
    intersect = "intersect with",
}

local MASKING_TOOL = "masking"
local MASK_READ_TIMEOUT_SECONDS = 5
local SELECT_TIMEOUT_SECONDS = 8
local RESELECT_SECONDS = 1
local POLL_SECONDS = 0.1
local COMPONENT_DETECTION_TIMEOUT_SECONDS = 30
local COMPONENT_STABLE_POLLS = 10

local function requirePhotoId(value)
    if type(value) == "number" then return tostring(value) end
    if type(value) ~= "string" or value == "" then
        error("photo_id is required")
    end
    return value
end

local function requireMaskId(value)
    if type(value) ~= "string" or value == "" then
        error("mask_id is required")
    end
    return value
end

local function requireOperation(value)
    if type(value) ~= "string" or not SDK_FUNCTION_OF_OPERATION[value] then
        error("operation must be one of: " .. table.concat(OPERATION_NAMES, ", "))
    end
    return value
end

local function requireCombineApi(operation)
    DevelopSession.requireMaskApi("combine_mask")
    local needed = { "selectTool", "getSelectedMask", SDK_FUNCTION_OF_OPERATION[operation] }
    for _, name in ipairs(needed) do
        if type(LrDevelopController[name]) ~= "function" then
            error("combine_mask needs Lightroom Classic 11 or later")
        end
    end
end

local function idString(value)
    if type(value) == "string" and value ~= "" then return value end
    return nil
end

local function scalarOrNil(value)
    local valueType = type(value)
    if valueType == "string" or valueType == "number" or valueType == "boolean" then return value end
    return nil
end

local function readMasksOrNil()
    local ok, result = LrTasks.pcall(LrDevelopController.getAllMasks)
    if not ok then return nil end
    if type(result) ~= "table" then return {} end
    return result
end

local function toolsOf(mask)
    local tools = type(mask) == "table" and mask.Tools
    if type(tools) ~= "table" then return {} end
    return tools
end

local function findMask(masks, maskId)
    for _, mask in ipairs(masks or {}) do
        if type(mask) == "table" and mask.ID == maskId then return mask end
    end
    return nil
end

local function toolIdSet(mask)
    local ids = {}
    for _, tool in ipairs(toolsOf(mask)) do
        local id = type(tool) == "table" and idString(tool.ID)
        if id then ids[id] = true end
    end
    return ids
end

local function toolsNotIn(mask, knownToolIds)
    local fresh = {}
    for _, tool in ipairs(toolsOf(mask)) do
        local id = type(tool) == "table" and idString(tool.ID)
        if id and not knownToolIds[id] then fresh[#fresh + 1] = tool end
    end
    return fresh
end

local function fingerprint(value)
    if type(value) ~= "table" then return tostring(value) end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = tostring(key) .. "=" .. fingerprint(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function maskCountInSettings(catalog, photo)
    local count = 0
    catalog:withReadAccessDo(function()
        local settings = photo:getDevelopSettings()
        local groups = type(settings) == "table" and settings.MaskGroupBasedCorrections
        if type(groups) == "table" then count = #groups end
    end)
    return count
end

local function readTargetMask(catalog, photo, photoId, maskId)
    local expectedCount = maskCountInSettings(catalog, photo)
    local masks
    local ready = DevelopSession.waitFor(function()
        masks = readMasksOrNil()
        return masks ~= nil and (#masks > 0 or expectedCount == 0)
    end, MASK_READ_TIMEOUT_SECONDS)
    if not ready then
        error("Lightroom could not read the masks of photo " .. photoId .. "; nothing was changed", 0)
    end
    local target = findMask(masks, maskId)
    if not target then
        error("Mask not found on photo " .. photoId .. ": " .. maskId, 0)
    end
    return target
end

local function readSelectedMask()
    local ok, id = LrTasks.pcall(LrDevelopController.getSelectedMask)
    if ok and type(id) == "string" and id ~= "" then return id end
    return nil
end

local function selectMaskAndWait(maskId)
    local sinceSelect = RESELECT_SECONDS
    return DevelopSession.waitFor(function()
        if readSelectedMask() == maskId then return true end
        if sinceSelect >= RESELECT_SECONDS then
            LrTasks.pcall(LrDevelopController.selectMask, maskId)
            sinceSelect = 0
        end
        sinceSelect = sinceSelect + POLL_SECONDS
        return false
    end, SELECT_TIMEOUT_SECONDS)
end

local function currentToolOrNil()
    if type(LrDevelopController.getSelectedTool) ~= "function" then return nil end
    local ok, tool = LrTasks.pcall(LrDevelopController.getSelectedTool)
    if ok and type(tool) == "string" then return tool end
    return nil
end

local function restoreTool(previousTool)
    if previousTool and previousTool ~= MASKING_TOOL then
        LrTasks.pcall(LrDevelopController.selectTool, previousTool)
    end
end

local function restoreSelectedMask(previousMask, targetMaskId)
    if previousMask and previousMask ~= targetMaskId then
        LrTasks.pcall(LrDevelopController.selectMask, previousMask)
    end
end

local function awaitNewComponents(maskId, knownToolIds)
    local fresh, stablePolls, lastCount = {}, 0, 0
    local settled = DevelopSession.waitFor(function()
        local target = findMask(readMasksOrNil(), maskId)
        fresh = target and toolsNotIn(target, knownToolIds) or {}
        if #fresh > 0 and #fresh == lastCount then
            stablePolls = stablePolls + 1
        else
            stablePolls = 0
        end
        lastCount = #fresh
        return stablePolls >= COMPONENT_STABLE_POLLS
    end, COMPONENT_DETECTION_TIMEOUT_SECONDS)
    if not settled then return nil end
    return fresh
end

local function describeNothingFound(typeName, operation, photoId, maskId, fingerprintBefore)
    local target = findMask(readMasksOrNil(), maskId)
    local alertAdvice = string.format("Lightroom shows an alert such as \"No %s detected\" for this,"
        .. " so click OK in Lightroom before the next Develop call", typeName)
    if target and fingerprint(target) ~= fingerprintBefore then
        return string.format("Lightroom changed mask %s on photo %s without adding a %s component (%s)",
            maskId, photoId, typeName, operation)
    end
    local state = target and "mask " .. maskId .. " is unchanged"
        or "Lightroom lists no masks while the alert is open, so check mask " .. maskId .. " with list_masks afterwards"
    return string.format("Lightroom found no %s to %s mask %s on photo %s; %s; %s",
        typeName, VERB_OF_OPERATION[operation], maskId, photoId, alertAdvice, state)
end

local function combineComponent(photoId, maskId, operation, typeName, spec, target)
    local knownToolIds = toolIdSet(target)
    local fingerprintBefore = fingerprint(target)

    local previousTool = currentToolOrNil()
    LrDevelopController.selectTool(MASKING_TOOL)
    local previousMask = readSelectedMask()

    local ok, outcome = LrTasks.pcall(function()
        if not selectMaskAndWait(maskId) then
            error("Could not select mask " .. maskId .. " on photo " .. photoId
                .. " in Develop; nothing was changed", 0)
        end
        local functionName = SDK_FUNCTION_OF_OPERATION[operation]
        local called, callError = LrTasks.pcall(LrDevelopController[functionName], spec.toolType, spec.subtype)
        if not called then
            error("Lightroom could not run " .. functionName .. " on mask " .. maskId .. ": " .. tostring(callError), 0)
        end
        local fresh = awaitNewComponents(maskId, knownToolIds)
        if not fresh then
            error(describeNothingFound(typeName, operation, photoId, maskId, fingerprintBefore), 0)
        end
        if #fresh > 1 then
            error(string.format("Lightroom added %d components to mask %s on photo %s while one %s component"
                .. " was expected; check the mask with list_masks", #fresh, maskId, photoId, typeName), 0)
        end
        return fresh[1]
    end)

    restoreSelectedMask(previousMask, maskId)
    restoreTool(previousTool)
    if not ok then error(outcome, 0) end

    return outcome, findMask(readMasksOrNil(), maskId)
end

local function normalizeTool(tool)
    return {
        id = idString(tool.ID),
        type = scalarOrNil(tool.Type),
        subtype = scalarOrNil(tool.Subtype),
        inverted = tool.Inverted == true,
    }
end

local function normalizeMask(mask)
    local tools = {}
    for _, tool in ipairs(toolsOf(mask)) do
        tools[#tools + 1] = normalizeTool(tool)
    end
    return {
        id = idString(mask.ID),
        name = scalarOrNil(mask.Name),
        hidden = mask.Hidden == true,
        tools = tools,
    }
end

function MaskCombineHandler.combineMask(args)
    local photoId = requirePhotoId(args.photo_id)
    local maskId = requireMaskId(args.mask_id)
    local operation = requireOperation(args.operation)
    local typeName, spec = MaskTypes.require(args.type)
    requireCombineApi(operation)

    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, photoId)
    if not photo then
        error("Photo not found: " .. photoId)
    end

    local result = DevelopSession.withPhoto("combine_mask", catalog, photo, function()
        local target = readTargetMask(catalog, photo, photoId, maskId)
        local component, after = combineComponent(photoId, maskId, operation, typeName, spec, target)
        return { component = component, mask = after }
    end)

    local component = normalizeTool(result.component)
    Log.info(string.format("Combined mask %s on photo %s (%s %s) -> component %s",
        maskId, photoId, operation, typeName, tostring(component.id)))

    local response = {
        success = true,
        photo_id = photoId,
        mask_id = maskId,
        operation = operation,
        type = typeName,
        tool_id = component.id,
        tool = component,
    }
    if result.mask then
        response.mask = normalizeMask(result.mask)
    end
    return response
end

return MaskCombineHandler
