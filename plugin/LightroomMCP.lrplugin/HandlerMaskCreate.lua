local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local Log = require 'Log'
local PhotoLookup = require 'PhotoLookup'

local MaskCreateHandler = {}

local MASK_TYPE_NAMES = { "subject", "sky", "background" }
local MASK_TYPES = {
    subject = { toolType = "aiSelection", subtype = "subject" },
    sky = { toolType = "aiSelection", subtype = "sky" },
    background = { toolType = "aiSelection", subtype = "background" },
}

local TWO_DECIMAL_ROUNDING_TOLERANCE = 0.01
local WHOLE_NUMBER_ROUNDING_TOLERANCE = 0.5
local WRITE_CONFIRM_TIMEOUT_SECONDS = 2

local ADJUSTMENTS = {
    { name = "exposure", param = "local_Exposure", min = -4, max = 4, tolerance = TWO_DECIMAL_ROUNDING_TOLERANCE },
    { name = "contrast", param = "local_Contrast", min = -100, max = 100, tolerance = WHOLE_NUMBER_ROUNDING_TOLERANCE },
    { name = "highlights", param = "local_Highlights", min = -100, max = 100, tolerance = WHOLE_NUMBER_ROUNDING_TOLERANCE },
    { name = "shadows", param = "local_Shadows", min = -100, max = 100, tolerance = WHOLE_NUMBER_ROUNDING_TOLERANCE },
    { name = "whites", param = "local_Whites", min = -100, max = 100, tolerance = WHOLE_NUMBER_ROUNDING_TOLERANCE },
    { name = "blacks", param = "local_Blacks", min = -100, max = 100, tolerance = WHOLE_NUMBER_ROUNDING_TOLERANCE },
    { name = "texture", param = "local_Texture", min = -100, max = 100, tolerance = WHOLE_NUMBER_ROUNDING_TOLERANCE },
    { name = "clarity", param = "local_Clarity", min = -100, max = 100, tolerance = WHOLE_NUMBER_ROUNDING_TOLERANCE },
    { name = "dehaze", param = "local_Dehaze", min = -100, max = 100, tolerance = WHOLE_NUMBER_ROUNDING_TOLERANCE },
    { name = "temperature", param = "local_Temperature", min = -100, max = 100, tolerance = WHOLE_NUMBER_ROUNDING_TOLERANCE },
    { name = "tint", param = "local_Tint", min = -100, max = 100, tolerance = WHOLE_NUMBER_ROUNDING_TOLERANCE },
    { name = "saturation", param = "local_Saturation", min = -100, max = 100, tolerance = WHOLE_NUMBER_ROUNDING_TOLERANCE },
    { name = "sharpness", param = "local_Sharpness", min = -100, max = 100, tolerance = WHOLE_NUMBER_ROUNDING_TOLERANCE },
    { name = "noise", param = "local_LuminanceNoise", min = -100, max = 100, tolerance = WHOLE_NUMBER_ROUNDING_TOLERANCE },
}

local ADJUSTMENT_BY_NAME = {}
local ADJUSTMENT_NAMES = {}
for _, adjustment in ipairs(ADJUSTMENTS) do
    ADJUSTMENT_BY_NAME[adjustment.name] = adjustment
    ADJUSTMENT_NAMES[#ADJUSTMENT_NAMES + 1] = adjustment.name
end

local REQUIRED_API_FUNCTIONS = { "createNewMask", "deleteMask", "selectMask", "selectTool", "setValue" }
local MASK_API_MINIMUM_VERSION = "Lightroom Classic 11"

local MASK_READ_TIMEOUT_SECONDS = 5
local AI_DETECTION_TIMEOUT_SECONDS = 30
local MASK_STABLE_POLLS = 10
local HISTORY_GROUPING_SECONDS = 10
local DEFAULT_TRACKING_DELAY_SECONDS = 2
local DEFAULT_GROUPING_THRESHOLD_SECONDS = 0.5
local MASKING_TOOL = "masking"
local NOTHING_FOUND_PREFIX = "Lightroom found no "

local function requirePhotoId(value)
    if type(value) == "number" then return tostring(value) end
    if type(value) ~= "string" or value == "" then
        error("photo_id is required")
    end
    return value
end

local function requireMaskType(value)
    local spec = type(value) == "string" and MASK_TYPES[value] or nil
    if not spec then
        error("type must be one of: " .. table.concat(MASK_TYPE_NAMES, ", "))
    end
    return value, spec
end

local function formatNumber(value)
    return string.format("%g", value)
end

local function validateAdjustments(adjustments)
    if adjustments == nil then return {} end
    if type(adjustments) ~= "table" then
        error("adjustments must be an object of slider names to numbers")
    end
    local values = {}
    for key, value in pairs(adjustments) do
        local adjustment = type(key) == "string" and ADJUSTMENT_BY_NAME[key] or nil
        if not adjustment then
            error("Unknown adjustment " .. tostring(key) .. "; valid sliders: "
                .. table.concat(ADJUSTMENT_NAMES, ", "))
        end
        if type(value) ~= "number" or value ~= value then
            error(adjustment.name .. " must be a number between "
                .. formatNumber(adjustment.min) .. " and " .. formatNumber(adjustment.max))
        end
        if value < adjustment.min or value > adjustment.max then
            error(adjustment.name .. " must be between " .. formatNumber(adjustment.min)
                .. " and " .. formatNumber(adjustment.max) .. " (got " .. formatNumber(value) .. ")")
        end
        values[adjustment.name] = value
    end
    return values
end

local function requireCreateApi(toolName)
    toolName = toolName or "create_mask"
    DevelopSession.requireMaskApi(toolName)
    for _, name in ipairs(REQUIRED_API_FUNCTIONS) do
        if type(LrDevelopController[name]) ~= "function" then
            error(toolName .. " needs " .. MASK_API_MINIMUM_VERSION .. " or later")
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

local function idSet(masks)
    local ids = {}
    for _, mask in ipairs(masks) do
        local id = type(mask) == "table" and idString(mask.ID)
        if id then ids[id] = true end
    end
    return ids
end

local function masksNotIn(masks, knownIds)
    local fresh = {}
    for _, mask in ipairs(masks) do
        local id = type(mask) == "table" and idString(mask.ID)
        if id and not knownIds[id] then fresh[#fresh + 1] = mask end
    end
    return fresh
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

local function readMasksBeforeCreating(catalog, photo, photoId)
    local expectedCount = maskCountInSettings(catalog, photo)
    local masks
    local ready = DevelopSession.waitFor(function()
        masks = readMasksOrNil()
        return masks ~= nil and (#masks > 0 or expectedCount == 0)
    end, MASK_READ_TIMEOUT_SECONDS)
    if not ready then
        error("Lightroom could not read the existing masks of photo " .. photoId
            .. "; no mask was created")
    end
    return masks
end

local function awaitNewMask(knownIds)
    local fresh, stablePolls = {}, 0
    local settled = DevelopSession.waitFor(function()
        local masks = readMasksOrNil()
        fresh = masks and masksNotIn(masks, knownIds) or {}
        if #fresh == 1 and #toolsOf(fresh[1]) > 0 then
            stablePolls = stablePolls + 1
        else
            stablePolls = 0
        end
        return stablePolls >= MASK_STABLE_POLLS
    end, AI_DETECTION_TIMEOUT_SECONDS)
    return settled and fresh[1] or nil
end

local function removeNewMasks(knownIds)
    local masks = readMasksOrNil()
    if not masks then return {} end
    local leftovers = {}
    for _, mask in ipairs(masksNotIn(masks, knownIds)) do
        local removed = LrTasks.pcall(LrDevelopController.deleteMask, mask.ID)
        if not removed then leftovers[#leftovers + 1] = mask.ID end
    end
    return leftovers
end

local function describeFailure(typeName, photoId, knownIds)
    local masks = readMasksOrNil() or {}
    local fresh = masksNotIn(masks, knownIds)
    if #fresh > 1 then
        return string.format("Lightroom added %d masks while creating the %s mask on photo %s",
            #fresh, typeName, photoId)
    end
    if #fresh == 1 then
        return string.format("Lightroom created an empty %s mask on photo %s", typeName, photoId)
    end
    return string.format(NOTHING_FOUND_PREFIX .. "%s to select on photo %s; Lightroom shows an alert such as"
        .. " \"No %s detected\" for this, so click OK in Lightroom before the next Develop call",
        typeName, photoId, typeName)
end

local function setHistoryGrouping(seconds, trackingSeconds)
    LrTasks.pcall(LrDevelopController.setTrackingDelay, trackingSeconds)
    LrTasks.pcall(LrDevelopController.setMultipleAdjustmentThreshold, seconds)
end

local function writeNeutralAdjustments(maskId, values)
    LrDevelopController.selectMask(maskId)
    setHistoryGrouping(HISTORY_GROUPING_SECONDS, HISTORY_GROUPING_SECONDS)
    local ok, err = LrTasks.pcall(function()
        for _, adjustment in ipairs(ADJUSTMENTS) do
            LrDevelopController.setValue(adjustment.param, values[adjustment.name] or 0)
        end
    end)
    LrTasks.pcall(LrDevelopController.stopTracking, true)
    setHistoryGrouping(DEFAULT_GROUPING_THRESHOLD_SECONDS, DEFAULT_TRACKING_DELAY_SECONDS)
    if not ok then error(err, 0) end
end

local function confirmAdjustments(values)
    for _, adjustment in ipairs(ADJUSTMENTS) do
        local wanted = values[adjustment.name]
        if wanted ~= nil then
            local function readsWanted()
                local ok, actual = LrTasks.pcall(LrDevelopController.getValue, adjustment.param)
                return ok and type(actual) == "number" and math.abs(actual - wanted) <= adjustment.tolerance
            end
            if not DevelopSession.waitFor(readsWanted, WRITE_CONFIRM_TIMEOUT_SECONDS) then
                local ok, actual = LrTasks.pcall(LrDevelopController.getValue, adjustment.param)
                error(string.format("Lightroom did not keep %s %s (reads %s)", adjustment.name,
                    formatNumber(wanted), ok and type(actual) == "number" and formatNumber(actual) or "nothing"), 0)
            end
        end
    end
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

local function normalizeMask(mask)
    local tools = {}
    for _, tool in ipairs(toolsOf(mask)) do
        tools[#tools + 1] = {
            id = idString(tool.ID),
            type = scalarOrNil(tool.Type),
            subtype = scalarOrNil(tool.Subtype),
            inverted = tool.Inverted == true,
        }
    end
    return {
        id = idString(mask.ID),
        name = scalarOrNil(mask.Name),
        hidden = mask.Hidden == true,
        tools = tools,
    }
end

local function findMask(masks, id)
    for _, mask in ipairs(masks or {}) do
        if type(mask) == "table" and mask.ID == id then return mask end
    end
    return nil
end

local function createInDevelop(catalog, photo, photoId, typeName, spec, values)
    local existing = readMasksBeforeCreating(catalog, photo, photoId)
    local knownIds = idSet(existing)
    local previousTool = currentToolOrNil()
    LrDevelopController.selectTool(MASKING_TOOL)

    local created
    local ok, err = LrTasks.pcall(function()
        LrDevelopController.createNewMask(spec.toolType, spec.subtype)
        created = awaitNewMask(knownIds)
        if not created then error(describeFailure(typeName, photoId, knownIds), 0) end
        writeNeutralAdjustments(created.ID, values)
        confirmAdjustments(values)
    end)

    if not ok then
        local failure = tostring(err)
        local leftovers = removeNewMasks(knownIds)
        restoreTool(previousTool)
        if #leftovers > 0 then
            failure = failure .. "; could not remove the new mask " .. table.concat(leftovers, ", ")
        end
        error(failure, 0)
    end
    restoreTool(previousTool)

    local after = readMasksOrNil()
    for id in pairs(knownIds) do
        if after and not findMask(after, id) then
            Log.warn(string.format("create_mask: mask %s on photo %s is missing after creating %s",
                id, photoId, created.ID))
        end
    end
    return findMask(after, created.ID) or created
end

MaskCreateHandler.requireMaskType = requireMaskType
MaskCreateHandler.validateAdjustments = validateAdjustments
MaskCreateHandler.requireCreateApi = requireCreateApi
MaskCreateHandler.createInDevelop = createInDevelop
MaskCreateHandler.normalizeMask = normalizeMask

function MaskCreateHandler.isNothingFoundFailure(message)
    return type(message) == "string" and message:find(NOTHING_FOUND_PREFIX, 1, true) ~= nil
end

function MaskCreateHandler.createMask(args)
    local photoId = requirePhotoId(args.photo_id)
    local typeName, spec = requireMaskType(args.type)
    local values = validateAdjustments(args.adjustments)
    requireCreateApi()

    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, photoId)
    if not photo then
        error("Photo not found: " .. photoId)
    end

    local created = DevelopSession.withPhoto("create_mask", catalog, photo, function()
        return createInDevelop(catalog, photo, photoId, typeName, spec, values)
    end)

    local mask = normalizeMask(created)
    Log.info(string.format("Created %s mask %s on photo %s", typeName, tostring(mask.id), photoId))

    local result = {
        success = true,
        photo_id = photoId,
        type = typeName,
        mask_id = mask.id,
        mask = mask,
    }
    if next(values) then
        result.adjustments = values
    end
    return result
end

return MaskCreateHandler
