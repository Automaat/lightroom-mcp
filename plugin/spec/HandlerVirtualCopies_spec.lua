local helper = require 'spec_helper'

describe('HandlerVirtualCopies', function()
    local Handler, catalog, photos, calls, state

    local function setup(opts)
        opts = opts or {}
        photos = {}
        for i = 1, 3 do
            photos[i] = helper.fakePhoto({ id = tostring(i), path = '/' .. i .. '.jpg' })
        end
        if opts.virtualInput then
            photos[3] = helper.fakePhoto({ id = '3', path = '/1.jpg',
                isVirtualCopy = true, masterPhoto = photos[1] })
        end
        local source = {}
        state = { active = photos[1], selected = { photos[1], photos[2] }, sources = { source } }
        if opts.empty then state.active, state.selected = nil, {} end
        calls = { create = {}, selection = {}, sources = {} }
        catalog = helper.fakeCatalog({ photos = photos })
        catalog.kAllPhotos = 'all'
        local getTargets = catalog.getTargetPhotos
        local setSelected = catalog.setSelectedPhotos
        catalog.getTargetPhoto = function() return state.active end
        catalog.getTargetPhotos = function(self)
            getTargets(self)
            return state.selected
        end
        catalog.getActiveSources = function() return state.sources end
        catalog.setActiveSources = function(_, sources)
            calls.sources[#calls.sources + 1] = sources
            state.sources = sources
        end
        catalog.setSelectedPhotos = function(self, active, selected)
            setSelected(self, active, selected)
            calls.selection[#calls.selection + 1] = { active = active, photos = selected }
            if opts.failRestore and #calls.create > 0 and active == photos[1] then return end
            if opts.restricted and active == photos[3] and state.sources[1] ~= 'all' then return end
            state.active, state.selected = active, selected
        end
        catalog.createVirtualCopies = function(_, name)
            assert.is_false(catalog.isInsideReadAccess())
            assert.are.equal(1, #state.selected)
            calls.create[#calls.create + 1] = { photo = state.active, name = name }
            if opts.failCreate then error('SDK failure') end
            local master = state.active:getRawMetadata('masterPhoto') or state.active
            local copy = helper.fakePhoto({ id = tostring(100 + #calls.create),
                isVirtualCopy = true, masterPhoto = master })
            state.active, state.selected = copy, { copy }
            return { copy }
        end
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrApplicationView = {},
            LrDevelopController = {},
            LrLogger = helper.defaultLrLogger(),
            LrSelection = { selectNone = function() state.active, state.selected = nil, {} end },
            LrTasks = { pcall = pcall, sleep = function() end },
        })
        package.loaded.DevelopSession = nil
        package.loaded.HandlerVirtualCopies = nil
        Handler = require 'HandlerVirtualCopies'
    end

    local function assertRestored()
        assert.are.equal(photos[1], state.active)
        assert.are.same({ photos[1], photos[2] }, state.selected)
        local last = calls.selection[#calls.selection]
        assert.are.equal(photos[1], last.active)
        assert.are.same({ photos[1], photos[2] }, last.photos)
    end

    it('creates named copies and returns stable photo, master and copy ids', function()
        setup()
        local result = Handler.create({ photo_ids = { '3', '2' }, copy_name = 'Experiment' })
        assert.are.equal(2, result.created)
        assert.are.same({
            { photo_id = '3', master_id = '3', copy_id = '101' },
            { photo_id = '2', master_id = '2', copy_id = '102' },
        }, result.copies)
        assert.are.equal('Experiment', calls.create[1].name)
        assert.are.equal('Experiment', calls.create[2].name)
        assertRestored()
        assert.is_false(catalog.getQueriedInsideReadAccess())
        assert.is_false(catalog.getQueriedInsideWriteAccess())
        assert.are.equal(0, catalog.getReadAccessCount())
        assert.are.equal(0, catalog.getWriteAccessCount())
    end)

    it('deduplicates ids and paths to the same photo and reports missing ids', function()
        setup()
        local result = Handler.create({ photo_ids = { '3', '3', '/3.jpg', '999' } })
        assert.are.equal(1, result.created)
        assert.are.same({ '999' }, result.missing)
        assert.is_nil(calls.create[1].name)
        assertRestored()
    end)

    it('selects only the requested photo even when it is already active', function()
        setup()
        Handler.create({ photo_ids = { '1' } })
        assert.are.equal(1, #calls.create)
        assert.are.equal(photos[1], calls.create[1].photo)
        assertRestored()
    end)

    it('returns the original master when the input is itself a virtual copy', function()
        setup({ virtualInput = true })
        local result = Handler.create({ photo_ids = { '3', '1' } })
        assert.are.equal(2, result.created)
        assert.are.same({ photo_id = '3', master_id = '1', copy_id = '101' }, result.copies[1])
        assert.are.same({ photo_id = '1', master_id = '1', copy_id = '102' }, result.copies[2])
        assertRestored()
    end)

    it('restores the view source after falling back to All Photographs', function()
        setup({ restricted = true })
        local originalSources = state.sources
        Handler.create({ photo_ids = { '3' } })
        assert.are.equal('all', calls.sources[1][1])
        assert.are.same(originalSources, state.sources)
        assertRestored()
    end)

    it('restores an empty selection', function()
        setup({ empty = true })
        Handler.create({ photo_ids = { '3' } })
        assert.is_nil(state.active)
        assert.are.same({}, state.selected)
    end)

    it('restores selection when the SDK fails and releases the session lock', function()
        setup({ failCreate = true })
        local ok, failure = pcall(Handler.create, { photo_ids = { '3' } })
        assert.is_false(ok)
        assert.matches('SDK failure', failure, 1, true)
        assertRestored()
        ok, failure = pcall(Handler.create, { photo_ids = { '3' } })
        assert.is_false(ok)
        assert.matches('SDK failure', failure, 1, true)
    end)

    it('reports a failed selection restore', function()
        setup({ failRestore = true })
        local ok, failure = pcall(Handler.create, { photo_ids = { '3' } })
        assert.is_false(ok)
        assert.matches('Could not restore the previous photo selection', failure, 1, true)
    end)

    it('leaves selection untouched when no photo resolves', function()
        setup()
        assert.has_error(function() Handler.create({ photo_ids = { '999' } }) end,
            'No photos matched photo_ids')
        assert.are.same({}, calls.selection)
        assert.are.same({}, calls.create)
    end)

    it('rejects malformed inputs before changing the selection', function()
        setup()
        for _, args in ipairs({ {}, { photo_ids = {} }, { photo_ids = { false } },
            { photo_ids = { '3' }, copy_name = ' ' } }) do
            assert.has_error(function() Handler.create(args) end)
        end
        local ids = {}
        for i = 1, 26 do ids[i] = '3' end
        assert.has_error(function() Handler.create({ photo_ids = ids }) end)
        assert.are.same({}, calls.selection)
    end)
end)
