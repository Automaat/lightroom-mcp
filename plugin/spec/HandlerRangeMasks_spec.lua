local helper = require 'spec_helper'
local Store = require 'fake_mask_store'

local linearComponent = Store.linearComponent
local correction = Store.correction

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

local SUBTYPE_OF_RANGE_TYPE = { [1] = "color", [2] = "luminance", [-1] = "depth" }

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
        local photo = helper.fakePhoto({
            id = spec.id, path = "/" .. spec.id .. ".jpg", orientation = spec.orientation or "AB",
        })
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

    local selectedMask
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
        selectMask = function(id) selectedMask = id end,
        getSelectedMask = function() return selectedMask end,
        getRange = function(name)
            if opts.narrowRange then return -0.5, 0.5 end
            if name == "local_Exposure" then return -4, 4 end
            return -100, 100
        end,
        getValue = function(name)
            if opts.wrongAdjustment then return 0 end
            for _, entry in ipairs(storeOf[active].entries) do
                if entry.CorrectionID == selectedMask then
                    if name == "local_Exposure" then return (entry.LocalExposure2012 or 0) * 4 end
                    if name == "local_Contrast" then return (entry.LocalContrast2012 or 0) * 100 end
                end
            end
            return 0
        end,
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
        "HandlerRangeMasks", "GuardedMaskWrite", "ImageFrame", "RangeMaskGeometry", "DevelopSession", "Log",
        "MaskCreationAdjustments", "MaskSelection", "LocalSliders",
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
        color = { sample = { x = 0.2, y = 0.8, l = 0.462745, a = 0.4, b = 0.1 }, amount = 0.4 },
    }
    for key, value in pairs(overrides or {}) do args[key] = value end
    return args
end

local function depthRequest(overrides)
    local args = { photo_id = "1", type = "depth", depth = { min = 0, max = 0.1, falloff = 0.25 } }
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
    it("writes requested adjustments with the geometry in one Develop session", function()
        local Handler, stores, calls = setup()
        local result = Handler.createRangeMask(luminanceRequest({ adjustments = { exposure = 1, contrast = -25 } }))
        assert.is_true(result.success)
        assert.are.equal(1, #stores["1"].writes)
        assert.are.equal(0.25, stores["1"].entries[1].LocalExposure2012)
        assert.are.equal(-0.25, stores["1"].entries[1].LocalContrast2012)
        assert.is_nil(stores["1"].entries[1].LocalTemperature)
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("rejects empty, unknown, out-of-range and existing-mask adjustments before writes", function()
        for _, adjustments in ipairs({ {}, { unknown = 1 }, { exposure = 5 }, { exposure = 0 / 0 } }) do
            local Handler, stores = setup()
            assert.matches("adjust", errorOf(function()
                Handler.createRangeMask(luminanceRequest({ adjustments = adjustments }))
            end))
            assert.are.equal(0, #stores["1"].writes)
        end
        local Handler, stores = setup()
        assert.matches("mask_id", errorOf(function()
            Handler.createRangeMask(luminanceRequest({ mask_id = "existing", adjustments = { exposure = 1 } }))
        end))
        assert.are.equal(0, #stores["1"].writes)
    end)

    it("restores all previous masks when the SDK adjustment read-back differs", function()
        local previous = { correction("Existing", { Store.linearComponent({ MaskID = "C1T1" }) },
            { CorrectionID = "C1" }) }
        local Handler, stores = setup({ wrongAdjustment = true, photos = { { id = "1", entries = previous } } })
        assert.matches("restored", errorOf(function()
            Handler.createRangeMask(luminanceRequest({ adjustments = { exposure = 1 } }))
        end))
        assert.are.same(previous, stores["1"].entries)
        assert.are.equal(2, #stores["1"].writes)
    end)

    it("rejects a narrower live slider range before writing", function()
        local Handler, stores = setup({ narrowRange = true })
        assert.matches("slider range", errorOf(function()
            Handler.createRangeMask(luminanceRequest({ adjustments = { exposure = 1 } }))
        end))
        assert.are.same({}, stores["1"].entries)
        assert.are.equal(0, #stores["1"].writes)
    end)

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
        assert.are.same({ x = 0.2, y = 0.8, l = 0.462745, a = 0.4, b = 0.1 }, result.color.sample)
        assert.are.equal(0.4, result.color.amount)
    end)

    it("stores the sample position in the unrotated frame of a rotated photo and reports the one asked for", function()
        local Handler, stores = setup({ photos = { { id = "1", orientation = "BC" } } })

        local result = Handler.createRangeMask(colorRequest())

        local range = stores["1"].writes[1][1].CorrectionMasks[1].CorrectionRangeMask
        assert.are.equal("0.462745 0.400000 0.100000 0.800000 0.800000 0", range.PointModels[1])
        assert.are.same({ x = 0.2, y = 0.8, l = 0.462745, a = 0.4, b = 0.1 }, result.color.sample)
    end)

    it("refuses a photo whose orientation it cannot map, writing nothing", function()
        local Handler, stores = setup({ photos = { { id = "1", orientation = "ZZ" } } })

        local message = errorOf(function() Handler.createRangeMask(colorRequest()) end)

        assert.is_truthy(message:find("cannot map", 1, true))
        assert.are.equal(0, stores["1"].attempts)
    end)

    it("never writes a second PointModels entry even when asked for one", function()
        local Handler, stores = setup()
        local sample = { x = 0.2, y = 0.8, l = 0.4, a = 0.4, b = 0.1 }

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

    it("refuses an existing range mask of a type it does not know, writing nothing", function()
        local entries = {
            correction("Unknown", {
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

    it("keeps a depth range mask Lightroom authored verbatim next to the new mask", function()
        local entries = {
            correction("Mask 1", {
                {
                    What = "Mask/RangeMask",
                    MaskID = "C1T1",
                    MaskActive = true,
                    MaskInverted = false,
                    MaskBlendMode = 0,
                    CorrectionRangeMask = {
                        Type = -1, Version = 3, SampleType = 0, Invert = false,
                        DepthRange = "0.000000 0.000000 0.100000 0.350000",
                        LuminanceDepthSampleInfo = "0 0.526012 0.506934",
                    },
                },
            }, { CorrectionID = "C1" }),
        }
        local Handler, stores = setup({ photos = { { id = "1", entries = entries } } })

        local result = Handler.createRangeMask(luminanceRequest())

        local written = stores["1"].writes[1]
        assert.are.equal(2, #written)
        assert.are.equal(-1, written[1].CorrectionMasks[1].CorrectionRangeMask.Type)
        assert.are.equal("0.000000 0.000000 0.100000 0.350000", written[1].CorrectionMasks[1].CorrectionRangeMask.DepthRange)
        assert.are.equal("C2", result.mask_id)
    end)

    it("writes a depth range as a new mask and returns the stored range", function()
        local Handler, stores = setup({ photos = { { id = "1", transformWrite = lightroomFillsDepthInfo } } })

        local result = Handler.createRangeMask(depthRequest({ name = "Subject" }))

        local written = stores["1"].writes[1]
        assert.are.equal(1, #written)
        assert.are.equal("Subject", written[1].CorrectionName)
        local range = written[1].CorrectionMasks[1].CorrectionRangeMask
        assert.are.equal(-1, range.Type)
        assert.are.equal("0.000000 0.000000 0.100000 0.350000", range.DepthRange)
        assert.is_true(result.success)
        assert.are.equal("depth", result.type)
        assert.are.same({ min = 0, max = 0.1, lower_falloff = 0, upper_falloff = 0.25 }, result.depth)
        assert.is_nil(result.luminance)
        assert.is_nil(result.color)
    end)

    it("refuses a depth range on a photo without a depth map and restores the previous masks", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingGradient() } } })

        local message = errorOf(function() Handler.createRangeMask(depthRequest()) end)

        assert.is_truthy(message:find("no depth map on this photo", 1, true))
        assert.is_truthy(message:find("previous masks were restored", 1, true))
        assert.are.equal(2, #stores["1"].writes)
        assert.are.equal(1, #stores["1"].entries)
        assert.are.equal("C1", stores["1"].entries[1].CorrectionID)
    end)

    it("does not require a depth sample for a luminance range", function()
        local Handler = setup()

        local result = Handler.createRangeMask(luminanceRequest())

        assert.is_true(result.success)
    end)

    it("rejects a narrow full-strength band before reading, writing or opening Develop", function()
        local Handler, stores, calls = setup()

        local message = errorOf(function()
            Handler.createRangeMask(depthRequest({ depth = { min = 0.5, max = 0.505 } }))
        end)

        assert.is_truthy(message:find("depth.max must be at least 0.01 above depth.min", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, stores["1"].reads)
        assert.are.equal(0, #calls.modules)
    end)

    it("rejects an unknown type before reading, writing or opening Develop", function()
        local Handler, stores, calls = setup()

        local message = errorOf(function() Handler.createRangeMask(luminanceRequest({ type = "hue" })) end)

        assert.is_truthy(message:find('type must be "luminance", "color" or "depth"', 1, true))
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

    describe("copy_sample_from", function()
        local RED = "0.522527 0.888059 0.758296 0.050000 0.188000 0"

        local function lightroomColorRange(overrides)
            local range = {
                What = "Mask/RangeMask", MaskID = "C1T1", MaskActive = true, MaskInverted = false, MaskBlendMode = 0,
                CorrectionRangeMask = { Type = 1, Version = 3, SampleType = 0, ColorAmount = 0.494949, PointModels = { RED } },
            }
            for key, value in pairs(overrides or {}) do range[key] = value end
            return range
        end

        local function sourceEntries(components)
            return { correction("Reds", components or { lightroomColorRange() }, { CorrectionID = "C1" }) }
        end

        local function copyRequest(overrides)
            local args = { photo_id = "1", type = "color", copy_sample_from = { mask_id = "C1", tool_id = "C1T1" } }
            for key, value in pairs(overrides or {}) do args[key] = value end
            return args
        end

        local function written(stores, photoId)
            return stores[photoId or "1"].writes[#stores[photoId or "1"].writes]
        end

        it("copies the stored triple, pin and amount of a Lightroom-authored color range into a new mask", function()
            local Handler, stores = setup({ photos = { { id = "1", entries = sourceEntries() } } })

            local result = Handler.createRangeMask(copyRequest({ name = "Copy" }))

            local entries = written(stores)
            assert.are.equal(2, #entries)
            local range = entries[2].CorrectionMasks[1].CorrectionRangeMask
            assert.are.equal(1, #range.PointModels)
            assert.are.equal(RED, range.PointModels[1])
            assert.are.equal(0.494949, range.ColorAmount)
            assert.are.equal("Copy", entries[2].CorrectionName)
            assert.are.equal("C2", result.mask_id)
            assert.is_true(result.new_mask)
            assert.are.same({ x = 0.05, y = 0.188, l = 0.522527, a = 0.888059, b = 0.758296 }, result.color.sample)
            assert.are.same({ photo_id = "1", mask_id = "C1", tool_id = "C1T1" }, result.copied_from)
        end)

        it("keeps the source range as it was", function()
            local Handler, stores = setup({ photos = { { id = "1", entries = sourceEntries() } } })

            Handler.createRangeMask(copyRequest())

            assert.are.same(lightroomColorRange().CorrectionRangeMask, written(stores)[1].CorrectionMasks[1].CorrectionRangeMask)
        end)

        it("lets the caller tweak amount, invert and mode while copying into an existing mask", function()
            local entries = sourceEntries()
            entries[2] = correction("Sky", { linearComponent({ MaskID = "C2T1" }) }, { CorrectionID = "C2" })
            local Handler, stores = setup({ photos = { { id = "1", entries = entries } } })

            local result = Handler.createRangeMask(copyRequest({
                color = { amount = 0.2 }, invert = true, mask_id = "C2", mode = "subtract",
            }))

            local component = written(stores)[2].CorrectionMasks[2]
            assert.are.equal(RED, component.CorrectionRangeMask.PointModels[1])
            assert.are.equal(0.2, component.CorrectionRangeMask.ColorAmount)
            assert.are.equal(1, component.MaskBlendMode)
            assert.is_true(component.MaskInverted)
            assert.are.equal("C2T2", result.tool_id)
            assert.are.equal("subtract", result.mode)
            assert.are.equal(0.2, result.color.amount)
        end)

        it("copies from another photo and keeps the pin at the same displayed position", function()
            local Handler, stores = setup({ photos = {
                { id = "1", orientation = "BC" },
                { id = "2", entries = sourceEntries() },
            } })

            local result = Handler.createRangeMask(copyRequest({
                copy_sample_from = { photo_id = "2", mask_id = "C1", tool_id = "C1T1" },
            }))

            local range = written(stores, "1")[1].CorrectionMasks[1].CorrectionRangeMask
            assert.are.equal(1, #range.PointModels)
            assert.are.equal("0.522527 0.888059 0.758296 0.188000 0.950000 0", range.PointModels[1])
            assert.are.same({ x = 0.05, y = 0.188, l = 0.522527, a = 0.888059, b = 0.758296 }, result.color.sample)
            assert.are.equal("2", result.copied_from.photo_id)
            assert.are.equal(0, #stores["2"].writes)
        end)

        it("maps the source pin out of the frame of a rotated source photo", function()
            local Handler, stores = setup({ photos = {
                { id = "1" },
                { id = "2", orientation = "BC", entries = sourceEntries() },
            } })

            local result = Handler.createRangeMask(copyRequest({
                copy_sample_from = { photo_id = "2", mask_id = "C1", tool_id = "C1T1" },
            }))

            local range = written(stores, "1")[1].CorrectionMasks[1].CorrectionRangeMask
            assert.are.equal("0.522527 0.888059 0.758296 0.812000 0.050000 0", range.PointModels[1])
            assert.are.equal(0.812, result.color.sample.x)
            assert.are.equal(0.05, result.color.sample.y)
        end)

        it("refuses a source that is not a color range, writing nothing and not opening Develop", function()
            local luminance = lightroomColorRange({
                CorrectionRangeMask = { Type = 2, Version = 3, SampleType = 0, LumRange = "0.1 0.2 0.3 0.4" },
            })
            local twoPoints = lightroomColorRange({
                CorrectionRangeMask = { Type = 1, ColorAmount = 0.5, PointModels = { RED, RED } },
            })
            local cases = {
                { components = { luminance }, expected = "is a luminance range, not a color range" },
                { components = { linearComponent({ MaskID = "C1T1" }) }, expected = "is not a range mask" },
                { components = { twoPoints }, expected = "has 2 color sample points; exactly one can be copied" },
            }
            for _, case in ipairs(cases) do
                local Handler, stores, calls = setup({ photos = { { id = "1", entries = sourceEntries(case.components) } } })

                local message = errorOf(function() Handler.createRangeMask(copyRequest()) end)

                assert.is_truthy(message:find("copy_sample_from: tool C1T1 " .. case.expected, 1, true), message)
                assert.are.equal(0, #stores["1"].writes)
                assert.are.equal(0, #calls.modules)
            end
        end)

        it("refuses an unknown mask, a tool of another mask, an unknown photo, writing nothing", function()
            local entries = sourceEntries()
            entries[2] = correction("Sky", { linearComponent({ MaskID = "C2T1" }) }, { CorrectionID = "C2" })
            local Handler, stores, calls = setup({ photos = { { id = "1", entries = entries } } })

            local unknownMask = errorOf(function()
                Handler.createRangeMask(copyRequest({ copy_sample_from = { mask_id = "C9", tool_id = "C1T1" } }))
            end)
            local otherMask = errorOf(function()
                Handler.createRangeMask(copyRequest({ copy_sample_from = { mask_id = "C2", tool_id = "C1T1" } }))
            end)
            local unknownPhoto = errorOf(function()
                Handler.createRangeMask(copyRequest({ copy_sample_from = { photo_id = "9", mask_id = "C1", tool_id = "C1T1" } }))
            end)

            assert.is_truthy(unknownMask:find("copy_sample_from: mask C9 not found on photo 1", 1, true))
            assert.is_truthy(otherMask:find("copy_sample_from: tool C1T1 is not in mask C2 on photo 1", 1, true))
            assert.is_truthy(unknownPhoto:find("Photo not found: 9", 1, true))
            assert.are.equal(0, #stores["1"].writes)
            assert.are.equal(0, #calls.modules)
        end)

        it("rejects a sample next to copy_sample_from and a copy for other range types before reading", function()
            local Handler, stores = setup({ photos = { { id = "1", entries = sourceEntries() } } })

            local both = errorOf(function()
                Handler.createRangeMask(copyRequest({ color = { sample = { x = 0, y = 0, l = 0, a = 0, b = 0 } } }))
            end)
            local luminanceCopy = errorOf(function()
                Handler.createRangeMask(luminanceRequest({ copy_sample_from = { mask_id = "C1", tool_id = "C1T1" } }))
            end)

            assert.is_truthy(both:find("both give the sample", 1, true))
            assert.is_truthy(luminanceCopy:find("only applies to color range masks", 1, true))
            assert.are.equal(0, stores["1"].reads)
        end)

        it("never queries or reads settings outside the gates", function()
            local Handler, stores, _, catalog = setup({ photos = { { id = "1", entries = sourceEntries() }, { id = "2" } } })

            Handler.createRangeMask(copyRequest({ photo_id = "2", copy_sample_from = { photo_id = "1", mask_id = "C1", tool_id = "C1T1" } }))

            assert.is_false(catalog.getQueriedInsideReadAccess())
            assert.are.equal(0, stores["1"].readsOutsideGate)
            assert.are.equal(0, stores["2"].readsOutsideGate)
        end)
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
