local helper = require 'spec_helper'
local Store = require 'fake_mask_store'

local linearComponent = Store.linearComponent
local correction = Store.correction

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

local SUBTYPE_OF_RANGE_TYPE = { [1] = "color", [2] = "luminance" }

local function maskListWithSubtypes(entries)
    local masks = Store.maskListOf(entries)
    for maskIndex, entry in ipairs(entries) do
        for toolIndex, component in ipairs(entry.CorrectionMasks) do
            local range = component.CorrectionRangeMask
            if range then masks[maskIndex].Tools[toolIndex].Subtype = SUBTYPE_OF_RANGE_TYPE[range.Type] end
        end
    end
    return masks
end

local function setup(opts)
    opts = opts or {}
    local photos, stores, storeOf = {}, {}, {}
    for _, spec in ipairs(opts.photos or { { id = "1" } }) do
        local photo = helper.fakePhoto({ id = spec.id, path = "/" .. spec.id .. ".jpg" })
        stores[spec.id] = Store.attach(photo, spec)
        storeOf[photo] = stores[spec.id]
        photos[#photos + 1] = photo
    end
    local active = photos[1]
    local module = "library"
    local calls = { modules = {}, getAllMasks = 0 }
    local catalog = helper.fakeCatalog({ photos = photos })
    for _, spec in ipairs(opts.photos or { { id = "1" } }) do
        Store.trackGates(stores[spec.id], catalog)
    end
    catalog.getTargetPhoto = function() return active end
    local recordSelection = catalog.setSelectedPhotos
    catalog.setSelectedPhotos = function(self, photo, selected)
        recordSelection(self, photo, selected)
        active = photo
    end
    catalog.kAllPhotos = "all photographs"
    catalog.getActiveSources = function() return { "folder" } end
    catalog.setActiveSources = function() end

    local controller = {
        getAllMasks = function()
            calls.getAllMasks = calls.getAllMasks + 1
            if opts.hideNewMasks then return {} end
            local masks = maskListWithSubtypes(storeOf[active].entries)
            if opts.wrongSubtype then
                for _, mask in ipairs(masks) do
                    for _, tool in ipairs(mask.Tools) do tool.Subtype = opts.wrongSubtype end
                end
            end
            return masks
        end,
        selectMask = function() end,
        selectMaskTool = function() end,
    }
    if opts.withoutMaskApi then controller = {} end

    helper.installImport({
        LrApplication = {
            activeCatalog = function() return catalog end,
            versionTable = function() return opts.version or { major = 15, minor = 6 } end,
        },
        LrApplicationView = {
            getCurrentModuleName = function() return module end,
            switchToModule = function(name)
                module = name
                calls.modules[#calls.modules + 1] = name
            end,
        },
        LrDevelopController = controller,
        LrSelection = { selectNone = function() active = nil end },
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    for _, name in ipairs({
        "HandlerRangeMasks", "GuardedMaskWrite", "RangeMaskGeometry", "DevelopSession", "Log",
    }) do
        package.loaded[name] = nil
    end
    return require 'HandlerRangeMasks', stores, calls, catalog
end

local function luminanceRequest(overrides)
    local args = {
        photo_id = "1", type = "luminance", luminance = { min = 0.3, max = 0.6, falloff = 0.1 },
    }
    for key, value in pairs(overrides or {}) do args[key] = value end
    return args
end

local function colorRequest(overrides)
    local args = {
        photo_id = "1",
        type = "color",
        color = { sample = { x = 0.2, y = 0.8, red = 0.462745, green = 0.4, blue = 0.1 }, amount = 0.4 },
    }
    for key, value in pairs(overrides or {}) do args[key] = value end
    return args
end

local function existingGradient()
    return {
        correction("Sky", { linearComponent({ MaskID = "C1T1" }) }, { CorrectionID = "C1" }),
    }
end

local function colorEntryWithPoints(pointModels)
    return {
        correction("Foliage", {
            {
                What = "Mask/RangeMask",
                MaskID = "C1T1",
                MaskActive = true,
                MaskInverted = false,
                MaskBlendMode = 0,
                CorrectionRangeMask = { Type = 1, Version = 3, SampleType = 0, ColorAmount = 0.5, PointModels = pointModels },
            },
        }, { CorrectionID = "C1" }),
    }
end

local function lightroomFillsDepthInfo(stored, writeNumber)
    if writeNumber == 1 then
        for _, entry in ipairs(stored) do
            for _, component in ipairs(entry.CorrectionMasks) do
                if component.CorrectionRangeMask then
                    component.CorrectionRangeMask.LuminanceDepthSampleInfo = "0 0.5 0.5"
                end
            end
        end
    end
    return stored
end

describe("HandlerRangeMasks.createRangeMask", function()
    it("writes a luminance range as a new mask and returns the stored range", function()
        local Handler, stores = setup({ photos = { { id = "1", transformWrite = lightroomFillsDepthInfo } } })

        local result = Handler.createRangeMask(luminanceRequest({ name = "Highlights" }))

        local written = stores["1"].writes[1]
        assert.are.equal(1, #written)
        assert.are.equal("Highlights", written[1].CorrectionName)
        local component = written[1].CorrectionMasks[1]
        assert.are.equal("Mask/RangeMask", component.What)
        assert.are.equal(2, component.CorrectionRangeMask.Type)
        assert.are.equal("0.200000 0.300000 0.600000 0.700000", component.CorrectionRangeMask.LumRange)
        assert.is_true(result.success)
        assert.are.equal("1", result.photo_id)
        assert.are.equal("C1", result.mask_id)
        assert.are.equal("C1T1", result.tool_id)
        assert.are.equal("luminance", result.type)
        assert.are.equal("add", result.mode)
        assert.is_false(result.invert)
        assert.is_true(result.new_mask)
        assert.are.same({ min = 0.3, max = 0.6, lower_falloff = 0.1, upper_falloff = 0.1 }, result.luminance)
        assert.is_nil(result.color)
    end)

    it("writes a color range with exactly one PointModels entry", function()
        local Handler, stores = setup()

        local result = Handler.createRangeMask(colorRequest())

        local range = stores["1"].writes[1][1].CorrectionMasks[1].CorrectionRangeMask
        assert.are.equal(1, range.Type)
        assert.are.equal(0.4, range.ColorAmount)
        assert.are.equal(1, #range.PointModels)
        assert.are.equal("0.462745 0.400000 0.100000 0.200000 0.800000 0", range.PointModels[1])
        assert.are.equal("color", result.type)
        assert.are.same({ x = 0.2, y = 0.8, red = 0.462745, green = 0.4, blue = 0.1 }, result.color.sample)
        assert.are.equal(0.4, result.color.amount)
    end)

    it("never writes a second PointModels entry even when asked for one", function()
        local Handler, stores = setup()
        local sample = { x = 0.2, y = 0.8, red = 0.4, green = 0.4, blue = 0.1 }

        local message = errorOf(function()
            Handler.createRangeMask(colorRequest({ color = { sample = { sample, sample } } }))
        end)

        assert.is_truthy(message:find("single sample point", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, stores["1"].reads)
    end)

    it("refuses a photo that already holds a color range with two PointModels, writing nothing", function()
        local entries = colorEntryWithPoints({
            "0.462745 0.462745 0.462745 0.200000 0.200000 0",
            "0.027451 0.027451 0.027451 0.800000 0.800000 0",
        })
        local Handler, stores, calls = setup({ photos = { { id = "1", entries = entries } } })

        local message = errorOf(function() Handler.createRangeMask(luminanceRequest()) end)

        assert.is_truthy(message:find("exactly one PointModels entry", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("keeps an existing single-point color range verbatim next to the new mask", function()
        local entries = colorEntryWithPoints({ "0.5 0.5 0.5 0.1 0.1 0" })
        local Handler, stores = setup({ photos = { { id = "1", entries = entries } } })

        local result = Handler.createRangeMask(luminanceRequest())

        local written = stores["1"].writes[1]
        assert.are.equal(2, #written)
        assert.are.equal(1, #written[1].CorrectionMasks[1].CorrectionRangeMask.PointModels)
        assert.are.equal("C2", result.mask_id)
    end)

    it("refuses an existing depth range mask, writing nothing", function()
        local entries = {
            correction("Depth", {
                {
                    What = "Mask/RangeMask",
                    MaskID = "C1T1",
                    CorrectionRangeMask = { Type = 3, Version = 3, SampleType = 0, DepthRange = "0 0 1 1" },
                },
            }, { CorrectionID = "C1" }),
        }
        local Handler, stores = setup({ photos = { { id = "1", entries = entries } } })

        local message = errorOf(function() Handler.createRangeMask(luminanceRequest()) end)

        assert.is_truthy(message:find("unsupported range Type 3", 1, true))
        assert.are.equal(0, #stores["1"].writes)
    end)

    it("rejects depth as a type before reading, writing or opening Develop", function()
        local Handler, stores, calls = setup()

        local message = errorOf(function() Handler.createRangeMask(luminanceRequest({ type = "depth" })) end)

        assert.is_truthy(message:find('type must be "luminance" or "color"', 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, stores["1"].reads)
        assert.are.equal(0, #calls.modules)
    end)

    it("adds a subtracting inverted component to an existing mask", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingGradient() } } })

        local result = Handler.createRangeMask(luminanceRequest({ mask_id = "C1", mode = "subtract", invert = true }))

        local written = stores["1"].writes[1]
        assert.are.equal(1, #written)
        assert.are.equal(2, #written[1].CorrectionMasks)
        assert.are.equal("C1T1", written[1].CorrectionMasks[1].MaskID)
        local component = written[1].CorrectionMasks[2]
        assert.are.equal(1, component.MaskBlendMode)
        assert.is_true(component.MaskInverted)
        assert.is_nil(component.CorrectionRangeMask.Invert)
        assert.are.equal("C1", result.mask_id)
        assert.are.equal("C1T2", result.tool_id)
        assert.are.equal("subtract", result.mode)
        assert.is_true(result.invert)
        assert.is_false(result.new_mask)
    end)

    it("fails for an unknown mask id without writing or opening Develop", function()
        local Handler, stores, calls = setup({ photos = { { id = "1", entries = existingGradient() } } })

        local message = errorOf(function() Handler.createRangeMask(luminanceRequest({ mask_id = "C9" })) end)

        assert.is_truthy(message:find("Mask not found on this photo: C9", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("never queries or reads settings outside the gates", function()
        local Handler, stores, _, catalog = setup()

        Handler.createRangeMask(luminanceRequest())

        assert.is_false(catalog.getQueriedInsideReadAccess())
        assert.is_false(catalog.getQueriedInsideWriteAccess())
        assert.are.equal(0, stores["1"].readsOutsideGate)
        assert.are.equal(0, stores["1"].writesOutsideGate)
    end)

    it("opens Develop for the cross-check and puts the module back", function()
        local Handler, _, calls = setup()

        Handler.createRangeMask(colorRequest())

        assert.are.same({ "develop", "library" }, calls.modules)
        assert.is_true(calls.getAllMasks >= 1)
    end)

    it("requires a photo id and a known photo", function()
        local Handler, _, calls = setup()

        assert.is_truthy(errorOf(function() Handler.createRangeMask(luminanceRequest({ photo_id = "" })) end)
            :find("photo_id is required", 1, true))
        assert.is_truthy(errorOf(function() Handler.createRangeMask(luminanceRequest({ photo_id = "404" })) end)
            :find("Photo not found: 404", 1, true))
        assert.are.equal(0, #calls.modules)
    end)

    it("refuses an untested Lightroom version, leaving the photo and the view alone", function()
        local Handler, stores, calls = setup({ version = { major = 15, minor = 7 } })

        local message = errorOf(function() Handler.createRangeMask(luminanceRequest()) end)

        assert.is_truthy(message:find("15.7", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("refuses an untested process version", function()
        local Handler, stores = setup({ photos = { { id = "1", processVersion = "11.0" } } })

        local message = errorOf(function() Handler.createRangeMask(colorRequest()) end)

        assert.is_truthy(message:find("process version (11.0)", 1, true))
        assert.are.equal(0, #stores["1"].writes)
    end)

    it("names the minimum Lightroom version when the mask API is missing", function()
        local Handler, stores, calls = setup({ withoutMaskApi = true })

        local message = errorOf(function() Handler.createRangeMask(luminanceRequest()) end)

        assert.is_truthy(message:find("create_range_mask needs Lightroom Classic 11 or later", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("restores the previous masks when Lightroom reads a different luminance range back", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                entries = existingGradient(),
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[2].CorrectionMasks[1].CorrectionRangeMask.LumRange = "0.000000 0.000000 1.000000 1.000000" end
                    return stored
                end,
            } },
        })

        local message = errorOf(function() Handler.createRangeMask(luminanceRequest()) end)

        assert.is_truthy(message:find("previous masks were restored", 1, true))
        assert.is_truthy(message:find("LumRange", 1, true))
        assert.are.equal(2, #stores["1"].writes)
        assert.are.equal(1, #stores["1"].entries)
        assert.are.equal("C1", stores["1"].entries[1].CorrectionID)
    end)

    it("restores the previous masks when Lightroom resets the range type", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[1].CorrectionMasks[1].CorrectionRangeMask.Type = 0 end
                    return stored
                end,
            } },
        })

        local message = errorOf(function() Handler.createRangeMask(colorRequest()) end)

        assert.is_truthy(message:find("previous masks were restored", 1, true))
        assert.are.equal(0, #stores["1"].entries)
    end)

    it("restores the previous masks when Lightroom changes the color sample", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then
                        stored[1].CorrectionMasks[1].CorrectionRangeMask.PointModels[1] = "0.1 0.1 0.1 0.9 0.9 0"
                    end
                    return stored
                end,
            } },
        })

        local message = errorOf(function() Handler.createRangeMask(colorRequest()) end)

        assert.is_truthy(message:find("previous masks were restored", 1, true))
        assert.are.equal(0, #stores["1"].entries)
    end)

    it("restores the previous masks when Lightroom ignores the inversion", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[1].CorrectionMasks[1].MaskInverted = false end
                    return stored
                end,
            } },
        })

        local message = errorOf(function() Handler.createRangeMask(luminanceRequest({ invert = true })) end)

        assert.is_truthy(message:find("MaskInverted", 1, true))
        assert.are.equal(0, #stores["1"].entries)
    end)

    it("restores the previous masks when Lightroom's mask list does not show the new tool", function()
        local Handler, stores, calls = setup({ hideNewMasks = true })

        local message = errorOf(function() Handler.createRangeMask(luminanceRequest()) end)

        assert.is_truthy(message:find("Lightroom's mask list has no rangeMask luminance tool C1T1 in mask C1", 1, true))
        assert.are.equal(2, #stores["1"].writes)
        assert.are.equal(0, #stores["1"].entries)
        assert.are.equal("library", calls.modules[#calls.modules])
    end)

    it("restores the previous masks when Lightroom lists the tool with another subtype", function()
        local Handler, stores = setup({ wrongSubtype = "color" })

        local message = errorOf(function() Handler.createRangeMask(luminanceRequest()) end)

        assert.is_truthy(message:find("has no rangeMask luminance tool", 1, true))
        assert.are.equal(0, #stores["1"].entries)
    end)

    it("accepts the derived fields Lightroom fills in", function()
        local Handler = setup({ photos = { { id = "1", transformWrite = lightroomFillsDepthInfo } } })

        local result = Handler.createRangeMask(luminanceRequest())

        assert.is_true(result.success)
    end)
end)
