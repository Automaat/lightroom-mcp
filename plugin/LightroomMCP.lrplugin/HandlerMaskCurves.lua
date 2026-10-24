local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local Log = require 'Log'
local MaskCurves = require 'MaskCurves'
local MaskSelection = require 'MaskSelection'

local MaskCurvesHandler = {}

local WRITE_CONFIRM_TIMEOUT_SECONDS = 2
local WRITE_ATTEMPTS = 2
local WRITE_PERSIST_SETTLE_SECONDS = 0.5

local CONTROLLER_FUNCTIONS = { "setValue", "getValue" }

local function requireCurveSupport(toolName)
    MaskSelection.requireControllerFunctions(toolName, CONTROLLER_FUNCTIONS, MaskCurves.MINIMUM_VERSION_LABEL)
    MaskSelection.requireVersionAtLeast(toolName, MaskCurves.MINIMUM_MAJOR, MaskCurves.MINIMUM_MINOR,
        MaskCurves.MINIMUM_VERSION_LABEL)
end

local function readCurve(channel)
    local ok, raw = LrTasks.pcall(LrDevelopController.getValue, channel.parameter)
    if not ok then return nil end
    return MaskCurves.normalize(raw)
end

local function unavailableMessage(channelNames, maskId, photoId)
    return string.format("Local tone curve %s of mask %s on photo %s cannot be read; local curves need %s or later",
        table.concat(channelNames, ", "), maskId, photoId, MaskCurves.MINIMUM_VERSION_LABEL)
end

local function writeAndConfirm(channel, wanted)
    for _ = 1, WRITE_ATTEMPTS do
        local ok, err = LrTasks.pcall(LrDevelopController.setValue, channel.parameter, MaskCurves.copy(wanted))
        if not ok then
            error(string.format("Lightroom rejected the %s curve: %s", channel.name, tostring(err)), 0)
        end
        local confirmed = DevelopSession.waitFor(function()
            return MaskCurves.same(readCurve(channel), wanted)
        end, WRITE_CONFIRM_TIMEOUT_SECONDS)
        if confirmed then return true end
    end
    return false
end

local function restoreCurves(written)
    for index = #written, 1, -1 do
        local entry = written[index]
        LrTasks.pcall(LrDevelopController.setValue, entry.channel.parameter, MaskCurves.copy(entry.before))
    end
end

local function describeRestored(written)
    if #written == 0 then return "no curve had been written yet" end
    local names = {}
    for _, entry in ipairs(written) do
        names[#names + 1] = entry.channel.name
    end
    return "restored: " .. table.concat(names, ", ")
end

local function failedWrite(channel, written)
    restoreCurves(written)
    error(string.format("Lightroom did not keep the %s curve; %s", channel.name, describeRestored(written)), 0)
end

local function applyToSelectedMask(photoId, maskId, requested)
    local before, unreadable = {}, {}
    for _, entry in ipairs(requested) do
        local current = readCurve(entry.channel)
        if current == nil then
            unreadable[#unreadable + 1] = entry.channel.name
        end
        before[entry.channel.name] = current
    end
    if #unreadable > 0 then
        error(unavailableMessage(unreadable, maskId, photoId) .. "; nothing was written", 0)
    end

    local changed, unchanged, written = {}, {}, {}
    for _, entry in ipairs(requested) do
        local channel, wanted = entry.channel, entry.points
        if MaskCurves.same(before[channel.name], wanted) then
            unchanged[#unchanged + 1] = channel.name
        else
            written[#written + 1] = { channel = channel, before = before[channel.name] }
            if not writeAndConfirm(channel, wanted) then
                failedWrite(channel, written)
            end
            changed[#changed + 1] = { channel = channel.name, from = before[channel.name], to = wanted }
        end
    end

    if #changed > 0 then
        LrTasks.sleep(WRITE_PERSIST_SETTLE_SECONDS)
        for _, entry in ipairs(requested) do
            if not MaskCurves.same(readCurve(entry.channel), entry.points) then
                failedWrite(entry.channel, written)
            end
        end
        if MaskSelection.readSelectedMask() ~= maskId then
            restoreCurves(written)
            error("Another mask became selected while writing; " .. describeRestored(written), 0)
        end
    end

    local curves = {}
    for _, entry in ipairs(requested) do
        curves[entry.channel.name] = readCurve(entry.channel)
    end
    for _, change in ipairs(changed) do
        change.to = curves[change.channel]
    end
    return { curves = curves, changed = changed, unchanged = unchanged }
end

local function readAllCurves(photoId, maskId)
    local curves, unavailable = {}, {}
    for _, channel in ipairs(MaskCurves.channels) do
        local points = readCurve(channel)
        if points == nil then
            unavailable[#unavailable + 1] = channel.name
        else
            curves[channel.name] = points
        end
    end
    if #unavailable == #MaskCurves.channels then
        error(unavailableMessage(unavailable, maskId, photoId), 0)
    end
    return { curves = curves, unavailable = unavailable }
end

function MaskCurvesHandler.setMaskCurves(args)
    local photoId, maskId = MaskSelection.requireTarget(args)
    local requested = MaskCurves.requireCurves(args.curves)
    requireCurveSupport("set_mask_curves")
    local catalog, photo = MaskSelection.resolvePhoto(photoId)

    local outcome = DevelopSession.withPhoto("set_mask_curves", catalog, photo, function()
        return MaskSelection.withMaskSelected(photoId, maskId, function()
            return applyToSelectedMask(photoId, maskId, requested)
        end)
    end)

    Log.info(string.format("Mask %s on photo %s: %d curves changed, %d already at the value",
        maskId, photoId, #outcome.changed, #outcome.unchanged))

    return {
        success = true,
        photo_id = photoId,
        mask_id = maskId,
        curves = outcome.curves,
        changed = outcome.changed,
        unchanged = outcome.unchanged,
    }
end

function MaskCurvesHandler.getMaskCurves(args)
    local photoId, maskId = MaskSelection.requireTarget(args)
    requireCurveSupport("get_mask_curves")
    local catalog, photo = MaskSelection.resolvePhoto(photoId)

    local outcome = DevelopSession.withPhoto("get_mask_curves", catalog, photo, function()
        return MaskSelection.withMaskSelected(photoId, maskId, function()
            return readAllCurves(photoId, maskId)
        end)
    end)

    Log.info(string.format("Read %d local curves of mask %s on photo %s",
        #MaskCurves.channels - #outcome.unavailable, maskId, photoId))

    return {
        success = true,
        photo_id = photoId,
        mask_id = maskId,
        curves = outcome.curves,
        unavailable = outcome.unavailable,
    }
end

return MaskCurvesHandler
