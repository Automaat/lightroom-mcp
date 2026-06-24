local LrApplication = import 'LrApplication'

local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'

local DevelopHandler = {}

local MAX_BULK_PHOTO_IDS = 1000

local ALLOWED_DEVELOP_SETTING_KEYS = {
    "WhiteBalance",
    "Temperature",
    "Tint",
    "Exposure2012",
    "Contrast2012",
    "Highlights2012",
    "Shadows2012",
    "Whites2012",
    "Blacks2012",
    "Texture",
    "Clarity2012",
    "Dehaze",
    "Vibrance",
    "Saturation",
    "ParametricShadows",
    "ParametricDarks",
    "ParametricLights",
    "ParametricHighlights",
    "ParametricShadowSplit",
    "ParametricMidtoneSplit",
    "ParametricHighlightSplit",
    "ToneCurveName2012",
    "ConvertToGrayscale",
    "Sharpness",
    "SharpenRadius",
    "SharpenDetail",
    "SharpenEdgeMasking",
    "LuminanceSmoothing",
    "LuminanceNoiseReductionDetail",
    "LuminanceNoiseReductionContrast",
    "ColorNoiseReduction",
    "ColorNoiseReductionDetail",
    "ColorNoiseReductionSmoothness",
    "LensProfileEnable",
    "LensManualDistortionAmount",
    "PerspectiveVertical",
    "PerspectiveHorizontal",
    "PerspectiveRotate",
    "PerspectiveScale",
    "PerspectiveAspect",
    "PerspectiveUpright",
    "PostCropVignetteAmount",
    "PostCropVignetteMidpoint",
    "PostCropVignetteRoundness",
    "PostCropVignetteFeather",
    "PostCropVignetteStyle",
    "GrainAmount",
    "GrainSize",
    "GrainFrequency",
    "CropTop",
    "CropLeft",
    "CropBottom",
    "CropRight",
    "CropAngle",
}

local ALLOWED_DEVELOP_SETTING_LOOKUP = {}
for _, key in ipairs(ALLOWED_DEVELOP_SETTING_KEYS) do
    ALLOWED_DEVELOP_SETTING_LOOKUP[key] = true
end

local function requireString(value, name)
    if type(value) ~= "string" or value == "" then
        error(name .. " is required")
    end
end

local function requireStringArray(value, name, maxItems)
    if type(value) ~= "table" then
        error(name .. " is required")
    end

    local count = 0
    for key, item in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            error(name .. " must be an array")
        end
        if type(item) ~= "string" or item == "" then
            error(name .. "[" .. tostring(key) .. "] must be a non-empty string")
        end
        count = count + 1
    end

    if count == 0 then
        error(name .. " is required")
    end
    if count ~= #value then
        error(name .. " must be an array")
    end
    if maxItems and count > maxItems then
        error(name .. " must contain at most " .. tostring(maxItems) .. " items")
    end
end

local function requireAllowedDevelopSettingKey(key)
    if not ALLOWED_DEVELOP_SETTING_LOOKUP[key] then
        error("Unsupported develop setting key: " .. tostring(key))
    end
end

local function requireDevelopSettingValue(key, value)
    local valueType = type(value)
    if valueType ~= "number" and valueType ~= "string" and valueType ~= "boolean" then
        error("Unsupported value for develop setting key: " .. tostring(key))
    end
end

local function requireDevelopSettingsObject(settings)
    if type(settings) ~= "table" then
        error("settings is required")
    end

    local count = 0
    for key, value in pairs(settings) do
        if type(key) ~= "string" then
            error("settings keys must be strings")
        end
        requireAllowedDevelopSettingKey(key)
        requireDevelopSettingValue(key, value)
        count = count + 1
    end

    if count == 0 then
        error("settings is required")
    end
end

local function requireDevelopSettingWhitelist(settings)
    if settings == nil then
        return
    end

    requireStringArray(settings, "settings", #ALLOWED_DEVELOP_SETTING_KEYS)
    for _, key in ipairs(settings) do
        requireAllowedDevelopSettingKey(key)
    end
end

local function findPresetByName(name)
    for _, folder in ipairs(LrApplication.developPresetFolders()) do
        for _, preset in ipairs(folder:getDevelopPresets()) do
            if preset:getName() == name then
                return preset, folder:getName()
            end
        end
    end
    return nil, nil
end

function DevelopHandler.listDevelopPresets(_)
    local out = {}
    for _, folder in ipairs(LrApplication.developPresetFolders()) do
        local fname = folder:getName()
        for _, preset in ipairs(folder:getDevelopPresets()) do
            table.insert(out, { name = preset:getName(), folder = fname })
        end
    end

    Log.info(string.format("Listed %d develop presets", #out))

    return {
        success = true,
        presets = out,
        count = #out,
    }
end

function DevelopHandler.applyDevelopPreset(args)
    requireStringArray(args.photo_ids, "photo_ids", MAX_BULK_PHOTO_IDS)
    requireString(args.preset_name, "preset_name")

    local preset, folder = findPresetByName(args.preset_name)
    if not preset then
        error("Preset not found: " .. args.preset_name)
    end

    local catalog = LrApplication.activeCatalog()
    local appliedCount = 0

    catalog:withWriteAccessDo("Apply Develop Preset", function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                entry.photo:applyDevelopPreset(preset)
                appliedCount = appliedCount + 1
            end
        end
    end)

    Log.info(string.format("Applied preset %s to %d photos", args.preset_name, appliedCount))

    return {
        success = true,
        applied = appliedCount,
        preset = args.preset_name,
        folder = folder,
        message = string.format("Applied preset %s to %d photos", args.preset_name, appliedCount),
    }
end

function DevelopHandler.copyDevelopSettings(args)
    requireString(args.source_id, "source_id")
    requireStringArray(args.target_ids, "target_ids", MAX_BULK_PHOTO_IDS)
    requireDevelopSettingWhitelist(args.settings)

    local catalog = LrApplication.activeCatalog()
    local sourceSettings

    catalog:withReadAccessDo(function()
        local source = PhotoLookup.resolveOne(catalog, args.source_id)
        if not source then
            error("Source photo not found: " .. args.source_id)
        end
        sourceSettings = source:getDevelopSettings()
    end)

    local toApply = sourceSettings
    if args.settings then
        toApply = {}
        for _, key in ipairs(args.settings) do
            toApply[key] = sourceSettings[key]
        end
    end

    local copiedCount = 0

    catalog:withWriteAccessDo("Copy Develop Settings", function()
        local resolved = PhotoLookup.resolveMany(catalog, args.target_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                entry.photo:applyDevelopSettings(toApply)
                copiedCount = copiedCount + 1
            end
        end
    end)

    Log.info(string.format("Copied develop settings from %s to %d photos", args.source_id, copiedCount))

    return {
        success = true,
        copied = copiedCount,
        source = args.source_id,
        message = string.format("Copied develop settings from %s to %d photos", args.source_id, copiedCount),
    }
end

function DevelopHandler.setDevelopSettings(args)
    requireString(args.photo_id, "photo_id")
    requireDevelopSettingsObject(args.settings)

    local catalog = LrApplication.activeCatalog()
    local applied = false

    catalog:withWriteAccessDo("Set Develop Settings", function()
        local photo = PhotoLookup.resolveOne(catalog, args.photo_id)
        if not photo then
            error("Photo not found: " .. args.photo_id)
        end
        photo:applyDevelopSettings(args.settings)
        applied = true
    end)

    Log.info(string.format("Set develop settings on photo %s", args.photo_id))

    return {
        success = applied,
        photo_id = args.photo_id,
    }
end

return DevelopHandler
