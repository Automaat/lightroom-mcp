local helper = require 'spec_helper'

local function clone(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = clone(child) end
    return result
end

local function setup(options)
    options = options or {}
    local photos = { helper.fakePhoto({ id = '1', path = '/1.jpg' }),
        helper.fakePhoto({ id = '2', path = '/2.jpg' }) }
    local catalog = helper.fakeCatalog({ photos = photos })
    local active, module, tool, selected = photos[1], 'library', options.tool or 'loupe', 2
    local spots = options.empty and {} or {
        { SpotType = 'heal', Opacity = 1, opacity = 1, Masks = { { MaskID = 'first' } } },
        { SpotType = 'heal', Opacity = 0.7, opacity = 0.7, Masks = { { MaskID = 'second' } } },
    }
    local calls = { writes = 0, deletes = 0, opens = 0 }
    local controller = {
        getAllSpots = function() return clone(spots) end,
        getSelectedTool = function() return tool end,
        selectTool = function(value) tool = value end,
        goToRemove = function() tool = 'dust'; calls.opens = calls.opens + 1 end,
        setSelectedSpotIndex = function(index)
            if options.refuse or not spots[index] then return false, 'not selectable' end
            selected = index
            return true
        end,
        getSelectedSpotIndex = function() return selected end,
        getSelectedSpotParams = function() return clone(spots[selected]) end,
        setSelectedSpotParams = function(params)
            calls.writes = calls.writes + 1
            assert.are.same(spots[selected].Masks, params.Masks)
            if options.throw then error('SDK failure') end
            if not options.ignore then spots[selected] = clone(params) end
        end,
        deleteSelectedSpot = function()
            calls.deletes = calls.deletes + 1
            if not options.ignore then table.remove(spots, selected) end
        end,
    }
    local originalSelect = catalog.setSelectedPhotos
    catalog.setSelectedPhotos = function(self, photo, selection)
        originalSelect(self, photo, selection)
        active = photo
    end
    catalog.getTargetPhoto = function() return active end
    catalog.getTargetPhotos = function() return { active } end
    catalog.getActiveSources = function() return { 'source' } end
    catalog.setActiveSources = function() end
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end,
            versionTable = function() return { major = options.old and 14 or 15, minor = options.old and 0 or 6 } end },
        LrApplicationView = { getCurrentModuleName = function() return module end,
            switchToModule = function(value) module = value end },
        LrDevelopController = controller,
        LrTasks = { pcall = pcall, sleep = function() end },
        LrSelection = { selectNone = function() active = nil end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerSpots = nil
    package.loaded.DevelopSession = nil
    local handler = require 'HandlerSpots'
    return handler, calls, function() return spots end, function()
        return { active = active.localIdentifier, module = module, tool = tool }
    end
end

local function failure(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

describe('Remove spots', function()
    it('lists complete SDK fields with reusable one-based indices and restores the view', function()
        local handler, calls, spots, state = setup()
        local result = handler.list({ photo_id = '2' })
        assert.are.equal(2, result.count)
        assert.are.same({ index = 1, params = spots()[1] }, result.spots[1])
        assert.are.same({ active = '1', module = 'library', tool = 'loupe' }, state())
        assert.are.equal(0, calls.opens)
    end)

    it('lists a photo without spots as an empty array', function()
        local handler = setup({ empty = true })
        assert.are.same({}, handler.list({ photo_id = '1' }).spots)
    end)

    it('updates only uppercase Opacity using the full selected table', function()
        local handler, calls, spots, state = setup()
        local second = clone(spots()[2])
        local result = handler.update({ photo_id = '2', index = 1, params = { Opacity = 0.4 } })
        assert.are.equal(0.4, result.params.Opacity)
        assert.are.equal(1, result.params.opacity)
        assert.are.same(second, spots()[2])
        assert.are.equal(1, calls.writes)
        assert.are.same({ active = '1', module = 'library', tool = 'loupe' }, state())
    end)

    it('does not write when the opacity already matches', function()
        local handler, calls = setup()
        assert.is_false(handler.update({ photo_id = '1', index = 1, params = { Opacity = 1 } }).changed)
        assert.are.equal(0, calls.writes)
    end)

    it('deletes only the selected spot and returns shifted indices', function()
        local handler, calls, spots = setup()
        local expected = clone(spots()[2])
        local result = handler.delete({ photo_id = '2', index = 1, confirm = true })
        assert.are.same({ expected }, spots())
        assert.are.same({ { index = 1, params = expected } }, result.spots)
        assert.are.equal(1, calls.deletes)
    end)

    it('rejects an out-of-range index without a write', function()
        local handler, calls = setup()
        assert.truthy(failure(function()
            handler.update({ photo_id = '2', index = 3, params = { Opacity = 0.4 } })
        end):find('valid range: 1..2', 1, true))
        assert.are.equal(0, calls.writes)
    end)

    it('reports the range when SDK selection returns false and leaves all spots unchanged', function()
        local handler, calls, spots, state = setup({ refuse = true })
        local original = clone(spots())
        assert.truthy(failure(function()
            handler.delete({ photo_id = '2', index = 1, confirm = true })
        end):find('valid range: 1..2', 1, true))
        assert.are.same(original, spots())
        assert.are.equal(0, calls.deletes)
        assert.are.same({ active = '1', module = 'library', tool = 'loupe' }, state())
    end)

    it('restores Remove when it was already open', function()
        local handler, _, _, state = setup({ tool = 'dust' })
        handler.update({ photo_id = '1', index = 1, params = { Opacity = 0.3 } })
        assert.are.equal('dust', state().tool)
    end)

    it('fails when an update is ignored and restores tool and module', function()
        local handler, _, _, state = setup({ ignore = true })
        assert.truthy(failure(function()
            handler.update({ photo_id = '2', index = 1, params = { Opacity = 0.3 } })
        end):find('did not keep Opacity', 1, true))
        assert.are.same({ active = '1', module = 'library', tool = 'loupe' }, state())
    end)

    it('requires confirmation and refuses every unproven field', function()
        local handler, calls = setup()
        failure(function() handler.delete({ photo_id = '1', index = 1 }) end)
        for _, params in ipairs({ { opacity = 0.3 }, { Opacity = -1 }, { Opacity = 0.3, radius = 0.4 } }) do
            failure(function() handler.update({ photo_id = '1', index = 1, params = params }) end)
        end
        assert.are.equal(0, calls.writes)
        assert.are.equal(0, calls.deletes)
    end)

    it('names the minimum SDK version before opening Develop', function()
        local handler, calls = setup({ old = true })
        assert.truthy(failure(function() handler.list({ photo_id = '1' }) end):find('14.1', 1, true))
        assert.are.equal(0, calls.opens)
    end)
end)
