local helper = require 'spec_helper'

local function setup(opts)
    opts = opts or {}
    local photos = { helper.fakePhoto({ id = '1' }), helper.fakePhoto({ id = '2' }) }
    local catalog = helper.fakeCatalog({ photos = photos })
    local active, selection, module = photos[2], { photos[2] }, 'library'
    local sources = { 'collection' }
    local values = opts.values or { LensBlurActive = false, LensBlurAmount = 35,
        LensBlurCatEye = 0, LensBlurHighlightsBoost = 50, LensBlurFocalRange = '-80 0 28 108' }
    local saved = { Active = values.LensBlurActive, BlurAmount = values.LensBlurAmount,
        CatEyeAmount = values.LensBlurCatEye, HighlightsBoost = values.LensBlurHighlightsBoost,
        FocalRange = values.LensBlurFocalRange, BokehShape = 0 }
    local bokeh = 'Circle'
    local writes = 0
    local pendingActive, activationWait, prematureFlush = nil, 0, false
    catalog.getTargetPhoto = function() return active end
    catalog.getTargetPhotos = function() return selection end
    catalog.setSelectedPhotos = function(_, photo, selected) active, selection = photo, selected end
    catalog.getActiveSources = function() return sources end
    catalog.setActiveSources = function(_, nextSources) sources = nextSources end
    photos[1].getDevelopSettings = function() return { LensBlur = saved } end
    local controller = {
        getProcessVersion = function() return opts.process or 'Version 6' end,
        getValue = function(name) return values[name] end,
        getRange = function(name)
            if name == 'LensBlurAmount' then return 0, opts.amountMax or 100 end
            return -100, 100
        end,
        setValue = function(name, value)
            writes = writes + 1
            if name == 'LensBlurActive' and opts.activationDelay then
                pendingActive, activationWait = value, opts.activationDelay
                return
            end
            if name == 'LensBlurActive' or values.LensBlurActive then
                values[name] = value
            end
        end,
        getSelectedLensBlurBokeh = function() if values.LensBlurActive then return bokeh end end,
        setLensBlurBokeh = function(value) writes = writes + 1 bokeh = value end,
        stopTracking = function(localParam)
            if localParam or opts.ignoreSave then return end
            if pendingActive ~= nil then prematureFlush = true end
            if prematureFlush then return end
            local amount = opts.ignoreAmountSave and saved.BlurAmount or values.LensBlurAmount
            saved = { Active = values.LensBlurActive, BlurAmount = values.LensBlurAmount,
                CatEyeAmount = values.LensBlurCatEye, HighlightsBoost = values.LensBlurHighlightsBoost,
                FocalRange = values.LensBlurFocalRange, BokehShape = bokeh }
            saved.BlurAmount = amount
        end,
    }
    helper.installImport({
        LrApplication = {
            activeCatalog = function() return catalog end,
            versionTable = function() return opts.version or { major = 15, minor = 6 } end,
        },
        LrDevelopController = controller,
        LrApplicationView = {
            getCurrentModuleName = function() return module end,
            switchToModule = function(value) module = value end,
        },
        LrSelection = { selectNone = function() active, selection = nil, {} end },
        LrTasks = { pcall = pcall, sleep = function(seconds)
            if opts.stealPhoto then active = photos[2] end
            if pendingActive ~= nil then
                activationWait = activationWait - seconds
                if activationWait <= 0 then
                    values.LensBlurActive, pendingActive = pendingActive, nil
                end
            end
        end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.DevelopSession = nil
    package.loaded.HandlerLensBlur = nil
    return {
        Handler = require 'HandlerLensBlur', values = values,
        saved = function() return saved end, writes = function() return writes end,
        view = function() return { active = active.localIdentifier, module = module, sources = sources } end,
    }
end

local function failure(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

describe('HandlerLensBlur', function()
    it('enables an inactive photo before saving Amount50 and restores the view', function()
        local ctx = setup()

        local result = ctx.Handler.set({ photo_id = '1', amount = 50 })

        assert.is_true(result.active)
        assert.are.equal(50, result.amount)
        assert.are.equal(50, ctx.saved().BlurAmount)
        assert.is_true(ctx.saved().Active)
        assert.are.same({ active = '2', module = 'library', sources = { 'collection' } }, ctx.view())
    end)

    it('waits for asynchronous activation before committing and saving Amount50', function()
        local ctx = setup({ activationDelay = 12 })

        local result = ctx.Handler.set({ photo_id = '1', amount = 50 })

        assert.is_true(result.active)
        assert.are.equal(50, result.amount)
        assert.are.equal(50, ctx.saved().BlurAmount)
        assert.is_true(ctx.saved().Active)
        assert.are.same({ active = '2', module = 'library', sources = { 'collection' } }, ctx.view())
    end)

    it('stops before Amount when activation never becomes ready', function()
        local ctx = setup({ activationDelay = 30 })

        local err = failure(function() ctx.Handler.set({ photo_id = '1', amount = 50 }) end)

        assert.matches('did not finish changing LensBlurActive', err, 1, true)
        assert.are.equal(1, ctx.writes())
        assert.are.equal(35, ctx.saved().BlurAmount)
        assert.are.same({ active = '2', module = 'library', sources = { 'collection' } }, ctx.view())
    end)

    it('reads an uninitialized photo as off without writing', function()
        local ctx = setup({ values = {} })

        local result = ctx.Handler.get({ photo_id = '1' })

        assert.is_false(result.active)
        assert.is_nil(result.amount)
        assert.are.same({ 'amount', 'cat_eye', 'highlights_boost', 'focal_range', 'bokeh' }, result.unavailable)
        assert.are.equal(0, ctx.writes())
    end)

    it('sets combined controls and returns the focal range inner endpoints', function()
        local ctx = setup()

        local result = ctx.Handler.set({ photo_id = '1', amount = 50, cat_eye = 20,
            highlights_boost = 30, focal_range = { near = 10, far = 30 }, bokeh = 'Ring' })

        assert.are.equal(20, result.cat_eye)
        assert.are.equal(30, result.highlights_boost)
        assert.are.same({ near = 10, far = 30 }, result.focal_range)
        assert.are.equal('-70 10 30 110', result.focal_range_raw)
        assert.are.equal('Ring', result.bokeh)
    end)

    it('can save adjustments and leave Lens Blur disabled', function()
        local ctx = setup()

        local result = ctx.Handler.set({ photo_id = '1', active = false, amount = 50 })

        assert.is_false(result.active)
        assert.is_false(ctx.saved().Active)
        assert.are.equal(50, ctx.saved().BlurAmount)
    end)

    it('rejects an amount outside the runtime range before enabling or writing anything', function()
        local ctx = setup({ amountMax = 40 })

        local err = failure(function() ctx.Handler.set({ photo_id = '1', amount = 50 }) end)

        assert.matches('range 0 to 40', err, 1, true)
        assert.are.equal(0, ctx.writes())
        assert.is_false(ctx.values.LensBlurActive)
    end)

    for _, version in ipairs({ 'Version 1', 'Version 2' }) do
        it('rejects ' .. version .. ' without writing', function()
            local ctx = setup({ process = version })

            local err = failure(function() ctx.Handler.set({ photo_id = '1', amount = 50 }) end)

            assert.matches(version, err, 1, true)
            assert.are.equal(0, ctx.writes())
            assert.are.same({ active = '2', module = 'library', sources = { 'collection' } }, ctx.view())
        end)
    end

    for _, args in ipairs({ { bokeh = 'Square' }, { focal_range = { near = 30, far = 10 } },
        { amount = 0 / 0 }, { active = 1 }, {} }) do
        it('rejects malformed controls without writing', function()
            local ctx = setup()
            args.photo_id = '1'

            failure(function() ctx.Handler.set(args) end)

            assert.are.equal(0, ctx.writes())
        end)
    end

    it('stops when the controller accepts a value but never saves it', function()
        local ctx = setup({ ignoreSave = true })

        local err = failure(function() ctx.Handler.set({ photo_id = '1', amount = 50 }) end)

        assert.matches('did not save LensBlurActive', err, 1, true)
        assert.are.equal(35, ctx.saved().BlurAmount)
        assert.are.same({ active = '2', module = 'library', sources = { 'collection' } }, ctx.view())
    end)

    it('stops later adjustments when Amount readback differs from saved settings', function()
        local ctx = setup({ ignoreAmountSave = true })

        local err = failure(function() ctx.Handler.set({ photo_id = '1', amount = 50, cat_eye = 20 }) end)

        assert.matches('did not save LensBlurAmount', err, 1, true)
        assert.are.equal(50, ctx.values.LensBlurAmount)
        assert.are.equal(35, ctx.saved().BlurAmount)
        assert.are.equal(0, ctx.values.LensBlurCatEye)
    end)

    it('leaves an uninitialized disabled photo unchanged when disabling it', function()
        local ctx = setup({ values = {} })

        local result = ctx.Handler.set({ photo_id = '1', active = false })

        assert.is_false(result.active)
        assert.are.equal(0, ctx.writes())
    end)

    it('rejects Lightroom below13.3 without writing', function()
        local ctx = setup({ version = { major = 13, minor = 2 } })

        local err = failure(function() ctx.Handler.get({ photo_id = '1' }) end)

        assert.matches('13.3', err, 1, true)
        assert.are.equal(0, ctx.writes())
    end)
end)
