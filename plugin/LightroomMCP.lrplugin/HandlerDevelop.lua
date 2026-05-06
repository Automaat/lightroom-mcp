local LrApplication = import 'LrApplication'
local LrLogger = import 'LrLogger'

local PhotoLookup = require 'PhotoLookup'

local logger = LrLogger('LightroomMCP')

local DevelopHandler = {}

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

    logger:info(string.format("Listed %d develop presets", #out))

    return {
        success = true,
        presets = out,
        count = #out,
    }
end

function DevelopHandler.applyDevelopPreset(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    if not args.preset_name then
        error("preset_name is required")
    end

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

    logger:info(string.format("Applied preset %s to %d photos", args.preset_name, appliedCount))

    return {
        success = true,
        applied = appliedCount,
        preset = args.preset_name,
        folder = folder,
        message = string.format("Applied preset %s to %d photos", args.preset_name, appliedCount),
    }
end

function DevelopHandler.copyDevelopSettings(args)
    if not args.source_id then
        error("source_id is required")
    end

    if not args.target_ids or #args.target_ids == 0 then
        error("target_ids is required")
    end

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
    if args.settings and #args.settings > 0 then
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

    logger:info(string.format("Copied develop settings from %s to %d photos", args.source_id, copiedCount))

    return {
        success = true,
        copied = copiedCount,
        source = args.source_id,
        message = string.format("Copied develop settings from %s to %d photos", args.source_id, copiedCount),
    }
end

function DevelopHandler.setDevelopSettings(args)
    if not args.photo_id then
        error("photo_id is required")
    end

    if not args.settings or type(args.settings) ~= "table" then
        error("settings is required")
    end

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

    logger:info(string.format("Set develop settings on photo %s", args.photo_id))

    return {
        success = applied,
        photo_id = args.photo_id,
    }
end

return DevelopHandler
