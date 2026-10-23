local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local Log = require 'Log'
local PhotoLookup = require 'PhotoLookup'

local MaskHandler = {}

local MASK_READ_TIMEOUT_SECONDS = 5

local MASK_ID_KEYS = { "id", "maskId", "maskID", "MaskID", "CorrectionID" }
local MASK_NAME_KEYS = { "name", "maskName", "CorrectionName" }
local MASK_HIDDEN_KEYS = { "hidden", "isHidden" }
local MASK_ACTIVE_KEYS = { "CorrectionActive" }
local MASK_TOOLS_KEYS = { "tools", "masks", "components", "CorrectionMasks" }
local TOOL_ID_KEYS = { "id", "toolId", "toolID", "maskToolId", "MaskID" }
local TOOL_TYPE_KEYS = { "type", "toolType", "maskType", "What" }
local TOOL_SUBTYPE_KEYS = { "subtype", "subType", "maskSubtype", "MaskSubType" }
local TOOL_INVERTED_KEYS = { "inverted", "isInverted", "MaskInverted" }

local function requirePhotoId(value)
    if type(value) == "number" then return tostring(value) end
    if type(value) ~= "string" or value == "" then
        error("photo_id is required")
    end
    return value
end

local function pick(entry, keys)
    for _, key in ipairs(keys) do
        if entry[key] ~= nil then return entry[key] end
    end
    return nil
end

local function scalarOrNil(value)
    local valueType = type(value)
    if valueType == "string" or valueType == "number" or valueType == "boolean" then return value end
    return nil
end

local function idString(value)
    if type(value) == "string" and value ~= "" then return value end
    if type(value) == "number" then return tostring(value) end
    return nil
end

local function sortedKeyNames(entry)
    local names = {}
    for key in pairs(entry) do names[#names + 1] = tostring(key) end
    table.sort(names)
    return table.concat(names, ", ")
end

local function toolType(raw)
    local value = scalarOrNil(raw)
    if type(value) == "string" then return (value:gsub("^Mask/", "")) end
    return value
end

local function normalizeTool(tool, photoId)
    if type(tool) ~= "table" then
        error("Lightroom returned a mask tool that is not a table for photo " .. photoId)
    end
    local id = idString(pick(tool, TOOL_ID_KEYS))
    if not id then
        error("Lightroom returned a mask tool without an id for photo " .. photoId
            .. " (fields: " .. sortedKeyNames(tool) .. ")")
    end
    local kind = toolType(pick(tool, TOOL_TYPE_KEYS))
    if kind == nil then
        Log.warn("list_masks: mask tool has no recognised type (fields: " .. sortedKeyNames(tool) .. ")")
    end
    return {
        id = id,
        type = kind,
        subtype = scalarOrNil(pick(tool, TOOL_SUBTYPE_KEYS)),
        inverted = pick(tool, TOOL_INVERTED_KEYS) == true,
    }
end

local function toolEntries(mask)
    local listed = pick(mask, MASK_TOOLS_KEYS)
    if type(listed) == "table" then return listed end
    return mask
end

local function maskHidden(mask)
    local hidden = pick(mask, MASK_HIDDEN_KEYS)
    if hidden ~= nil then return hidden == true end
    return pick(mask, MASK_ACTIVE_KEYS) == false
end

local function normalizeMask(mask, photoId)
    if type(mask) ~= "table" then
        error("Lightroom returned a mask that is not a table for photo " .. photoId)
    end
    local id = idString(pick(mask, MASK_ID_KEYS))
    if not id then
        error("Lightroom returned a mask without an id for photo " .. photoId
            .. " (fields: " .. sortedKeyNames(mask) .. ")")
    end
    local tools = {}
    for _, tool in ipairs(toolEntries(mask)) do
        tools[#tools + 1] = normalizeTool(tool, photoId)
    end
    local name = scalarOrNil(pick(mask, MASK_NAME_KEYS))
    if name == nil then
        Log.warn("list_masks: mask has no recognised name (fields: " .. sortedKeyNames(mask) .. ")")
    end
    return {
        id = id,
        name = name,
        hidden = maskHidden(mask),
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
        return { masks = readAllMasks(photoId) }
    end).masks

    local masks = {}
    for _, mask in ipairs(raw) do
        masks[#masks + 1] = normalizeMask(mask, photoId)
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
