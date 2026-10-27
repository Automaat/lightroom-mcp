local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local GradientGeometry = require 'GradientGeometry'
local GuardedMaskWrite = require 'GuardedMaskWrite'
local ImageFrame = require 'ImageFrame'
local Log = require 'Log'
local MaskCreationAdjustments = require 'MaskCreationAdjustments'
local PhotoLookup = require 'PhotoLookup'

local GradientMaskHandler = {}

local MASK_LIST_TIMEOUT_SECONDS = 5

local function requirePhotoId(value)
    if type(value) == "number" then return tostring(value) end
    if type(value) ~= "string" or value == "" then
        error("photo_id is required")
    end
    return value
end

local function resolvePhoto(catalog, photoId)
    local photo = PhotoLookup.resolveOne(catalog, photoId)
    if not photo then
        error("Photo not found: " .. photoId)
    end
    return photo
end

local function readDisplayedAspect(catalog, photo)
    local dimensions
    catalog:withReadAccessDo(function() dimensions = photo:getRawMetadata("dimensions") end)
    if type(dimensions) ~= "table" then return nil end
    local width, height = tonumber(dimensions.width), tonumber(dimensions.height)
    if width == nil or height == nil or width <= 0 or height <= 0 then return nil end
    return width / height
end

local function toolListed(masks, maskId, toolId, toolType)
    for _, mask in ipairs(masks) do
        if tostring(mask.ID) == tostring(maskId) then
            for _, tool in ipairs(mask.Tools or {}) do
                if tostring(tool.ID) == tostring(toolId) and tool.Type == toolType then
                    return true
                end
            end
        end
    end
    return false
end

local function problemUnlessListed(maskId, toolId, toolType)
    if maskId == nil or toolId == nil then
        return "Lightroom did not assign ids to the written mask"
    end
    local listed = DevelopSession.waitFor(function()
        local ok, masks = LrTasks.pcall(LrDevelopController.getAllMasks)
        return ok and type(masks) == "table" and toolListed(masks, maskId, toolId, toolType)
    end, MASK_LIST_TIMEOUT_SECONDS)
    if listed then return nil end
    return string.format("Lightroom's mask list has no %s tool %s in mask %s after the write",
        toolType, tostring(toolId), tostring(maskId))
end

local function placementFor(catalog, photo)
    local frame = ImageFrame.forPhoto(catalog, photo)
    local storedAspect = GradientGeometry.storedAspectOf(frame, readDisplayedAspect(catalog, photo))
    return { frame = frame, storedAspect = storedAspect }
end

local function resultFor(photoId, entries, location, placement)
    local entry = entries[location.entry]
    local component = entry.CorrectionMasks[location.component]
    local storedShape, storedGeometry = GradientGeometry.geometryOf(component, placement.storedAspect)
    local shape = storedShape
    local geometry = GradientGeometry.toDisplayedFrame(storedShape, storedGeometry, placement.frame)
    return {
        success = true,
        photo_id = photoId,
        mask_id = tostring(entry.CorrectionID),
        tool_id = tostring(component.MaskID),
        shape = shape,
        mode = component.MaskBlendMode == 1 and "subtract" or "add",
        geometry = geometry,
    }
end

local function addGradient(entries, request, placement)
    local storedGeometry = GradientGeometry.toStoredFrame(request.shape, request.geometry, placement.frame)
    local component = GradientGeometry.newComponent(request.shape, storedGeometry, request.mode,
        placement.storedAspect)
    if request.maskId == nil then
        local name = request.name or component.MaskName
        entries[#entries + 1] = GuardedMaskWrite.newCorrection(name, { component })
        MaskCreationAdjustments.write(entries[#entries], request.adjustments)
        return { entry = #entries, component = 1 }
    end
    local index, entry = GuardedMaskWrite.findCorrection(entries, request.maskId)
    if not index then
        error("Mask not found on this photo: " .. request.maskId, 0)
    end
    entry.CorrectionMasks[#entry.CorrectionMasks + 1] = component
    return { entry = index, component = #entry.CorrectionMasks }
end

function GradientMaskHandler.createGradientMask(args)
    local photoId = requirePhotoId(args.photo_id)
    local request = GradientGeometry.parseCreate(args)
    request.adjustments = MaskCreationAdjustments.parse(args)
    DevelopSession.requireMaskApi("create_gradient_mask")

    local catalog = LrApplication.activeCatalog()
    local photo = resolvePhoto(catalog, photoId)
    local placement = placementFor(catalog, photo)
    local existing = GuardedMaskWrite.preflight(catalog, photo)
    addGradient(existing, request, placement)

    local location
    local toolType = GradientGeometry.TOOL_TYPE_OF_SHAPE[request.shape]
    local written = DevelopSession.withPhoto("create_gradient_mask", catalog, photo, function()
        MaskCreationAdjustments.requireLiveRanges(request.adjustments)
        return GuardedMaskWrite.apply(catalog, photo, {
            description = "Create gradient mask",
            build = function(entries)
                location = addGradient(entries, request, placement)
                return entries
            end,
            crossCheck = function(actual)
                local entry = actual[location.entry]
                local component = entry.CorrectionMasks[location.component]
                local problem = problemUnlessListed(entry.CorrectionID, component.MaskID, toolType)
                if problem then return problem end
                MaskCreationAdjustments.confirm(photoId, entry.CorrectionID, request.adjustments)
            end,
        })
    end)

    local result = resultFor(photoId, written.entries, location, placement)
    result.new_mask = request.maskId == nil
    Log.info(string.format("Placed %s gradient %s in mask %s on photo %s",
        request.shape, result.tool_id, result.mask_id, photoId))
    return result
end

local function reshapeGradient(entries, request, placement)
    local entryIndex, componentIndex, component = GuardedMaskWrite.findComponent(entries, request.toolId)
    if not entryIndex then
        error("Gradient tool not found on this photo: " .. request.toolId, 0)
    end
    local shape, storedGeometry = GradientGeometry.geometryOf(component, placement.storedAspect)
    if not shape then
        error(string.format("Tool %s is a %s mask, not a linear or radial gradient",
            request.toolId, tostring(component.What)), 0)
    end
    local displayedGeometry = GradientGeometry.toDisplayedFrame(shape, storedGeometry, placement.frame)
    local merged = GradientGeometry.mergeChanges(shape, displayedGeometry, request.changes)
    local storedMerged = GradientGeometry.toStoredFrame(shape, merged, placement.frame)
    GradientGeometry.applyGeometry(shape, component, storedMerged, placement.storedAspect)
    local entry = entries[entryIndex]
    entry.CorrectionReferenceX = nil
    entry.CorrectionReferenceY = nil
    return { entry = entryIndex, component = componentIndex, shape = shape }
end

function GradientMaskHandler.updateGradientMask(args)
    local photoId = requirePhotoId(args.photo_id)
    local request = GradientGeometry.parseUpdate(args)
    DevelopSession.requireMaskApi("update_gradient_mask")

    local catalog = LrApplication.activeCatalog()
    local photo = resolvePhoto(catalog, photoId)
    local placement = placementFor(catalog, photo)
    local existing = GuardedMaskWrite.preflight(catalog, photo)
    reshapeGradient(existing, request, placement)

    local location
    local written = DevelopSession.withPhoto("update_gradient_mask", catalog, photo, function()
        return GuardedMaskWrite.apply(catalog, photo, {
            description = "Update gradient mask",
            build = function(entries)
                location = reshapeGradient(entries, request, placement)
                return entries
            end,
            crossCheck = function(actual)
                local entry = actual[location.entry]
                local component = entry.CorrectionMasks[location.component]
                local toolType = GradientGeometry.TOOL_TYPE_OF_SHAPE[location.shape]
                return problemUnlessListed(entry.CorrectionID, component.MaskID, toolType)
            end,
        })
    end)

    local result = resultFor(photoId, written.entries, location, placement)
    Log.info(string.format("Reshaped %s gradient %s in mask %s on photo %s",
        result.shape, result.tool_id, result.mask_id, photoId))
    return result
end

return GradientMaskHandler
