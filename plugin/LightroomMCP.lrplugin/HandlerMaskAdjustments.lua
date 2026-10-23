local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local LocalSliders = require 'LocalSliders'
local Log = require 'Log'
local PhotoLookup = require 'PhotoLookup'

local MaskAdjustmentsHandler = {}

local POLL_SECONDS = 0.1
local MASK_LIST_TIMEOUT_SECONDS = 5
local MASK_SELECT_TIMEOUT_SECONDS = 8
local MASK_RESELECT_SECONDS = 1
local MASK_SELECT_SETTLE_SECONDS = 0.3
local WRITE_CONFIRM_TIMEOUT_SECONDS = 2
local WRITE_ATTEMPTS = 2
local WRITE_PERSIST_SETTLE_SECONDS = 0.5

local EXTRA_CONTROLLER_FUNCTIONS = { "setValue", "getValue", "getRange", "getSelectedMask" }

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

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function formatNumber(value)
    return string.format("%g", value)
end

local function requireAdjustments(value)
    if type(value) ~= "table" or next(value) == nil then
        error("adjustments is required: an object of local slider names and numbers")
    end
    for key, amount in pairs(value) do
        if type(key) ~= "string" or not LocalSliders.byName[key] then
            error(string.format("Unknown mask adjustment %s; valid sliders: %s",
                tostring(key), table.concat(LocalSliders.names(), ", ")))
        end
        if not isFiniteNumber(amount) then
            error(key .. " must be a number")
        end
    end
    local requested = {}
    for _, slider in ipairs(LocalSliders.list) do
        if value[slider.name] ~= nil then
            requested[#requested + 1] = { slider = slider, value = value[slider.name] }
        end
    end
    return requested
end

local function requireMaskControls(toolName)
    DevelopSession.requireMaskApi(toolName)
    for _, name in ipairs(EXTRA_CONTROLLER_FUNCTIONS) do
        if type(LrDevelopController[name]) ~= "function" then
            error(toolName .. " needs Lightroom Classic 11 or later")
        end
    end
end

local function listMaskIds()
    local ok, masks = LrTasks.pcall(LrDevelopController.getAllMasks)
    if not ok or type(masks) ~= "table" then return nil end
    local ids = {}
    for _, mask in ipairs(masks) do
        if type(mask) == "table" and type(mask.ID) == "string" then
            ids[#ids + 1] = mask.ID
        end
    end
    return ids
end

local function contains(list, wanted)
    for _, item in ipairs(list) do
        if item == wanted then return true end
    end
    return false
end

local function requireMaskOnPhoto(photoId, maskId)
    local ids
    DevelopSession.waitFor(function()
        ids = listMaskIds()
        return ids ~= nil and (#ids > 0 or contains(ids, maskId))
    end, MASK_LIST_TIMEOUT_SECONDS)
    if ids == nil then
        error("Lightroom could not read the masks of photo " .. photoId)
    end
    if not contains(ids, maskId) then
        error(string.format("Mask not found on photo %s: %s (masks on this photo: %s)",
            photoId, maskId, #ids > 0 and table.concat(ids, ", ") or "none"))
    end
end

local function readSelectedMask()
    local ok, id = LrTasks.pcall(LrDevelopController.getSelectedMask)
    if ok and type(id) == "string" and id ~= "" then return id end
    return nil
end

local function openMaskingPanel()
    if type(LrDevelopController.goToMasking) == "function" then
        LrTasks.pcall(LrDevelopController.goToMasking)
    end
end

local function selectMaskAndWait(maskId)
    local sinceSelect = MASK_RESELECT_SECONDS
    return DevelopSession.waitFor(function()
        if readSelectedMask() == maskId then return true end
        if sinceSelect >= MASK_RESELECT_SECONDS then
            LrTasks.pcall(LrDevelopController.selectMask, maskId)
            sinceSelect = 0
        end
        sinceSelect = sinceSelect + POLL_SECONDS
        return false
    end, MASK_SELECT_TIMEOUT_SECONDS)
end

local function withMaskSelected(photoId, maskId, body)
    requireMaskOnPhoto(photoId, maskId)
    openMaskingPanel()
    local previousMask = readSelectedMask()
    if not selectMaskAndWait(maskId) then
        error("Could not select mask " .. maskId .. " on photo " .. photoId .. " in Develop")
    end
    LrTasks.sleep(MASK_SELECT_SETTLE_SECONDS)

    local ok, result = LrTasks.pcall(body)
    if previousMask and previousMask ~= maskId then
        LrTasks.pcall(LrDevelopController.selectMask, previousMask)
    end
    if not ok then error(result, 0) end
    return result
end

local function readValue(sliderName)
    local ok, value = LrTasks.pcall(LrDevelopController.getValue, sliderName)
    if ok and isFiniteNumber(value) then return value end
    return nil
end

local function liveRange(slider)
    local ok, low, high = LrTasks.pcall(LrDevelopController.getRange, slider.name)
    if ok and isFiniteNumber(low) and isFiniteNumber(high) and low < high then
        return low, high
    end
    return slider.fallbackMin, slider.fallbackMax
end

local function requireInRange(requested)
    local problems = {}
    for _, entry in ipairs(requested) do
        local low, high = liveRange(entry.slider)
        if entry.value < low or entry.value > high then
            problems[#problems + 1] = string.format("%s %s is outside its range %s to %s",
                entry.slider.name, formatNumber(entry.value), formatNumber(low), formatNumber(high))
        end
    end
    if #problems > 0 then
        error("Nothing was written: " .. table.concat(problems, "; "))
    end
end

local function near(slider, actual, wanted)
    return actual ~= nil and math.abs(actual - wanted) <= slider.tolerance
end

local function writeAndConfirm(slider, wanted)
    for _ = 1, WRITE_ATTEMPTS do
        local ok, err = LrTasks.pcall(LrDevelopController.setValue, slider.name, wanted)
        if not ok then
            error(string.format("Lightroom rejected %s %s: %s", slider.name, formatNumber(wanted), tostring(err)), 0)
        end
        local confirmed = DevelopSession.waitFor(function()
            return near(slider, readValue(slider.name), wanted)
        end, WRITE_CONFIRM_TIMEOUT_SECONDS)
        if confirmed then return true end
    end
    return false
end

local function describeWritten(written)
    if #written == 0 then return "no slider had been written yet" end
    return "already written: " .. table.concat(written, ", ")
end

local function failedWrite(slider, wanted, written)
    local actual = readValue(slider.name)
    error(string.format("Lightroom did not keep %s %s (reads %s); %s",
        slider.name, formatNumber(wanted), actual and formatNumber(actual) or "nothing", describeWritten(written)), 0)
end

local function applyToSelectedMask(photoId, maskId, requested)
    requireInRange(requested)

    local before = {}
    for _, entry in ipairs(requested) do
        local current = readValue(entry.slider.name)
        if current == nil then
            error(entry.slider.name .. " is not available on mask " .. maskId .. " of photo " .. photoId
                .. "; nothing was written")
        end
        before[entry.slider.name] = current
    end

    local changed, unchanged, written = {}, {}, {}
    for _, entry in ipairs(requested) do
        local slider, wanted = entry.slider, entry.value
        if near(slider, before[slider.name], wanted) then
            unchanged[#unchanged + 1] = slider.name
        else
            if not writeAndConfirm(slider, wanted) then
                failedWrite(slider, wanted, written)
            end
            written[#written + 1] = slider.name
            changed[#changed + 1] = { slider = slider.name, from = before[slider.name], to = wanted }
        end
    end

    if #changed > 0 then
        LrTasks.sleep(WRITE_PERSIST_SETTLE_SECONDS)
        for _, entry in ipairs(requested) do
            if not near(entry.slider, readValue(entry.slider.name), entry.value) then
                failedWrite(entry.slider, entry.value, written)
            end
        end
        if readSelectedMask() ~= maskId then
            error("Another mask became selected while writing; " .. describeWritten(written), 0)
        end
    end

    local adjustments = {}
    for _, entry in ipairs(requested) do
        adjustments[entry.slider.name] = readValue(entry.slider.name)
    end
    for _, change in ipairs(changed) do
        change.to = adjustments[change.slider]
    end
    return { adjustments = adjustments, changed = changed, unchanged = unchanged }
end

local function readAllSliders()
    local adjustments, unavailable = {}, {}
    for _, slider in ipairs(LocalSliders.list) do
        local value = readValue(slider.name)
        if value == nil then
            unavailable[#unavailable + 1] = slider.name
        else
            adjustments[slider.name] = value
        end
    end
    return { adjustments = adjustments, unavailable = unavailable }
end

local function requireTarget(args)
    return requirePhotoId(args.photo_id), requireMaskId(args.mask_id)
end

local function resolvePhoto(photoId)
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, photoId)
    if not photo then
        error("Photo not found: " .. photoId)
    end
    return catalog, photo
end

function MaskAdjustmentsHandler.setMaskAdjustments(args)
    local photoId, maskId = requireTarget(args)
    local requested = requireAdjustments(args.adjustments)
    requireMaskControls("set_mask_adjustments")
    local catalog, photo = resolvePhoto(photoId)

    local outcome = DevelopSession.withPhoto("set_mask_adjustments", catalog, photo, function()
        return withMaskSelected(photoId, maskId, function()
            return applyToSelectedMask(photoId, maskId, requested)
        end)
    end)

    Log.info(string.format("Mask %s on photo %s: %d sliders changed, %d already at the value",
        maskId, photoId, #outcome.changed, #outcome.unchanged))

    return {
        success = true,
        photo_id = photoId,
        mask_id = maskId,
        adjustments = outcome.adjustments,
        changed = outcome.changed,
        unchanged = outcome.unchanged,
    }
end

function MaskAdjustmentsHandler.getMaskAdjustments(args)
    local photoId, maskId = requireTarget(args)
    requireMaskControls("get_mask_adjustments")
    local catalog, photo = resolvePhoto(photoId)

    local outcome = DevelopSession.withPhoto("get_mask_adjustments", catalog, photo, function()
        return withMaskSelected(photoId, maskId, readAllSliders)
    end)

    Log.info(string.format("Read %d local sliders of mask %s on photo %s",
        #LocalSliders.list - #outcome.unavailable, maskId, photoId))

    return {
        success = true,
        photo_id = photoId,
        mask_id = maskId,
        adjustments = outcome.adjustments,
        unavailable = outcome.unavailable,
    }
end

return MaskAdjustmentsHandler
