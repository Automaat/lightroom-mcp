local MaskCurves = {}

MaskCurves.MINIMUM_VERSION_LABEL = "Lightroom Classic 12.3"
MaskCurves.MINIMUM_MAJOR = 12
MaskCurves.MINIMUM_MINOR = 3

local MIN_PAIRS = 2
local MAX_PAIRS = 32
local CURVE_MAX = 255
local VALUE_TOLERANCE = 1

MaskCurves.channels = {
    { name = "main", parameter = "local_Maincurve" },
    { name = "red", parameter = "local_Redcurve" },
    { name = "green", parameter = "local_Greencurve" },
    { name = "blue", parameter = "local_Bluecurve" },
}

MaskCurves.byName = {}
for _, channel in ipairs(MaskCurves.channels) do
    MaskCurves.byName[channel.name] = channel
end

function MaskCurves.channelNames()
    local names = {}
    for _, channel in ipairs(MaskCurves.channels) do
        names[#names + 1] = channel.name
    end
    return names
end

local function isWholeNumberInRange(value)
    return type(value) == "number" and value == math.floor(value) and value >= 0 and value <= CURVE_MAX
end

function MaskCurves.requireCurve(value, label)
    if type(value) ~= "table" then
        error(label .. " must be an array of input/output number pairs")
    end
    local count = 0
    for index, item in pairs(value) do
        if type(index) ~= "number" or index < 1 or index ~= math.floor(index) then
            error(label .. " must be an array")
        end
        if not isWholeNumberInRange(item) then
            error(string.format("%s[%d] must be an integer from 0 to %d", label, index, CURVE_MAX))
        end
        count = count + 1
    end
    if count ~= #value then
        error(label .. " must be an array")
    end
    if count < MIN_PAIRS * 2 or count > MAX_PAIRS * 2 or count % 2 ~= 0 then
        error(string.format("%s must contain %d to %d input/output pairs", label, MIN_PAIRS, MAX_PAIRS))
    end
    if value[1] ~= 0 or value[count - 1] ~= CURVE_MAX then
        error(string.format("%s must start at input 0 and end at input %d", label, CURVE_MAX))
    end
    local previousInput
    for index = 1, count, 2 do
        if previousInput ~= nil and value[index] <= previousInput then
            error(label .. " inputs must be strictly increasing")
        end
        previousInput = value[index]
    end
end

function MaskCurves.requireCurves(value)
    if type(value) ~= "table" or next(value) == nil then
        error("curves is required: an object of channel names (main, red, green, blue) and point arrays")
    end
    for key in pairs(value) do
        if type(key) ~= "string" or not MaskCurves.byName[key] then
            error(string.format("Unknown curve channel %s; valid channels: %s",
                tostring(key), table.concat(MaskCurves.channelNames(), ", ")))
        end
    end
    local requested = {}
    for _, channel in ipairs(MaskCurves.channels) do
        local points = value[channel.name]
        if points ~= nil then
            MaskCurves.requireCurve(points, "curves." .. channel.name)
            requested[#requested + 1] = { channel = channel, points = points }
        end
    end
    return requested
end

function MaskCurves.normalize(raw)
    if type(raw) ~= "table" then return nil end
    local count = #raw
    if count < MIN_PAIRS * 2 or count % 2 ~= 0 then return nil end
    local points = {}
    for index = 1, count do
        if type(raw[index]) ~= "number" then return nil end
        points[index] = raw[index]
    end
    return points
end

function MaskCurves.same(left, right)
    if left == nil or right == nil or #left ~= #right then return false end
    for index = 1, #left do
        if math.abs(left[index] - right[index]) > VALUE_TOLERANCE then return false end
    end
    return true
end

function MaskCurves.copy(points)
    local copied = {}
    for index = 1, #points do
        copied[index] = points[index]
    end
    return copied
end

return MaskCurves
