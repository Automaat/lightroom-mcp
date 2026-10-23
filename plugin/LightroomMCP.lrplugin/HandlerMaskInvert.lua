local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local Log = require 'Log'
local PhotoLookup = require 'PhotoLookup'

local MaskInvertHandler = {}

local MASK_READ_TIMEOUT_SECONDS = 5
local INVERSION_VISIBLE_TIMEOUT_SECONDS = 5
local INVERT_API_FUNCTIONS = { "goToMasking", "invertMask", "duplicateAndInvertMask" }
local INVERT_API_MINIMUM_VERSION = "Lightroom Classic 11.4"
local SELECT_TIMEOUT_SECONDS = 8
local RESELECT_SECONDS = 1
local POLL_SECONDS = 0.1
local COPY_CONFIRM_TIMEOUT_SECONDS = 2
local TWO_DECIMAL_ROUNDING_TOLERANCE = 0.01
local WHOLE_NUMBER_ROUNDING_TOLERANCE = 0.5
local COPIED_SLIDERS = {
    "local_Exposure", "local_Contrast", "local_Highlights", "local_Shadows", "local_Whites",
    "local_Blacks", "local_Texture", "local_Clarity", "local_Dehaze", "local_Temperature",
    "local_Tint", "local_Saturation", "local_Sharpness", "local_LuminanceNoise", "local_Moire",
    "local_Defringe",
}
local MODE_IN_PLACE = "in_place"
local MODE_COPY = "copy"

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

local function requireMode(value)
    if value ~= MODE_IN_PLACE and value ~= MODE_COPY then
        error("mode must be \"" .. MODE_IN_PLACE .. "\" or \"" .. MODE_COPY .. "\"")
    end
    return value
end

local function requireInvertApi()
    DevelopSession.requireMaskApi("invert_mask")
    for _, name in ipairs(INVERT_API_FUNCTIONS) do
        if type(LrDevelopController[name]) ~= "function" then
            error("invert_mask needs " .. INVERT_API_MINIMUM_VERSION .. " or later")
        end
    end
end

local function idString(value)
    if type(value) == "string" and value ~= "" then return value end
    return nil
end

local function readAllMasks(photoId)
    local masks, lastError
    local read = DevelopSession.waitFor(function()
        local ok, result = LrTasks.pcall(LrDevelopController.getAllMasks)
        if ok then
            masks = result
            return true
        end
        lastError = result
        return false
    end, MASK_READ_TIMEOUT_SECONDS)
    if not read then
        error("Lightroom could not read the masks of photo " .. photoId .. ": " .. tostring(lastError))
    end
    return masks or {}
end

local function findMask(masks, maskId)
    for _, mask in ipairs(masks) do
        if type(mask) == "table" and mask.ID == maskId then return mask end
    end
    return nil
end

local function idsOf(masks)
    local ids = {}
    for _, mask in ipairs(masks) do
        local id = type(mask) == "table" and idString(mask.ID)
        if id then ids[id] = true end
    end
    return ids
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

local function describeMask(mask)
    local tools = {}
    if type(mask.Tools) == "table" then
        for _, tool in ipairs(mask.Tools) do
            if type(tool) == "table" then
                tools[#tools + 1] = { id = idString(tool.ID), inverted = tool.Inverted == true }
            end
        end
    end
    return { id = mask.ID, name = type(mask.Name) == "string" and mask.Name or nil, tools = tools }
end

local function requireMaskOnPhoto(masks, maskId, photoId)
    local mask = findMask(masks, maskId)
    if not mask then
        error("Mask not found on photo " .. photoId .. ": " .. maskId)
    end
    return mask
end

local function callInvertFunction(name, maskId)
    LrDevelopController.goToMasking()
    local ok, result = LrTasks.pcall(LrDevelopController[name], maskId)
    if not ok then
        error("Lightroom could not run " .. name .. " on mask " .. maskId .. ": " .. tostring(result), 0)
    end
    if result == false then
        error("Lightroom refused " .. name .. " on mask " .. maskId, 0)
    end
end

local function invertInPlace(photoId, maskId)
    local before = requireMaskOnPhoto(readAllMasks(photoId), maskId, photoId)
    local fingerprintBefore = fingerprint(before)

    callInvertFunction("invertMask", maskId)

    local after
    local changed = DevelopSession.waitFor(function()
        after = findMask(readAllMasks(photoId), maskId)
        return after ~= nil and fingerprint(after) ~= fingerprintBefore
    end, INVERSION_VISIBLE_TIMEOUT_SECONDS)
    if not changed then
        error("Lightroom did not report mask " .. maskId .. " on photo " .. photoId
            .. " as changed after invertMask; the inversion may not have been saved", 0)
    end
    return {
        mode = MODE_IN_PLACE,
        mask_id = maskId,
        mask = describeMask(after),
    }
end

local function newMaskIds(knownIds, masksAfter)
    local fresh = {}
    for _, mask in ipairs(masksAfter) do
        local id = type(mask) == "table" and idString(mask.ID)
        if id and not knownIds[id] then fresh[#fresh + 1] = id end
    end
    return fresh
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

local function readSliderValue(name)
    local ok, value = LrTasks.pcall(LrDevelopController.getValue, name)
    if ok and type(value) == "number" and value == value then return value end
    return nil
end

local function toleranceOf(name)
    if name == "local_Exposure" then return TWO_DECIMAL_ROUNDING_TOLERANCE end
    return WHOLE_NUMBER_ROUNDING_TOLERANCE
end

local function readSliderValues()
    local values = {}
    for _, name in ipairs(COPIED_SLIDERS) do
        values[name] = readSliderValue(name)
    end
    return values
end

local function copyAdjustments(values, copyId)
    if not selectMaskAndWait(copyId) then
        error("Could not select the inverted copy " .. copyId, 0)
    end
    local copied = 0
    for _, name in ipairs(COPIED_SLIDERS) do
        local wanted = values[name]
        if wanted ~= nil and math.abs(wanted) > toleranceOf(name) then
            LrDevelopController.setValue(name, wanted)
            local kept = DevelopSession.waitFor(function()
                local actual = readSliderValue(name)
                return actual ~= nil and math.abs(actual - wanted) <= toleranceOf(name)
            end, COPY_CONFIRM_TIMEOUT_SECONDS)
            if not kept then
                error(string.format("Lightroom did not keep %s %g on the copy", name, wanted), 0)
            end
            copied = copied + 1
        end
    end
    return copied
end

local function invertAsCopy(photoId, maskId)
    local masksBefore = readAllMasks(photoId)
    local original = requireMaskOnPhoto(masksBefore, maskId, photoId)
    local originalFingerprint = fingerprint(original)
    local idsBefore = idsOf(masksBefore)

    LrDevelopController.goToMasking()
    local previousMask = readSelectedMask()
    if not selectMaskAndWait(maskId) then
        error("Could not select mask " .. maskId .. " on photo " .. photoId .. " in Develop", 0)
    end
    local originalValues = readSliderValues()

    callInvertFunction("duplicateAndInvertMask", maskId)

    local masksAfter
    local fresh = {}
    local copyAppeared = DevelopSession.waitFor(function()
        masksAfter = readAllMasks(photoId)
        fresh = newMaskIds(idsBefore, masksAfter)
        return #fresh > 0
    end, INVERSION_VISIBLE_TIMEOUT_SECONDS)
    if not copyAppeared then
        error("Lightroom did not create an inverted copy of mask " .. maskId .. " on photo " .. photoId, 0)
    end
    if #fresh > 1 then
        error("Lightroom created " .. #fresh .. " new masks on photo " .. photoId
            .. " while copying mask " .. maskId .. "; cannot tell which is the copy", 0)
    end

    local originalAfter = findMask(masksAfter, maskId)
    if not originalAfter or fingerprint(originalAfter) ~= originalFingerprint then
        Log.warn(string.format("invert_mask copy of %s changed the original mask on photo %s", maskId, photoId))
    end

    local copyId = fresh[1]
    local copiedOk, copiedCount = LrTasks.pcall(copyAdjustments, originalValues, copyId)
    if not copiedOk then
        local removed = LrTasks.pcall(LrDevelopController.deleteMask, copyId)
        error(string.format("Lightroom does not copy the local adjustments to an inverted copy and they could"
            .. " not be copied (%s); %s", tostring(copiedCount),
            removed and "the copy was removed" or "remove the copy " .. copyId .. " in Develop"), 0)
    end
    if previousMask and previousMask ~= copyId then
        LrTasks.pcall(LrDevelopController.selectMask, previousMask)
    end

    return {
        mode = MODE_COPY,
        source_mask_id = maskId,
        mask_id = copyId,
        adjustments_copied = copiedCount,
        mask = describeMask(findMask(readAllMasks(photoId), copyId)),
    }
end

function MaskInvertHandler.invertMask(args)
    local photoId = requirePhotoId(args.photo_id)
    local maskId = requireMaskId(args.mask_id)
    local mode = requireMode(args.mode)
    requireInvertApi()

    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, photoId)
    if not photo then
        error("Photo not found: " .. photoId)
    end

    local result = DevelopSession.withPhoto("invert_mask", catalog, photo, function()
        if mode == MODE_COPY then return invertAsCopy(photoId, maskId) end
        return invertInPlace(photoId, maskId)
    end)

    Log.info(string.format("Inverted mask %s on photo %s (%s) -> %s", maskId, photoId, mode, result.mask_id))

    result.success = true
    result.photo_id = photoId
    return result
end

return MaskInvertHandler
