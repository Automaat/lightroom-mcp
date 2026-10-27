local helper = require 'spec_helper'
local Store = require 'fake_mask_store'
local RadialEllipse = require 'radial_ellipse'

local linearComponent = Store.linearComponent
local radialComponent = Store.radialComponent
local correction = Store.correction

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

local function point(x, y) return { x = x, y = y } end

local function setup(opts)
    opts = opts or {}
    local photos, stores, storeOf = {}, {}, {}
    for _, spec in ipairs(opts.photos or { { id = "1" } }) do
        local photo = helper.fakePhoto({
            id = spec.id, path = "/" .. spec.id .. ".jpg", orientation = spec.orientation or "AB",
            dimensions = not spec.noDimensions and (spec.dimensions or { width = 3000, height = 2000 }) or nil,
        })
        stores[spec.id] = Store.attach(photo, spec)
        storeOf[photo] = stores[spec.id]
        photos[#photos + 1] = photo
    end
    local active = photos[1]
    local module = opts.startModule or "library"
    local calls = { modules = {}, getAllMasks = 0, stopTracking = {} }
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
            return Store.maskListOf(storeOf[active].entries)
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
        stopTracking = function(commit) calls.stopTracking[#calls.stopTracking + 1] = commit end,
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
        "HandlerGradientMasks", "GuardedMaskWrite", "GradientGeometry", "DevelopSession", "Log",
        "MaskCreationAdjustments", "MaskSelection", "LocalSliders",
    }) do
        package.loaded[name] = nil
    end
    return require 'HandlerGradientMasks', stores, calls, catalog
end

local function linearRequest(overrides)
    local args = { photo_id = "1", shape = "linear", start = point(0.5, 0.2), ["end"] = point(0.5, 0.6) }
    for key, value in pairs(overrides or {}) do args[key] = value end
    return args
end

local function radialRequest(overrides)
    local args = {
        photo_id = "1", shape = "radial", center = point(0.5, 0.5), width = 0.4, height = 0.6,
    }
    for key, value in pairs(overrides or {}) do args[key] = value end
    return args
end

local function existingGradients()
    return {
        correction("Sky", {
            linearComponent({ MaskID = "C1T1" }),
            radialComponent({ MaskID = "C1T2", Flipped = true, Angle = 0 }),
        }, { CorrectionID = "C1" }),
    }
end

describe("HandlerGradientMasks.createGradientMask", function()
    it("writes requested adjustments with the geometry in one Develop session", function()
        local Handler, stores, calls = setup()
        local result = Handler.createGradientMask(radialRequest({ adjustments = { exposure = 1, contrast = -25 } }))
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
                Handler.createGradientMask(radialRequest({ adjustments = adjustments }))
            end))
            assert.are.equal(0, #stores["1"].writes)
        end
        local Handler, stores = setup()
        assert.matches("mask_id", errorOf(function()
            Handler.createGradientMask(radialRequest({ mask_id = "existing", adjustments = { exposure = 1 } }))
        end))
        assert.are.equal(0, #stores["1"].writes)
    end)

    it("restores all previous masks when the SDK adjustment read-back differs", function()
        local previous = { correction("Existing", { Store.linearComponent({ MaskID = "C1T1" }) },
            { CorrectionID = "C1" }) }
        local Handler, stores = setup({ wrongAdjustment = true, photos = { { id = "1", entries = previous } } })
        assert.matches("restored", errorOf(function()
            Handler.createGradientMask(radialRequest({ adjustments = { exposure = 1 } }))
        end))
        assert.are.same(previous, stores["1"].entries)
        assert.are.equal(2, #stores["1"].writes)
    end)

    it("rejects a narrower live slider range before writing", function()
        local Handler, stores = setup({ narrowRange = true })
        assert.matches("slider range", errorOf(function()
            Handler.createGradientMask(radialRequest({ adjustments = { exposure = 1 } }))
        end))
        assert.are.same({}, stores["1"].entries)
        assert.are.equal(0, #stores["1"].writes)
    end)

    it("commits an edit pending on the photo open in Develop before it writes the mask", function()
        local Handler, _, calls = setup({ startModule = "develop" })

        Handler.createGradientMask(linearRequest())

        assert.are.same({ true }, calls.stopTracking)
    end)

    it("leaves Lightroom's edit tracking alone when it has to open the photo itself", function()
        local Handler, _, calls = setup()

        Handler.createGradientMask(linearRequest())

        assert.are.same({}, calls.stopTracking)
    end)

    it("places a linear gradient as a new mask and returns its ids", function()
        local Handler, stores = setup()

        local result = Handler.createGradientMask(linearRequest({ name = "Sky" }))

        local written = stores["1"].writes[1]
        assert.are.equal(1, #written)
        assert.are.equal("Sky", written[1].CorrectionName)
        local component = written[1].CorrectionMasks[1]
        assert.are.equal("Mask/Gradient", component.What)
        assert.are.equal(0.2, component.FullY)
        assert.are.equal(0.6, component.ZeroY)
        assert.is_true(result.success)
        assert.are.equal("1", result.photo_id)
        assert.are.equal("C1", result.mask_id)
        assert.are.equal("C1T1", result.tool_id)
        assert.are.equal("linear", result.shape)
        assert.are.equal("add", result.mode)
        assert.is_true(result.new_mask)
        assert.are.same({ start = point(0.5, 0.2), ["end"] = point(0.5, 0.6) }, result.geometry)
    end)

    it("places a radial gradient outside the ellipse with rotation and feather", function()
        local Handler, stores = setup()

        local result = Handler.createGradientMask(radialRequest({ rotation = 30, feather = 10, area = "outside" }))

        local component = stores["1"].writes[1][1].CorrectionMasks[1]
        assert.are.equal("Mask/CircularGradient", component.What)
        assert.is_true(component.MaskInverted)
        assert.are.equal(30, component.Angle)
        assert.are.equal(10, component.Feather)
        assert.are.equal("radialGradient", Store.maskListOf(stores["1"].entries)[1].Tools[1].Type)
        assert.are.equal("outside", result.geometry.area)
        assert.are.equal(0.4, result.geometry.width)
    end)

    it("adds a component to an existing mask and keeps the other entries verbatim", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingGradients() } } })

        local result = Handler.createGradientMask(linearRequest({
            mask_id = "C1", mode = "subtract", start = point(0.1, 0.1), ["end"] = point(0.9, 0.9),
        }))

        local written = stores["1"].writes[1]
        assert.are.equal(1, #written)
        assert.are.equal(3, #written[1].CorrectionMasks)
        assert.are.equal("C1T1", written[1].CorrectionMasks[1].MaskID)
        assert.are.equal(1, written[1].CorrectionMasks[3].MaskBlendMode)
        assert.are.equal("C1", result.mask_id)
        assert.are.equal("C1T3", result.tool_id)
        assert.are.equal("subtract", result.mode)
        assert.is_false(result.new_mask)
    end)

    it("adds a second mask next to existing ones", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingGradients() } } })

        local result = Handler.createGradientMask(linearRequest())

        assert.are.equal(2, #stores["1"].writes[1])
        assert.are.equal("C2", result.mask_id)
    end)

    it("never queries or reads settings outside the gates", function()
        local Handler, stores, _, catalog = setup()

        Handler.createGradientMask(linearRequest())

        assert.is_false(catalog.getQueriedInsideReadAccess())
        assert.is_false(catalog.getQueriedInsideWriteAccess())
        assert.are.equal(0, stores["1"].readsOutsideGate)
        assert.are.equal(0, stores["1"].writesOutsideGate)
    end)

    it("opens Develop for the cross-check and puts the module back", function()
        local Handler, _, calls = setup()

        Handler.createGradientMask(linearRequest())

        assert.are.same({ "develop", "library" }, calls.modules)
        assert.is_true(calls.getAllMasks >= 1)
    end)

    it("accepts a numeric photo id and a file path", function()
        local Handler = setup({ photos = { { id = "7" } } })

        assert.are.equal("7", Handler.createGradientMask(linearRequest({ photo_id = 7 })).photo_id)
        assert.are.equal("/7.jpg", Handler.createGradientMask(linearRequest({ photo_id = "/7.jpg" })).photo_id)
    end)

    it("rejects coordinates outside the image before reading, writing or opening Develop", function()
        local Handler, stores, calls = setup()

        local message = errorOf(function()
            Handler.createGradientMask(linearRequest({ ["end"] = point(0.5, 1.2) }))
        end)

        assert.is_truthy(message:find("end.y is outside the image", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, stores["1"].reads)
        assert.are.equal(0, #calls.modules)
    end)

    it("requires a photo id and a known photo", function()
        local Handler, _, calls = setup()

        assert.is_truthy(errorOf(function() Handler.createGradientMask(linearRequest({ photo_id = "" })) end)
            :find("photo_id is required", 1, true))
        assert.is_truthy(errorOf(function() Handler.createGradientMask(linearRequest({ photo_id = "404" })) end)
            :find("Photo not found: 404", 1, true))
        assert.are.equal(0, #calls.modules)
    end)

    it("fails for an unknown mask id without writing or opening Develop", function()
        local Handler, stores, calls = setup({ photos = { { id = "1", entries = existingGradients() } } })

        local message = errorOf(function() Handler.createGradientMask(linearRequest({ mask_id = "C9" })) end)

        assert.is_truthy(message:find("Mask not found on this photo: C9", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("refuses an untested Lightroom version, leaving the photo and the view alone", function()
        local Handler, stores, calls = setup({ version = { major = 15, minor = 7 } })

        local message = errorOf(function() Handler.createGradientMask(linearRequest()) end)

        assert.is_truthy(message:find("15.7", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("refuses a photo whose existing masks use an unknown field", function()
        local entries = existingGradients()
        entries[1].CorrectionMasks[1].FullYY = 1
        local Handler, stores, calls = setup({ photos = { { id = "1", entries = entries } } })

        local message = errorOf(function() Handler.createGradientMask(linearRequest()) end)

        assert.is_truthy(message:find("unexpected field FullYY", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("names the minimum Lightroom version when the mask API is missing", function()
        local Handler, stores, calls = setup({ withoutMaskApi = true })

        local message = errorOf(function() Handler.createGradientMask(linearRequest()) end)

        assert.is_truthy(message:find("create_gradient_mask needs Lightroom Classic 11 or later", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("restores the previous masks when Lightroom reads different geometry back", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                entries = existingGradients(),
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[2].CorrectionMasks[1].FullY = 0.99 end
                    return stored
                end,
            } },
        })

        local message = errorOf(function() Handler.createGradientMask(linearRequest()) end)

        assert.is_truthy(message:find("previous masks were restored", 1, true))
        assert.are.equal(2, #stores["1"].writes)
        assert.are.equal(1, #stores["1"].entries)
        assert.are.equal("C1", stores["1"].entries[1].CorrectionID)
    end)

    it("restores the previous masks when Lightroom drops the component", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[1].CorrectionMasks = {} end
                    return stored
                end,
            } },
        })

        local message = errorOf(function() Handler.createGradientMask(linearRequest()) end)

        assert.is_truthy(message:find("count changed from 1 to 0", 1, true))
        assert.are.equal(0, #stores["1"].entries)
    end)

    it("restores the previous masks when Lightroom's mask list does not show the new tool", function()
        local Handler, stores, calls = setup({ hideNewMasks = true })

        local message = errorOf(function() Handler.createGradientMask(linearRequest()) end)

        assert.is_truthy(message:find("Lightroom's mask list has no gradient tool C1T1 in mask C1", 1, true))
        assert.are.equal(2, #stores["1"].writes)
        assert.are.equal(0, #stores["1"].entries)
        assert.are.equal("library", calls.modules[#calls.modules])
    end)
end)

describe("HandlerGradientMasks.updateGradientMask", function()
    it("moves a linear gradient and keeps its ids", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingGradients() } } })

        local result = Handler.updateGradientMask({
            photo_id = "1", tool_id = "C1T1", ["end"] = point(0.9, 0.9),
        })

        local component = stores["1"].writes[1][1].CorrectionMasks[1]
        assert.are.equal("C1T1", component.MaskID)
        assert.are.equal(0.9, component.ZeroX)
        assert.are.equal(0.9, component.ZeroY)
        assert.are.equal(0.5, component.FullX)
        assert.are.equal(0.2, component.FullY)
        assert.is_nil(stores["1"].writes[1][1].CorrectionReferenceX)
        assert.are.equal("C1", result.mask_id)
        assert.are.equal("C1T1", result.tool_id)
        assert.are.same(point(0.9, 0.9), result.geometry["end"])
        assert.are.same(point(0.5, 0.2), result.geometry.start)
    end)

    it("reshapes a radial gradient and leaves the other components alone", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingGradients() } } })

        local result = Handler.updateGradientMask({
            photo_id = "1", tool_id = "C1T2", center = point(0.4, 0.5), width = 0.2, feather = 80, area = "outside",
        })

        local written = stores["1"].writes[1][1].CorrectionMasks
        assert.are.equal(0.5, written[1].ZeroX)
        local radial = written[2]
        assert.are.equal(80, radial.Feather)
        assert.are.equal(0, radial.Angle)
        assert.is_true(radial.MaskInverted)
        assert.are.equal(50, radial.Midpoint)
        assert.are.equal("radial", result.shape)
        assert.are.equal("outside", result.geometry.area)
        assert.are.equal(0.2, result.geometry.width)
        assert.is_true(math.abs(result.geometry.height - 0.6) < 1e-9)
        assert.is_true(math.abs(result.geometry.center.x - 0.4) < 1e-9)
    end)

    it("does not write the derived Flipped flag", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingGradients() } } })

        Handler.updateGradientMask({ photo_id = "1", tool_id = "C1T2", feather = 5 })

        assert.is_nil(stores["1"].writes[1][1].CorrectionMasks[2].Flipped)
    end)

    it("changes only one field when only one is given", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingGradients() } } })

        local result = Handler.updateGradientMask({ photo_id = "1", tool_id = "C1T2", rotation = 45 })

        assert.are.equal(45, result.geometry.rotation)
        assert.are.equal(50, result.geometry.feather)
        assert.is_true(math.abs(result.geometry.width - 0.4) < 1e-5)
        assert.is_true(math.abs(result.geometry.height - 0.6) < 1e-5)
        assert.are.equal(45, stores["1"].writes[1][1].CorrectionMasks[2].Angle)
    end)

    it("stores a rotated radial in the pixel space of the photo and reports the requested size", function()
        local Handler, stores = setup({ photos = { { id = "1", dimensions = { width = 3000, height = 2000 } } } })

        local result = Handler.createGradientMask(radialRequest({
            center = point(0.5, 0.4), width = 0.2, height = 0.2, rotation = 45,
        }))

        local component = stores["1"].writes[1][1].CorrectionMasks[1]
        local reach = math.sqrt(0.5)
        assert.is_true(math.abs(component.Left - (0.5 - 0.05 * reach / 1.5)) < 1e-9)
        assert.is_true(math.abs(component.Right - (0.5 + 0.05 * reach / 1.5)) < 1e-9)
        assert.is_true(math.abs(component.Top - (0.4 - 0.25 * reach)) < 1e-9)
        assert.is_true(math.abs(component.Bottom - (0.4 + 0.25 * reach)) < 1e-9)
        assert.are.equal(45, component.Angle)
        assert.is_true(math.abs(result.geometry.width - 0.2) < 1e-5)
        assert.is_true(math.abs(result.geometry.height - 0.2) < 1e-5)
    end)

    it("refuses a rotated radial when Lightroom reports no photo size, before anything is written", function()
        local Handler, stores = setup({ photos = { { id = "1", noDimensions = true } } })

        local message = errorOf(function()
            Handler.createGradientMask(radialRequest({ rotation = 30 }))
        end)

        assert.is_truthy(message:find("size", 1, true))
        assert.are.equal(0, #stores["1"].writes)
    end)

    it("places an unrotated radial without needing the photo size", function()
        local Handler, stores = setup({ photos = { { id = "1", noDimensions = true } } })

        local result = Handler.createGradientMask(radialRequest())

        assert.is_true(result.success)
        assert.are.equal(1, #stores["1"].writes)
    end)

    it("rejects out-of-image coordinates and degenerate gradients without writing", function()
        local Handler, stores, calls = setup({ photos = { { id = "1", entries = existingGradients() } } })

        local outside = errorOf(function()
            Handler.updateGradientMask({ photo_id = "1", tool_id = "C1T1", start = point(-1, 0) })
        end)
        local degenerate = errorOf(function()
            Handler.updateGradientMask({ photo_id = "1", tool_id = "C1T1", ["end"] = point(0.5, 0.2) })
        end)

        assert.is_truthy(outside:find("start.x is outside the image", 1, true))
        assert.is_truthy(degenerate:find("same point", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("fails for an unknown tool id or a tool that is not a gradient", function()
        local entries = existingGradients()
        entries[1].CorrectionMasks[#entries[1].CorrectionMasks + 1] = {
            What = "Mask/Aggregate",
            MaskID = "C1T3",
            Masks = { { What = "Mask/Paint", Dabs = { "d 0.1 0.1" }, Radius = 0.1, Flow = 1, CenterWeight = 0 } },
        }
        local Handler, stores, calls = setup({ photos = { { id = "1", entries = entries } } })

        local unknown = errorOf(function()
            Handler.updateGradientMask({ photo_id = "1", tool_id = "NOPE", feather = 5 })
        end)
        local brush = errorOf(function()
            Handler.updateGradientMask({ photo_id = "1", tool_id = "C1T3", start = point(0, 0) })
        end)

        assert.is_truthy(unknown:find("Gradient tool not found on this photo: NOPE", 1, true))
        assert.is_truthy(brush:find("Mask/Aggregate mask, not a linear or radial gradient", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("rejects a field of the other shape", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingGradients() } } })

        local message = errorOf(function()
            Handler.updateGradientMask({ photo_id = "1", tool_id = "C1T1", feather = 5 })
        end)

        assert.is_truthy(message:find("feather only applies to radial gradients", 1, true))
        assert.are.equal(0, #stores["1"].writes)
    end)

    it("rolls back when Lightroom reads different geometry back", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                entries = existingGradients(),
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[1].CorrectionMasks[1].ZeroY = 0.1 end
                    return stored
                end,
            } },
        })

        local message = errorOf(function()
            Handler.updateGradientMask({ photo_id = "1", tool_id = "C1T1", ["end"] = point(0.9, 0.9) })
        end)

        assert.is_truthy(message:find("previous masks were restored", 1, true))
        assert.are.equal(0.6, stores["1"].entries[1].CorrectionMasks[1].ZeroY)
    end)

    it("refuses on an untested process version", function()
        local Handler, stores = setup({
            photos = { { id = "1", entries = existingGradients(), processVersion = "11.0" } },
        })

        local message = errorOf(function()
            Handler.updateGradientMask({ photo_id = "1", tool_id = "C1T1", ["end"] = point(0.9, 0.9) })
        end)

        assert.is_truthy(message:find("process version (11.0)", 1, true))
        assert.are.equal(0, #stores["1"].writes)
    end)
end)

local LINEAR_BY_ORIENTATION = {
    AB = { start = point(0.2, 0.1), finish = point(0.2, 0.6) },
    BA = { start = point(0.8, 0.1), finish = point(0.8, 0.6) },
    CD = { start = point(0.8, 0.9), finish = point(0.8, 0.4) },
    DC = { start = point(0.2, 0.9), finish = point(0.2, 0.4) },
    CB = { start = point(0.1, 0.2), finish = point(0.6, 0.2) },
    BC = { start = point(0.1, 0.8), finish = point(0.6, 0.8) },
    AD = { start = point(0.9, 0.8), finish = point(0.4, 0.8) },
    DA = { start = point(0.9, 0.2), finish = point(0.4, 0.2) },
}

local RADIAL_BY_ORIENTATION = {
    AB = { width = 0.3, height = 0.5, angle = 30 },
    BA = { width = 0.3, height = 0.5, angle = -30 },
    CD = { width = 0.3, height = 0.5, angle = 30 },
    DC = { width = 0.3, height = 0.5, angle = -30 },
    CB = { width = 0.5, height = 0.3, angle = -30 },
    BC = { width = 0.5, height = 0.3, angle = 30 },
    AD = { width = 0.5, height = 0.3, angle = -30 },
    DA = { width = 0.5, height = 0.3, angle = 30 },
}

local ORIENTATIONS = { "AB", "BA", "CD", "DC", "CB", "BC", "AD", "DA" }

local function near(expected, actual)
    return math.abs(expected - actual) < 1e-9
end

local function displayedVertical(overrides)
    return linearRequest(overrides or {
        start = point(0.2, 0.1), ["end"] = point(0.2, 0.6),
    })
end

describe("HandlerGradientMasks in the stored frame of a rotated photo", function()
    for _, orientation in ipairs(ORIENTATIONS) do
        local expected = LINEAR_BY_ORIENTATION[orientation]

        it("stores a displayed vertical linear gradient for " .. orientation, function()
            local Handler, stores = setup({ photos = { { id = "1", orientation = orientation } } })

            local result = Handler.createGradientMask(displayedVertical())

            local component = stores["1"].writes[1][1].CorrectionMasks[1]
            assert.is_true(near(expected.start.x, component.FullX))
            assert.is_true(near(expected.start.y, component.FullY))
            assert.is_true(near(expected.finish.x, component.ZeroX))
            assert.is_true(near(expected.finish.y, component.ZeroY))
            assert.are.same(point(0.2, 0.1), result.geometry.start)
            assert.are.same(point(0.2, 0.6), result.geometry["end"])
        end)

        it("moves one end of a linear gradient in the displayed frame for " .. orientation, function()
            local Handler, stores = setup({ photos = { { id = "1", orientation = orientation } } })
            local created = Handler.createGradientMask(displayedVertical())

            local result = Handler.updateGradientMask({
                photo_id = "1", tool_id = created.tool_id, ["end"] = point(0.2, 0.8),
            })

            assert.are.same(point(0.2, 0.1), result.geometry.start)
            assert.are.same(point(0.2, 0.8), result.geometry["end"])
            local component = stores["1"].writes[2][1].CorrectionMasks[1]
            assert.is_true(near(expected.start.x, component.FullX))
            assert.is_true(near(expected.start.y, component.FullY))
        end)

        local radial = RADIAL_BY_ORIENTATION[orientation]

        it("stores a displayed radial gradient with swapped sizes and mirrored rotation for " .. orientation,
            function()
                local Handler, stores = setup({ photos = { { id = "1", orientation = orientation } } })

                local result = Handler.createGradientMask(radialRequest({
                    center = point(0.2, 0.1), width = 0.3, height = 0.5, rotation = 30,
                }))

                local component = stores["1"].writes[1][1].CorrectionMasks[1]
                local storedCenter = LINEAR_BY_ORIENTATION[orientation].start
                assert.are.equal(radial.angle, component.Angle)
                assert.is_true(near(storedCenter.x, (component.Left + component.Right) / 2))
                assert.is_true(near(storedCenter.y, (component.Top + component.Bottom) / 2))
                assert.is_true(near(0.2, result.geometry.center.x))
                assert.is_true(near(0.1, result.geometry.center.y))
                assert.is_true(math.abs(0.3 - result.geometry.width) < 1e-5)
                assert.is_true(math.abs(0.5 - result.geometry.height) < 1e-5)
                assert.are.equal(30, result.geometry.rotation)
            end)

        it("sizes an unrotated radial gradient along the stored axes for " .. orientation, function()
            local Handler, stores = setup({ photos = { { id = "1", orientation = orientation } } })

            Handler.createGradientMask(radialRequest({
                center = point(0.2, 0.1), width = 0.3, height = 0.5,
            }))

            local component = stores["1"].writes[1][1].CorrectionMasks[1]
            assert.is_true(near(radial.width, component.Right - component.Left))
            assert.is_true(near(radial.height, component.Bottom - component.Top))
            assert.are.equal(0, component.Angle)
        end)

        it("reshapes a radial gradient in the displayed frame for " .. orientation, function()
            local Handler, stores = setup({ photos = { { id = "1", orientation = orientation } } })
            local created = Handler.createGradientMask(radialRequest({
                center = point(0.2, 0.1), width = 0.3, height = 0.5, rotation = 30,
            }))

            local result = Handler.updateGradientMask({
                photo_id = "1", tool_id = created.tool_id, rotation = 45, feather = 20,
            })

            assert.are.equal(45, result.geometry.rotation)
            assert.are.equal(20, result.geometry.feather)
            assert.is_true(near(0.2, result.geometry.center.x))
            assert.is_true(near(0.1, result.geometry.center.y))
            assert.is_true(math.abs(0.3 - result.geometry.width) < 1e-5)
            assert.is_true(math.abs(0.5 - result.geometry.height) < 1e-5)
            local component = stores["1"].writes[2][1].CorrectionMasks[1]
            assert.are.equal(radial.angle > 0 and 45 or -45, component.Angle)
        end)
    end

    local function rotationSweep()
        local rotations = {}
        for rotation = -180, 180, 15 do rotations[#rotations + 1] = rotation end
        for _, rotation in ipairs({ -360, -61, -59, -46, 46, 59, 61, 91, 270, 360 }) do
            rotations[#rotations + 1] = rotation
        end
        return rotations
    end

    local DISPLAYED_ASPECT = 3000 / 2000

    local function requestedEllipse(rotation)
        return RadialEllipse.ofGeometry({
            center = point(0.2, 0.1), width = 0.3, height = 0.5, rotation = rotation,
        }, DISPLAYED_ASPECT)
    end

    local function expectedStoredEllipse(orientation, rotation)
        local radial = RADIAL_BY_ORIENTATION[orientation]
        local storedAspect = radial.width == 0.5 and 1 / DISPLAYED_ASPECT or DISPLAYED_ASPECT
        local center = LINEAR_BY_ORIENTATION[orientation].start
        return RadialEllipse.ofGeometry({
            center = center, width = radial.width, height = radial.height,
            rotation = (radial.angle > 0 and 1 or -1) * rotation,
        }, storedAspect)
    end

    local function storedEllipseOf(orientation, component)
        local radial = RADIAL_BY_ORIENTATION[orientation]
        local storedAspect = radial.width == 0.5 and 1 / DISPLAYED_ASPECT or DISPLAYED_ASPECT
        return RadialEllipse.ofComponent(component, storedAspect)
    end

    for _, orientation in ipairs(ORIENTATIONS) do
        it("creates the displayed radial ellipse at every rotation for " .. orientation, function()
            for _, rotation in ipairs(rotationSweep()) do
                local Handler, stores = setup({ photos = { { id = "1", orientation = orientation } } })

                local result = Handler.createGradientMask(radialRequest({
                    center = point(0.2, 0.1), width = 0.3, height = 0.5, rotation = rotation,
                }))

                local component = stores["1"].writes[1][1].CorrectionMasks[1]
                assert.is_true(math.abs(component.Angle) <= 45, "angle " .. component.Angle .. " for " .. rotation)
                assert.is_true(RadialEllipse.differenceBetween(
                    expectedStoredEllipse(orientation, rotation), storedEllipseOf(orientation, component)) < 1e-9,
                    "stored ellipse differs for rotation " .. rotation)
                assert.is_true(RadialEllipse.differenceBetween(
                    requestedEllipse(rotation), RadialEllipse.ofGeometry(result.geometry, DISPLAYED_ASPECT)) < 1e-4,
                    "reported ellipse differs for rotation " .. rotation)
            end
        end)

        it("turns an existing radial to every rotation for " .. orientation, function()
            for _, rotation in ipairs(rotationSweep()) do
                local Handler, stores = setup({ photos = { { id = "1", orientation = orientation } } })
                local created = Handler.createGradientMask(radialRequest({
                    center = point(0.2, 0.1), width = 0.3, height = 0.5,
                }))

                local result = Handler.updateGradientMask({
                    photo_id = "1", tool_id = created.tool_id, rotation = rotation,
                })

                local component = stores["1"].writes[2][1].CorrectionMasks[1]
                assert.is_true(math.abs(component.Angle) <= 45, "angle " .. component.Angle .. " for " .. rotation)
                assert.is_true(RadialEllipse.differenceBetween(
                    expectedStoredEllipse(orientation, rotation), storedEllipseOf(orientation, component)) < 1e-9,
                    "stored ellipse differs for rotation " .. rotation)
                assert.is_true(RadialEllipse.differenceBetween(
                    requestedEllipse(rotation), RadialEllipse.ofGeometry(result.geometry, DISPLAYED_ASPECT)) < 1e-4,
                    "reported ellipse differs for rotation " .. rotation)
            end
        end)
    end

    it("reads an existing gradient from the stored frame back to the displayed one", function()
        local entries = {
            correction("Sky", {
                linearComponent({ MaskID = "C1T1", FullX = 0.1, FullY = 0.2, ZeroX = 0.6, ZeroY = 0.2 }),
            }, { CorrectionID = "C1" }),
        }
        local Handler = setup({ photos = { { id = "1", orientation = "CB", entries = entries } } })

        local result = Handler.updateGradientMask({
            photo_id = "1", tool_id = "C1T1", ["end"] = point(0.2, 0.9),
        })

        assert.are.same(point(0.2, 0.1), result.geometry.start)
        assert.are.same(point(0.2, 0.9), result.geometry["end"])
    end)

    it("leaves the stored values equal to the displayed ones when the photo is not rotated", function()
        local Handler, stores = setup()

        Handler.createGradientMask(radialRequest({
            center = point(0.2, 0.1), width = 0.3, height = 0.5, rotation = 30,
        }))
        Handler.createGradientMask(displayedVertical())

        local radial = stores["1"].writes[1][1].CorrectionMasks[1]
        local linear = stores["1"].writes[2][2].CorrectionMasks[1]
        assert.are.equal(30, radial.Angle)
        assert.are.equal(0.2, linear.FullX)
        assert.are.equal(0.1, linear.FullY)
        assert.are.equal(0.2, linear.ZeroX)
        assert.are.equal(0.6, linear.ZeroY)
    end)

    it("refuses a photo whose orientation it cannot map, writing nothing", function()
        local Handler, stores, calls = setup({ photos = { { id = "1", orientation = "ZZ" } } })

        local message = errorOf(function() Handler.createGradientMask(displayedVertical()) end)

        assert.is_truthy(message:find("cannot map", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)
end)
