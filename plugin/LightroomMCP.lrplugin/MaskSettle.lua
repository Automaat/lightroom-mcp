local DevelopSession = require 'DevelopSession'
local GuardedMaskWrite = require 'GuardedMaskWrite'

local MaskSettle = {}

local COMMIT_TIMEOUT_SECONDS = 8
local MASK_SHAPE_FIELD = "CorrectionMasks"
local NUMBER_TOLERANCE = 1e-9

local function sameValue(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) == "number" then return math.abs(left - right) <= NUMBER_TOLERANCE end
    if type(left) ~= "table" then return left == right end
    for key, item in pairs(left) do
        if not sameValue(item, right[key]) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

function MaskSettle.storedAdjustmentFields(catalog, photo, maskId)
    local _, entry = GuardedMaskWrite.findCorrection(GuardedMaskWrite.readEntries(catalog, photo), maskId)
    if entry == nil then return nil end
    local fields = {}
    for key, value in pairs(entry) do
        if key ~= MASK_SHAPE_FIELD then fields[key] = value end
    end
    return fields
end

function MaskSettle.sameFields(left, right)
    if left == nil or right == nil then return left == right end
    return sameValue(left, right)
end

function MaskSettle.waitForCommit(catalog, photo, maskId, fieldsBefore)
    return DevelopSession.waitFor(function()
        return not MaskSettle.sameFields(MaskSettle.storedAdjustmentFields(catalog, photo, maskId), fieldsBefore)
    end, COMMIT_TIMEOUT_SECONDS)
end

MaskSettle.COMMIT_TIMEOUT_SECONDS = COMMIT_TIMEOUT_SECONDS

return MaskSettle
