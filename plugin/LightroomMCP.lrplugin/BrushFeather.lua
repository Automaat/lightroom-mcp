local BrushFeather = {}

local FEATHER_SAMPLES = {
    { 0, 0.392053, 1 },
    { 0.02, 0.394077, 0.934595 },
    { 0.05, 0.397636, 0.843964 },
    { 0.1, 0.405332, 0.710941 },
    { 0.15, 0.415990, 0.597666 },
    { 0.2, 0.430693, 0.501304 },
    { 0.25, 0.450700, 0.419401 },
    { 0.3, 0.477400, 0.349837 },
    { 0.35, 0.512008, 0.290787 },
    { 0.4, 0.554709, 0.240684 },
    { 0.45, 0.603801, 0.198184 },
    { 0.5, 0.656012, 0.16214 },
    { 0.55, 0.707956, 0.131575 },
    { 0.6, 0.757206, 0.105656 },
    { 0.65, 0.802427, 0.083679 },
    { 0.7, 0.843085, 0.065044 },
    { 0.75, 0.879117, 0.049246 },
    { 0.8, 0.910729, 0.035858 },
    { 0.85, 0.938245, 0.024519 },
    { 0.9, 0.962042, 0.014927 },
    { 0.95, 0.982506, 0.006825 },
    { 1, 1, 0 },
}

local FEATHER_AT = 1
local RADIUS_SCALE_AT = 2
local CENTER_WEIGHT_AT = 3

BrushFeather.MAX_PERCENT = 100
BrushFeather.SOFT = 1

local function interpolate(feather, column)
    for index = 2, #FEATHER_SAMPLES do
        local upper = FEATHER_SAMPLES[index]
        if feather <= upper[FEATHER_AT] then
            local lower = FEATHER_SAMPLES[index - 1]
            local span = upper[FEATHER_AT] - lower[FEATHER_AT]
            local fraction = (feather - lower[FEATHER_AT]) / span
            return lower[column] + (upper[column] - lower[column]) * fraction
        end
    end
    return FEATHER_SAMPLES[#FEATHER_SAMPLES][column]
end

function BrushFeather.fromPercent(percent)
    return percent / BrushFeather.MAX_PERCENT
end

function BrushFeather.radiusScale(feather)
    return interpolate(feather, RADIUS_SCALE_AT)
end

function BrushFeather.centerWeight(feather)
    return interpolate(feather, CENTER_WEIGHT_AT)
end

return BrushFeather
