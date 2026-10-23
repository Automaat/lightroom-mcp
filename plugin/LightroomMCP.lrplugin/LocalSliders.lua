local LocalSliders = {}

local WHOLE_NUMBER_ROUNDING_TOLERANCE = 0.5
local TWO_DECIMAL_ROUNDING_TOLERANCE = 0.01

local function wholeNumberSlider(name)
    return {
        name = name,
        fallbackMin = -100,
        fallbackMax = 100,
        tolerance = WHOLE_NUMBER_ROUNDING_TOLERANCE,
    }
end

LocalSliders.list = {
    {
        name = "local_Exposure",
        fallbackMin = -5,
        fallbackMax = 5,
        tolerance = TWO_DECIMAL_ROUNDING_TOLERANCE,
    },
    wholeNumberSlider("local_Contrast"),
    wholeNumberSlider("local_Highlights"),
    wholeNumberSlider("local_Shadows"),
    wholeNumberSlider("local_Whites"),
    wholeNumberSlider("local_Blacks"),
    wholeNumberSlider("local_Texture"),
    wholeNumberSlider("local_Clarity"),
    wholeNumberSlider("local_Dehaze"),
    wholeNumberSlider("local_Temperature"),
    wholeNumberSlider("local_Tint"),
    wholeNumberSlider("local_Saturation"),
    wholeNumberSlider("local_Sharpness"),
    wholeNumberSlider("local_LuminanceNoise"),
    wholeNumberSlider("local_Moire"),
    wholeNumberSlider("local_Defringe"),
}

LocalSliders.byName = {}
for _, slider in ipairs(LocalSliders.list) do
    LocalSliders.byName[slider.name] = slider
end

function LocalSliders.names()
    local names = {}
    for _, slider in ipairs(LocalSliders.list) do
        names[#names + 1] = slider.name
    end
    return names
end

return LocalSliders
