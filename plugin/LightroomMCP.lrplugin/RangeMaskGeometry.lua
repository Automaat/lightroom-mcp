local RangeMaskGeometry = {}

local LUMINANCE = "luminance"
local COLOR = "color"

local RANGE_TYPE_OF_KIND = { [COLOR] = 1, [LUMINANCE] = 2 }
local KIND_OF_RANGE_TYPE = { [1] = COLOR, [2] = LUMINANCE }
local KIND_FIELD = { [LUMINANCE] = "luminance", [COLOR] = "color" }
local OTHER_KIND = { [LUMINANCE] = COLOR, [COLOR] = LUMINANCE }

local BLEND_MODE_OF_MODE = { add = 0, subtract = 1 }
local MASK_VALUE_OF_MODE = { add = 1, subtract = 0 }

local RANGE_VERSION = 3
local RANGE_SAMPLE_TYPE = 0
local POINT_MODEL_TRAILER = 0
local DEFAULT_FALLOFF = 0.1
local DEFAULT_COLOR_AMOUNT = 0.5
local STORED_DECIMALS = 1e6

local LUMINANCE_KEYS = { min = true, max = true, falloff = true }
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

local function parseLuminance(value)
    requireObject(value, "luminance", LUMINANCE_KEYS)
    if value.min == nil or value.max == nil then fail("luminance needs min and max") end
    local min = requireUnit(value.min, "luminance.min")
    local max = requireUnit(value.max, "luminance.max")
    if min > max then fail("luminance.min must not be greater than luminance.max") end
    local falloff = DEFAULT_FALLOFF
    if value.falloff ~= nil then falloff = requireUnit(value.falloff, "luminance.falloff") end
    if min == max and falloff == 0 then
        fail("luminance.min equals luminance.max and luminance.falloff is 0, which selects nothing")
    end
    return { min = min, max = max, falloff = falloff }
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

local PARSER_OF_KIND = { [LUMINANCE] = parseLuminance, [COLOR] = parseColor }

function RangeMaskGeometry.parseCreate(args)
    local kind = args.type
    if kind ~= LUMINANCE and kind ~= COLOR then
        fail('type must be "luminance" or "color"')
    end
    local otherField = KIND_FIELD[OTHER_KIND[kind]]
    if args[otherField] ~= nil then
        fail(otherField .. " only applies to " .. OTHER_KIND[kind] .. " range masks, not " .. kind .. " ones")
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
            fail("the luminance range is not ordered from 0 to 1, which Lightroom would replace with its default")
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
    if kind == LUMINANCE then
        local trapezoid = RangeMaskGeometry.trapezoidOf(range)
        requireOrderedTrapezoid(trapezoid)
        settings.LumRange = string.format("%.6f %.6f %.6f %.6f",
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
        MaskName = request.kind == LUMINANCE and "Luminance Range" or "Color Range",
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
    if kind == LUMINANCE then
        local values = numbersIn(range.LumRange)
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
