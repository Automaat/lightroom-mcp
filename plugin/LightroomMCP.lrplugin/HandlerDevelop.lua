local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
local LrDevelopController = import 'LrDevelopController'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local AIMaskData = require 'AIMaskData'
local PhotoLookup = require 'PhotoLookup'
local DevelopSession = require 'DevelopSession'
local Log = require 'Log'
local JSON = require 'JSON'

local DevelopHandler = {}

local MAX_BULK_PHOTO_IDS = 1000
local MAX_POINT_CURVE_VALUES = 64

local POINT_CURVE_SETTING_KEYS = {
    "ToneCurvePV2012",
    "ToneCurvePV2012Red",
    "ToneCurvePV2012Green",
    "ToneCurvePV2012Blue",
}

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
    "ToneCurvePV2012",
    "ToneCurvePV2012Red",
    "ToneCurvePV2012Green",
    "ToneCurvePV2012Blue",
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

local POINT_CURVE_SETTING_LOOKUP = {}
for _, key in ipairs(POINT_CURVE_SETTING_KEYS) do
    POINT_CURVE_SETTING_LOOKUP[key] = true
end

local function requireString(value, name)
    if type(value) ~= "string" or value == "" then
        error(name .. " is required")
    end
end

-- Photo ids leave the catalog as numbers (localIdentifier), so a caller feeding
-- search/selection output back in sends numbers. PhotoLookup normalizes with
-- tostring; only these validators used to reject them, which surfaced as a
-- misleading "photo_id is required".
local function requirePhotoId(value, name)
    if type(value) == "number" then
        return tostring(value)
    end
    requireString(value, name)
    return value
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

local function requirePhotoIdArray(value, name, maxItems)
    if type(value) ~= "table" then
        error(name .. " is required")
    end

    local normalized = {}
    local count = 0
    local maxIndex = 0
    for key, item in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            error(name .. " must be an array")
        end
        if type(item) == "number" then
            normalized[key] = tostring(item)
        elseif type(item) == "string" and item ~= "" then
            normalized[key] = item
        else
            error(name .. "[" .. tostring(key) .. "] must be a photo id or file path")
        end
        count = count + 1
        if key > maxIndex then maxIndex = key end
    end

    if count == 0 then
        error(name .. " is required")
    end
    if count ~= maxIndex then
        error(name .. " must be an array")
    end
    if maxItems and count > maxItems then
        error(name .. " must contain at most " .. tostring(maxItems) .. " items")
    end

    return normalized
end

local function requireAllowedDevelopSettingKey(key)
    if not ALLOWED_DEVELOP_SETTING_LOOKUP[key] then
        error("Unsupported develop setting key: " .. tostring(key))
    end
end

local function requirePointCurve(value, name)
    if type(value) ~= "table" then
        error(name .. " must be an array of input/output number pairs")
    end

    local count = 0
    for index, item in pairs(value) do
        if type(index) ~= "number" or index < 1 or index ~= math.floor(index) then
            error(name .. " must be an array")
        end
        if type(item) ~= "number" or item < 0 or item > 255 or item ~= math.floor(item) then
            error(name .. "[" .. tostring(index) .. "] must be an integer from 0 to 255")
        end
        count = count + 1
    end

    if count ~= #value then
        error(name .. " must be an array")
    end
    if count < 4 or count > MAX_POINT_CURVE_VALUES or count % 2 ~= 0 then
        error(name .. " must contain 2 to 32 input/output pairs")
    end
    if value[1] ~= 0 or value[count - 1] ~= 255 then
        error(name .. " must start at input 0 and end at input 255")
    end

    local previousInput = nil
    for index = 1, count, 2 do
        local input = value[index]
        if previousInput ~= nil and input <= previousInput then
            error(name .. " input values must be strictly increasing")
        end
        previousInput = input
    end
end

local function requireDevelopSettingValue(key, value)
    if POINT_CURVE_SETTING_LOOKUP[key] then
        requirePointCurve(value, key)
        return
    end

    local valueType = type(value)
    if valueType ~= "number" and valueType ~= "string" and valueType ~= "boolean" then
        error("Unsupported value for develop setting key: " .. tostring(key))
    end
end

local function requireCapturedSettingValue(key, value)
    local valueType = type(value)
    if valueType == "number" or valueType == "string" or valueType == "boolean" then
        return
    end
    if POINT_CURVE_SETTING_LOOKUP[key] and valueType == "table" then
        local count = 0
        for index, item in pairs(value) do
            if type(index) ~= "number" or index < 1 or index ~= math.floor(index) then
                error("Develop setting " .. tostring(key) .. " is not a capturable array")
            end
            if type(item) ~= "number" then
                error("Develop setting " .. tostring(key) .. " must contain only numbers")
            end
            count = count + 1
        end
        if count ~= #value or count % 2 ~= 0 or count < 4 or count > MAX_POINT_CURVE_VALUES then
            error("Develop setting " .. tostring(key) .. " is not a capturable point curve")
        end
        return
    end
    error("Unsupported value for develop setting key: " .. tostring(key))
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

local function sharesOneUuid(matches)
    local uuid = matches[1].uuid
    if uuid == nil then
        return false
    end
    for index = 2, #matches do
        if matches[index].uuid ~= uuid then
            return false
        end
    end
    return true
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
    if #matches > 1 and args.preset_uuid == nil and not sharesOneUuid(matches) then
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

-- Lightroom mints a fresh CorrectionID/MaskID on every getSetting() call, so
-- they identify a read rather than the preset. Comparing them made every
-- masked preset (all the Adaptive/AI ones) differ from itself.
local VOLATILE_SETTING_KEYS = {
    CorrectionID = true,
    MaskID = true,
}

local function withoutVolatileIds(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do
        if not VOLATILE_SETTING_KEYS[key] then
            out[key] = withoutVolatileIds(item)
        end
    end
    return out
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
        local before = withoutVolatileIds(baseSettings[key])
        local after = withoutVolatileIds(candidateSettings[key])
        if not deepEqual(before, after) then
            local change = {
                key = key,
                before_present = baseSettings[key] ~= nil,
                after_present = candidateSettings[key] ~= nil,
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
    args.photo_id = requirePhotoId(args.photo_id, "photo_id")
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
    -- Resolved OUTSIDE the read gate: the lookup runs catalog queries.
    local photo = PhotoLookup.resolveOne(catalog, args.photo_id)
    if not photo then
        error("Photo not found: " .. args.photo_id)
    end
    catalog:withReadAccessDo(function()
        sourceSettings = photo:getDevelopSettings()
    end)

    local presetSettings = {}
    for _, key in ipairs(args.settings) do
        local value = sourceSettings[key]
        if value == nil then
            error("Source photo has no develop setting: " .. key)
        end
        requireCapturedSettingValue(key, value)
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

local AI_UPDATE_UNSUPPORTED_NOTE = "; AI mask update needs Lightroom Classic 13.3 or later"

local containsAIMasks = AIMaskData.containsAIMasks
local withoutComputedAIMaskData = AIMaskData.withoutComputedData

local function presetContainsAIMasks(preset)
    return containsAIMasks(callPresetMethod(preset, "getSetting"))
end

-- applyDevelopSettings has no AI flag and the applyDevelopPreset one reportedly
-- reopens the modal-dialog lockup, so recompute in a second write transaction
-- (same-transaction calls do not see the new settings).
local function recomputeAISettings(catalog, applied)
    local updated = 0
    local failed = {}
    if #applied == 0 then
        return updated, failed, true
    end
    if type(applied[1].photo.updateAISettings) ~= "function" then
        return updated, failed, false
    end
    catalog:withWriteAccessDo("Update AI Settings", function()
        for _, entry in ipairs(applied) do
            local ok = LrTasks.pcall(function() entry.photo:updateAISettings() end)
            if ok then
                updated = updated + 1
            else
                failed[#failed + 1] = tostring(entry.id)
            end
        end
    end)
    return updated, failed, true
end

local function aiUpdateMessageSuffix(supported, failed)
    if not supported then
        return AI_UPDATE_UNSUPPORTED_NOTE
    end
    if #failed > 0 then
        return string.format("; AI mask update failed for %d photos", #failed)
    end
    return ""
end

local DRY_RUN_DETAIL_LIMIT = 5
local DRY_RUN_DETAIL_BUDGET = 12000

local function requireDryRun(args)
    if args.dry_run ~= nil and type(args.dry_run) ~= "boolean" then
        error("dry_run must be a boolean")
    end
end

local function previewValue(value)
    if type(value) == "table" then
        local count = 0
        for _ in pairs(value) do count = count + 1 end
        return { type = "table", entries = count }
    end
    if type(value) == "string" and #value > 128 then
        return { type = "string", length = #value, prefix = value:sub(1, 128) }
    end
    return value
end

local function previewDevelopSettings(catalog, resolved, settings)
    local result = {
        success = true,
        dry_run = true,
        targets = 0,
        changed_targets = 0,
        missing = {},
        details = {},
        detail_limit = DRY_RUN_DETAIL_LIMIT,
        detail_truncated = false,
        setting_totals = {},
        masks_would_be_copied = settings.MaskGroupBasedCorrections ~= nil,
        ai_recomputed = false,
    }
    local keys = sortedSettingKeys(settings)
    local normalized = withoutVolatileIds(withoutComputedAIMaskData(settings))
    local detailBytes = 0
    for _, entry in ipairs(resolved) do
        if not entry.photo then
            result.missing[#result.missing + 1] = tostring(entry.id)
        else
            result.targets = result.targets + 1
            local current
            catalog:withReadAccessDo(function() current = entry.photo:getDevelopSettings() end)
            current = withoutVolatileIds(withoutComputedAIMaskData(current))
            local detail = { id = tostring(entry.id), changes = {} }
            local changed = false
            for _, key in ipairs(keys) do
                if not deepEqual(current[key], normalized[key]) then
                    changed = true
                    result.setting_totals[key] = (result.setting_totals[key] or 0) + 1
                    detail.changes[#detail.changes + 1] = {
                        key = key,
                        before_present = current[key] ~= nil,
                        after_present = normalized[key] ~= nil,
                        before = previewValue(current[key]),
                        after = previewValue(normalized[key]),
                    }
                end
            end
            if changed then result.changed_targets = result.changed_targets + 1 end
            if #result.details < DRY_RUN_DETAIL_LIMIT then
                local bytes = #JSON:encode(detail)
                if detailBytes + bytes <= DRY_RUN_DETAIL_BUDGET then
                    result.details[#result.details + 1] = detail
                    detailBytes = detailBytes + bytes
                else
                    result.detail_truncated = true
                end
            else
                result.detail_truncated = true
            end
        end
    end
    while #result.details > 0 and #JSON:encode(result) > 20000 do
        table.remove(result.details)
        result.detail_truncated = true
    end
    return result
end

function DevelopHandler.applyDevelopPreset(args)
    args.photo_ids = requirePhotoIdArray(args.photo_ids, "photo_ids", MAX_BULK_PHOTO_IDS)
    local selectedPreset = findPreset(args)
    requireDryRun(args)

    local catalog = LrApplication.activeCatalog()
    local appliedCount = 0

    local missingIds = {}
    local missingCount = 0

    -- Resolve outside the write gate: the lookup scans the catalog and does
    -- not write, so holding the exclusive gate across it only serializes
    -- every other handler behind it.
    local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
    if args.dry_run then
        return previewDevelopSettings(catalog, resolved, normalizedPresetSettings(selectedPreset.preset))
    end
    local applied = {}

    catalog:withWriteAccessDo("Apply Develop Preset", function()
        for _, resolvedEntry in ipairs(resolved) do
            if resolvedEntry.photo then
                if selectedPreset.scope == "plugin" then
                    resolvedEntry.photo:applyDevelopPreset(selectedPreset.preset, _PLUGIN)
                else
                    resolvedEntry.photo:applyDevelopPreset(selectedPreset.preset)
                end
                appliedCount = appliedCount + 1
                applied[appliedCount] = resolvedEntry
            else
                missingCount = missingCount + 1
                missingIds[missingCount] = tostring(resolvedEntry.id)
            end
        end
    end)

    local aiUpdated, aiFailed, aiSupported = 0, {}, true
    if presetContainsAIMasks(selectedPreset.preset) then
        aiUpdated, aiFailed, aiSupported = recomputeAISettings(catalog, applied)
    end

    Log.info(string.format("Applied preset %s to %d photos (AI masks recomputed: %d, failed: %d)",
        selectedPreset.name, appliedCount, aiUpdated, #aiFailed))

    return {
        success = true,
        applied = appliedCount,
        preset = selectedPreset.name,
        folder = selectedPreset.folder,
        scope = selectedPreset.scope,
        uuid = selectedPreset.uuid,
        missing = missingIds,
        ai_updated = aiUpdated,
        ai_update_failed = aiFailed,
        message = string.format("Applied preset %s to %d photos (%d ids not found)",
            selectedPreset.name, appliedCount, missingCount) .. aiUpdateMessageSuffix(aiSupported, aiFailed),
    }
end

function DevelopHandler.copyDevelopSettings(args)
    args.source_id = requirePhotoId(args.source_id, "source_id")
    args.target_ids = requirePhotoIdArray(args.target_ids, "target_ids", MAX_BULK_PHOTO_IDS)
    requireDevelopSettingWhitelist(args.settings)
    requireDryRun(args)

    local catalog = LrApplication.activeCatalog()
    local sourceSettings

    -- Resolved OUTSIDE the read gate: the lookup runs catalog queries.
    local source = PhotoLookup.resolveOne(catalog, args.source_id)
    if not source then
        error("Source photo not found: " .. args.source_id)
    end
    catalog:withReadAccessDo(function()
        sourceSettings = source:getDevelopSettings()
    end)

    local toApply = sourceSettings
    if args.settings then
        toApply = {}
        for _, key in ipairs(args.settings) do
            toApply[key] = sourceSettings[key]
        end
    end
    toApply = withoutComputedAIMaskData(toApply)

    local copiedCount = 0
    local missingIds = {}
    local missingCount = 0

    local resolved = PhotoLookup.resolveMany(catalog, args.target_ids)
    if args.dry_run then
        return previewDevelopSettings(catalog, resolved, toApply)
    end
    local applied = {}

    catalog:withWriteAccessDo("Copy Develop Settings", function()
        for _, entry in ipairs(resolved) do
            if entry.photo then
                entry.photo:applyDevelopSettings(toApply, "Copy Develop Settings")
                copiedCount = copiedCount + 1
                applied[copiedCount] = entry
            else
                missingCount = missingCount + 1
                missingIds[missingCount] = tostring(entry.id)
            end
        end
    end)

    local aiUpdated, aiFailed, aiSupported = 0, {}, true
    if containsAIMasks(toApply) then
        aiUpdated, aiFailed, aiSupported = recomputeAISettings(catalog, applied)
    end

    Log.info(string.format("Copied develop settings from %s to %d photos (AI masks recomputed: %d, failed: %d)",
        args.source_id, copiedCount, aiUpdated, #aiFailed))

    return {
        success = true,
        copied = copiedCount,
        source = args.source_id,
        missing = missingIds,
        ai_updated = aiUpdated,
        ai_update_failed = aiFailed,
        message = string.format("Copied develop settings from %s to %d photos (%d ids not found)",
            args.source_id, copiedCount, missingCount) .. aiUpdateMessageSuffix(aiSupported, aiFailed),
    }
end

function DevelopHandler.setDevelopSettings(args)
    args.photo_id = requirePhotoId(args.photo_id, "photo_id")
    requireDevelopSettingsObject(args.settings)

    local catalog = LrApplication.activeCatalog()
    local applied = false

    local photo = PhotoLookup.resolveOne(catalog, args.photo_id)
    if not photo then
        error("Photo not found: " .. args.photo_id)
    end

    catalog:withWriteAccessDo("Set Develop Settings", function()
        photo:applyDevelopSettings(args.settings, "Set Develop Settings")
        applied = true
    end)

    Log.info(string.format("Set develop settings on photo %s", args.photo_id))

    return {
        success = applied,
        photo_id = args.photo_id,
    }
end

-- AI Denoise is not a plain develop key: Lightroom stores it as an "Enhance"
-- filter carrying data computed for that one image, so applyDevelopSettings
-- cannot create it and copying it between photos breaks it. LrC 15 exposes
-- the Develop panel's own path instead (LrDevelopController.setEnhance /
-- changeDenoiseAmount), which only acts on the photo active in Develop.
-- So the handler drives Develop: select one photo, let the panel catch up,
-- apply, move on. Lightroom computes the denoise itself in the background.
local MAX_DENOISE_PHOTO_IDS = 100
-- The Enhance panel updates asynchronously after the active photo changes:
-- right after a switch it can still describe the previous photo, or report
-- Denoise unavailable until the new image has loaded.
local DENOISE_PANEL_SETTLE_SECONDS = 0.5
local DENOISE_PANEL_TIMEOUT_SECONDS = 8
local DENOISE_CONFIRM_TIMEOUT_SECONDS = 1.5
local DENOISE_SAVE_TIMEOUT_SECONDS = 5
local SERVER_LONG_RUNNING_TIMEOUT_SECONDS = 300
local DENOISE_LAST_PHOTO_AND_RESTORE_SECONDS = 60
local DENOISE_TIME_BUDGET_SECONDS = SERVER_LONG_RUNNING_TIMEOUT_SECONDS - DENOISE_LAST_PHOTO_AND_RESTORE_SECONDS

local function requireDenoiseAmount(value)
    if type(value) ~= "number" or value ~= math.floor(value) or value < 1 or value > 100 then
        error("amount must be an integer from 1 to 100")
    end
    return value
end

local function requireDenoiseSupport()
    if type(LrDevelopController.getEnhancePanelState) ~= "function"
            or type(LrDevelopController.setEnhance) ~= "function"
            or type(LrDevelopController.changeDenoiseAmount) ~= "function" then
        error("apply_denoise needs Lightroom Classic 15 or later")
    end
end

local waitFor = DevelopSession.waitFor

-- Ground truth for "already has Denoise", independent of the panel, which may
-- still describe the previously active photo. Any Enhance filter counts.
local function enhanceDigest(catalog, photo)
    local digest
    catalog:withReadAccessDo(function()
        local settings = photo:getDevelopSettings()
        local filterList = settings and settings.FilterList
        local filters = type(filterList) == "table" and filterList.Filters
        if type(filters) == "table" then
            for _, filter in ipairs(filters) do
                if type(filter) == "table" and filter.Name == "Enhance" then
                    digest = tostring(filter.CompressedSettings or "")
                end
            end
        end
    end)
    return digest
end

local function waitForSavedChange(catalog, photo, before)
    return waitFor(function()
        local now = enhanceDigest(catalog, photo)
        return now ~= nil and now ~= before
    end, DENOISE_SAVE_TIMEOUT_SECONDS)
end

local function denoisePhoto(catalog, photo, amount)
    LrTasks.sleep(DENOISE_PANEL_SETTLE_SECONDS)
    local panel
    waitFor(function()
        panel = LrDevelopController.getEnhancePanelState()
        return panel ~= nil and panel.denoiseEnabled
    end, DENOISE_PANEL_TIMEOUT_SECONDS)
    local digestBefore = enhanceDigest(catalog, photo)
    local hasDenoise = digestBefore ~= nil
    if not panel then
        return { status = "failed", reason = "Develop panel state unavailable" }
    elseif not panel.denoiseEnabled then
        return { status = "skipped", reason = "Denoise is not available for this photo" }
    elseif hasDenoise and panel.denoiseState and panel.denoiseAmount == amount then
        return { status = "unchanged" }
    elseif catalog:getTargetPhoto() ~= photo then
        return { status = "failed", reason = "another photo became active before Denoise was applied" }
    end

    local change = hasDenoise and panel.denoiseState and true or false
    local ok, err = LrTasks.pcall(function()
        if change then
            LrDevelopController.changeDenoiseAmount(amount)
        else
            LrDevelopController.setEnhance("denoise", true, amount)
        end
    end)
    if not ok then
        return { status = "failed", reason = tostring(err) }
    end
    local confirmed = waitFor(function()
        local now = LrDevelopController.getEnhancePanelState()
        return catalog:getTargetPhoto() == photo
            and now ~= nil and now.denoiseState and now.denoiseAmount == amount
    end, DENOISE_CONFIRM_TIMEOUT_SECONDS)
    if not confirmed then
        return { status = "failed", reason = "the Develop panel did not show the new amount; check this photo" }
    end
    if not waitForSavedChange(catalog, photo, digestBefore) then
        if change then
            LrTasks.pcall(function() LrDevelopController.changeDenoiseAmount(panel.denoiseAmount) end)
        end
        return {
            status = "failed",
            reason = "Lightroom did not save the change; it can drop a change made while it is still computing"
                .. " Denoise for this photo. Call again once the Activity Center is idle.",
        }
    end
    return {
        status = change and "amount_changed" or "applied",
        previous_amount = change and panel.denoiseAmount or nil,
    }
end

local function denoiseAll(catalog, resolved, amount, state, startedAt, context)
    DevelopSession.openDevelop(function() return LrDevelopController.getEnhancePanelState() ~= nil end)

    local results, remaining = {}, {}
    local counts = { applied = 0, amount_changed = 0, unchanged = 0, skipped = 0, failed = 0 }
    local seen = {}

    for _, entry in ipairs(resolved) do
        local result
        if #remaining > 0 or (context and context:isCanceled())
            or LrDate.currentTime() - startedAt >= DENOISE_TIME_BUDGET_SECONDS then
            remaining[#remaining + 1] = tostring(entry.id)
        elseif not entry.photo then
            result = { status = "skipped", reason = "photo not found" }
        elseif seen[entry.photo] then
            result = { status = "skipped", reason = "duplicate" }
        else
            if context then context:report(#results, #resolved, entry.photo:getFormattedMetadata("fileName") or tostring(entry.id)) end
            seen[entry.photo] = true
            if DevelopSession.activate(catalog, entry.photo, state) then
                result = denoisePhoto(catalog, entry.photo, amount)
                result.id = tostring(entry.photo.localIdentifier)
            else
                result = { status = "skipped", reason = "could not select the photo in Develop" }
            end
        end
        if result then
            result.id = result.id or tostring(entry.id)
            counts[result.status] = counts[result.status] + 1
            results[#results + 1] = result
        end
    end
    if context and #results > 0 then context:report(#results, #resolved, results[#results].id) end
    return results, counts, remaining
end

function DevelopHandler.applyDenoise(args, context)
    args.photo_ids = requirePhotoIdArray(args.photo_ids, "photo_ids", MAX_DENOISE_PHOTO_IDS)
    local amount = requireDenoiseAmount(args.amount)
    if args.restore_selection ~= nil and type(args.restore_selection) ~= "boolean" then
        error("restore_selection must be a boolean")
    end
    requireDenoiseSupport()

    local catalog = LrApplication.activeCatalog()
    local startedAt = LrDate.currentTime()
    local outcome = DevelopSession.run("apply_denoise", catalog, args.restore_selection ~= false, function(state)
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        local results, counts, remaining = denoiseAll(catalog, resolved, amount, state, startedAt, context)
        return { results = results, counts = counts, remaining = remaining }
    end)
    local results, counts, remaining = outcome.results, outcome.counts, outcome.remaining

    Log.info(string.format(
        "applyDenoise %d%%: %d applied, %d changed, %d unchanged, %d skipped, %d failed, %d not reached",
        amount, counts.applied, counts.amount_changed, counts.unchanged, counts.skipped, counts.failed,
        #remaining))

    local complete = #remaining == 0
    return {
        success = counts.failed == 0 and complete,
        complete = complete,
        amount = amount,
        applied = counts.applied,
        amount_changed = counts.amount_changed,
        unchanged = counts.unchanged,
        skipped = counts.skipped,
        failed = counts.failed,
        results = results,
        remaining_ids = not complete and remaining or nil,
        seconds = math.floor((LrDate.currentTime() - startedAt) * 10 + 0.5) / 10,
        message = complete
            and "Denoise runs in Lightroom's background; the Activity Center shows progress."
            or string.format(
                "Stopped after %d s to stay within the request timeout; call again with remaining_ids.",
                DENOISE_TIME_BUDGET_SECONDS),
    }
end

local AUTO_TONE_KEYS = {
    "Exposure2012", "Contrast2012", "Highlights2012", "Shadows2012", "Whites2012", "Blacks2012",
    "Vibrance", "Saturation",
}
local AUTO_WHITE_BALANCE_KEYS = { "WhiteBalance", "Temperature", "Tint" }
local AUTO_TIME_BUDGET_SECONDS = 240
local AUTO_SETTLE_TIMEOUT_SECONDS = 8

local function autoValues(catalog, photo, keys)
    local values = {}
    catalog:withReadAccessDo(function()
        local settings = photo:getDevelopSettings()
        for _, key in ipairs(keys) do values[key] = settings[key] end
    end)
    return values
end

local function sameAutoValues(first, second, keys)
    for _, key in ipairs(keys) do
        if first[key] ~= second[key] then return false end
    end
    return true
end

local function autoOperation(catalog, photo, keys, apply)
    local before = autoValues(catalog, photo, keys)
    apply()
    DevelopSession.flushPendingEdits()
    local previous, stable, elapsed = before, 0, 0
    local settled = waitFor(function()
        if catalog:getTargetPhoto() ~= photo then
            error("another photo became active while applying Auto")
        end
        local current = autoValues(catalog, photo, keys)
        stable = sameAutoValues(previous, current, keys) and stable + 0.1 or 0
        previous = current
        elapsed = elapsed + 0.1
        return elapsed >= 2 and stable >= 1 and not sameAutoValues(before, current, keys)
    end, AUTO_SETTLE_TIMEOUT_SECONDS)
    if not settled and stable < 1 then
        return { status = "failed", reason = "Auto settings did not settle; check this photo before retrying" }
    end
    if sameAutoValues(before, previous, keys) then
        return { status = "unchanged", reason = "Auto returned the current settings" }
    end
    return { status = "applied" }
end

local function autoPhoto(catalog, photo, args)
    local changed = false
    if args.tone then
        local result = autoOperation(catalog, photo, AUTO_TONE_KEYS, LrDevelopController.setAutoTone)
        if result.status == "failed" then return result end
        changed = result.status == "applied"
    end
    if args.white_balance then
        local result = autoOperation(catalog, photo, AUTO_WHITE_BALANCE_KEYS, LrDevelopController.setAutoWhiteBalance)
        if result.status == "failed" then return result end
        changed = changed or result.status == "applied"
    end
    return changed and { status = "applied" }
        or { status = "unchanged", reason = "Auto returned the current settings" }
end

function DevelopHandler.applyAutoAdjustments(args)
    args.photo_ids = requirePhotoIdArray(args.photo_ids, "photo_ids", 100)
    for _, name in ipairs({ "tone", "white_balance" }) do
        if args[name] ~= nil and type(args[name]) ~= "boolean" then error(name .. " must be a boolean") end
    end
    if args.tone ~= true and args.white_balance ~= true then
        error("tone or white_balance must be true")
    end
    if args.tone and type(LrDevelopController.setAutoTone) ~= "function"
            or args.white_balance and type(LrDevelopController.setAutoWhiteBalance) ~= "function" then
        error("apply_auto_adjustments needs Lightroom Classic 7.4 or later")
    end
    local catalog = LrApplication.activeCatalog()
    local startedAt = LrDate.currentTime()
    return DevelopSession.run("apply_auto_adjustments", catalog, true, function(state)
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        local results, remaining, seen = {}, {}, {}
        local counts = { applied = 0, unchanged = 0, skipped = 0, failed = 0 }
        for _, entry in ipairs(resolved) do
            local result
            if #remaining > 0 or LrDate.currentTime() - startedAt >= AUTO_TIME_BUDGET_SECONDS then
                remaining[#remaining + 1] = tostring(entry.id)
            elseif not entry.photo then
                result = { status = "skipped", reason = "photo not found" }
            elseif seen[entry.photo] then
                result = { status = "skipped", reason = "duplicate" }
            else
                seen[entry.photo] = true
                local ok, outcome = LrTasks.pcall(function()
                    DevelopSession.openPhoto(catalog, entry.photo, state)
                    return autoPhoto(catalog, entry.photo, args)
                end)
                result = ok and outcome or { status = "failed", reason = tostring(outcome) }
            end
            if result then
                result.id = tostring(entry.id)
                counts[result.status] = counts[result.status] + 1
                results[#results + 1] = result
            end
        end
        return {
            success = counts.failed == 0 and #remaining == 0,
            complete = #remaining == 0,
            applied = counts.applied,
            unchanged = counts.unchanged,
            skipped = counts.skipped,
            failed = counts.failed,
            results = results,
            remaining_ids = #remaining > 0 and remaining or nil,
        }
    end)
end

return DevelopHandler
