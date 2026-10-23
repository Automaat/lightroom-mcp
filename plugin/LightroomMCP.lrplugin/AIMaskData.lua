local AIMaskData = {}

AIMaskData.KIND = "Mask/Image"
AIMaskData.COMPUTED_KEYS = { "MaskDigest", "InputDigest", "LocalInputDigest" }
AIMaskData.COMPUTATION_MARKER_KEY = "MaskDigest"

function AIMaskData.containsAIMasks(settings)
    local groups = type(settings) == "table" and settings.MaskGroupBasedCorrections
    if type(groups) ~= "table" then
        return false
    end
    for _, correction in ipairs(groups) do
        local masks = type(correction) == "table" and correction.CorrectionMasks
        if type(masks) == "table" then
            for _, mask in ipairs(masks) do
                if type(mask) == "table" and mask.What == AIMaskData.KIND then
                    return true
                end
            end
        end
    end
    return false
end

local function shallowCopy(source)
    local copy = {}
    for key, value in pairs(source) do
        copy[key] = value
    end
    return copy
end

function AIMaskData.withoutComputedData(settings)
    if not AIMaskData.containsAIMasks(settings) then
        return settings
    end
    local stripped = shallowCopy(settings)
    stripped.MaskGroupBasedCorrections = {}
    for groupIndex, correction in ipairs(settings.MaskGroupBasedCorrections) do
        local strippedCorrection = correction
        if type(correction) == "table" then
            strippedCorrection = shallowCopy(correction)
        end
        if type(correction) == "table" and type(correction.CorrectionMasks) == "table" then
            strippedCorrection.CorrectionMasks = {}
            for maskIndex, mask in ipairs(correction.CorrectionMasks) do
                local strippedMask = mask
                if type(mask) == "table" then
                    strippedMask = shallowCopy(mask)
                    if mask.What == AIMaskData.KIND then
                        for _, key in ipairs(AIMaskData.COMPUTED_KEYS) do
                            strippedMask[key] = nil
                        end
                    end
                end
                strippedCorrection.CorrectionMasks[maskIndex] = strippedMask
            end
        end
        stripped.MaskGroupBasedCorrections[groupIndex] = strippedCorrection
    end
    return stripped
end

function AIMaskData.correctionIsComputed(correction)
    local components = type(correction) == "table" and correction.CorrectionMasks
    if type(components) ~= "table" then return false end
    local sawAIMask = false
    for _, component in ipairs(components) do
        if type(component) == "table" and component.What == AIMaskData.KIND then
            sawAIMask = true
            if component[AIMaskData.COMPUTATION_MARKER_KEY] == nil then return false end
        end
    end
    return sawAIMask
end

return AIMaskData
