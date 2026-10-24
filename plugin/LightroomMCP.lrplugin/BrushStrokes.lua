local BrushFeather = require 'BrushFeather'

local BrushStrokes = {}

local AGGREGATE_WHAT = "Mask/Aggregate"
local PAINT_WHAT = "Mask/Paint"

local DEFAULT_RADIUS = 0.14
local DEFAULT_FLOW = 1
local MAX_RADIUS = 1
local MIN_FLOW = 0.01
local MIN_DENSITY = 0.01
local MAX_STROKES = 50
local MAX_POINTS_PER_STROKE = 1000
local MAX_DABS_PER_STROKE = 2000
local DAB_SPACING_IN_RADII = 0.5
local FLOW_TOKEN_DECIMALS = 10000
local STORED_DECIMALS = 1000000
local ERASE_VALUE = 0
local DISTANCE_EPSILON = 1e-9

local STROKE_FIELDS = { points = true, radius = true, flow = true, feather = true, density = true, erase = true }
local REASON_OF_UNSUPPORTED_FIELD = {
    size = "size is not supported: Lightroom's Size slider is a screen size, so the stored radius changes with the"
        .. " zoom of the Develop view; use radius, a fraction of the longer edge of the image",
}

local function fail(message)
    error(message, 0)
end

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function parseCoordinate(value, field)
    if not isFiniteNumber(value) then fail(field .. " must be a number") end
    if value < 0 or value > 1 then
        fail(field .. " is outside the image: it must be between 0 and 1 (normalized image coordinates)")
    end
    return value
end

local function parsePoint(value, field)
    if type(value) ~= "table" then fail(field .. " must be an object with x and y") end
    for key in pairs(value) do
        if key ~= "x" and key ~= "y" then fail(field .. " has an unknown property " .. tostring(key)) end
    end
    return { x = parseCoordinate(value.x, field .. ".x"), y = parseCoordinate(value.y, field .. ".y") }
end

local function parseRadius(value, field)
    if value == nil then return DEFAULT_RADIUS end
    if not isFiniteNumber(value) or value <= 0 or value > MAX_RADIUS then
        fail(string.format("%s must be greater than 0 and at most %d", field, MAX_RADIUS))
    end
    return value
end

local function roundFlow(value)
    return math.floor(value * FLOW_TOKEN_DECIMALS + 0.5) / FLOW_TOKEN_DECIMALS
end

local function parseFlow(value, field)
    if value == nil then return DEFAULT_FLOW end
    if not isFiniteNumber(value) or value < MIN_FLOW or value > 1 then
        fail(string.format("%s must be between %s and 1", field, tostring(MIN_FLOW)))
    end
    return roundFlow(value)
end

local function roundStored(value)
    return math.floor(value * STORED_DECIMALS + 0.5) / STORED_DECIMALS
end

local function parseFeather(value, field)
    if value == nil then return BrushFeather.SOFT end
    if not isFiniteNumber(value) or value < 0 or value > BrushFeather.MAX_PERCENT then
        fail(string.format("%s must be between 0 (hard) and %d (soft)", field, BrushFeather.MAX_PERCENT))
    end
    return BrushFeather.fromPercent(value)
end

local function parseErase(value, field)
    if value == nil then return false end
    if type(value) ~= "boolean" then fail(field .. " must be true or false") end
    return value
end

local function parseDensity(value, erase, field)
    if value == nil then return 1 end
    if erase then fail(field .. " does not apply to an erase stroke: erasing removes the paint it covers") end
    if not isFiniteNumber(value) or value < MIN_DENSITY or value > 1 then
        fail(string.format("%s must be between %s and 1", field, tostring(MIN_DENSITY)))
    end
    return roundStored(value)
end

local function rejectUnknownFields(stroke, field)
    for key in pairs(stroke) do
        if not STROKE_FIELDS[key] then
            fail(field .. ": " .. (REASON_OF_UNSUPPORTED_FIELD[key] or ("unknown property " .. tostring(key))))
        end
    end
end

local function dabCountOf(points, radius)
    local spacing = radius * DAB_SPACING_IN_RADII
    local count = 1
    for index = 2, #points do
        local distance = math.sqrt((points[index].x - points[index - 1].x) ^ 2
            + (points[index].y - points[index - 1].y) ^ 2)
        count = count + math.ceil(distance / spacing - DISTANCE_EPSILON)
    end
    return count
end

local function requireDabBudget(field, dabCount, radius)
    if dabCount > MAX_DABS_PER_STROKE then
        fail(string.format(
            "%s would need %d dabs along its path at radius %s; at most %d are allowed (use a larger radius"
                .. " or a shorter path)", field, dabCount, tostring(radius), MAX_DABS_PER_STROKE))
    end
end

local function parseStroke(stroke, index)
    local field = "strokes[" .. index .. "]"
    if type(stroke) ~= "table" then fail(field .. " must be an object with points") end
    rejectUnknownFields(stroke, field)
    local rawPoints = stroke.points
    if type(rawPoints) ~= "table" or #rawPoints == 0 then
        fail(field .. ".points must list at least one point")
    end
    if #rawPoints > MAX_POINTS_PER_STROKE then
        fail(string.format("%s.points has %d points; at most %d are allowed", field, #rawPoints, MAX_POINTS_PER_STROKE))
    end
    local points = {}
    for pointIndex, rawPoint in ipairs(rawPoints) do
        points[pointIndex] = parsePoint(rawPoint, field .. ".points[" .. pointIndex .. "]")
    end
    local brushSize = parseRadius(stroke.radius, field .. ".radius")
    local flow = parseFlow(stroke.flow, field .. ".flow")
    local feather = parseFeather(stroke.feather, field .. ".feather")
    local erase = parseErase(stroke.erase, field .. ".erase")
    local density = parseDensity(stroke.density, erase, field .. ".density")
    local radius = roundStored(brushSize * BrushFeather.radiusScale(feather))
    requireDabBudget(field, dabCountOf(points, radius), radius)
    return {
        points = points,
        radius = radius,
        flow = flow,
        centerWeight = roundStored(BrushFeather.centerWeight(feather)),
        density = density,
        erase = erase,
    }
end

function BrushStrokes.parseStrokes(strokes)
    if type(strokes) ~= "table" or #strokes == 0 then
        fail("strokes must list at least one stroke; an empty stroke list would paint an empty mask")
    end
    if #strokes > MAX_STROKES then
        fail(string.format("strokes has %d entries; at most %d are allowed per call", #strokes, MAX_STROKES))
    end
    local parsed = {}
    for index, stroke in ipairs(strokes) do
        parsed[index] = parseStroke(stroke, index)
    end
    return parsed
end

function BrushStrokes.toStoredFrame(strokes, frame)
    if frame.isNormal then return strokes end
    local mapped = {}
    for index, stroke in ipairs(strokes) do
        local points = {}
        for pointIndex, point in ipairs(stroke.points) do
            local x, y = frame.toStored(point.x, point.y)
            points[pointIndex] = { x = x, y = y }
        end
        requireDabBudget("strokes[" .. index .. "]", dabCountOf(points, stroke.radius), stroke.radius)
        local copy = {}
        for key, item in pairs(stroke) do copy[key] = item end
        copy.points = points
        mapped[index] = copy
    end
    return mapped
end

local function clampUnit(value)
    return math.min(1, math.max(0, value))
end

local function dabText(x, y)
    return string.format("d %.6f %.6f", clampUnit(x), clampUnit(y))
end

local function dabsAlong(stroke)
    local dabs = { dabText(stroke.points[1].x, stroke.points[1].y) }
    local spacing = stroke.radius * DAB_SPACING_IN_RADII
    for index = 2, #stroke.points do
        local from, to = stroke.points[index - 1], stroke.points[index]
        local distance = math.sqrt((to.x - from.x) ^ 2 + (to.y - from.y) ^ 2)
        local steps = math.ceil(distance / spacing - DISTANCE_EPSILON)
        for step = 1, steps do
            local fraction = step / steps
            dabs[#dabs + 1] = dabText(from.x + (to.x - from.x) * fraction, from.y + (to.y - from.y) * fraction)
        end
    end
    local tokens = {}
    if stroke.flow < 1 then tokens[#tokens + 1] = string.format("f %.4f", stroke.flow) end
    if stroke.centerWeight > 0 and stroke.centerWeight < 1 then
        tokens[#tokens + 1] = string.format("h %.4f", stroke.centerWeight)
    end
    for index = #tokens, 1, -1 do table.insert(dabs, 1, tokens[index]) end
    return dabs
end

function BrushStrokes.newPaint(stroke)
    return {
        What = PAINT_WHAT,
        MaskActive = true,
        MaskInverted = false,
        MaskBlendMode = 0,
        MaskValue = stroke.erase and ERASE_VALUE or stroke.density,
        Flow = stroke.flow,
        Radius = stroke.radius,
        CenterWeight = stroke.centerWeight,
        Dabs = dabsAlong(stroke),
    }
end

function BrushStrokes.newAggregate(strokes)
    local paints = {}
    for index, stroke in ipairs(strokes) do paints[index] = BrushStrokes.newPaint(stroke) end
    return {
        What = AGGREGATE_WHAT,
        MaskActive = true,
        MaskInverted = false,
        MaskBlendMode = 0,
        MaskValue = 1,
        MaskName = "Brush",
        Masks = paints,
    }
end

function BrushStrokes.isBrush(component)
    return component ~= nil and component.What == AGGREGATE_WHAT
end

function BrushStrokes.appendStrokes(aggregate, strokes)
    if type(aggregate.Masks) ~= "table" then aggregate.Masks = {} end
    for _, stroke in ipairs(strokes) do
        aggregate.Masks[#aggregate.Masks + 1] = BrushStrokes.newPaint(stroke)
    end
    return #aggregate.Masks
end

BrushStrokes.TOOL_TYPE = "brush"

return BrushStrokes
