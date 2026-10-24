local helper = require 'spec_helper'
local Store = require 'fake_mask_store'

local correction = Store.correction
local brushComponent = Store.brushComponent
local paint = Store.paint

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

    local controller = {
        getAllMasks = function()
            calls.getAllMasks = calls.getAllMasks + 1
            if opts.hideNewMasks then return {} end
            return Store.maskListOf(storeOf[active].entries)
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
        "HandlerBrushMasks", "BrushStrokes", "GuardedMaskWrite", "ImageFrame", "DevelopSession", "Log",
    }) do
        package.loaded[name] = nil
    end
    return require 'HandlerBrushMasks', stores, calls, catalog
end

local function stroke(overrides)
    local value = { points = { point(0.2, 0.3), point(0.3, 0.3) } }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
end

local function createRequest(overrides)
    local args = { photo_id = "1", strokes = { stroke() } }
    for key, value in pairs(overrides or {}) do args[key] = value end
    return args
end

local function existingBrush()
    return {
        correction("Face", {
            brushComponent({ MaskID = "C1T1" }, { paint(), paint({ Radius = 0.05 }) }),
            Store.linearComponent({ MaskID = "C1T2" }),
        }, { CorrectionID = "C1" }),
    }
end

describe("HandlerBrushMasks.createBrushMask", function()
    it("paints a new brush mask and returns its ids", function()
        local Handler, stores = setup()

        local result = Handler.createBrushMask(createRequest({
            name = "Face", strokes = { stroke({ radius = 0.05 }), stroke({ points = { point(0.7, 0.8) } }) },
        }))

        local written = stores["1"].writes[1]
        assert.are.equal(1, #written)
        assert.are.equal("Face", written[1].CorrectionName)
        local aggregate = written[1].CorrectionMasks[1]
        assert.are.equal("Mask/Aggregate", aggregate.What)
        assert.are.equal(2, #aggregate.Masks)
        assert.are.equal(0.05, aggregate.Masks[1].Radius)
        assert.are.same({ "d 0.700000 0.800000" }, aggregate.Masks[2].Dabs)
        assert.is_true(result.success)
        assert.are.equal("1", result.photo_id)
        assert.are.equal("C1", result.mask_id)
        assert.are.equal("C1T1", result.tool_id)
        assert.are.equal(2, result.strokes_added)
        assert.are.equal(2, result.stroke_count)
        assert.is_true(result.new_mask)
    end)

    it("maps displayed points into the stored frame of a rotated photo", function()
        local Handler, stores = setup({ photos = { { id = "1", orientation = "BC" } } })

        Handler.createBrushMask(createRequest({
            strokes = { stroke({ points = { point(0.25, 0.75) }, radius = 0.05 }) },
        }))

        local dabs = stores["1"].writes[1][1].CorrectionMasks[1].Masks[1].Dabs
        assert.are.same({ "d 0.750000 0.750000" }, dabs)
    end)

    it("maps a displayed path into the stored frame when it is appended to a brush", function()
        local Handler, stores = setup({ photos = { { id = "1", orientation = "CD", entries = existingBrush() } } })

        Handler.addBrushStrokes({
            photo_id = "1", tool_id = "C1T1", strokes = { stroke({ points = { point(0.25, 0.75) } }) },
        })

        local masks = stores["1"].writes[1][1].CorrectionMasks[1].Masks
        assert.are.same({ "d 0.750000 0.250000" }, masks[#masks].Dabs)
    end)

    it("refuses a photo whose orientation it cannot map, writing nothing", function()
        local Handler, stores = setup({ photos = { { id = "1", orientation = "ZZ" } } })

        local message = errorOf(function() Handler.createBrushMask(createRequest()) end)

        assert.matches("cannot map", message, 1, true)
        assert.are.equal(0, stores["1"].attempts)
    end)

    it("writes a low-flow stroke with the flow token and verifies it when Lightroom reads it back", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                transformWrite = function(stored)
                    local lightroomPaint = stored[1].CorrectionMasks[1].Masks[1]
                    lightroomPaint.Flow = 0.299998
                    return stored
                end,
            } },
        })

        local result = Handler.createBrushMask(createRequest({ strokes = { stroke({ flow = 0.3 }) } }))

        local written = stores["1"].writes[1][1].CorrectionMasks[1].Masks[1]
        assert.are.equal(0.3, written.Flow)
        assert.are.equal("f 0.3000", written.Dabs[1])
        assert.is_true(result.success)
        assert.are.equal(1, #stores["1"].writes)
    end)

    it("adds a brush component to an existing mask and keeps the other entries verbatim", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingBrush() } } })

        local result = Handler.createBrushMask(createRequest({ mask_id = "C1" }))

        local written = stores["1"].writes[1]
        assert.are.equal(1, #written)
        assert.are.equal(3, #written[1].CorrectionMasks)
        assert.are.equal("C1T1", written[1].CorrectionMasks[1].MaskID)
        assert.are.equal(2, #written[1].CorrectionMasks[1].Masks)
        assert.are.equal("Mask/Aggregate", written[1].CorrectionMasks[3].What)
        assert.are.equal("C1", result.mask_id)
        assert.are.equal("C1T3", result.tool_id)
        assert.is_false(result.new_mask)
    end)

    it("never queries or reads settings outside the gates", function()
        local Handler, stores, _, catalog = setup()

        Handler.createBrushMask(createRequest())

        assert.is_false(catalog.getQueriedInsideReadAccess())
        assert.is_false(catalog.getQueriedInsideWriteAccess())
        assert.are.equal(0, stores["1"].readsOutsideGate)
        assert.are.equal(0, stores["1"].writesOutsideGate)
    end)

    it("opens Develop for the cross-check and puts the module back", function()
        local Handler, _, calls = setup()

        Handler.createBrushMask(createRequest())

        assert.are.same({ "develop", "library" }, calls.modules)
        assert.is_true(calls.getAllMasks >= 1)
    end)

    it("accepts a numeric photo id", function()
        local Handler = setup({ photos = { { id = "7" } } })

        assert.are.equal("7", Handler.createBrushMask(createRequest({ photo_id = 7 })).photo_id)
    end)

    it("rejects an empty stroke list before reading, writing or opening Develop", function()
        local Handler, stores, calls = setup()

        local message = errorOf(function() Handler.createBrushMask(createRequest({ strokes = {} })) end)

        assert.is_truthy(message:find("at least one stroke", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, stores["1"].reads)
        assert.are.equal(0, #calls.modules)
    end)

    it("rejects points outside the image before reading, writing or opening Develop", function()
        local Handler, stores, calls = setup()

        local message = errorOf(function()
            Handler.createBrushMask(createRequest({ strokes = { stroke({ points = { point(0.5, -0.1) } }) } }))
        end)

        assert.is_truthy(message:find("strokes[1].points[1].y is outside the image", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, stores["1"].reads)
        assert.are.equal(0, #calls.modules)
    end)

    it("rejects size with the reason and an erase stroke with a density, writing nothing", function()
        local Handler, stores = setup()

        local size = errorOf(function()
            Handler.createBrushMask(createRequest({ strokes = { stroke({ size = 30 }) } }))
        end)
        local density = errorOf(function()
            Handler.createBrushMask(createRequest({ strokes = { stroke({ erase = true, density = 0.5 }) } }))
        end)

        assert.is_truthy(size:find("size is not supported", 1, true))
        assert.is_truthy(density:find("density does not apply to an erase stroke", 1, true))
        assert.are.equal(0, #stores["1"].writes)
    end)

    it("writes feather, density and erase strokes and verifies them when Lightroom reads them back", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                transformWrite = function(stored)
                    for _, lightroomPaint in ipairs(stored[1].CorrectionMasks[1].Masks) do
                        lightroomPaint.CenterWeight = lightroomPaint.CenterWeight + 0.0000004
                        lightroomPaint.Radius = lightroomPaint.Radius - 0.0000004
                    end
                    return stored
                end,
            } },
        })

        local result = Handler.createBrushMask(createRequest({
            strokes = {
                stroke({ radius = 0.411904, feather = 50, density = 0.3, points = { point(0.5, 0.5) } }),
                stroke({ erase = true, feather = 0, points = { point(0.5, 0.5) } }),
            },
        }))

        local masks = stores["1"].writes[1][1].CorrectionMasks[1].Masks
        assert.are.equal(0.3, masks[1].MaskValue)
        assert.is_true(math.abs(masks[1].CenterWeight - 0.16214) < 1e-5)
        assert.are.equal("h 0.1621", masks[1].Dabs[1])
        assert.are.equal(0, masks[2].MaskValue)
        assert.are.equal(1, masks[2].CenterWeight)
        assert.is_true(result.success)
        assert.are.equal(1, #stores["1"].writes)
    end)

    it("rolls back when Lightroom keeps a different density", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[1].CorrectionMasks[1].Masks[1].MaskValue = 1 end
                    return stored
                end,
            } },
        })

        local message = errorOf(function()
            Handler.createBrushMask(createRequest({ strokes = { stroke({ density = 0.3 }) } }))
        end)

        assert.is_truthy(message:find("MaskValue: wrote 0.3, read back 1", 1, true))
        assert.are.equal(0, #stores["1"].entries)
    end)

    it("rolls back when Lightroom turns an erase stroke into an add stroke", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[1].CorrectionMasks[1].Masks[1].MaskValue = 1 end
                    return stored
                end,
            } },
        })

        local message = errorOf(function()
            Handler.createBrushMask(createRequest({ strokes = { stroke({ erase = true }) } }))
        end)

        assert.is_truthy(message:find("MaskValue: wrote 0, read back 1", 1, true))
        assert.are.equal(0, #stores["1"].entries)
    end)

    it("rejects a name together with mask_id", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingBrush() } } })

        local message = errorOf(function() Handler.createBrushMask(createRequest({ mask_id = "C1", name = "X" })) end)

        assert.is_truthy(message:find("name applies to a new mask", 1, true))
        assert.are.equal(0, #stores["1"].writes)
    end)

    it("requires a photo id and a known photo", function()
        local Handler, _, calls = setup()

        assert.is_truthy(errorOf(function() Handler.createBrushMask(createRequest({ photo_id = "" })) end)
            :find("photo_id is required", 1, true))
        assert.is_truthy(errorOf(function() Handler.createBrushMask(createRequest({ photo_id = "404" })) end)
            :find("Photo not found: 404", 1, true))
        assert.are.equal(0, #calls.modules)
    end)

    it("fails for an unknown mask id without writing or opening Develop", function()
        local Handler, stores, calls = setup({ photos = { { id = "1", entries = existingBrush() } } })

        local message = errorOf(function() Handler.createBrushMask(createRequest({ mask_id = "C9" })) end)

        assert.is_truthy(message:find("Mask not found on this photo: C9", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("refuses an untested Lightroom version, leaving the photo and the view alone", function()
        local Handler, stores, calls = setup({ version = { major = 15, minor = 7 } })

        local message = errorOf(function() Handler.createBrushMask(createRequest()) end)

        assert.is_truthy(message:find("15.7", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("refuses a photo whose existing brush uses an unknown field", function()
        local entries = existingBrush()
        entries[1].CorrectionMasks[1].Masks[1].Spacing = 0.1
        local Handler, stores, calls = setup({ photos = { { id = "1", entries = entries } } })

        local message = errorOf(function() Handler.createBrushMask(createRequest()) end)

        assert.is_truthy(message:find("unexpected field Spacing", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("names the minimum Lightroom version when the mask API is missing", function()
        local Handler, stores, calls = setup({ withoutMaskApi = true })

        local message = errorOf(function() Handler.createBrushMask(createRequest()) end)

        assert.is_truthy(message:find("create_brush_mask needs Lightroom Classic 11 or later", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("restores the previous masks when Lightroom reads different dabs back", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                entries = existingBrush(),
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[2].CorrectionMasks[1].Masks[1].Dabs[1] = "d 0.900000 0.900000" end
                    return stored
                end,
            } },
        })

        local message = errorOf(function() Handler.createBrushMask(createRequest()) end)

        assert.is_truthy(message:find("previous masks were restored", 1, true))
        assert.is_truthy(message:find("dab 1 changed", 1, true))
        assert.are.equal(2, #stores["1"].writes)
        assert.are.equal(1, #stores["1"].entries)
    end)

    it("restores the previous masks when Lightroom drops a stroke", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[1].CorrectionMasks[1].Masks = {} end
                    return stored
                end,
            } },
        })

        local message = errorOf(function()
            Handler.createBrushMask(createRequest({ strokes = { stroke(), stroke() } }))
        end)

        assert.is_truthy(message:find("count changed from 2 to 0", 1, true))
        assert.are.equal(0, #stores["1"].entries)
    end)

    it("restores the previous masks when Lightroom ignores the flow", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then stored[1].CorrectionMasks[1].Masks[1].Flow = 1 end
                    return stored
                end,
            } },
        })

        local message = errorOf(function()
            Handler.createBrushMask(createRequest({ strokes = { stroke({ flow = 0.3 }) } }))
        end)

        assert.is_truthy(message:find("Flow: wrote 0.3, read back 1", 1, true))
        assert.are.equal(0, #stores["1"].entries)
    end)

    it("restores the previous masks when Lightroom's mask list does not show a brush tool", function()
        local Handler, stores, calls = setup({ hideNewMasks = true })

        local message = errorOf(function() Handler.createBrushMask(createRequest()) end)

        assert.is_truthy(message:find("Lightroom's mask list has no brush tool C1T1 in mask C1", 1, true))
        assert.are.equal(2, #stores["1"].writes)
        assert.are.equal(0, #stores["1"].entries)
        assert.are.equal("library", calls.modules[#calls.modules])
    end)
end)

describe("HandlerBrushMasks.addBrushStrokes", function()
    local function addRequest(overrides)
        local args = { photo_id = "1", tool_id = "C1T1", strokes = { stroke({ points = { point(0.6, 0.6) } }) } }
        for key, value in pairs(overrides or {}) do args[key] = value end
        return args
    end

    it("appends strokes to the brush and keeps its ids and earlier strokes", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingBrush() } } })

        local result = Handler.addBrushStrokes(addRequest({ strokes = { stroke(), stroke({ flow = 0.5 }) } }))

        local written = stores["1"].writes[1][1].CorrectionMasks
        assert.are.equal("C1T1", written[1].MaskID)
        assert.are.equal(4, #written[1].Masks)
        assert.are.equal(0.05, written[1].Masks[2].Radius)
        assert.are.equal("f 0.5000", written[1].Masks[4].Dabs[1])
        assert.are.equal("C1T2", written[2].MaskID)
        assert.are.equal("C1", result.mask_id)
        assert.are.equal("C1T1", result.tool_id)
        assert.are.equal(2, result.strokes_added)
        assert.are.equal(4, result.stroke_count)
        assert.is_nil(result.new_mask)
    end)

    it("requires a tool id", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingBrush() } } })

        local message = errorOf(function() Handler.addBrushStrokes(addRequest({ tool_id = "" })) end)

        assert.is_truthy(message:find("tool_id must be a non-empty string", 1, true))
        assert.are.equal(0, #stores["1"].writes)
    end)

    it("rejects an empty stroke list and outside points before reading or writing", function()
        local Handler, stores, calls = setup({ photos = { { id = "1", entries = existingBrush() } } })

        local empty = errorOf(function() Handler.addBrushStrokes(addRequest({ strokes = {} })) end)
        local outside = errorOf(function()
            Handler.addBrushStrokes(addRequest({ strokes = { stroke({ points = { point(1.5, 0.5) } }) } }))
        end)

        assert.is_truthy(empty:find("at least one stroke", 1, true))
        assert.is_truthy(outside:find("is outside the image", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, stores["1"].reads)
        assert.are.equal(0, #calls.modules)
    end)

    it("fails for an unknown tool id or a tool that is not a brush, writing nothing", function()
        local Handler, stores, calls = setup({ photos = { { id = "1", entries = existingBrush() } } })

        local unknown = errorOf(function() Handler.addBrushStrokes(addRequest({ tool_id = "NOPE" })) end)
        local gradient = errorOf(function() Handler.addBrushStrokes(addRequest({ tool_id = "C1T2" })) end)

        assert.is_truthy(unknown:find("Brush tool not found on this photo: NOPE", 1, true))
        assert.is_truthy(gradient:find("Mask/Gradient mask, not a brush", 1, true))
        assert.are.equal(0, #stores["1"].writes)
        assert.are.equal(0, #calls.modules)
    end)

    it("appends an erase stroke with feather after the strokes it erases", function()
        local Handler, stores = setup({ photos = { { id = "1", entries = existingBrush() } } })

        Handler.addBrushStrokes(addRequest({ strokes = { stroke({ erase = true, feather = 0, radius = 0.1 }) } }))

        local masks = stores["1"].writes[1][1].CorrectionMasks[1].Masks
        assert.are.equal(3, #masks)
        assert.are.equal(1, masks[2].MaskValue)
        assert.are.equal(0, masks[3].MaskValue)
        assert.are.equal(1, masks[3].CenterWeight)
    end)

    it("rolls back when Lightroom reads fewer strokes back", function()
        local Handler, stores = setup({
            photos = { {
                id = "1",
                entries = existingBrush(),
                transformWrite = function(stored, writeNumber)
                    if writeNumber == 1 then table.remove(stored[1].CorrectionMasks[1].Masks) end
                    return stored
                end,
            } },
        })

        local message = errorOf(function() Handler.addBrushStrokes(addRequest()) end)

        assert.is_truthy(message:find("previous masks were restored", 1, true))
        assert.are.equal(2, #stores["1"].entries[1].CorrectionMasks[1].Masks)
    end)

    it("refuses on an untested process version", function()
        local Handler, stores = setup({
            photos = { { id = "1", entries = existingBrush(), processVersion = "11.0" } },
        })

        local message = errorOf(function() Handler.addBrushStrokes(addRequest()) end)

        assert.is_truthy(message:find("process version (11.0)", 1, true))
        assert.are.equal(0, #stores["1"].writes)
    end)
end)
