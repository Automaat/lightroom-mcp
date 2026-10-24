local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local PhotoLookup = require 'PhotoLookup'

local MaskSelection = {}

local POLL_SECONDS = 0.1
local MASK_LIST_TIMEOUT_SECONDS = 5
local MASK_SELECT_TIMEOUT_SECONDS = 8
local MASK_RESELECT_SECONDS = 1
local MASK_SELECT_SETTLE_SECONDS = 0.3

function MaskSelection.requirePhotoId(value)
    if type(value) == "number" then return tostring(value) end
    if type(value) ~= "string" or value == "" then
        error("photo_id is required")
    end
    return value
end

function MaskSelection.requireMaskId(value)
    if type(value) ~= "string" or value == "" then
        error("mask_id is required")
    end
    return value
end

function MaskSelection.requireTarget(args)
    return MaskSelection.requirePhotoId(args.photo_id), MaskSelection.requireMaskId(args.mask_id)
end

function MaskSelection.requireControllerFunctions(toolName, names, minimumVersion)
    DevelopSession.requireMaskApi(toolName)
    for _, name in ipairs(names) do
        if type(LrDevelopController[name]) ~= "function" then
            error(toolName .. " needs " .. minimumVersion .. " or later")
        end
    end
end

function MaskSelection.requireVersionAtLeast(toolName, major, minor, label)
    local version = LrApplication.versionTable and LrApplication.versionTable() or nil
    if type(version) ~= "table" or type(version.major) ~= "number" then return end
    local installedMinor = type(version.minor) == "number" and version.minor or 0
    if version.major < major or (version.major == major and installedMinor < minor) then
        error(string.format("%s needs %s or later; this is Lightroom Classic %d.%d",
            toolName, label, version.major, installedMinor))
    end
end

function MaskSelection.resolvePhoto(photoId)
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, photoId)
    if not photo then
        error("Photo not found: " .. photoId)
    end
    return catalog, photo
end

local function listMaskIds()
    local ok, masks = LrTasks.pcall(LrDevelopController.getAllMasks)
    if not ok or type(masks) ~= "table" then return nil end
    local ids = {}
    for _, mask in ipairs(masks) do
        if type(mask) == "table" and type(mask.ID) == "string" then
            ids[#ids + 1] = mask.ID
        end
    end
    return ids
end

local function contains(list, wanted)
    for _, item in ipairs(list) do
        if item == wanted then return true end
    end
    return false
end

local function requireMaskOnPhoto(photoId, maskId)
    local ids
    DevelopSession.waitFor(function()
        ids = listMaskIds()
        return ids ~= nil and (#ids > 0 or contains(ids, maskId))
    end, MASK_LIST_TIMEOUT_SECONDS)
    if ids == nil then
        error("Lightroom could not read the masks of photo " .. photoId)
    end
    if not contains(ids, maskId) then
        error(string.format("Mask not found on photo %s: %s (masks on this photo: %s)",
            photoId, maskId, #ids > 0 and table.concat(ids, ", ") or "none"))
    end
end

function MaskSelection.readSelectedMask()
    local ok, id = LrTasks.pcall(LrDevelopController.getSelectedMask)
    if ok and type(id) == "string" and id ~= "" then return id end
    return nil
end

local function openMaskingPanel()
    if type(LrDevelopController.goToMasking) == "function" then
        LrTasks.pcall(LrDevelopController.goToMasking)
    end
end

local function selectMaskAndWait(maskId)
    local sinceSelect = MASK_RESELECT_SECONDS
    return DevelopSession.waitFor(function()
        if MaskSelection.readSelectedMask() == maskId then return true end
        if sinceSelect >= MASK_RESELECT_SECONDS then
            LrTasks.pcall(LrDevelopController.selectMask, maskId)
            sinceSelect = 0
        end
        sinceSelect = sinceSelect + POLL_SECONDS
        return false
    end, MASK_SELECT_TIMEOUT_SECONDS)
end

function MaskSelection.withMaskSelected(photoId, maskId, body)
    requireMaskOnPhoto(photoId, maskId)
    openMaskingPanel()
    local previousMask = MaskSelection.readSelectedMask()
    if not selectMaskAndWait(maskId) then
        error("Could not select mask " .. maskId .. " on photo " .. photoId .. " in Develop")
    end
    LrTasks.sleep(MASK_SELECT_SETTLE_SECONDS)

    local ok, result = LrTasks.pcall(body)
    if previousMask and previousMask ~= maskId then
        LrTasks.pcall(LrDevelopController.selectMask, previousMask)
    end
    if not ok then error(result, 0) end
    return result
end

return MaskSelection
