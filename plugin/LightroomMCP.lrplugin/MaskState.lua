local AIMaskData = require 'AIMaskData'
local AiMaskParts = require 'AiMaskParts'

local MaskState = {}

local KIND_PREFIX = "Mask/"
local AGGREGATE_KIND = "Mask/Aggregate"
local PAINT_KIND = "Mask/Paint"
local ERASE_MASK_VALUE = 0
local SUBTRACT_BLEND_MODE = 1
local MAX_DEPTH = 4
local BACKGROUND_CATEGORY = 22
local STATE_ORDER = { "failed", "unknown", "pending", "computed" }

local KIND_BY_SUBTYPE = {
    [1] = "subject",
    [2] = "sky",
    [AiMaskParts.PEOPLE_SUBTYPE] = "people",
}

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function isArray(value)
    if type(value) ~= "table" then return false end
    local count = 0
    for key in pairs(value) do
        if not finite(key) or key % 1 ~= 0 or key < 1 or key > #value then return false end
        count = count + 1
    end
    return count == #value
end

local function nonEmptyString(value)
    return type(value) == "string" and value ~= "" and value or nil
end

local function worst(states)
    local seen = {}
    for _, state in ipairs(states) do seen[state] = true end
    for _, state in ipairs(STATE_ORDER) do
        if seen[state] then return state end
    end
    return nil
end

local function blendMode(value)
    if value == nil or value == 0 then return "add" end
    if value == SUBTRACT_BLEND_MODE then return "subtract" end
    return "unknown"
end

local function aiComponentState(component)
    local reason, digest = component.ErrorReason, component.MaskDigest
    if reason ~= nil and not finite(reason) then return "unknown" end
    if digest ~= nil and type(digest) ~= "string" then return "unknown" end
    if reason ~= nil and reason ~= 0 then return "failed" end
    if digest ~= nil and digest ~= "" then return "computed" end
    return "pending"
end

local function describeAi(component, described)
    local subtype, category = component.MaskSubType, component.MaskSubCategoryID
    if finite(subtype) or type(subtype) == "string" then described.subtype = subtype end
    local part = finite(category) and AiMaskParts.nameForCategory(category) or nil
    if subtype == AiMaskParts.LANDSCAPE_SUBTYPE and part ~= nil then
        described.kind = "landscape"
    elseif subtype == AiMaskParts.LANDSCAPE_SUBTYPE and category == BACKGROUND_CATEGORY then
        described.kind = "background"
    else
        described.kind = KIND_BY_SUBTYPE[subtype]
    end
    if described.kind == "people" or described.kind == "landscape" then described.part = part end
    described.state = aiComponentState(component)
    if finite(component.ErrorReason) and component.ErrorReason ~= 0 then
        described.error_reason = component.ErrorReason
    end
end

local function describeComponent(component, states, depth)
    if type(component) ~= "table" or type(component.What) ~= "string" or depth > MAX_DEPTH then
        states[#states + 1] = "unknown"
        return { type = "unknown", state = "unknown" }
    end
    local kind = component.What
    local described = {
        id = nonEmptyString(component.MaskID),
        type = kind:sub(1, #KIND_PREFIX) == KIND_PREFIX and kind:sub(#KIND_PREFIX + 1) or kind,
        mode = blendMode(component.MaskBlendMode),
    }
    if kind == PAINT_KIND and component.MaskValue == ERASE_MASK_VALUE then described.mode = "erase" end
    if component.MaskInverted == true then described.inverted = true end
    if kind == AIMaskData.KIND then
        describeAi(component, described)
        states[#states + 1] = described.state
    elseif kind == AGGREGATE_KIND then
        if not isArray(component.Masks) then
            described.state = "unknown"
            states[#states + 1] = "unknown"
            return described
        end
        local childStates = {}
        described.components = {}
        for _, child in ipairs(component.Masks) do
            described.components[#described.components + 1] = describeComponent(child, childStates, depth + 1)
        end
        described.state = worst(childStates)
        for _, state in ipairs(childStates) do states[#states + 1] = state end
    end
    return described
end

local function describeGroup(group)
    local described = { components = {} }
    if type(group) ~= "table" then
        described.state = "unknown"
        return described
    end
    described.id = nonEmptyString(group.CorrectionID)
    described.name = nonEmptyString(group.CorrectionName)
    if not isArray(group.CorrectionMasks) or #group.CorrectionMasks == 0 then
        described.state = "unknown"
        return described
    end
    local states = {}
    for _, component in ipairs(group.CorrectionMasks) do
        described.components[#described.components + 1] = describeComponent(component, states, 1)
    end
    described.state = worst(states)
    return described
end

function MaskState.summarize(settings)
    if type(settings) ~= "table" then return { state = "unknown" } end
    local groups = settings.MaskGroupBasedCorrections
    if groups == nil then return { count = 0, state = "none" } end
    if not isArray(groups) then return { state = "unknown" } end
    if #groups == 0 then return { count = 0, state = "none" } end
    local summary = { count = #groups, masks = {} }
    local states, seen = {}, {}
    for _, group in ipairs(groups) do
        local described = describeGroup(group)
        if described.id then
            if seen[described.id] then described.state = "unknown" end
            seen[described.id] = true
        end
        summary.masks[#summary.masks + 1] = described
        states[#states + 1] = described.state
    end
    summary.state = worst(states) or "none"
    return summary
end

return MaskState
