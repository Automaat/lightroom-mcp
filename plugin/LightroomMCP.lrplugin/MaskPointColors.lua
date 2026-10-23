local MaskPointColors = {}

MaskPointColors.MINIMUM_VERSION_LABEL = "Lightroom Classic 13.2"
MaskPointColors.MINIMUM_MAJOR = 13
MaskPointColors.MINIMUM_MINOR = 2
MaskPointColors.MAX_SWATCHES = 8
MaskPointColors.VALUE_TOLERANCE = 0.01

local SCALARS = {
    { name = "SrcHue", low = 0, high = 6, required = true },
    { name = "SrcSat", low = 0, high = 1, required = true },
    { name = "SrcLum", low = 0, high = 1, required = true },
    { name = "HueShift", low = -1, high = 1 },
    { name = "SatScale", low = -1, high = 1 },
    { name = "LumScale", low = -1, high = 1 },
    { name = "RangeAmount", low = 0, high = 1 },
}

local RANGES = { "HueRange", "SatRange", "LumRange" }
local RANGE_EDGES = { "LowerNone", "LowerFull", "UpperFull", "UpperNone" }

MaskPointColors.scalars = SCALARS
MaskPointColors.ranges = RANGES
MaskPointColors.rangeEdges = RANGE_EDGES

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function formatNumber(value)
    return string.format("%g", value)
end

local function requireNumberInRange(value, label, low, high)
    if not isFiniteNumber(value) then
        error(label .. " must be a number")
    end
    if value < low or value > high then
        error(string.format("%s %s is outside its range %s to %s", label, formatNumber(value),
            formatNumber(low), formatNumber(high)))
    end
end

local function knownNames()
    local names = {}
    for _, scalar in ipairs(SCALARS) do names[#names + 1] = scalar.name end
    for _, range in ipairs(RANGES) do names[#names + 1] = range end
    return names
end

local function isKnownField(key)
    for _, name in ipairs(knownNames()) do
        if name == key then return true end
    end
    return false
end

local function isRangeEdge(key)
    for _, edge in ipairs(RANGE_EDGES) do
        if edge == key then return true end
    end
    return false
end

local function requireRange(value, label)
    if type(value) ~= "table" or next(value) == nil then
        error(label .. " must be an object with " .. table.concat(RANGE_EDGES, ", "))
    end
    for key in pairs(value) do
        if type(key) ~= "string" or not isRangeEdge(key) then
            error(string.format("Unknown field %s.%s; valid fields: %s", label, tostring(key),
                table.concat(RANGE_EDGES, ", ")))
        end
    end
    for _, edge in ipairs(RANGE_EDGES) do
        requireNumberInRange(value[edge], label .. "." .. edge, 0, 1)
    end
end

function MaskPointColors.requireSwatch(value, label, requireSource)
    if type(value) ~= "table" or next(value) == nil then
        error(label .. " is required: an object of Point Color swatch fields")
    end
    for key in pairs(value) do
        if type(key) ~= "string" or not isKnownField(key) then
            error(string.format("Unknown swatch field %s; valid fields: %s", tostring(key),
                table.concat(knownNames(), ", ")))
        end
    end
    for _, scalar in ipairs(SCALARS) do
        local amount = value[scalar.name]
        if amount == nil then
            if requireSource and scalar.required then
                error(label .. "." .. scalar.name .. " is required")
            end
        else
            requireNumberInRange(amount, label .. "." .. scalar.name, scalar.low, scalar.high)
        end
    end
    for _, range in ipairs(RANGES) do
        if value[range] ~= nil then
            requireRange(value[range], label .. "." .. range)
        end
    end
end

local function normalizeRange(raw)
    if type(raw) ~= "table" then return nil end
    local range = {}
    for _, edge in ipairs(RANGE_EDGES) do
        if not isFiniteNumber(raw[edge]) then return nil end
        range[edge] = raw[edge]
    end
    return range
end

function MaskPointColors.normalizeSwatch(raw)
    if type(raw) ~= "table" then return nil end
    local swatch = {}
    for _, scalar in ipairs(SCALARS) do
        local amount = raw[scalar.name]
        if isFiniteNumber(amount) then
            swatch[scalar.name] = amount
        elseif scalar.required then
            return nil
        end
    end
    for _, range in ipairs(RANGES) do
        swatch[range] = normalizeRange(raw[range])
    end
    return swatch
end

function MaskPointColors.normalizeList(raw)
    local swatches = {}
    if type(raw) ~= "table" then return swatches end
    for index = 1, #raw do
        local swatch = MaskPointColors.normalizeSwatch(raw[index])
        if swatch == nil then
            error("Lightroom returned an unreadable Point Color swatch at index " .. index)
        end
        swatches[index] = swatch
    end
    return swatches
end

local function copyRange(range)
    local copied = {}
    for _, edge in ipairs(RANGE_EDGES) do copied[edge] = range[edge] end
    return copied
end

function MaskPointColors.copySwatch(swatch)
    local copied = {}
    for _, scalar in ipairs(SCALARS) do copied[scalar.name] = swatch[scalar.name] end
    for _, range in ipairs(RANGES) do
        if swatch[range] then copied[range] = copyRange(swatch[range]) end
    end
    return copied
end

function MaskPointColors.merge(current, patch)
    local merged = MaskPointColors.copySwatch(current)
    for _, scalar in ipairs(SCALARS) do
        if patch[scalar.name] ~= nil then merged[scalar.name] = patch[scalar.name] end
    end
    for _, range in ipairs(RANGES) do
        if patch[range] ~= nil then merged[range] = copyRange(patch[range]) end
    end
    return merged
end

local function nearlyEqual(actual, wanted)
    return actual ~= nil and math.abs(actual - wanted) <= MaskPointColors.VALUE_TOLERANCE
end

function MaskPointColors.holds(actual, wanted)
    if actual == nil then return false end
    for _, scalar in ipairs(SCALARS) do
        if wanted[scalar.name] ~= nil and not nearlyEqual(actual[scalar.name], wanted[scalar.name]) then
            return false
        end
    end
    for _, range in ipairs(RANGES) do
        if wanted[range] ~= nil then
            if actual[range] == nil then return false end
            for _, edge in ipairs(RANGE_EDGES) do
                if not nearlyEqual(actual[range][edge], wanted[range][edge]) then return false end
            end
        end
    end
    return true
end

function MaskPointColors.sameSource(left, right)
    return MaskPointColors.holds(left, {
        SrcHue = right.SrcHue,
        SrcSat = right.SrcSat,
        SrcLum = right.SrcLum,
    })
end

function MaskPointColors.indexed(swatches)
    local listed = {}
    for index, swatch in ipairs(swatches) do
        local entry = MaskPointColors.copySwatch(swatch)
        entry.index = index
        listed[index] = entry
    end
    return listed
end

return MaskPointColors
