local helper = require 'spec_helper'

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

local function tool(id, type, subtype, inverted)
    return { ID = id, Name = type .. " " .. id, Type = type, Subtype = subtype, Hidden = false, Inverted = inverted }
end

local function mask(id, name, hidden, tools)
    return { ID = id, Name = name, Hidden = hidden, Tools = tools }
end

local function setup(opts)
    local photos, masksOf, outside, failuresLeft, readErrorOf = {}, {}, {}, {}, {}
    for _, spec in ipairs(opts.photos) do
        local p = helper.fakePhoto({
            id = spec.id, path = "/" .. spec.id .. ".jpg", developSettings = spec.developSettings,
        })
        photos[#photos + 1] = p
        masksOf[p] = spec.masks
        outside[p] = spec.outsideSource
        failuresLeft[p] = spec.readyAfter or 0
        readErrorOf[p] = spec.readError
    end
    local active = not opts.nothingSelected and photos[1] or nil
    local module = "library"
    local sources = { "folder" }
    local autoSelectPending = false
    local calls = { modules = {}, selections = {}, sources = {}, selectNone = 0, getAllMasks = 0 }
    local Handler

    local controller = {
        getAllMasks = function()
            calls.getAllMasks = calls.getAllMasks + 1
            if module ~= "develop" then error("Develop module is not active") end
            if opts.onGetAllMasks then opts.onGetAllMasks(Handler) end
            if readErrorOf[active] then error(readErrorOf[active]) end
            if failuresLeft[active] > 0 then
                failuresLeft[active] = failuresLeft[active] - 1
                error("photo is still loading")
            end
            return masksOf[active]
        end,
        selectMask = function() end,
        selectMaskTool = function() end,
    }
    if opts.withoutMaskApi then
        controller.getAllMasks, controller.selectMask, controller.selectMaskTool = nil, nil, nil
    end

    local view = {
        getCurrentModuleName = function() return module end,
        switchToModule = function(name)
            module = name
            calls.modules[#calls.modules + 1] = name
        end,
    }
    local catalog = helper.fakeCatalog({ photos = photos })
    local recordSelection = catalog.setSelectedPhotos
    catalog.setSelectedPhotos = function(self, photo, selected)
        recordSelection(self, photo, selected)
        if outside[photo] and sources[1] ~= catalog.kAllPhotos then return end
        active = photo
        calls.selections[#calls.selections + 1] = photo.localIdentifier
    end
    catalog.getTargetPhoto = function() return active end
    catalog.kAllPhotos = "all photographs"
    catalog.getActiveSources = function() return sources end
    catalog.setActiveSources = function(_, newSources)
        sources = newSources
        calls.sources[#calls.sources + 1] = newSources[1]
        autoSelectPending = opts.autoSelectAfterSourceSwitch or false
    end

    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrApplicationView = view,
        LrDevelopController = controller,
        LrSelection = {
            selectNone = function()
                active = nil
                calls.selectNone = calls.selectNone + 1
            end,
        },
        LrTasks = {
            pcall = pcall,
            sleep = function()
                if autoSelectPending then
                    autoSelectPending = false
                    active = photos[1]
                end
            end,
        },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerMasks = nil
    package.loaded.DevelopSession = nil
    Handler = require 'HandlerMasks'
    return Handler, calls, catalog
end

describe("HandlerMasks.listMasks", function()
    it("returns every mask with its tools", function()
        local Handler = setup({
            photos = {
                { id = "10" },
                {
                    id = "11",
                    masks = {
                        mask("m-1", "Subject 1", false, {
                            tool("t-1", "aiSelection", "subject", false),
                            tool("t-2", "gradient", nil, true),
                        }),
                        mask("m-2", "Mask 2", true, {
                            tool("t-3", "rangeMask", "luminance", false),
                        }),
                    },
                },
            },
        })

        local r = Handler.listMasks({ photo_id = "11" })

        assert.is_true(r.success)
        assert.are.equal("11", r.photo_id)
        assert.are.equal(2, r.count)
        assert.are.same({
            {
                id = "m-1",
                name = "Subject 1",
                hidden = false,
                tools = {
                    { id = "t-1", type = "aiSelection", subtype = "subject", inverted = false },
                    { id = "t-2", type = "gradient", inverted = true },
                },
            },
            {
                id = "m-2",
                name = "Mask 2",
                hidden = true,
                tools = { { id = "t-3", type = "rangeMask", subtype = "luminance", inverted = false } },
            },
        }, r.masks)
    end)

    it("returns the stored range of a range mask tool next to its Lightroom ids", function()
        local Handler = setup({
            photos = { {
                id = "1",
                masks = { mask("m-1", "Mask 1", false, {
                    tool("t-color", "rangeMask", "color", false),
                    tool("t-lum", "rangeMask", "luminance", false),
                    tool("t-grad", "gradient", nil, false),
                }) },
                developSettings = { MaskGroupBasedCorrections = { {
                    What = "Correction",
                    CorrectionID = "m-1",
                    CorrectionMasks = {
                        {
                            What = "Mask/RangeMask",
                            MaskID = "t-color",
                            CorrectionRangeMask = {
                                Type = 1,
                                ColorAmount = 0.494949,
                                PointModels = { "0.522527 0.888059 0.758296 0.050000 0.188000 0" },
                            },
                        },
                        {
                            What = "Mask/RangeMask",
                            MaskID = "t-lum",
                            CorrectionRangeMask = { Type = 2, LumRange = "0.200000 0.300000 0.600000 0.700000" },
                        },
                        { What = "Mask/Gradient", MaskID = "t-grad" },
                    },
                } } },
            } },
        })

        local tools = Handler.listMasks({ photo_id = "1" }).masks[1].tools

        assert.are.same({
            sample = { x = 0.05, y = 0.188, l = 0.522527, a = 0.888059, b = 0.758296 },
            amount = 0.494949,
        }, tools[1].range)
        assert.are.same({ min = 0.3, max = 0.6, lower_falloff = 0.1, upper_falloff = 0.1 }, tools[2].range)
        assert.is_nil(tools[3].range)
    end)

    it("still lists the masks when the stored ranges cannot be read", function()
        local Handler = setup({
            photos = { {
                id = "1",
                masks = { mask("m-1", "Mask 1", false, { tool("t-color", "rangeMask", "color", false) }) },
                developSettings = { MaskGroupBasedCorrections = "not a list" },
            } },
        })

        local r = Handler.listMasks({ photo_id = "1" })

        assert.are.equal(1, r.count)
        assert.is_nil(r.masks[1].tools[1].range)
    end)

    it("returns an empty list for a photo without masks", function()
        for _, masks in ipairs({ {}, false }) do
            local Handler = setup({ photos = { { id = "1", masks = masks or nil } } })

            local r = Handler.listMasks({ photo_id = "1" })

            assert.is_true(r.success)
            assert.are.equal(0, r.count)
            assert.are.same({}, r.masks)
        end
    end)

    it("accepts a numeric photo id and a file path", function()
        local Handler = setup({ photos = { { id = "7", masks = { mask("m", "M", false, {}) } } } })

        assert.are.equal("7", Handler.listMasks({ photo_id = 7 }).photo_id)
        assert.are.equal(1, Handler.listMasks({ photo_id = "/7.jpg" }).count)
    end)

    it("names the photo id when the photo is unknown and never touches Develop", function()
        local Handler, calls = setup({ photos = { { id = "1" } } })

        local err = errorOf(function() Handler.listMasks({ photo_id = "404" }) end)

        assert.truthy(err:find("Photo not found: 404", 1, true))
        assert.are.equal(0, #calls.modules)
    end)

    it("requires a photo id", function()
        local Handler = setup({ photos = { { id = "1" } } })

        for _, bad in ipairs({ "", true }) do
            assert.truthy(errorOf(function() Handler.listMasks({ photo_id = bad }) end)
                :find("photo_id is required", 1, true))
        end
        assert.truthy(errorOf(function() Handler.listMasks({}) end):find("photo_id is required", 1, true))
    end)

    it("names the minimum Lightroom version when the mask API is missing", function()
        local Handler, calls = setup({ photos = { { id = "1" } }, withoutMaskApi = true })

        local err = errorOf(function() Handler.listMasks({ photo_id = "1" }) end)

        assert.truthy(err:find("list_masks needs Lightroom Classic 11 or later", 1, true))
        assert.are.equal(0, #calls.modules)
    end)

    it("puts back the module and the selection", function()
        local Handler, calls = setup({
            photos = {
                { id = "1" },
                { id = "2", masks = { mask("m", "M", false, {}) } },
            },
        })

        Handler.listMasks({ photo_id = "2" })

        assert.are.same({ "develop", "library" }, calls.modules)
        assert.are.same({ "2", "1" }, calls.selections)
    end)

    it("clears the selection again when nothing was selected", function()
        local Handler, calls = setup({ photos = { { id = "1", masks = {} } }, nothingSelected = true })

        Handler.listMasks({ photo_id = "1" })

        assert.are.equal(1, calls.selectNone)
    end)

    it("reaches a photo outside the current source and restores the source", function()
        local Handler, calls = setup({
            photos = { { id = "1" }, { id = "2", outsideSource = true, masks = {} } },
        })

        local r = Handler.listMasks({ photo_id = "2" })

        assert.is_true(r.success)
        assert.are.same({ "all photographs", "folder" }, calls.sources)
        assert.are.same({ "develop", "library" }, calls.modules)
        assert.are.same({ "2", "1" }, calls.selections)
    end)

    it("waits for a photo that is still loading in Develop", function()
        local Handler, calls = setup({
            photos = { { id = "1", readyAfter = 3, masks = { mask("m", "M", false, {}) } } },
        })

        local r = Handler.listMasks({ photo_id = "1" })

        assert.are.equal(1, r.count)
        assert.are.equal(4, calls.getAllMasks)
    end)

    it("restores the view and reports the reason when Lightroom never answers", function()
        local Handler, calls = setup({
            photos = { { id = "1" }, { id = "2", readError = "unsupported photo" } },
        })

        local err = errorOf(function() Handler.listMasks({ photo_id = "2" }) end)

        assert.truthy(err:find("could not read the masks of photo 2", 1, true))
        assert.truthy(err:find("unsupported photo", 1, true))
        assert.are.same({ "develop", "library" }, calls.modules)
        assert.are.same({ "2", "1" }, calls.selections)
    end)

    it("rejects a second Develop call while one is running and accepts calls afterwards", function()
        local nested
        local Handler = setup({
            photos = { { id = "1", masks = {} } },
            onGetAllMasks = function(handler)
                if nested == nil then
                    nested = errorOf(function() handler.listMasks({ photo_id = "1" }) end)
                end
            end,
        })

        assert.are.equal(0, Handler.listMasks({ photo_id = "1" }).count)
        assert.truthy(nested:find("list_masks is already running", 1, true))
        assert.are.equal(0, Handler.listMasks({ photo_id = "1" }).count)
    end)

    it("errors with the field names when a mask has no id", function()
        local Handler = setup({ photos = { { id = "1", masks = { { label = "x", Tools = {} } } } } })

        local err = errorOf(function() Handler.listMasks({ photo_id = "1" }) end)

        assert.truthy(err:find("mask without an id for photo 1", 1, true))
        assert.truthy(err:find("Tools, label", 1, true))
    end)

    it("errors with the field names when a mask tool has no id", function()
        local Handler = setup({
            photos = { { id = "1", masks = { { ID = "m", Tools = { { Type = "brush" } } } } } },
        })

        local err = errorOf(function() Handler.listMasks({ photo_id = "1" }) end)

        assert.truthy(err:find("mask tool without an id for photo 1", 1, true))
        assert.truthy(err:find("(fields: Type)", 1, true))
    end)

    it("reads the shape Lightroom Classic 15.6 returned for real masks", function()
        local Handler = setup({
            photos = {
                {
                    id = "1",
                    masks = {
                        {
                            Tools = {
                                { Type = "gradient", Name = "Linear Gradient 2", Inverted = false,
                                    ID = "7B716E7B-452A-4EC3-8199-531B2F1CFF41", Hidden = false },
                                { Type = "radialGradient", Name = "Radial Gradient 1", Inverted = true,
                                    ID = "83166C5E-AE77-435E-B108-F1B1A4DA4870", Hidden = false },
                            },
                            Hidden = true,
                            Name = "Radial test",
                            ID = "3A7C8A70-9924-4302-BFC5-18245650F139",
                        },
                        {
                            Tools = {
                                { Type = "aiSelection", Name = "Sky 1", Subtype = "sky", Inverted = false,
                                    ID = "6EA08274-0303-4FAD-80D7-263C230EF658", Hidden = false },
                            },
                            Hidden = false,
                            Name = "Mask 1",
                            ID = "A6585ED4-99D0-4B82-A48B-2472A8E9E178",
                        },
                    },
                },
            },
        })

        local r = Handler.listMasks({ photo_id = "1" })

        assert.are.same({
            {
                id = "3A7C8A70-9924-4302-BFC5-18245650F139",
                name = "Radial test",
                hidden = true,
                tools = {
                    { id = "7B716E7B-452A-4EC3-8199-531B2F1CFF41", type = "gradient", inverted = false },
                    { id = "83166C5E-AE77-435E-B108-F1B1A4DA4870", type = "radialGradient", inverted = true },
                },
            },
            {
                id = "A6585ED4-99D0-4B82-A48B-2472A8E9E178",
                name = "Mask 1",
                hidden = false,
                tools = {
                    {
                        id = "6EA08274-0303-4FAD-80D7-263C230EF658",
                        type = "aiSelection",
                        subtype = "sky",
                        inverted = false,
                    },
                },
            },
        }, r.masks)
    end)

    it("lists a mask whose tools field is missing as having no tools", function()
        local Handler = setup({ photos = { { id = "1", masks = { { ID = "m", Name = "M", Hidden = false } } } } })

        local r = Handler.listMasks({ photo_id = "1" })

        assert.are.same({}, r.masks[1].tools)
    end)

    it("never opens a catalog gate", function()
        local Handler, _, catalog = setup({ photos = { { id = "1", masks = {} } } })

        Handler.listMasks({ photo_id = "1" })

        assert.are.equal(0, catalog.getWriteAccessCount())
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)
end)
