local LrApplication = import 'LrApplication'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

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
    "SaturationAdjustmentRed",
    "SaturationAdjustmentOrange",
    "SaturationAdjustmentYellow",
    "SaturationAdjustmentGreen",
    "SaturationAdjustmentAqua",
    "SaturationAdjustmentBlue",
    "SaturationAdjustmentPurple",
    "SaturationAdjustmentMagenta",
    "HueAdjustmentRed",
    "HueAdjustmentOrange",
    "HueAdjustmentYellow",
    "HueAdjustmentGreen",
    "HueAdjustmentAqua",
    "HueAdjustmentBlue",
    "HueAdjustmentPurple",
    "HueAdjustmentMagenta",
    "LuminanceAdjustmentRed",
    "LuminanceAdjustmentOrange",
    "LuminanceAdjustmentYellow",
    "LuminanceAdjustmentGreen",
    "LuminanceAdjustmentAqua",
    "LuminanceAdjustmentBlue",
    "LuminanceAdjustmentPurple",
    "LuminanceAdjustmentMagenta",
    "ParametricShadows",
    "ParametricDarks",
    "ParametricLights",
    "ParametricHighlights",
    "ParametricShadowSplit",
    "ParametricMidtoneSplit",
    "ParametricHighlightSplit",
    "ToneCurveName2012",
    "ToneCurvePV2012",
    "ToneCurvePV2012Red",
    "ToneCurvePV2012Green",
    "ToneCurvePV2012Blue",
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

local CURVE_DEVELOP_SETTING_LOOKUP = {
    ToneCurvePV2012 = true,
    ToneCurvePV2012Red = true,
    ToneCurvePV2012Green = true,
    ToneCurvePV2012Blue = true,
}

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
    if CURVE_DEVELOP_SETTING_LOOKUP[key] and valueType == "table" then
        local count = 0
        for index, coordinate in pairs(value) do
            if type(index) ~= "number" or index < 1 or index ~= math.floor(index) then
                error("Curve setting " .. tostring(key) .. " must be a numeric array")
            end
            if type(coordinate) ~= "number" then
                error("Curve setting " .. tostring(key) .. " must contain only numbers")
            end
            count = count + 1
        end
        if count < 4 or count > 512 or count ~= #value or count % 2 ~= 0 then
            error("Curve setting " .. tostring(key) .. " must contain 2-256 coordinate pairs")
        end
        return
    end
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

local function callPresetMethod(preset, methodName)
    local method = preset and preset[methodName]
    if type(method) ~= "function" then
        return nil
    end
    local ok, value = pcall(method, preset)
    if not ok then
        return nil
    end
    return value
end

local function presetEntry(preset, folder, scope)
    return {
        preset = preset,
        name = callPresetMethod(preset, "getName"),
        folder = folder,
        scope = scope,
        uuid = callPresetMethod(preset, "getUuid"),
        file = callPresetMethod(preset, "getFile"),
    }
end

local function allDevelopPresetEntries()
    local entries = {}
    for _, folder in ipairs(LrApplication.developPresetFolders()) do
        for _, preset in ipairs(folder:getDevelopPresets()) do
            table.insert(entries, presetEntry(preset, folder:getName(), "lightroom"))
        end
    end

    if _PLUGIN and type(LrApplication.getDevelopPresetsForPlugin) == "function" then
        local pluginPresets = LrApplication.getDevelopPresetsForPlugin(_PLUGIN) or {}
        for _, preset in ipairs(pluginPresets) do
            table.insert(entries, presetEntry(preset, "Plugin Develop Presets", "plugin"))
        end
    end

    return entries
end

local function presetSummary(entry)
    return {
        name = entry.name,
        folder = entry.folder,
        scope = entry.scope,
        uuid = entry.uuid,
        file = entry.file,
    }
end

local function requirePresetSelector(args)
    if type(args) ~= "table" then
        error("preset selector is required")
    end
    local hasName = type(args.preset_name) == "string" and args.preset_name ~= ""
    local hasUuid = type(args.preset_uuid) == "string" and args.preset_uuid ~= ""
    if not hasName and not hasUuid then
        error("preset_name or preset_uuid is required")
    end
    if args.preset_folder ~= nil then requireString(args.preset_folder, "preset_folder") end
    if args.preset_scope ~= nil and args.preset_scope ~= "lightroom" and args.preset_scope ~= "plugin" then
        error("preset_scope must be lightroom or plugin")
    end
end

local function findPreset(args)
    requirePresetSelector(args)
    local matches = {}
    for _, entry in ipairs(allDevelopPresetEntries()) do
        local uuidMatches = args.preset_uuid == nil or entry.uuid == args.preset_uuid
        local nameMatches = args.preset_name == nil or entry.name == args.preset_name
        local folderMatches = args.preset_folder == nil or entry.folder == args.preset_folder
        local scopeMatches = args.preset_scope == nil or entry.scope == args.preset_scope
        if uuidMatches and nameMatches and folderMatches and scopeMatches then
            table.insert(matches, entry)
        end
    end
    if #matches == 0 then
        error("Preset not found")
    end
    -- Lightroom can expose the same preset more than once (for example, as a
    -- favourite and in its original group). Those aliases share one UUID, so
    -- a UUID selector is still exact even when the flattened folder list has
    -- multiple entries for it.
    if #matches > 1 and args.preset_uuid ~= nil then
        return matches[1]
    end
    if #matches > 1 then
        error("Preset selector is ambiguous; provide preset_uuid or preset_folder")
    end
    return matches[1]
end

local function cloneSerializable(value, depth, seen)
    local valueType = type(value)
    if valueType == "number" or valueType == "string" or valueType == "boolean" then
        return value, true
    end
    if valueType ~= "table" or depth >= 6 or seen[value] then
        return nil, false
    end

    seen[value] = true
    local out = {}
    local count = 0
    for key, item in pairs(value) do
        if type(key) ~= "string" and type(key) ~= "number" then
            seen[value] = nil
            return nil, false
        end
        count = count + 1
        if count > 2000 then
            seen[value] = nil
            return nil, false
        end
        local cloned, supported = cloneSerializable(item, depth + 1, seen)
        if not supported then
            seen[value] = nil
            return nil, false
        end
        out[key] = cloned
    end
    seen[value] = nil
    return out, true
end

local function normalizedPresetSettings(preset)
    local settings = callPresetMethod(preset, "getSetting")
    if type(settings) ~= "table" then
        error("Preset settings are unavailable")
    end
    local normalized, supported = cloneSerializable(settings, 0, {})
    if not supported then
        error("Preset settings contain unsupported nested values")
    end
    return normalized
end

local function deepEqual(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do
        if not deepEqual(value, right[key]) then return false end
    end
    for key, _ in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

local function sortedSettingKeys(settings)
    local keys = {}
    for key, _ in pairs(settings) do table.insert(keys, key) end
    table.sort(keys)
    return keys
end

function DevelopHandler.listDevelopPresets(_)
    local out = {}
    for _, entry in ipairs(allDevelopPresetEntries()) do
        table.insert(out, presetSummary(entry))
    end

    Log.info(string.format("Listed %d develop presets", #out))

    return {
        success = true,
        presets = out,
        count = #out,
    }
end

function DevelopHandler.getDevelopPreset(args)
    local entry = findPreset(args)
    local settings = normalizedPresetSettings(entry.preset)
    local result = presetSummary(entry)
    result.success = true
    result.settings = settings
    result.setting_count = #sortedSettingKeys(settings)
    return result
end

function DevelopHandler.compareDevelopPresets(args)
    if type(args.base) ~= "table" or type(args.candidate) ~= "table" then
        error("base and candidate preset selectors are required")
    end
    local base = findPreset(args.base)
    local candidate = findPreset(args.candidate)
    local baseSettings = normalizedPresetSettings(base.preset)
    local candidateSettings = normalizedPresetSettings(candidate.preset)
    local keys = {}
    for key, _ in pairs(baseSettings) do keys[key] = true end
    for key, _ in pairs(candidateSettings) do keys[key] = true end

    local keyList = {}
    for key, _ in pairs(keys) do table.insert(keyList, key) end
    table.sort(keyList)

    local changes = {}
    for _, key in ipairs(keyList) do
        local before = baseSettings[key]
        local after = candidateSettings[key]
        if not deepEqual(before, after) then
            local change = {
                key = key,
                before_present = before ~= nil,
                after_present = after ~= nil,
            }
            if before ~= nil then change.before = before end
            if after ~= nil then change.after = after end
            table.insert(changes, change)
        end
    end

    return {
        success = true,
        base = presetSummary(base),
        candidate = presetSummary(candidate),
        changes = changes,
        changed_count = #changes,
    }
end

function DevelopHandler.createDevelopPreset(args)
    requireString(args.photo_id, "photo_id")
    requireString(args.preset_name, "preset_name")
    requireStringArray(args.settings, "settings", #ALLOWED_DEVELOP_SETTING_KEYS)
    requireDevelopSettingWhitelist(args.settings)

    if not _PLUGIN or type(LrApplication.addDevelopPresetForPlugin) ~= "function" then
        error("Plugin preset creation is unavailable")
    end
    for _, entry in ipairs(allDevelopPresetEntries()) do
        if entry.scope == "plugin" and entry.name == args.preset_name then
            error("Plugin preset already exists; use a versioned preset_name")
        end
    end

    local catalog = LrApplication.activeCatalog()
    local sourceSettings
    catalog:withReadAccessDo(function()
        local photo = PhotoLookup.resolveOne(catalog, args.photo_id)
        if not photo then
            error("Photo not found: " .. args.photo_id)
        end
        sourceSettings = photo:getDevelopSettings()
    end)

    local presetSettings = {}
    for _, key in ipairs(args.settings) do
        local value = sourceSettings[key]
        if value == nil then
            error("Source photo has no develop setting: " .. key)
        end
        requireDevelopSettingValue(key, value)
        presetSettings[key] = value
    end

    local preset = LrApplication.addDevelopPresetForPlugin(_PLUGIN, args.preset_name, presetSettings)
    if not preset then error("Lightroom did not create the plugin preset") end
    local entry = presetEntry(preset, "Plugin Develop Presets", "plugin")
    local result = presetSummary(entry)
    result.success = true
    result.source_photo_id = args.photo_id
    result.settings = args.settings
    result.visible_in_develop = false
    result.message = "Created plugin-managed Develop preset checkpoint"
    Log.info(string.format("Created plugin preset %s from photo %s", args.preset_name, args.photo_id))
    return result
end

local function requireLeafFilename(filename)
    requireString(filename, "filename")
    if filename == "." or filename == ".." or LrPathUtils.leafName(filename) ~= filename then
        error("filename must be a leaf filename without path separators")
    end
end

function DevelopHandler.exportDevelopPreset(args)
    requireString(args.destination_dir, "destination_dir")
    local entry = findPreset(args)
    local source = entry.file
    if type(source) ~= "string" or source == "" or LrFileUtils.exists(source) ~= "file" then
        error("Preset has no exportable backing file")
    end

    local sourceExtension = LrPathUtils.extension(source)
    if type(sourceExtension) ~= "string" or sourceExtension == "" then
        error("Preset backing file has no extension")
    end
    local filename = args.filename or LrPathUtils.leafName(source)
    requireLeafFilename(filename)
    local requestedExtension = LrPathUtils.extension(filename)
    if requestedExtension == "" then
        filename = filename .. "." .. sourceExtension
    elseif requestedExtension:lower() ~= sourceExtension:lower() then
        error("filename extension must match preset backing file: ." .. sourceExtension)
    end

    if LrFileUtils.exists(args.destination_dir) == false then
        LrFileUtils.createAllDirectories(args.destination_dir)
    end
    if LrFileUtils.exists(args.destination_dir) ~= "directory" then
        error("destination_dir is not a directory")
    end

    local destination = LrPathUtils.child(args.destination_dir, filename)
    if LrFileUtils.exists(destination) then
        error("destination preset already exists; choose a new filename")
    end
    local copied, copyError = LrFileUtils.copy(source, destination)
    if not copied then
        error("Preset export failed: " .. tostring(copyError))
    end

    local result = presetSummary(entry)
    result.success = true
    result.destination = destination
    result.message = "Exported Develop preset without overwriting existing files"
    Log.info(string.format("Exported preset %s to %s", tostring(entry.name), destination))
    return result
end

function DevelopHandler.applyDevelopPreset(args)
    requireStringArray(args.photo_ids, "photo_ids", MAX_BULK_PHOTO_IDS)
    local selectedPreset = findPreset(args)

    local catalog = LrApplication.activeCatalog()
    local appliedCount = 0

    catalog:withWriteAccessDo("Apply Develop Preset", function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, resolvedEntry in ipairs(resolved) do
            if resolvedEntry.photo then
                if selectedPreset.scope == "plugin" then
                    resolvedEntry.photo:applyDevelopPreset(selectedPreset.preset, _PLUGIN)
                else
                    resolvedEntry.photo:applyDevelopPreset(selectedPreset.preset)
                end
                appliedCount = appliedCount + 1
            end
        end
    end)

    Log.info(string.format("Applied preset %s to %d photos", selectedPreset.name, appliedCount))

    return {
        success = true,
        applied = appliedCount,
        preset = selectedPreset.name,
        folder = selectedPreset.folder,
        scope = selectedPreset.scope,
        uuid = selectedPreset.uuid,
        message = string.format("Applied preset %s to %d photos", selectedPreset.name, appliedCount),
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
