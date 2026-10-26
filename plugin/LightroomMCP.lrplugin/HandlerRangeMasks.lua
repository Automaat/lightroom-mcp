local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local GuardedMaskWrite = require 'GuardedMaskWrite'
local ImageFrame = require 'ImageFrame'
local Log = require 'Log'
local MaskCreationAdjustments = require 'MaskCreationAdjustments'
local PhotoLookup = require 'PhotoLookup'
local RangeMaskGeometry = require 'RangeMaskGeometry'

local RangeMaskHandler = {}

local MASK_LIST_TIMEOUT_SECONDS = 5

local NO_DEPTH_MAP_PROBLEM = "Lightroom found no depth map on this photo, so a depth range would select nothing;"
    .. " depth range needs device depth such as an iPhone Portrait HEIC"

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

local function toolListed(masks, maskId, toolId, subtype)
    for _, mask in ipairs(masks) do
        if tostring(mask.ID) == tostring(maskId) then
            for _, tool in ipairs(mask.Tools or {}) do
                if tostring(tool.ID) == tostring(toolId)
                    and tool.Type == RangeMaskGeometry.TOOL_TYPE and tool.Subtype == subtype then
                    return true
                end
            end
        end
    end
    return false
end

local function problemUnlessListed(maskId, toolId, subtype)
    if maskId == nil or toolId == nil then
        return "Lightroom did not assign ids to the written mask"
    end
    local listed = DevelopSession.waitFor(function()
        local ok, masks = LrTasks.pcall(LrDevelopController.getAllMasks)
        return ok and type(masks) == "table" and toolListed(masks, maskId, toolId, subtype)
    end, MASK_LIST_TIMEOUT_SECONDS)
    if listed then return nil end
    return string.format("Lightroom's mask list has no %s %s tool %s in mask %s after the write",
        RangeMaskGeometry.TOOL_TYPE, subtype, tostring(toolId), tostring(maskId))
end

local function problemUnlessDepthMapFound(kind, component)
    if kind ~= "depth" or component.CorrectionRangeMask.LuminanceDepthSampleInfo ~= nil then return nil end
    return NO_DEPTH_MAP_PROBLEM
end

local function addRangeComponent(entries, request)
    local component = RangeMaskGeometry.newComponent(request)
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

local function sourceComponent(entries, copy, label)
    local _, entry = GuardedMaskWrite.findCorrection(entries, copy.maskId)
    if not entry then
        error(string.format("copy_sample_from: mask %s not found on photo %s", copy.maskId, label), 0)
    end
    for _, component in ipairs(entry.CorrectionMasks or {}) do
        if component.MaskID ~= nil and tostring(component.MaskID) == copy.toolId then return component end
    end
    error(string.format("copy_sample_from: tool %s is not in mask %s on photo %s", copy.toolId, copy.maskId, label), 0)
end

local function resolveCopiedSample(catalog, photo, photoId, request)
    local copy = request.copy
    local sourcePhotoId = copy.photoId or photoId
    local sourcePhoto = photo
    if copy.photoId ~= nil and copy.photoId ~= photoId then
        sourcePhoto = resolvePhoto(catalog, copy.photoId)
    end
    local component = sourceComponent(GuardedMaskWrite.readEntries(catalog, sourcePhoto), copy, sourcePhotoId)
    local range, problem = RangeMaskGeometry.copiableColorRange(component)
    if not range then
        error(string.format("copy_sample_from: tool %s %s", copy.toolId, problem), 0)
    end
    local sample = range.sample
    local x, y = ImageFrame.forPhoto(catalog, sourcePhoto).toDisplayed(sample.x, sample.y)
    request.range.sample = { x = x, y = y, l = sample.l, a = sample.a, b = sample.b }
    if request.range.amount == nil then request.range.amount = range.amount end
    return sourcePhotoId
end

local function resultFor(photoId, entries, location, displayed)
    local entry = entries[location.entry]
    local component = entry.CorrectionMasks[location.component]
    local kind, range = RangeMaskGeometry.rangeOf(component)
    local result = {
        success = true,
        photo_id = photoId,
        mask_id = tostring(entry.CorrectionID),
        tool_id = tostring(component.MaskID),
        type = kind,
        mode = component.MaskBlendMode == 1 and "subtract" or "add",
        invert = component.MaskInverted == true,
    }
    if kind ~= nil then result[kind] = range end
    if kind == "color" and displayed.kind == "color" then
        range.sample.x = displayed.range.sample.x
        range.sample.y = displayed.range.sample.y
    end
    return result
end

function RangeMaskHandler.createRangeMask(args)
    local photoId = requirePhotoId(args.photo_id)
    local displayedRequest = RangeMaskGeometry.parseCreate(args)
    local adjustments = MaskCreationAdjustments.parse(args)
    DevelopSession.requireMaskApi("create_range_mask")

    local catalog = LrApplication.activeCatalog()
    local photo = resolvePhoto(catalog, photoId)
    local copiedFrom
    if displayedRequest.copy ~= nil then
        copiedFrom = resolveCopiedSample(catalog, photo, photoId, displayedRequest)
    end
    local request = RangeMaskGeometry.toStoredFrame(displayedRequest, ImageFrame.forPhoto(catalog, photo))
    request.adjustments = adjustments
    local existing = GuardedMaskWrite.preflight(catalog, photo)
    addRangeComponent(existing, request)

    local location
    local written = DevelopSession.withPhoto("create_range_mask", catalog, photo, function()
        return GuardedMaskWrite.apply(catalog, photo, {
            description = "Create range mask",
            build = function(entries)
                location = addRangeComponent(entries, request)
                return entries
            end,
            crossCheck = function(actual)
                local entry = actual[location.entry]
                local component = entry.CorrectionMasks[location.component]
                local problem = problemUnlessDepthMapFound(request.kind, component)
                    or problemUnlessListed(entry.CorrectionID, component.MaskID, request.kind)
                if problem then return problem end
                MaskCreationAdjustments.confirm(photoId, entry.CorrectionID, adjustments)
            end,
        })
    end)

    local result = resultFor(photoId, written.entries, location, displayedRequest)
    result.new_mask = request.maskId == nil
    if copiedFrom ~= nil then
        result.copied_from = {
            photo_id = copiedFrom, mask_id = displayedRequest.copy.maskId, tool_id = displayedRequest.copy.toolId,
        }
    end
    Log.info(string.format("Placed %s range mask %s in mask %s on photo %s",
        request.kind, result.tool_id, result.mask_id, photoId))
    return result
end

return RangeMaskHandler
