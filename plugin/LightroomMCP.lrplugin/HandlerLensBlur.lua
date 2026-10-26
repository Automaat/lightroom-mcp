local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local PhotoLookup = require 'PhotoLookup'

local Handler = {}
local SLIDERS = {
    { key = 'amount', parameter = 'LensBlurAmount', stored = 'BlurAmount' },
    { key = 'cat_eye', parameter = 'LensBlurCatEye', stored = 'CatEyeAmount' },
    { key = 'highlights_boost', parameter = 'LensBlurHighlightsBoost', stored = 'HighlightsBoost' },
}
local BOKEH = { Circle = true, SoapBubble = true, Blade = true, Ring = true, Anamorphic = true }

local function sdk(fn, ...)
    local ok, value = LrTasks.pcall(fn, ...)
    if not ok then error(tostring(value), 0) end
    return value
end

local function finite(value)
    return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

local function close(a, b)
    return finite(a) and finite(b) and math.abs(a - b) <= 0.001
end

local function requireApi()
    local version = LrApplication.versionTable()
    if version.major < 13 or (version.major == 13 and version.minor < 3) then
        error('Lens Blur needs Lightroom Classic 13.3 or later')
    end
    for _, name in ipairs({ 'getProcessVersion', 'getValue', 'getRange', 'setValue',
        'getSelectedLensBlurBokeh', 'setLensBlurBokeh', 'stopTracking' }) do
        if type(LrDevelopController[name]) ~= 'function' then
            error('Lens Blur needs Lightroom Classic 13.3 or later: missing ' .. name)
        end
    end
end

local function target(args)
    requireApi()
    local id = args.photo_id
    if (type(id) ~= 'string' or not id:find('%S')) and not finite(id) then
        error('photo_id is required')
    end
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, id)
    if not photo then error('Photo not found: ' .. tostring(id)) end
    return catalog, photo
end

local function requireProcess()
    local version = sdk(LrDevelopController.getProcessVersion)
    local number = type(version) == 'string' and tonumber(version:match('^Version (%d+)$'))
    if not number or number < 3 then
        error('Lens Blur needs Process Version 3 or later; this photo uses ' .. tostring(version))
    end
end

local function assertActive(catalog, photo)
    if catalog:getTargetPhoto() ~= photo then error('Another photo became active; Lens Blur stopped') end
end

local function focalRange(value)
    if type(value) ~= 'string' then return nil end
    local points = {}
    for token in value:gmatch('%S+') do
        local number = tonumber(token)
        if not finite(number) then return nil end
        points[#points + 1] = number
    end
    if #points ~= 4 then return nil end
    return { near = points[2], far = points[3] }
end

local function read(catalog, photo)
    assertActive(catalog, photo)
    local active = sdk(LrDevelopController.getValue, 'LensBlurActive')
    if active ~= nil and type(active) ~= 'boolean' then error('Lightroom returned an invalid Lens Blur state') end
    local result = { active = active == true, unavailable = {} }
    for _, slider in ipairs(SLIDERS) do
        result[slider.key] = sdk(LrDevelopController.getValue, slider.parameter)
        if result[slider.key] == nil then result.unavailable[#result.unavailable + 1] = slider.key end
    end
    result.focal_range_raw = sdk(LrDevelopController.getValue, 'LensBlurFocalRange')
    result.focal_range = focalRange(result.focal_range_raw)
    result.bokeh = sdk(LrDevelopController.getSelectedLensBlurBokeh)
    if not result.focal_range then result.unavailable[#result.unavailable + 1] = 'focal_range' end
    if not result.bokeh then result.unavailable[#result.unavailable + 1] = 'bokeh' end
    return result
end

local function range(parameter, value, label)
    local ok, low, high = LrTasks.pcall(LrDevelopController.getRange, parameter)
    if not ok or not finite(low) or not finite(high) or low > high then
        error('Lightroom did not report a valid range for ' .. label .. '; nothing was written')
    end
    if not finite(value) or value < low or value > high then
        error(string.format('%s must be within Lightroom range %s to %s; nothing was written', label, low, high))
    end
end

local function validate(args)
    local changed = args.active ~= nil or args.bokeh ~= nil or args.focal_range ~= nil
    if args.active ~= nil and type(args.active) ~= 'boolean' then error('active must be a boolean') end
    if args.bokeh ~= nil and not BOKEH[args.bokeh] then error('Unknown Lens Blur bokeh style') end
    for _, slider in ipairs(SLIDERS) do
        local value = args[slider.key]
        if value ~= nil then
            changed = true
            range(slider.parameter, value, slider.key)
        end
    end
    if args.focal_range ~= nil then
        local focal = args.focal_range
        if type(focal) ~= 'table' or not finite(focal.near) or not finite(focal.far)
            or focal.near < 0 or focal.far > 100 or focal.near > focal.far then
            error('focal_range needs near <= far within 0 to 100; nothing was written')
        end
        range('LensBlurFocalRange', focal.near, 'focal_range.near')
        range('LensBlurFocalRange', focal.far, 'focal_range.far')
    end
    if not changed then error('Provide at least one Lens Blur value') end
end

local function stored(photo)
    return sdk(function() return photo:getDevelopSettings().LensBlur or {} end)
end

local function flush(catalog, photo)
    assertActive(catalog, photo)
    sdk(LrDevelopController.stopTracking, false)
    LrTasks.sleep(5)
    assertActive(catalog, photo)
end

local function write(catalog, photo, parameter, value, matches)
    assertActive(catalog, photo)
    sdk(LrDevelopController.setValue, parameter, value)
    if parameter == "LensBlurActive" and not DevelopSession.waitFor(function()
        assertActive(catalog, photo)
        return sdk(LrDevelopController.getValue, parameter) == value
    end, 20) then
        error("Lightroom did not finish changing LensBlurActive; Lens Blur stopped; earlier changes may remain")
    end
    flush(catalog, photo)
    local controllerValue, savedSettings
    if not DevelopSession.waitFor(function()
        assertActive(catalog, photo)
        controllerValue, savedSettings = sdk(LrDevelopController.getValue, parameter), stored(photo)
        return matches(controllerValue, savedSettings)
    end, 10) then
        error('Lightroom did not save ' .. parameter .. ' (controller=' .. tostring(controllerValue)
            .. ', saved Active=' .. tostring(savedSettings and savedSettings.Active)
            .. ', saved BlurAmount=' .. tostring(savedSettings and savedSettings.BlurAmount)
            .. '); Lens Blur stopped; earlier changes may remain')
    end
end

local function setActive(catalog, photo, active)
    if not active and sdk(LrDevelopController.getValue, 'LensBlurActive') ~= true
        and stored(photo).Active ~= true then return end
    write(catalog, photo, 'LensBlurActive', active, function(value, settings)
        return value == active and settings.Active == active
    end)
end

function Handler.get(args)
    args = args or {}
    local catalog, photo = target(args)
    return DevelopSession.withPhoto('get_lens_blur', catalog, photo, function()
        requireProcess()
        local result = read(catalog, photo)
        result.photo_id = tostring(photo.localIdentifier)
        return result
    end)
end

function Handler.set(args)
    args = args or {}
    local catalog, photo = target(args)
    return DevelopSession.withPhoto('set_lens_blur', catalog, photo, function()
        requireProcess()
        validate(args)
        local adjustments = args.bokeh ~= nil or args.focal_range ~= nil
        for _, slider in ipairs(SLIDERS) do adjustments = adjustments or args[slider.key] ~= nil end
        if adjustments or args.active == true then
            setActive(catalog, photo, true)
        end
        for _, slider in ipairs(SLIDERS) do
            local wanted = args[slider.key]
            if wanted ~= nil then
                write(catalog, photo, slider.parameter, wanted, function(value, settings)
                    return close(value, wanted) and close(settings[slider.stored], wanted)
                end)
            end
        end
        if args.focal_range then
            local near, far = args.focal_range.near, args.focal_range.far
            local encoded = string.format('%.10g %.10g %.10g %.10g', near - 80, near, far, far + 80)
            write(catalog, photo, 'LensBlurFocalRange', encoded, function(value, settings)
                local current, saved = focalRange(value), focalRange(settings.FocalRange)
                return current and saved and close(current.near, near) and close(current.far, far)
                    and close(saved.near, near) and close(saved.far, far)
            end)
        end
        if args.bokeh then
            assertActive(catalog, photo)
            local previous = sdk(LrDevelopController.getSelectedLensBlurBokeh)
            local before = stored(photo)
            sdk(LrDevelopController.setLensBlurBokeh, args.bokeh)
            flush(catalog, photo)
            local saved = DevelopSession.waitFor(function()
                assertActive(catalog, photo)
                if sdk(LrDevelopController.getSelectedLensBlurBokeh) ~= args.bokeh then return false end
                if previous == args.bokeh then return true end
                local current = stored(photo)
                for _, key in ipairs({ 'BokehShape', 'BokehShapeDetail', 'BokehAspect',
                    'BokehRotation', 'SphericalAberration' }) do
                    if current[key] ~= before[key] then return true end
                end
                return false
            end, 10)
            if not saved then
                error('Lightroom did not save Lens Blur bokeh; earlier changes may remain')
            end
        end
        if args.active == false then setActive(catalog, photo, false) end
        local result = read(catalog, photo)
        result.photo_id = tostring(photo.localIdentifier)
        result.success = true
        return result
    end)
end

return Handler
