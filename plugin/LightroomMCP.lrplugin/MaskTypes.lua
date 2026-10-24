local MaskTypes = {}

MaskTypes.NAMES = { "subject", "sky", "background" }

MaskTypes.SPECS = {
    subject = { toolType = "aiSelection", subtype = "subject" },
    sky = { toolType = "aiSelection", subtype = "sky" },
    background = { toolType = "aiSelection", subtype = "background" },
}

function MaskTypes.require(value)
    local spec = type(value) == "string" and MaskTypes.SPECS[value] or nil
    if not spec then
        error("type must be one of: " .. table.concat(MaskTypes.NAMES, ", "))
    end
    return value, spec
end

return MaskTypes
