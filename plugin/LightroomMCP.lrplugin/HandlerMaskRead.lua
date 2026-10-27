local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local MaskSelection = require 'MaskSelection'
local Adjustments = require 'HandlerMaskAdjustments'
local Curves = require 'HandlerMaskCurves'
local PointColors = require 'HandlerMaskPointColors'

local MaskReadHandler = {}

local KINDS = { "adjustments", "curves", "point_colors" }
local READERS = {
    adjustments = { major = 11, minor = 0, label = "Lightroom Classic 11",
        functions = { "getValue", "getSelectedMask" }, read = Adjustments.readSelected },
    curves = { major = 12, minor = 3, label = "Lightroom Classic 12.3",
        functions = { "getValue", "getSelectedMask" }, read = Curves.readSelected },
    point_colors = { major = 13, minor = 2, label = "Lightroom Classic 13.2",
        functions = { "getValue", "getSelectedMask", "getSelectedPointColorSwatchIndex" }, read = PointColors.readSelected },
}

local function requireKinds(value)
    if value == nil then return KINDS end
    if type(value) ~= "table" or #value == 0 then
        error("kinds must be a nonempty array of adjustments, curves or point_colors", 0)
    end
    local seen, count = {}, 0
    for key, kind in pairs(value) do
        if type(key) ~= "number" or key < 1 or key > #value or key ~= math.floor(key)
            or type(kind) ~= "string" or not READERS[kind] or seen[kind] then
            error("kinds must contain unique adjustments, curves or point_colors entries", 0)
        end
        seen[kind] = true
        count = count + 1
    end
    if count ~= #value then error("kinds must be an array without gaps", 0) end
    local ordered = {}
    for _, kind in ipairs(KINDS) do
        if seen[kind] then ordered[#ordered + 1] = kind end
    end
    return ordered
end

local function errorsMessage(errors)
    local messages = {}
    for _, kind in ipairs(KINDS) do
        if errors[kind] then messages[#messages + 1] = kind .. ": " .. errors[kind] end
    end
    return table.concat(messages, "; ")
end

function MaskReadHandler.getMask(args)
    local photoId, maskId = MaskSelection.requireTarget(args)
    local kinds = requireKinds(args.kinds)
    local supported, errors = {}, {}
    for _, kind in ipairs(kinds) do
        local reader = READERS[kind]
        local ok, err = LrTasks.pcall(function()
            MaskSelection.requireControllerFunctions("get_mask " .. kind, reader.functions, reader.label)
            MaskSelection.requireVersionAtLeast("get_mask " .. kind, reader.major, reader.minor, reader.label)
        end)
        if ok then supported[#supported + 1] = kind else errors[kind] = tostring(err) end
    end
    if #supported == 0 then error(errorsMessage(errors), 0) end
    local catalog, photo = MaskSelection.resolvePhoto(photoId)
    return DevelopSession.withPhoto("get_mask", catalog, photo, function()
        return MaskSelection.withMaskSelected(photoId, maskId, function()
            local result = { success = true, photo_id = photoId, mask_id = maskId }
            local completed = 0
            for _, kind in ipairs(supported) do
                local ok, values = LrTasks.pcall(READERS[kind].read, photoId, maskId)
                if ok then
                    for key, value in pairs(values) do
                        if key == "unavailable" then
                            result.unavailable = result.unavailable or {}
                            result.unavailable[kind] = value
                        else
                            result[key] = value
                        end
                    end
                    completed = completed + 1
                else
                    errors[kind] = tostring(values)
                end
            end
            if completed == 0 then error(errorsMessage(errors), 0) end
            if next(errors) then result.errors = errors end
            return result
        end)
    end)
end

return MaskReadHandler
