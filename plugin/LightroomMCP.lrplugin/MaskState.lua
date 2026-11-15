local AIMaskData = require 'AIMaskData'

-- Read-only summary of the masks saved in a photo's develop settings.
--
-- list_masks drives the Develop module, so it reads one photo at a time and
-- briefly moves the selection. The saved settings answer a narrower question
-- without touching the UI: how many mask groups does a photo hold, what are
-- they made of, and has Lightroom finished computing the AI ones? Reading
-- them is the safe way to poll a photo that is still computing, because
-- nothing here writes or selects.
--
-- State of an AI component (What == "Mask/Image"):
--   failed    ErrorReason is a nonzero number
--   computed  a nonempty MaskDigest and no error
--   pending   no digest yet
--   unknown   a field has an unexpected type
-- A digest proves that a computation was saved. It does not prove that the
-- mask covers the right area.
local MaskState = {}

local KIND_PREFIX = "Mask/"
-- Worst state first: one failed component fails its group, and a group
-- or photo is computed only when every AI part of it is.
local STATE_ORDER = { "failed", "unknown", "pending", "computed" }

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

local function worst(states)
    local seen = {}
    for _, state in ipairs(states) do seen[state] = true end
    for _, state in ipairs(STATE_ORDER) do
        if seen[state] then return state end
    end
    return nil
end

local function aiComponentState(component)
    local reason, digest = component.ErrorReason, component.MaskDigest
    if reason ~= nil and not finite(reason) then return "unknown" end
    if digest ~= nil and type(digest) ~= "string" then return "unknown" end
    if reason ~= nil and reason ~= 0 then return "failed" end
    if digest ~= nil and digest ~= "" then return "computed" end
    return "pending"
end

local function describeComponent(component)
    if type(component) ~= "table" or type(component.What) ~= "string" then
        return { type = "unknown", state = "unknown" }
    end
    local kind = component.What
    local described = { type = kind:sub(1, #KIND_PREFIX) == KIND_PREFIX and kind:sub(#KIND_PREFIX + 1) or kind }
    if component.MaskInverted == true then described.inverted = true end
    if kind == AIMaskData.KIND then
        if finite(component.MaskSubType) or type(component.MaskSubType) == "string" then
            described.subtype = component.MaskSubType
        end
        described.state = aiComponentState(component)
        if finite(component.ErrorReason) and component.ErrorReason ~= 0 then
            described.error_reason = component.ErrorReason
        end
    end
    return described
end

local function describeGroup(group)
    local described = { components = {} }
    if type(group) ~= "table" then
        described.state = "unknown"
        return described
    end
    if type(group.CorrectionID) == "string" and group.CorrectionID ~= "" then described.id = group.CorrectionID end
    if not isArray(group.CorrectionMasks) or #group.CorrectionMasks == 0 then
        described.state = "unknown"
        return described
    end
    local aiStates = {}
    for _, component in ipairs(group.CorrectionMasks) do
        local item = describeComponent(component)
        described.components[#described.components + 1] = item
        aiStates[#aiStates + 1] = item.state
    end
    -- Only AI groups carry a state; gradients, brushes and ranges are saved
    -- as they are and have nothing to compute.
    described.state = worst(aiStates)
    return described
end

-- Returns { count, state, masks } for a photo's develop settings.
--   count  mask groups saved on the photo; nil when the saved shape is not a list
--   state  "none" without AI components, otherwise the worst component state
--   masks  one { id, state, components } per group; absent when count is 0 or nil
-- Component entries hold the saved type without its "Mask/" prefix, "inverted"
-- when set and, for AI components, Lightroom's raw MaskSubType as subtype and
-- the state above. MaskDigest is never copied out: it is a large computed
-- blob, and the state already says whether one is saved.
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
        -- A repeated group id means the saved list cannot be trusted.
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
