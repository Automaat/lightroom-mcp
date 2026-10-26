local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local PhotoLookup = require 'PhotoLookup'

local HandlerSpots = {}
local REQUIRED = { 'getAllSpots', 'getSelectedTool', 'selectTool', 'goToRemove',
    'setSelectedSpotIndex', 'getSelectedSpotIndex', 'getSelectedSpotParams',
    'setSelectedSpotParams', 'deleteSelectedSpot' }

local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end

local function same(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= 'table' then return left == right end
    for key, value in pairs(left) do
        if not same(value, right[key]) then return false end
    end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end

local function requireApi(name)
    local version = LrApplication.versionTable()
    if version.major < 14 or (version.major == 14 and version.minor < 1) then
        error(name .. ' needs Lightroom Classic 14.1 or later')
    end
    for _, key in ipairs(REQUIRED) do
        if type(LrDevelopController[key]) ~= 'function' then
            error(name .. ' needs Lightroom Classic 14.1 or later')
        end
    end
end

local function readSpots()
    local spots = LrDevelopController.getAllSpots()
    if type(spots) ~= 'table' then error('Lightroom could not read the spots') end
    return copy(spots)
end

local function indexed(spots)
    local result = {}
    for index, params in ipairs(spots) do result[index] = { index = index, params = params } end
    return result
end

local function requireIndex(index, count)
    if type(index) ~= 'number' or index ~= math.floor(index) or index < 1 or index > count then
        error(string.format('Spot index %s is invalid; valid range: %s', tostring(index),
            count == 0 and 'empty (no spots)' or '1..' .. tostring(count)))
    end
end

local function withPhoto(name, args, body)
    requireApi(name)
    local id = args.photo_id
    if type(id) == 'number' then id = tostring(id) end
    if type(id) ~= 'string' or id == '' then error('photo_id is required') end
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, id)
    if not photo then error('Photo not found: ' .. id) end
    local result = DevelopSession.withPhoto(name, catalog, photo, body)
    result.success = true
    result.photo_id = id
    return result
end

local function withSelected(index, body)
    local previousTool = LrDevelopController.getSelectedTool()
    local previousIndex
    if previousTool == 'dust' then previousIndex = LrDevelopController.getSelectedSpotIndex() end
    local ok, result = LrTasks.pcall(function()
        if previousTool ~= 'dust' then
            LrDevelopController.goToRemove()
            if not DevelopSession.waitFor(function()
                return LrDevelopController.getSelectedTool() == 'dust'
            end, 5) then error('Lightroom did not open Remove') end
        end
        local spots = readSpots()
        requireIndex(index, #spots)
        local selected, message = LrDevelopController.setSelectedSpotIndex(index)
        if selected ~= true or LrDevelopController.getSelectedSpotIndex() ~= index then
            error(string.format('Could not select spot %d; valid range: 1..%d (%s)',
                index, #spots, tostring(message)))
        end
        return body(spots)
    end)
    local restored, restoreError = LrTasks.pcall(function()
        if previousTool == 'dust' and previousIndex then
            local count = #readSpots()
            if previousIndex <= count then LrDevelopController.setSelectedSpotIndex(previousIndex) end
        elseif previousTool ~= 'dust' then
            LrDevelopController.selectTool(previousTool)
            if not DevelopSession.waitFor(function()
                return LrDevelopController.getSelectedTool() == previousTool
            end, 5) then error('Lightroom did not restore tool ' .. tostring(previousTool)) end
        end
    end)
    if not restored then error('Could not restore Remove tool state: ' .. tostring(restoreError)) end
    if not ok then error(result, 0) end
    return result
end

function HandlerSpots.list(args)
    return withPhoto('list_spots', args, function()
        local spots = readSpots()
        return { count = #spots, spots = indexed(spots) }
    end)
end

function HandlerSpots.update(args)
    local params = args.params
    if type(params) ~= 'table' or type(params.Opacity) ~= 'number'
        or params.Opacity ~= params.Opacity or params.Opacity < 0 or params.Opacity > 1 then
        error('params.Opacity must be a number from 0 to 1')
    end
    for key in pairs(params) do if key ~= 'Opacity' then error('Only params.Opacity is writable') end end
    return withPhoto('update_spot', args, function()
        return withSelected(args.index, function(before)
            local original = copy(LrDevelopController.getSelectedSpotParams())
            if type(original) ~= 'table' or original.SpotType ~= 'heal'
                or type(original.Opacity) ~= 'number' then
                error('Opacity editing is supported only for Heal spots with readable parameters')
            end
            if original.Opacity == params.Opacity then
                return { index = args.index, changed = false, params = original }
            end
            local desired = copy(original)
            desired.Opacity = params.Opacity
            local ok, err = LrTasks.pcall(function()
                LrDevelopController.setSelectedSpotParams(desired)
                if not DevelopSession.waitFor(function()
                    local current = LrDevelopController.getSelectedSpotParams()
                    return type(current) == 'table' and current.Opacity == params.Opacity
                end, 5) then error('Lightroom did not keep Opacity') end
                local after = readSpots()
                if #after ~= #before then error('Lightroom changed the spot count') end
                for index, spot in ipairs(before) do
                    if index ~= args.index and not same(spot, after[index]) then
                        error('Lightroom changed another spot')
                    end
                end
            end)
            if not ok then
                local rolledBack = LrTasks.pcall(function()
                    if LrDevelopController.setSelectedSpotIndex(args.index) ~= true then
                        error('Original spot is no longer selectable')
                    end
                    LrDevelopController.setSelectedSpotParams(original)
                end)
                error(tostring(err) .. (rolledBack and '; original parameters restored' or '; rollback failed; list_spots to inspect'))
            end
            return { index = args.index, changed = true,
                params = copy(LrDevelopController.getSelectedSpotParams()) }
        end)
    end)
end

function HandlerSpots.delete(args)
    if args.confirm ~= true then error('confirm must be true to delete a spot') end
    return withPhoto('delete_spot', args, function()
        return withSelected(args.index, function(before)
            LrDevelopController.deleteSelectedSpot()
            local after
            if not DevelopSession.waitFor(function()
                after = readSpots()
                return #after == #before - 1
            end, 5) then error('Lightroom did not delete the spot; list_spots to inspect') end
            local expected = copy(before)
            table.remove(expected, args.index)
            if not same(expected, after) then error('Other spots changed during deletion; list_spots to inspect') end
            return { deleted_index = args.index, count = #after, spots = indexed(after) }
        end)
    end)
end

return HandlerSpots
