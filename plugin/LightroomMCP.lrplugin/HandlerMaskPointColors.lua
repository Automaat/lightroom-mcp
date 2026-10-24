local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local Log = require 'Log'
local MaskPointColors = require 'MaskPointColors'
local MaskSelection = require 'MaskSelection'

local MaskPointColorsHandler = {}

local LOCAL_POINT_COLORS = "local_PointColors"
local FOR_MASKING = true
local CHANGE_TIMEOUT_SECONDS = 3
local SELECT_TIMEOUT_SECONDS = 4
local RESELECT_SECONDS = 1
local POLL_SECONDS = 0.1
local UPDATE_ATTEMPTS = 2
local PERSIST_SETTLE_SECONDS = 0.5

local ACTIONS = { "add", "update", "delete", "clear" }
local ACTION_LOOKUP = {}
for _, action in ipairs(ACTIONS) do ACTION_LOOKUP[action] = true end

local READ_CONTROLLER_FUNCTIONS = { "getValue", "getSelectedPointColorSwatchIndex" }
local EDIT_CONTROLLER_FUNCTIONS = {
    "getValue",
    "getSelectedPointColorSwatchIndex",
    "selectPointColorSwatch",
    "addPointColorSwatch",
    "updateSelectedPointColorSwatch",
    "deletePointColorSwatch",
}

local function requireSupport(toolName, functionNames)
    MaskSelection.requireControllerFunctions(toolName, functionNames, MaskPointColors.MINIMUM_VERSION_LABEL)
    MaskSelection.requireVersionAtLeast(toolName, MaskPointColors.MINIMUM_MAJOR, MaskPointColors.MINIMUM_MINOR,
        MaskPointColors.MINIMUM_VERSION_LABEL)
end

local function requireIndex(value, action)
    if type(value) ~= "number" or value ~= math.floor(value) or value < 1
        or value > MaskPointColors.MAX_SWATCHES then
        error(string.format("index is required for %s: a whole number from 1 to %d", action,
            MaskPointColors.MAX_SWATCHES))
    end
    return value
end

local function requireRequest(args)
    local action = args.action
    if type(action) ~= "string" or not ACTION_LOOKUP[action] then
        error("action is required: one of " .. table.concat(ACTIONS, ", "))
    end
    local request = { action = action }
    if action == "add" then
        MaskPointColors.requireSwatch(args.swatch, "swatch", true)
        request.swatch = args.swatch
        if args.index ~= nil then error("index is not used by add") end
    elseif action == "update" then
        MaskPointColors.requireSwatch(args.swatch, "swatch", false)
        request.swatch = args.swatch
        request.index = requireIndex(args.index, action)
    elseif action == "delete" then
        request.index = requireIndex(args.index, action)
        if args.swatch ~= nil then error("swatch is not used by delete") end
    else
        if args.index ~= nil or args.swatch ~= nil then error("clear takes no index or swatch") end
    end
    return request
end

local function readSwatches()
    local ok, raw = LrTasks.pcall(LrDevelopController.getValue, LOCAL_POINT_COLORS)
    if not ok then
        error(string.format("Lightroom could not read local Point Color swatches (%s); they need %s or later",
            tostring(raw), MaskPointColors.MINIMUM_VERSION_LABEL), 0)
    end
    return MaskPointColors.normalizeList(raw)
end

local function readSelectedIndex()
    local ok, index = LrTasks.pcall(LrDevelopController.getSelectedPointColorSwatchIndex, FOR_MASKING)
    if ok and type(index) == "number" then return index end
    return nil
end

local function selectSwatchAndWait(index)
    local sinceSelect = RESELECT_SECONDS
    return DevelopSession.waitFor(function()
        if readSelectedIndex() == index then return true end
        if sinceSelect >= RESELECT_SECONDS then
            LrTasks.pcall(LrDevelopController.selectPointColorSwatch, index, FOR_MASKING)
            sinceSelect = 0
        end
        sinceSelect = sinceSelect + POLL_SECONDS
        return false
    end, SELECT_TIMEOUT_SECONDS)
end

local function restoreSelection(previousIndex, count)
    if previousIndex and previousIndex >= 1 and previousIndex <= count
        and readSelectedIndex() ~= previousIndex then
        LrTasks.pcall(LrDevelopController.selectPointColorSwatch, previousIndex, FOR_MASKING)
    end
end

local function callController(label, name, ...)
    local called, succeeded, message = LrTasks.pcall(LrDevelopController[name], ...)
    if not called then
        error(string.format("Lightroom rejected %s: %s", label, tostring(succeeded)), 0)
    end
    if succeeded ~= true then
        error(string.format("Lightroom refused %s: %s", label, tostring(message or "no reason given")), 0)
    end
end

local function waitForCount(expected)
    return DevelopSession.waitFor(function()
        return #readSwatches() == expected
    end, CHANGE_TIMEOUT_SECONDS)
end

local function listHolds(actual, expected)
    if #actual ~= #expected then return false end
    for index = 1, #expected do
        if not MaskPointColors.holds(actual[index], expected[index]) then return false end
    end
    return true
end

local function confirmPersisted(expected, maskId, what)
    LrTasks.sleep(PERSIST_SETTLE_SECONDS)
    if not listHolds(readSwatches(), expected) then
        error("Lightroom did not keep " .. what, 0)
    end
    if MaskSelection.readSelectedMask() ~= maskId then
        error("Another mask became selected while writing " .. what, 0)
    end
end

local function copyList(swatches)
    local copied = {}
    for index, swatch in ipairs(swatches) do copied[index] = MaskPointColors.copySwatch(swatch) end
    return copied
end

local function findNewIndex(after, swatch)
    for index = #after, 1, -1 do
        if MaskPointColors.sameSource(after[index], swatch) then return index end
    end
    return nil
end

local function addSwatch(request, maskId)
    local before = readSwatches()
    if #before >= MaskPointColors.MAX_SWATCHES then
        error(string.format("Mask %s already holds %d Point Color swatches, the most Lightroom allows",
            maskId, MaskPointColors.MAX_SWATCHES))
    end
    local previousIndex = readSelectedIndex()
    callController("the new Point Color swatch", "addPointColorSwatch", request.swatch, FOR_MASKING)
    if not waitForCount(#before + 1) then
        local existing = findNewIndex(before, request.swatch)
        if existing then
            error(string.format("Mask %s already has a swatch with that source color at index %d; nothing was added",
                maskId, existing), 0)
        end
        error("Lightroom did not add the Point Color swatch to mask " .. maskId, 0)
    end

    local after = readSwatches()
    local index = findNewIndex(after, request.swatch)
    if index == nil or not MaskPointColors.holds(after[index], request.swatch) then
        if index then
            LrTasks.pcall(LrDevelopController.deletePointColorSwatch, false, index, FOR_MASKING)
        end
        error("Lightroom did not keep the Point Color swatch values; the new swatch was removed", 0)
    end

    local expected = copyList(before)
    table.insert(expected, index, MaskPointColors.copySwatch(after[index]))
    confirmPersisted(expected, maskId, "the new Point Color swatch")
    restoreSelection(previousIndex, #before)
    return { index = index, changed = true }
end

local function updateSwatch(request, maskId)
    local before = readSwatches()
    local index = request.index
    if index > #before then
        error(string.format("No swatch at index %d on mask %s (the mask has %d)", index, maskId, #before))
    end
    local previousIndex = readSelectedIndex()
    if not selectSwatchAndWait(index) then
        error(string.format("Could not select Point Color swatch %d on mask %s", index, maskId), 0)
    end

    local original = before[index]
    local merged = MaskPointColors.merge(original, request.swatch)
    if MaskPointColors.holds(original, merged) then
        restoreSelection(previousIndex, #before)
        return { index = index, changed = false }
    end

    local kept = false
    for _ = 1, UPDATE_ATTEMPTS do
        callController("the Point Color swatch update", "updateSelectedPointColorSwatch",
            MaskPointColors.copySwatch(merged), FOR_MASKING)
        kept = DevelopSession.waitFor(function()
            local now = readSwatches()
            return #now == #before and MaskPointColors.holds(now[index], merged)
        end, CHANGE_TIMEOUT_SECONDS)
        if kept then break end
    end
    if not kept then
        LrTasks.pcall(LrDevelopController.updateSelectedPointColorSwatch,
            MaskPointColors.copySwatch(original), FOR_MASKING)
        error(string.format("Lightroom did not keep the update of swatch %d; the original values were restored", index), 0)
    end

    local expected = copyList(before)
    expected[index] = merged
    confirmPersisted(expected, maskId, string.format("the update of swatch %d", index))
    restoreSelection(previousIndex, #before)
    return { index = index, changed = true }
end

local function deleteSwatch(request, maskId)
    local before = readSwatches()
    local index = request.index
    if index > #before then
        error(string.format("No swatch at index %d on mask %s (the mask has %d)", index, maskId, #before))
    end
    local previousIndex = readSelectedIndex()
    callController("the Point Color swatch deletion", "deletePointColorSwatch", false, index, FOR_MASKING)
    if not waitForCount(#before - 1) then
        error(string.format("Lightroom did not delete swatch %d of mask %s", index, maskId), 0)
    end

    local expected = copyList(before)
    table.remove(expected, index)
    confirmPersisted(expected, maskId, string.format("the deletion of swatch %d", index))
    local newPrevious = previousIndex
    if previousIndex and previousIndex > index then newPrevious = previousIndex - 1 end
    restoreSelection(newPrevious, #expected)
    return { index = index, changed = true }
end

local function clearSwatches(_, maskId)
    local before = readSwatches()
    if #before == 0 then return { changed = false } end
    callController("clearing the Point Color swatches", "deletePointColorSwatch", true, 1, FOR_MASKING)
    if not waitForCount(0) then
        error("Lightroom did not clear the Point Color swatches of mask " .. maskId, 0)
    end
    confirmPersisted({}, maskId, "the cleared Point Color swatches")
    return { changed = true }
end

local EDIT = {
    add = addSwatch,
    update = updateSwatch,
    delete = deleteSwatch,
    clear = clearSwatches,
}

function MaskPointColorsHandler.editMaskPointColors(args)
    local photoId, maskId = MaskSelection.requireTarget(args)
    local request = requireRequest(args)
    requireSupport("edit_mask_point_colors", EDIT_CONTROLLER_FUNCTIONS)
    local catalog, photo = MaskSelection.resolvePhoto(photoId)

    local outcome = DevelopSession.withPhoto("edit_mask_point_colors", catalog, photo, function()
        return MaskSelection.withMaskSelected(photoId, maskId, function()
            local result = EDIT[request.action](request, maskId)
            result.swatches = MaskPointColors.indexed(readSwatches())
            return result
        end)
    end)

    Log.info(string.format("Point Color %s on mask %s of photo %s: %d swatches now",
        request.action, maskId, photoId, #outcome.swatches))

    return {
        success = true,
        photo_id = photoId,
        mask_id = maskId,
        action = request.action,
        index = outcome.index,
        changed = outcome.changed,
        swatches = outcome.swatches,
    }
end

function MaskPointColorsHandler.getMaskPointColors(args)
    local photoId, maskId = MaskSelection.requireTarget(args)
    requireSupport("get_mask_point_colors", READ_CONTROLLER_FUNCTIONS)
    local catalog, photo = MaskSelection.resolvePhoto(photoId)

    local swatches = DevelopSession.withPhoto("get_mask_point_colors", catalog, photo, function()
        return MaskSelection.withMaskSelected(photoId, maskId, function()
            return MaskPointColors.indexed(readSwatches())
        end)
    end)

    Log.info(string.format("Read %d Point Color swatches of mask %s on photo %s", #swatches, maskId, photoId))

    return {
        success = true,
        photo_id = photoId,
        mask_id = maskId,
        swatches = swatches,
    }
end

return MaskPointColorsHandler
