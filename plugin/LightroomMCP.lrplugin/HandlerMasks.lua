local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local GuardedMaskWrite = require 'GuardedMaskWrite'
local Log = require 'Log'
local PhotoLookup = require 'PhotoLookup'
local RangeMaskGeometry = require 'RangeMaskGeometry'

local MaskHandler = {}

local MASK_READ_TIMEOUT_SECONDS = 5

local function requirePhotoId(value)
    if type(value) == "number" then return tostring(value) end
    if type(value) ~= "string" or value == "" then
        error("photo_id is required")
    end
    return value
end

local function scalarOrNil(value)
    local valueType = type(value)
    if valueType == "string" or valueType == "number" or valueType == "boolean" then return value end
    return nil
end

local function idString(value)
    if type(value) == "string" and value ~= "" then return value end
    return nil
end

local function sortedKeyNames(entry)
    local names = {}
    for key in pairs(entry) do names[#names + 1] = tostring(key) end
    table.sort(names)
    return table.concat(names, ", ")
end

local function rangesByToolId(catalog, photo)
    local ranges = {}
    local ok, entries = LrTasks.pcall(GuardedMaskWrite.readEntries, catalog, photo)
    if not ok then
        Log.warn(string.format("Could not read the stored ranges of photo %s: %s",
            tostring(photo.localIdentifier), tostring(entries)))
        return ranges
    end
    for _, entry in ipairs(entries) do
        for _, component in ipairs(entry.CorrectionMasks or {}) do
            local kind, range = RangeMaskGeometry.rangeOf(component)
            if kind ~= nil then ranges[tostring(component.MaskID)] = range end
        end
    end
    return ranges
end

local function normalizeTool(tool, photoId, ranges)
    if type(tool) ~= "table" then
        error("Lightroom returned a mask tool that is not a table for photo " .. photoId)
    end
    local id = idString(tool.ID)
    if not id then
        error("Lightroom returned a mask tool without an id for photo " .. photoId
            .. " (fields: " .. sortedKeyNames(tool) .. ")")
    end
    return {
        id = id,
        type = scalarOrNil(tool.Type),
        subtype = scalarOrNil(tool.Subtype),
        inverted = tool.Inverted == true,
        range = ranges[id],
    }
end

local function normalizeMask(mask, photoId, ranges)
    if type(mask) ~= "table" then
        error("Lightroom returned a mask that is not a table for photo " .. photoId)
    end
    local id = idString(mask.ID)
    if not id then
        error("Lightroom returned a mask without an id for photo " .. photoId
            .. " (fields: " .. sortedKeyNames(mask) .. ")")
    end
    local tools = {}
    if type(mask.Tools) == "table" then
        for _, tool in ipairs(mask.Tools) do
            tools[#tools + 1] = normalizeTool(tool, photoId, ranges)
        end
    end
    return {
        id = id,
        name = scalarOrNil(mask.Name),
        hidden = mask.Hidden == true,
        tools = tools,
    }
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

function MaskHandler.listMasks(args)
    local photoId = requirePhotoId(args.photo_id)
    DevelopSession.requireMaskApi("list_masks")

    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, photoId)
    if not photo then
        error("Photo not found: " .. photoId)
    end

    local raw = DevelopSession.withPhoto("list_masks", catalog, photo, function()
        return { masks = readAllMasks(photoId), ranges = rangesByToolId(catalog, photo) }
    end)

    local masks = {}
    for _, mask in ipairs(raw.masks) do
        masks[#masks + 1] = normalizeMask(mask, photoId, raw.ranges)
    end

    Log.info(string.format("Listed %d masks on photo %s", #masks, photoId))

    return {
        success = true,
        photo_id = photoId,
        count = #masks,
        masks = masks,
    }
end

return MaskHandler
