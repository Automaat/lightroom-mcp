local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local LocalSliders = require 'LocalSliders'
local MaskSelection = require 'MaskSelection'

local MaskCreationAdjustments = {}

local SLIDERS = {
    exposure = { sdk = "local_Exposure", field = "LocalExposure2012", scale = 4 },
    contrast = { sdk = "local_Contrast", field = "LocalContrast2012", scale = 100 },
    highlights = { sdk = "local_Highlights", field = "LocalHighlights2012", scale = 100 },
    shadows = { sdk = "local_Shadows", field = "LocalShadows2012", scale = 100 },
    whites = { sdk = "local_Whites", field = "LocalWhites2012", scale = 100 },
    blacks = { sdk = "local_Blacks", field = "LocalBlacks2012", scale = 100 },
    texture = { sdk = "local_Texture", field = "LocalTexture", scale = 100 },
    clarity = { sdk = "local_Clarity", field = "LocalClarity2012", scale = 100 },
    dehaze = { sdk = "local_Dehaze", field = "LocalDehaze", scale = 100 },
    temperature = { sdk = "local_Temperature", field = "LocalTemperature", scale = 100 },
    tint = { sdk = "local_Tint", field = "LocalTint", scale = 100 },
    saturation = { sdk = "local_Saturation", field = "LocalSaturation", scale = 100 },
    sharpness = { sdk = "local_Sharpness", field = "LocalSharpness", scale = 100 },
    noise = { sdk = "local_LuminanceNoise", field = "LocalLuminanceNoise", scale = 100 },
}

function MaskCreationAdjustments.parse(args)
    if args.adjustments == nil then return nil end
    if args.mask_id ~= nil then
        error("adjustments applies to a new mask; omit mask_id to preserve an existing mask's sliders", 0)
    end
    if type(args.adjustments) ~= "table" or next(args.adjustments) == nil then
        error("adjustments must be a non-empty object of slider names and numbers", 0)
    end
    local requested = {}
    for name, value in pairs(args.adjustments) do
        local spec = SLIDERS[name]
        if spec == nil then error("Unknown adjustments slider: " .. tostring(name), 0) end
        local slider = LocalSliders.byName[spec.sdk]
        if type(value) ~= "number" or value ~= value or value < slider.fallbackMin or value > slider.fallbackMax then
            error(string.format("adjustments.%s must be a number from %s to %s",
                name, slider.fallbackMin, slider.fallbackMax), 0)
        end
        requested[#requested + 1] = { name = name, spec = spec, slider = slider, value = value }
    end
    table.sort(requested, function(left, right) return left.name < right.name end)
    MaskSelection.requireControllerFunctions("mask creation adjustments",
        { "getValue", "getRange", "getSelectedMask" }, "Lightroom Classic 11")
    return requested
end

function MaskCreationAdjustments.write(entry, requested)
    for _, item in ipairs(requested or {}) do
        entry[item.spec.field] = item.value / item.spec.scale
    end
end

function MaskCreationAdjustments.requireLiveRanges(requested)
    for _, item in ipairs(requested or {}) do
        local ok, low, high = LrTasks.pcall(LrDevelopController.getRange, item.spec.sdk)
        if ok and type(low) == "number" and type(high) == "number"
            and (item.value < low or item.value > high) then
            error("adjustments." .. item.name .. " is outside Lightroom's slider range; nothing was written", 0)
        end
    end
end

function MaskCreationAdjustments.confirm(photoId, maskId, requested)
    if requested == nil then return end
    MaskSelection.withMaskSelected(photoId, tostring(maskId), function()
        for _, item in ipairs(requested) do
            local confirmed = DevelopSession.waitFor(function()
                local read, value = LrTasks.pcall(LrDevelopController.getValue, item.spec.sdk)
                return read and type(value) == "number"
                    and math.abs(value - item.value) <= item.slider.tolerance
            end, 2)
            if not confirmed then
                error("Lightroom did not keep adjustments." .. item.name .. " within its slider tolerance", 0)
            end
        end
    end)
end

return MaskCreationAdjustments
