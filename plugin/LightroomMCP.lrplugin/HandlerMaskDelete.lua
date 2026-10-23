local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local Log = require 'Log'
local PhotoLookup = require 'PhotoLookup'

local MaskDeleteHandler = {}

local MAX_DELETE_IDS = 100
local MAX_BULK_PHOTO_IDS = 1000
local MASK_READ_TIMEOUT_SECONDS = 5
local EMPTY_READ_CONFIRM_TIMEOUT_SECONDS = 5
local TOOL_SWITCH_TIMEOUT_SECONDS = 5
local DELETION_SETTLE_TIMEOUT_SECONDS = 5
local SAVE_SETTLE_TIMEOUT_SECONDS = 5
local MASKING_TOOL = "masking"
local DELETE_API_FUNCTIONS = { "deleteMask", "deleteMaskTool", "selectTool" }
local DELETE_API_MINIMUM_VERSION = "Lightroom Classic 11"
local DELETE_EMPTY_MINIMUM_VERSION = "Lightroom Classic 14"

local function requirePhotoId(value)
    if type(value) == "number" then return tostring(value) end
    if type(value) ~= "string" or value == "" then
        error("photo_id is required")
    end
    return value
end

local function requirePhotoIdArray(value)
    if type(value) ~= "table" or #value == 0 then
        error("photo_ids is required and must be a non-empty array")
    end
    if #value > MAX_BULK_PHOTO_IDS then
        error(string.format("photo_ids may hold at most %d ids", MAX_BULK_PHOTO_IDS))
    end
    for _, id in ipairs(value) do
        local idType = type(id)
        if not ((idType == "string" and id ~= "") or idType == "number") then
            error("photo_ids must hold photo ids or file paths")
        end
    end
    return value
end

local function requireIdList(value, fieldName)
    if type(value) ~= "table" or #value == 0 then
        error(fieldName .. " must be a non-empty array of ids")
    end
    if #value > MAX_DELETE_IDS then
        error(string.format("%s may hold at most %d ids", fieldName, MAX_DELETE_IDS))
    end
    local ids, seen = {}, {}
    for _, id in ipairs(value) do
        if type(id) ~= "string" or id == "" then
            error(fieldName .. " must hold non-empty id strings")
        end
        if not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    return ids
end

local function parseTarget(args)
    local given = {}
    for _, fieldName in ipairs({ "mask_ids", "tool_ids", "all" }) do
        if args[fieldName] ~= nil then given[#given + 1] = fieldName end
    end
    if #given ~= 1 then
        error("delete_masks needs exactly one of mask_ids, tool_ids or all")
    end
    if given[1] == "all" then
        if args.all ~= true then
            error("all must be true; pass mask_ids or tool_ids to delete specific masks")
        end
        return { kind = "all" }
    end
    return { kind = given[1], ids = requireIdList(args[given[1]], given[1]) }
end

local function requireDeleteApi(toolName)
    DevelopSession.requireMaskApi(toolName)
    for _, name in ipairs(DELETE_API_FUNCTIONS) do
        if type(LrDevelopController[name]) ~= "function" then
            error(toolName .. " needs " .. DELETE_API_MINIMUM_VERSION .. " or later")
        end
    end
end

local function idString(value)
    if type(value) == "string" and value ~= "" then return value end
    return nil
end

local function snapshotFromRaw(raw, photoId)
    local snapshot = { masksById = {}, maskOrder = {}, maskIdOfTool = {}, count = 0 }
    for _, mask in ipairs(raw) do
        local maskId = type(mask) == "table" and idString(mask.ID)
        if not maskId then
            error("Lightroom returned a mask without an id for photo " .. photoId)
        end
        local toolIds = {}
        if type(mask.Tools) == "table" then
            for _, tool in ipairs(mask.Tools) do
                local toolId = type(tool) == "table" and idString(tool.ID)
                if not toolId then
                    error("Lightroom returned a mask tool without an id for photo " .. photoId)
                end
                toolIds[#toolIds + 1] = toolId
                snapshot.maskIdOfTool[toolId] = maskId
            end
        end
        snapshot.masksById[maskId] = { id = maskId, toolIds = toolIds }
        snapshot.maskOrder[#snapshot.maskOrder + 1] = maskId
        snapshot.count = snapshot.count + 1
    end
    return snapshot
end

local function readMaskSnapshot(photoId)
    local raw, lastError
    local read = DevelopSession.waitFor(function()
        local ok, result = LrTasks.pcall(LrDevelopController.getAllMasks)
        if ok then
            raw = result
            return true
        end
        lastError = result
        return false
    end, MASK_READ_TIMEOUT_SECONDS)
    if not read then
        error("Lightroom could not read the masks of photo " .. photoId .. ": " .. tostring(lastError))
    end
    return snapshotFromRaw(raw or {}, photoId)
end

local function tryReadMaskSnapshot(photoId)
    local ok, snapshot = LrTasks.pcall(function()
        return snapshotFromRaw(LrDevelopController.getAllMasks() or {}, photoId)
    end)
    if ok then return snapshot end
    return nil
end

local function readSavedMasks(catalog, photo)
    local settings
    catalog:withReadAccessDo(function() settings = photo:getDevelopSettings() end)
    local saved = { maskIds = {}, toolIds = {}, groupCount = 0 }
    local groups = type(settings) == "table" and settings.MaskGroupBasedCorrections
    if type(groups) ~= "table" then return saved end
    for _, group in ipairs(groups) do
        saved.groupCount = saved.groupCount + 1
        if type(group) == "table" then
            if group.CorrectionID ~= nil then saved.maskIds[group.CorrectionID] = true end
            if type(group.CorrectionMasks) == "table" then
                for _, tool in ipairs(group.CorrectionMasks) do
                    if type(tool) == "table" and tool.MaskID ~= nil then
                        saved.toolIds[tool.MaskID] = true
                    end
                end
            end
        end
    end
    return saved
end

local function readMasksOnceDevelopIsReady(catalog, photo, photoId)
    local snapshot = readMaskSnapshot(photoId)
    if snapshot.count > 0 then return snapshot end
    local agreed = DevelopSession.waitFor(function()
        snapshot = readMaskSnapshot(photoId)
        return snapshot.count > 0 or readSavedMasks(catalog, photo).groupCount == 0
    end, EMPTY_READ_CONFIRM_TIMEOUT_SECONDS)
    if not agreed then
        error("Lightroom reports no masks on photo " .. photoId
            .. " although the photo has masks saved; call again once Develop has loaded it")
    end
    return snapshot
end

local function listUnknown(ids, isKnown)
    local unknown = {}
    for _, id in ipairs(ids) do
        if not isKnown(id) then unknown[#unknown + 1] = id end
    end
    return unknown
end

local function planDeletion(snapshot, target, photoId)
    local plan = { maskIds = {}, toolsByMask = {}, removedMaskIds = {}, removedToolIds = {} }

    if target.kind == "all" or target.kind == "mask_ids" then
        local maskIds = target.ids or snapshot.maskOrder
        local unknown = listUnknown(maskIds, function(id) return snapshot.masksById[id] ~= nil end)
        if #unknown > 0 then
            error("Unknown mask id(s) on photo " .. photoId .. ": " .. table.concat(unknown, ", ")
                .. "; nothing was deleted")
        end
        for _, maskId in ipairs(maskIds) do
            plan.maskIds[#plan.maskIds + 1] = maskId
            plan.removedMaskIds[#plan.removedMaskIds + 1] = maskId
            for _, toolId in ipairs(snapshot.masksById[maskId].toolIds) do
                plan.removedToolIds[#plan.removedToolIds + 1] = toolId
            end
        end
        return plan
    end

    local unknown = listUnknown(target.ids, function(id) return snapshot.maskIdOfTool[id] ~= nil end)
    if #unknown > 0 then
        error("Unknown tool id(s) on photo " .. photoId .. ": " .. table.concat(unknown, ", ")
            .. "; nothing was deleted")
    end
    local requestedToolIds = {}
    for _, toolId in ipairs(target.ids) do requestedToolIds[toolId] = true end
    for _, maskId in ipairs(snapshot.maskOrder) do
        local toolIds, remaining = {}, 0
        for _, toolId in ipairs(snapshot.masksById[maskId].toolIds) do
            if requestedToolIds[toolId] then
                toolIds[#toolIds + 1] = toolId
            else
                remaining = remaining + 1
            end
        end
        if #toolIds > 0 then
            plan.toolsByMask[#plan.toolsByMask + 1] = { maskId = maskId, toolIds = toolIds }
            for _, toolId in ipairs(toolIds) do
                plan.removedToolIds[#plan.removedToolIds + 1] = toolId
            end
            if remaining == 0 then
                plan.removedMaskIds[#plan.removedMaskIds + 1] = maskId
            end
        end
    end
    return plan
end

local function attempt(description, fn)
    local ok, err = LrTasks.pcall(fn)
    if not ok then
        error("Lightroom could not " .. description .. ": " .. tostring(err), 0)
    end
end

local function issueDeletions(plan)
    for _, maskId in ipairs(plan.maskIds) do
        attempt("delete mask " .. maskId, function()
            LrDevelopController.selectMask(maskId)
            LrDevelopController.deleteMask(maskId)
        end)
    end
    for _, entry in ipairs(plan.toolsByMask) do
        attempt("select mask " .. entry.maskId, function()
            LrDevelopController.selectMask(entry.maskId)
        end)
        for _, toolId in ipairs(entry.toolIds) do
            attempt("delete mask tool " .. toolId, function()
                LrDevelopController.deleteMaskTool(toolId)
            end)
        end
    end
end

local function deletionIsVisible(snapshot, plan)
    for _, maskId in ipairs(plan.removedMaskIds) do
        if snapshot.masksById[maskId] ~= nil then return false end
    end
    for _, toolId in ipairs(plan.removedToolIds) do
        if snapshot.maskIdOfTool[toolId] ~= nil then return false end
    end
    return true
end

local function deleteEmptiedMasksLeftBehind(snapshot, plan, alreadyDeleted)
    for _, maskId in ipairs(plan.removedMaskIds) do
        local mask = snapshot.masksById[maskId]
        if mask and #mask.toolIds == 0 and not alreadyDeleted[maskId] then
            alreadyDeleted[maskId] = true
            LrTasks.pcall(function()
                LrDevelopController.selectMask(maskId)
                LrDevelopController.deleteMask(maskId)
            end)
        end
    end
end

local function waitUntilDeletionIsVisible(photoId, plan)
    local emptiedMasksAlreadyDeleted = {}
    local latest
    local visible = DevelopSession.waitFor(function()
        latest = tryReadMaskSnapshot(photoId)
        if not latest then return false end
        deleteEmptiedMasksLeftBehind(latest, plan, emptiedMasksAlreadyDeleted)
        return deletionIsVisible(latest, plan)
    end, DELETION_SETTLE_TIMEOUT_SECONDS)
    if not visible then
        error("Lightroom did not remove the requested masks from photo " .. photoId
            .. " in Develop; the photo may be partly changed, so list_masks to check")
    end
    return latest
end

local function savedDeletionMatches(saved, plan)
    for _, maskId in ipairs(plan.removedMaskIds) do
        if saved.maskIds[maskId] then return false end
    end
    for _, toolId in ipairs(plan.removedToolIds) do
        if saved.toolIds[toolId] then return false end
    end
    return true
end

local function waitUntilDeletionIsSaved(catalog, photo, photoId, plan)
    local saved = DevelopSession.waitFor(function()
        return savedDeletionMatches(readSavedMasks(catalog, photo), plan)
    end, SAVE_SETTLE_TIMEOUT_SECONDS)
    if not saved then
        error("Lightroom showed the deletion in Develop but did not save it for photo " .. photoId
            .. "; list_masks to check, then call again")
    end
end

local function selectedToolName()
    if type(LrDevelopController.getSelectedTool) ~= "function" then return nil end
    local ok, name = LrTasks.pcall(LrDevelopController.getSelectedTool)
    if ok then return name end
    return nil
end

local function openMaskingTool()
    local previousTool = selectedToolName()
    if previousTool == MASKING_TOOL then return previousTool end
    LrDevelopController.selectTool(MASKING_TOOL)
    if previousTool ~= nil then
        local opened = DevelopSession.waitFor(function()
            return selectedToolName() == MASKING_TOOL
        end, TOOL_SWITCH_TIMEOUT_SECONDS)
        if not opened then error("Lightroom did not open the masking tool") end
    end
    return previousTool
end

local function reopenTool(previousTool)
    if previousTool == nil or previousTool == MASKING_TOOL then return end
    LrTasks.pcall(function() LrDevelopController.selectTool(previousTool) end)
end

function MaskDeleteHandler.deleteMasks(args)
    local photoId = requirePhotoId(args.photo_id)
    local target = parseTarget(args)
    requireDeleteApi("delete_masks")

    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, photoId)
    if not photo then
        error("Photo not found: " .. photoId)
    end

    local plan, remainingCount
    DevelopSession.withPhoto("delete_masks", catalog, photo, function()
        local previousTool = openMaskingTool()
        local ok, err = LrTasks.pcall(function()
            local snapshot = readMasksOnceDevelopIsReady(catalog, photo, photoId)
            plan = planDeletion(snapshot, target, photoId)
            if #plan.removedMaskIds == 0 and #plan.removedToolIds == 0 then return end
            issueDeletions(plan)
            remainingCount = waitUntilDeletionIsVisible(photoId, plan).count
        end)
        reopenTool(previousTool)
        if not ok then error(err, 0) end
    end)

    if remainingCount == nil then
        remainingCount = 0
    else
        waitUntilDeletionIsSaved(catalog, photo, photoId, plan)
    end

    Log.info(string.format("Deleted %d masks and %d mask tools from photo %s",
        #plan.removedMaskIds, #plan.removedToolIds, photoId))

    return {
        success = true,
        photo_id = photoId,
        deleted_mask_ids = plan.removedMaskIds,
        deleted_tool_ids = plan.removedToolIds,
        remaining_mask_count = remainingCount,
    }
end

local function countGroups(catalog, photos)
    local counts = {}
    for _, photo in ipairs(photos) do
        counts[photo] = readSavedMasks(catalog, photo).groupCount
    end
    return counts
end

function MaskDeleteHandler.deleteEmptyMasks(args)
    local photoIds = requirePhotoIdArray(args.photo_ids)
    local catalog = LrApplication.activeCatalog()
    if type(catalog.deleteAllEmptyMasks) ~= "function" then
        error("delete_empty_masks needs " .. DELETE_EMPTY_MINIMUM_VERSION .. " or later")
    end

    local resolved = PhotoLookup.resolveMany(catalog, photoIds)
    local photos, missingIds, seen = {}, {}, {}
    for _, entry in ipairs(resolved) do
        if not entry.photo then
            missingIds[#missingIds + 1] = tostring(entry.id)
        elseif not seen[entry.photo] then
            seen[entry.photo] = true
            photos[#photos + 1] = entry.photo
        end
    end

    local photosChanged = 0
    if #photos > 0 then
        local groupsBefore = countGroups(catalog, photos)
        catalog:withWriteAccessDo("Delete Empty Masks", function()
            catalog:deleteAllEmptyMasks(photos)
        end)
        local groupsAfter = countGroups(catalog, photos)
        for _, photo in ipairs(photos) do
            if groupsAfter[photo] < groupsBefore[photo] then
                photosChanged = photosChanged + 1
            end
        end
    end

    Log.info(string.format("Deleted empty masks: %d of %d photos changed (%d ids not found)",
        photosChanged, #photos, #missingIds))

    return {
        success = true,
        photos_changed = photosChanged,
        photos_checked = #photos,
        missing = missingIds,
    }
end

return MaskDeleteHandler
