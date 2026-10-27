local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local BrushStrokes = require 'BrushStrokes'
local DevelopSession = require 'DevelopSession'
local GuardedMaskWrite = require 'GuardedMaskWrite'
local ImageFrame = require 'ImageFrame'
local Log = require 'Log'
local MaskCreationAdjustments = require 'MaskCreationAdjustments'
local PhotoLookup = require 'PhotoLookup'

local BrushMaskHandler = {}

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

local function optionalText(value, field)
    if value == nil then return nil end
    if type(value) ~= "string" or value == "" then error(field .. " must be a non-empty string", 0) end
    return value
end

local function toolListed(masks, maskId, toolId)
    for _, mask in ipairs(masks) do
        if tostring(mask.ID) == tostring(maskId) then
            for _, tool in ipairs(mask.Tools or {}) do
                if tostring(tool.ID) == tostring(toolId) and tool.Type == BrushStrokes.TOOL_TYPE then
                    return true
                end
            end
        end
    end
    return false
end

local function problemUnlessListed(maskId, toolId)
    if maskId == nil or toolId == nil then
        return "Lightroom did not assign ids to the written mask"
    end
    local listed = DevelopSession.waitFor(function()
        local ok, masks = LrTasks.pcall(LrDevelopController.getAllMasks)
        return ok and type(masks) == "table" and toolListed(masks, maskId, toolId)
    end, MASK_LIST_TIMEOUT_SECONDS)
    if listed then return nil end
    return string.format("Lightroom's mask list has no %s tool %s in mask %s after the write",
        BrushStrokes.TOOL_TYPE, tostring(toolId), tostring(maskId))
end

local function resultFor(photoId, entries, location, strokesAdded)
    local entry = entries[location.entry]
    local component = entry.CorrectionMasks[location.component]
    return {
        success = true,
        photo_id = photoId,
        mask_id = tostring(entry.CorrectionID),
        tool_id = tostring(component.MaskID),
        strokes_added = strokesAdded,
        stroke_count = #component.Masks,
    }
end

local function writeWithBrushCrossCheck(catalog, photo, toolName, description, build, locationOf, photoId, adjustments)
    return DevelopSession.withPhoto(toolName, catalog, photo, function()
        MaskCreationAdjustments.requireLiveRanges(adjustments)
        return GuardedMaskWrite.apply(catalog, photo, {
            description = description,
            build = build,
            crossCheck = function(actual)
                local location = locationOf()
                local entry = actual[location.entry]
                local component = entry.CorrectionMasks[location.component]
                local problem = problemUnlessListed(entry.CorrectionID, component.MaskID)
                if problem then return problem end
                MaskCreationAdjustments.confirm(photoId, entry.CorrectionID, adjustments)
            end,
        })
    end)
end

local function addBrush(entries, request)
    local component = BrushStrokes.newAggregate(request.strokes)
    if request.maskId == nil then
        entries[#entries + 1] = GuardedMaskWrite.newCorrection(request.name or component.MaskName, { component })
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

function BrushMaskHandler.createBrushMask(args)
    local photoId = requirePhotoId(args.photo_id)
    local strokes = BrushStrokes.parseStrokes(args.strokes)
    local maskId = optionalText(args.mask_id, "mask_id")
    local name = optionalText(args.name, "name")
    local adjustments = MaskCreationAdjustments.parse(args)
    if name ~= nil and maskId ~= nil then
        error("name applies to a new mask; omit it when mask_id adds a brush to an existing mask", 0)
    end
    DevelopSession.requireMaskApi("create_brush_mask")

    local catalog = LrApplication.activeCatalog()
    local photo = resolvePhoto(catalog, photoId)
    local request = {
        strokes = BrushStrokes.toStoredFrame(strokes, ImageFrame.forPhoto(catalog, photo)),
        maskId = maskId,
        name = name,
        adjustments = adjustments,
    }
    addBrush(GuardedMaskWrite.preflight(catalog, photo), request)

    local location
    local written = writeWithBrushCrossCheck(catalog, photo, "create_brush_mask", "Create brush mask",
        function(entries)
            location = addBrush(entries, request)
            return entries
        end,
        function() return location end, photoId, adjustments)

    local result = resultFor(photoId, written.entries, location, #strokes)
    result.new_mask = maskId == nil
    Log.info(string.format("Painted %d brush stroke(s) as tool %s in mask %s on photo %s",
        #strokes, result.tool_id, result.mask_id, photoId))
    return result
end

local function appendToBrush(entries, request)
    local entryIndex, componentIndex, component = GuardedMaskWrite.findComponent(entries, request.toolId)
    if not entryIndex then
        error("Brush tool not found on this photo: " .. request.toolId, 0)
    end
    if not BrushStrokes.isBrush(component) then
        error(string.format("Tool %s is a %s mask, not a brush", request.toolId, tostring(component.What)), 0)
    end
    BrushStrokes.appendStrokes(component, request.strokes)
    return { entry = entryIndex, component = componentIndex }
end

function BrushMaskHandler.addBrushStrokes(args)
    local photoId = requirePhotoId(args.photo_id)
    local toolId = optionalText(args.tool_id, "tool_id")
    if toolId == nil then error("tool_id is required", 0) end
    local strokes = BrushStrokes.parseStrokes(args.strokes)
    DevelopSession.requireMaskApi("add_brush_strokes")

    local catalog = LrApplication.activeCatalog()
    local photo = resolvePhoto(catalog, photoId)
    local request = {
        toolId = toolId,
        strokes = BrushStrokes.toStoredFrame(strokes, ImageFrame.forPhoto(catalog, photo)),
    }
    appendToBrush(GuardedMaskWrite.preflight(catalog, photo), request)

    local location
    local written = writeWithBrushCrossCheck(catalog, photo, "add_brush_strokes", "Add brush strokes",
        function(entries)
            location = appendToBrush(entries, request)
            return entries
        end,
        function() return location end)

    local result = resultFor(photoId, written.entries, location, #strokes)
    Log.info(string.format("Added %d brush stroke(s) to tool %s in mask %s on photo %s",
        #strokes, result.tool_id, result.mask_id, photoId))
    return result
end

return BrushMaskHandler
