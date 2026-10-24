local RangeMaskGeometry = {}

local LUMINANCE = "luminance"
local COLOR = "color"
local DEPTH = "depth"

local RANGE_TYPE_OF_KIND = { [COLOR] = 1, [LUMINANCE] = 2, [DEPTH] = -1 }
local KIND_OF_RANGE_TYPE = { [1] = COLOR, [2] = LUMINANCE, [-1] = DEPTH }
local KIND_FIELD = { [LUMINANCE] = "luminance", [COLOR] = "color", [DEPTH] = "depth" }
local KINDS = { LUMINANCE, COLOR, DEPTH }
local TRAPEZOID_FIELD_OF_KIND = { [LUMINANCE] = "LumRange", [DEPTH] = "DepthRange" }
local NAME_OF_KIND = { [LUMINANCE] = "Luminance Range", [COLOR] = "Color Range", [DEPTH] = "Depth Range" }

local BLEND_MODE_OF_MODE = { add = 0, subtract = 1 }
local MASK_VALUE_OF_MODE = { add = 1, subtract = 0 }

local RANGE_VERSION = 3
local RANGE_SAMPLE_TYPE = 0
local POINT_MODEL_TRAILER = 0
local DEFAULT_FALLOFF = 0.1
local MIN_FULL_STRENGTH_WIDTH = 0.01
local DEFAULT_COLOR_AMOUNT = 0.5
local STORED_DECIMALS = 1e6

local TRAPEZOID_KEYS = { min = true, max = true, falloff = true }
local COLOR_KEYS = { sample = true, amount = true }
local SAMPLE_FIELDS = { "x", "y", "red", "green", "blue" }
local SAMPLE_KEYS = {}
for _, field in ipairs(SAMPLE_FIELDS) do SAMPLE_KEYS[field] = true end

local function fail(message)
    error(message, 0)
end

local function round(value)
    return math.floor(value * STORED_DECIMALS + 0.5) / STORED_DECIMALS
end

local function requireNumber(value, field)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        fail(field .. " must be a number")
    end
    return value
end

local function requireUnit(value, field)
    requireNumber(value, field)
    if value < 0 or value > 1 then
        fail(field .. " must be between 0 and 1")
    end
    return value
end

local function requireObject(value, field, allowedKeys)
    if type(value) ~= "table" then fail(field .. " must be an object") end
    for key in pairs(value) do
        if not allowedKeys[key] then fail(field .. " has an unknown property " .. tostring(key)) end
    end
    return value
end

local function optionalText(value, field)
    if value == nil then return nil end
    if type(value) ~= "string" or value == "" then fail(field .. " must be a non-empty string") end
    return value
end

local function parseTrapezoid(name)
    return function(value)
        requireObject(value, name, TRAPEZOID_KEYS)
        if value.min == nil or value.max == nil then fail(name .. " needs min and max") end
        local min = requireUnit(value.min, name .. ".min")
        local max = requireUnit(value.max, name .. ".max")
        if min > max then fail(name .. ".min must not be greater than " .. name .. ".max") end
        if round(max - min) < MIN_FULL_STRENGTH_WIDTH then
            fail(string.format(
                "%s.max must be at least %s above %s.min: Lightroom replaces a narrower range with its default",
                name, MIN_FULL_STRENGTH_WIDTH, name))
        end
        local falloff = DEFAULT_FALLOFF
        if value.falloff ~= nil then falloff = requireUnit(value.falloff, name .. ".falloff") end
        return { min = min, max = max, falloff = falloff }
    end
end

local function parseSample(value)
    requireObject(value, "color.sample", SAMPLE_KEYS)
    local sample = {}
    for _, field in ipairs(SAMPLE_FIELDS) do
        if value[field] == nil then fail("color.sample." .. field .. " is required") end
        sample[field] = requireUnit(value[field], "color.sample." .. field)
    end
    return sample
end

local function parseColor(value)
    if type(value) == "table" and type(value.sample) == "table" and value.sample[1] ~= nil then
        fail("color.sample must be a single sample point; more than one sample point is not supported")
    end
    requireObject(value, "color", COLOR_KEYS)
    if value.sample == nil then fail("color.sample is required") end
    local amount = DEFAULT_COLOR_AMOUNT
    if value.amount ~= nil then
        amount = requireNumber(value.amount, "color.amount")
        if amount <= 0 or amount > 1 then fail("color.amount must be greater than 0 and at most 1") end
    end
    return { sample = parseSample(value.sample), amount = amount }
end

local parseDepthTrapezoid = parseTrapezoid("depth")

local function parseDepth(value)
    local range = parseDepthTrapezoid(value)
    if range.min == 0 and range.max == 1 then
        fail("depth.min 0 with depth.max 1 covers the whole scene, which Lightroom stores as its default depth"
            .. " range and this tool cannot tell from a photo without a depth map; narrow the range")
    end
    return range
end

local PARSER_OF_KIND = {
    [LUMINANCE] = parseTrapezoid("luminance"),
    [COLOR] = parseColor,
    [DEPTH] = parseDepth,
}

function RangeMaskGeometry.parseCreate(args)
    local kind = args.type
    if RANGE_TYPE_OF_KIND[kind] == nil then
        fail('type must be "luminance", "color" or "depth"')
    end
    for _, otherKind in ipairs(KINDS) do
        local otherField = KIND_FIELD[otherKind]
        if otherKind ~= kind and args[otherField] ~= nil then
            fail(otherField .. " only applies to " .. otherKind .. " range masks, not " .. kind .. " ones")
        end
    end
    local ownField = KIND_FIELD[kind]
    if args[ownField] == nil then
        fail(ownField .. " is required for a " .. kind .. " range mask")
    end
    local range = PARSER_OF_KIND[kind](args[ownField])

    local maskId = optionalText(args.mask_id, "mask_id")
    local mode = args.mode == nil and "add" or args.mode
    if BLEND_MODE_OF_MODE[mode] == nil then fail('mode must be "add" or "subtract"') end
    if maskId == nil and mode == "subtract" then
        fail('mode "subtract" needs mask_id: a new mask has nothing to subtract from')
    end
    local name = optionalText(args.name, "name")
    if name ~= nil and maskId ~= nil then
        fail("name applies to a new mask; omit it when mask_id adds a component to an existing mask")
    end
    local invert = args.invert
    if invert == nil then invert = false end
    if type(invert) ~= "boolean" then fail("invert must be true or false") end
    return { kind = kind, range = range, maskId = maskId, mode = mode, name = name, invert = invert }
end

function RangeMaskGeometry.trapezoidOf(luminance)
    local lowerStart = round(math.max(0, luminance.min - luminance.falloff))
    local upperEnd = round(math.min(1, luminance.max + luminance.falloff))
    return { lowerStart, round(luminance.min), round(luminance.max), upperEnd }
end

local function requireOrderedTrapezoid(trapezoid)
    local previous = 0
    for _, value in ipairs(trapezoid) do
        if value < previous or value > 1 then
            fail("the range is not ordered from 0 to 1, which Lightroom would replace with its default")
        end
        previous = value
    end
end

local function rangeSettingsFor(kind, range)
    local settings = {
        Type = RANGE_TYPE_OF_KIND[kind],
        Version = RANGE_VERSION,
        SampleType = RANGE_SAMPLE_TYPE,
    }
    if TRAPEZOID_FIELD_OF_KIND[kind] ~= nil then
        local trapezoid = RangeMaskGeometry.trapezoidOf(range)
        requireOrderedTrapezoid(trapezoid)
        settings[TRAPEZOID_FIELD_OF_KIND[kind]] = string.format("%.6f %.6f %.6f %.6f",
            trapezoid[1], trapezoid[2], trapezoid[3], trapezoid[4])
        return settings
    end
    local sample = range.sample
    settings.ColorAmount = round(range.amount)
    settings.PointModels = {
        string.format("%.6f %.6f %.6f %.6f %.6f %d",
            sample.red, sample.green, sample.blue, sample.x, sample.y, POINT_MODEL_TRAILER),
    }
    return settings
end

function RangeMaskGeometry.toStoredFrame(request, frame)
    if request.kind ~= COLOR or frame.isNormal then return request end
    local stored = {}
    for key, value in pairs(request) do stored[key] = value end
    local sample = {}
    for key, value in pairs(request.range.sample) do sample[key] = value end
    sample.x, sample.y = frame.toStored(sample.x, sample.y)
    stored.range = { sample = sample, amount = request.range.amount }
    return stored
end

function RangeMaskGeometry.newComponent(request)
    return {
        What = "Mask/RangeMask",
        MaskActive = true,
        MaskInverted = request.invert,
        MaskBlendMode = BLEND_MODE_OF_MODE[request.mode],
        MaskValue = MASK_VALUE_OF_MODE[request.mode],
        MaskName = NAME_OF_KIND[request.kind],
        CorrectionRangeMask = rangeSettingsFor(request.kind, request.range),
    }
end

local function numbersIn(text)
    local numbers = {}
    for token in tostring(text):gmatch("%S+") do
        local number = tonumber(token)
        if number == nil then return nil end
        numbers[#numbers + 1] = number
    end
    return numbers
end

function RangeMaskGeometry.rangeOf(component)
    if component.What ~= "Mask/RangeMask" or type(component.CorrectionRangeMask) ~= "table" then return nil end
    local range = component.CorrectionRangeMask
    local kind = KIND_OF_RANGE_TYPE[range.Type]
    if TRAPEZOID_FIELD_OF_KIND[kind] ~= nil then
        local values = numbersIn(range[TRAPEZOID_FIELD_OF_KIND[kind]])
        if values == nil or #values ~= 4 then return nil end
        return kind, {
            min = round(values[2]),
            max = round(values[3]),
            lower_falloff = round(values[2] - values[1]),
            upper_falloff = round(values[4] - values[3]),
        }
    end
    if kind == COLOR then
        local point = type(range.PointModels) == "table" and numbersIn(range.PointModels[1]) or nil
        if point == nil or #point < 5 then return nil end
        return kind, {
            sample = {
                x = round(point[4]), y = round(point[5]),
                red = round(point[1]), green = round(point[2]), blue = round(point[3]),
            },
            amount = round(range.ColorAmount),
        }
    end
    return nil
end

RangeMaskGeometry.TOOL_TYPE = "rangeMask"

return RangeMaskGeometry
