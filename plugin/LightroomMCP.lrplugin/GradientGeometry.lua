local GradientGeometry = {}

local LINEAR = "linear"
local RADIAL = "radial"

local WHAT_OF_SHAPE = { [LINEAR] = "Mask/Gradient", [RADIAL] = "Mask/CircularGradient" }
local SHAPE_OF_WHAT = { ["Mask/Gradient"] = LINEAR, ["Mask/CircularGradient"] = RADIAL }

local SHAPE_FIELDS = {
    [LINEAR] = { "start", "end" },
    [RADIAL] = { "center", "width", "height", "rotation", "feather", "area" },
}
local POINT_FIELDS = { [LINEAR] = { "start", "end" }, [RADIAL] = { "center" } }
local OTHER_SHAPE = { [LINEAR] = RADIAL, [RADIAL] = LINEAR }

local BLEND_MODE_OF_MODE = { add = 0, subtract = 1 }
local MASK_VALUE_OF_MODE = { add = 1, subtract = 0 }
local AREA_INSIDE = "inside"
local AREA_OUTSIDE = "outside"

local DEFAULT_ROTATION_DEGREES = 0
local DEFAULT_FEATHER = 50
local MAX_FEATHER = 100
local MAX_ROTATION_DEGREES = 360
local MAX_RADIAL_SIZE = 2
local RADIAL_VERSION = 2
local RADIAL_MIDPOINT = 50
local RADIAL_ROUNDNESS = 0
local MIN_LINEAR_LENGTH = 1e-6
local STORED_DECIMALS = 1e6

local function fail(message)
    error(message, 0)
end

local function requireNumber(value, field)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        fail(field .. " must be a number")
    end
    return value
end

local function parseCoordinate(value, field)
    requireNumber(value, field)
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

local function parseSize(value, field)
    requireNumber(value, field)
    if value <= 0 or value > MAX_RADIAL_SIZE then
        fail(string.format("%s must be greater than 0 and at most %d (a fraction of the image %s)",
            field, MAX_RADIAL_SIZE, field == "width" and "width" or "height"))
    end
    return value
end

local function parseRotation(value, field)
    requireNumber(value, field)
    if value < -MAX_ROTATION_DEGREES or value > MAX_ROTATION_DEGREES then
        fail(string.format("%s must be between -%d and %d degrees", field, MAX_ROTATION_DEGREES, MAX_ROTATION_DEGREES))
    end
    return value
end

local function parseFeather(value, field)
    requireNumber(value, field)
    if value < 0 or value > MAX_FEATHER then
        fail(string.format("%s must be between 0 and %d", field, MAX_FEATHER))
    end
    return value
end

local function parseArea(value, field)
    if value ~= AREA_INSIDE and value ~= AREA_OUTSIDE then
        fail(field .. ' must be "inside" or "outside"')
    end
    return value
end

local FIELD_PARSERS = {
    start = parsePoint,
    ["end"] = parsePoint,
    center = parsePoint,
    width = parseSize,
    height = parseSize,
    rotation = parseRotation,
    feather = parseFeather,
    area = parseArea,
}

local function readFields(args, fields)
    local changes = {}
    for _, field in ipairs(fields) do
        if args[field] ~= nil then
            changes[field] = FIELD_PARSERS[field](args[field], field)
        end
    end
    return changes
end

local function requireField(changes, field, shape)
    if changes[field] == nil then
        fail(field .. " is required for a " .. shape .. " gradient")
    end
    return changes[field]
end

local function optionalText(value, field)
    if value == nil then return nil end
    if type(value) ~= "string" or value == "" then fail(field .. " must be a non-empty string") end
    return value
end

local function rejectOtherShapeFields(args, shape)
    for _, field in ipairs(SHAPE_FIELDS[OTHER_SHAPE[shape]]) do
        if args[field] ~= nil then
            fail(field .. " only applies to " .. OTHER_SHAPE[shape] .. " gradients, not " .. shape .. " ones")
        end
    end
end

local function copyGeometry(geometry)
    local copy = {}
    for key, value in pairs(geometry) do
        if type(value) == "table" then
            copy[key] = { x = value.x, y = value.y }
        else
            copy[key] = value
        end
    end
    return copy
end

local function samePoint(left, right)
    return math.abs(left.x - right.x) < MIN_LINEAR_LENGTH and math.abs(left.y - right.y) < MIN_LINEAR_LENGTH
end

function GradientGeometry.validateGeometry(shape, geometry)
    if shape == LINEAR and samePoint(geometry.start, geometry["end"]) then
        fail("start and end are the same point; a linear gradient needs two different points")
    end
end

function GradientGeometry.parseCreate(args)
    local shape = args.shape
    if shape ~= LINEAR and shape ~= RADIAL then fail('shape must be "linear" or "radial"') end
    rejectOtherShapeFields(args, shape)
    local changes = readFields(args, SHAPE_FIELDS[shape])

    local geometry
    if shape == LINEAR then
        geometry = {
            start = requireField(changes, "start", shape),
            ["end"] = requireField(changes, "end", shape),
        }
    else
        geometry = {
            center = requireField(changes, "center", shape),
            width = requireField(changes, "width", shape),
            height = requireField(changes, "height", shape),
            rotation = changes.rotation or DEFAULT_ROTATION_DEGREES,
            feather = changes.feather or DEFAULT_FEATHER,
            area = changes.area or AREA_INSIDE,
        }
    end
    GradientGeometry.validateGeometry(shape, geometry)

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
    return { shape = shape, geometry = geometry, maskId = maskId, mode = mode, name = name }
end

function GradientGeometry.parseUpdate(args)
    local toolId = optionalText(args.tool_id, "tool_id")
    if toolId == nil then fail("tool_id is required") end
    local allFields = {}
    for _, shape in ipairs({ LINEAR, RADIAL }) do
        for _, field in ipairs(SHAPE_FIELDS[shape]) do allFields[#allFields + 1] = field end
    end
    local changes = readFields(args, allFields)
    if next(changes) == nil then
        fail("give at least one geometry field to change: " .. table.concat(allFields, ", "))
    end
    return { toolId = toolId, changes = changes }
end

local function round(value)
    return math.floor(value * STORED_DECIMALS + 0.5) / STORED_DECIMALS
end

local function carriedAcrossFrame(shape, geometry, frame, mapPoint)
    if frame.isNormal then return geometry end
    local carried = copyGeometry(geometry)
    for _, field in ipairs(POINT_FIELDS[shape]) do
        local x, y = mapPoint(geometry[field].x, geometry[field].y)
        carried[field] = { x = round(x), y = round(y) }
    end
    if shape == RADIAL then
        if frame.swapsAxes then carried.width, carried.height = geometry.height, geometry.width end
        if frame.reversesTurnDirection then carried.rotation = 0 - geometry.rotation end
    end
    return carried
end

function GradientGeometry.toStoredFrame(shape, geometry, frame)
    return carriedAcrossFrame(shape, geometry, frame, frame.toStored)
end

function GradientGeometry.toDisplayedFrame(shape, geometry, frame)
    return carriedAcrossFrame(shape, geometry, frame, frame.toDisplayed)
end

function GradientGeometry.storedAspectOf(frame, displayedAspect)
    if displayedAspect == nil or not frame.swapsAxes then return displayedAspect end
    return 1 / displayedAspect
end

function GradientGeometry.shapeOf(component)
    return SHAPE_OF_WHAT[component.What]
end

local function requireAspect(aspect, rotation)
    if aspect ~= nil then return aspect end
    if rotation == 0 then return 1 end
    fail("the photo's size is needed to place a rotated radial gradient, and Lightroom did not report it")
end

function GradientGeometry.geometryOf(component, aspect)
    local shape = SHAPE_OF_WHAT[component.What]
    if shape == nil then return nil end
    if shape == LINEAR then
        return shape, {
            start = { x = round(component.FullX), y = round(component.FullY) },
            ["end"] = { x = round(component.ZeroX), y = round(component.ZeroY) },
        }
    end
    local ratio = requireAspect(aspect, component.Angle)
    local radians = math.rad(component.Angle)
    local cosine, sine = math.cos(radians), math.sin(radians)
    local boxHalfWidth = (component.Right - component.Left) / 2 * ratio
    local boxHalfHeight = (component.Bottom - component.Top) / 2
    return shape, {
        center = {
            x = round((component.Left + component.Right) / 2),
            y = round((component.Top + component.Bottom) / 2),
        },
        width = round(2 * math.abs(boxHalfWidth * cosine + boxHalfHeight * sine) / ratio),
        height = round(2 * math.abs(boxHalfHeight * cosine - boxHalfWidth * sine)),
        rotation = round(component.Angle),
        feather = round(component.Feather),
        area = component.MaskInverted and AREA_OUTSIDE or AREA_INSIDE,
    }
end

function GradientGeometry.mergeChanges(shape, geometry, changes)
    for field in pairs(changes) do
        local belongs = false
        for _, own in ipairs(SHAPE_FIELDS[shape]) do belongs = belongs or own == field end
        if not belongs then
            fail(string.format("%s only applies to %s gradients, but this tool is a %s gradient",
                field, OTHER_SHAPE[shape], shape))
        end
    end
    local merged = copyGeometry(geometry)
    for field, value in pairs(changes) do merged[field] = value end
    GradientGeometry.validateGeometry(shape, merged)
    return merged
end

function GradientGeometry.applyGeometry(shape, component, geometry, aspect)
    if shape == LINEAR then
        component.FullX = geometry.start.x
        component.FullY = geometry.start.y
        component.ZeroX = geometry["end"].x
        component.ZeroY = geometry["end"].y
        return component
    end
    local ratio = requireAspect(aspect, geometry.rotation)
    local radians = math.rad(geometry.rotation)
    local cosine, sine = math.cos(radians), math.sin(radians)
    local semiWidth, semiHeight = geometry.width / 2 * ratio, geometry.height / 2
    local boxHalfWidth = (semiWidth * cosine - semiHeight * sine) / ratio
    local boxHalfHeight = semiWidth * sine + semiHeight * cosine
    component.Left = geometry.center.x - boxHalfWidth
    component.Right = geometry.center.x + boxHalfWidth
    component.Top = geometry.center.y - boxHalfHeight
    component.Bottom = geometry.center.y + boxHalfHeight
    component.Angle = geometry.rotation
    component.Feather = geometry.feather
    component.MaskInverted = geometry.area == AREA_OUTSIDE
    component.Flipped = nil
    return component
end

function GradientGeometry.newComponent(shape, geometry, mode, aspect)
    local component = {
        What = WHAT_OF_SHAPE[shape],
        MaskActive = true,
        MaskInverted = false,
        MaskBlendMode = BLEND_MODE_OF_MODE[mode],
        MaskValue = MASK_VALUE_OF_MODE[mode],
        MaskName = shape == LINEAR and "Linear Gradient" or "Radial Gradient",
    }
    if shape == RADIAL then
        component.Midpoint = RADIAL_MIDPOINT
        component.Roundness = RADIAL_ROUNDNESS
        component.Version = RADIAL_VERSION
    end
    return GradientGeometry.applyGeometry(shape, component, geometry, aspect)
end

GradientGeometry.TOOL_TYPE_OF_SHAPE = { [LINEAR] = "gradient", [RADIAL] = "radialGradient" }

return GradientGeometry
