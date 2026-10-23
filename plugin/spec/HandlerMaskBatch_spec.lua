local helper = require 'spec_helper'
local Store = require 'fake_mask_store'

local COMPUTED_KEYS = { "MaskDigest", "InputDigest", "LocalInputDigest" }

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

local function gradientCorrection(id)
    return Store.correction("Sky", {
        Store.linearComponent({ MaskID = id .. "T1" }),
    }, { CorrectionID = id })
end

local function aiComponentOf(entry)
    for _, component in ipairs(entry.CorrectionMasks) do
        if component.What == "Mask/Image" then return component end
    end
    return nil
end

local function newAIEntry(photoId)
    return {
        What = "Correction",
        CorrectionName = "Mask",
        CorrectionActive = true,
        CorrectionAmount = 1,
        CorrectionID = "mask-" .. photoId,
        CorrectionSyncID = "sync-" .. photoId,
        LocalExposure2012 = 0,
        CorrectionMasks = {
            {
                What = "Mask/Image",
                MaskActive = true,
                MaskInverted = false,
                MaskBlendMode = 0,
                MaskID = "tool-" .. photoId,
                MaskSyncID = "tool-sync-" .. photoId,
                MaskDigest = "mask-digest-" .. photoId,
                InputDigest = "input-digest-" .. photoId,
                LocalInputDigest = "local-input-digest-" .. photoId,
                Origin = "origin-" .. photoId,
            },
        },
    }
end

local function setup(opts)
    opts = opts or {}
    local specs = opts.photos or { { id = "1" }, { id = "2" }, { id = "3" } }
    local photos, stores, storeOf, specOf = {}, {}, {}, {}
    local clock = { now = 0 }
    local calls = {
        modules = {},
        created = {},
        updates = {},
        updateSawDigests = {},
        setValue = {},
        deleted = {},
        writeDescriptions = {},
    }

    for _, spec in ipairs(specs) do
        local photo = helper.fakePhoto({
            id = spec.id,
            path = "/" .. spec.id .. ".jpg",
        })
        local store = Store.attach(photo, spec)
        stores[spec.id] = store
        storeOf[photo] = store
        specOf[photo] = spec
        photos[#photos + 1] = photo
        if opts.withoutUpdateApi then
            photo.updateAISettings = nil
        else
            photo.updateAISettings = function()
                local mode = spec.aiMode or "ok"
                local computing
                for _, entry in ipairs(store.entries) do
                    local component = aiComponentOf(entry)
                    if component then computing = computing or { entry = entry, component = component } end
                end
                calls.updates[#calls.updates + 1] = spec.id
                calls.updateSawDigests[spec.id] = computing ~= nil and computing.component.MaskDigest ~= nil
                clock.now = clock.now + (opts.secondsPerUpdate or 0)
                if mode == "fail" then error("AI update failed") end
                if mode == "ok" and computing and computing.component.MaskDigest == nil then
                    for _, key in ipairs(COMPUTED_KEYS) do
                        computing.component[key] = key .. "-" .. spec.id
                    end
                    computing.component.Origin = "origin-" .. spec.id
                end
            end
        end
    end

    local active = photos[opts.startIndex or #photos]
    local startPhoto = active
    local module = "library"

    local catalog = helper.fakeCatalog({ photos = photos })
    for _, spec in ipairs(specs) do
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

    local function addDevelopMask(photo, subtype)
        local spec = specOf[photo]
        local behavior = spec.createBehavior or "append"
        calls.created[#calls.created + 1] = { photo = spec.id, subtype = subtype }
        if behavior == "nothing" then return end
        local store = storeOf[photo]
        store.entries[#store.entries + 1] = newAIEntry(spec.id)
        if behavior == "double" then
            local second = newAIEntry(spec.id .. "b")
            store.entries[#store.entries + 1] = second
        end
    end

    local values = {}
    local controller = {
        getAllMasks = function()
            if module ~= "develop" then error("Develop module is not active") end
            return Store.maskListOf(storeOf[active].entries)
        end,
        selectMask = function() end,
        selectMaskTool = function() end,
        selectTool = function() end,
        getSelectedTool = function() return "loupe" end,
        createNewMask = function(_, subtype)
            if module ~= "develop" then error("Develop module is not active") end
            addDevelopMask(active, subtype)
        end,
        deleteMask = function(id)
            calls.deleted[#calls.deleted + 1] = id
            local store = storeOf[active]
            for index = #store.entries, 1, -1 do
                if store.entries[index].CorrectionID == id then table.remove(store.entries, index) end
            end
        end,
        setValue = function(param, value)
            calls.setValue[#calls.setValue + 1] = { photo = specOf[active].id, param = param, value = value }
            local entries = storeOf[active].entries
            local last = entries[#entries]
            if last then last["Local" .. param] = value end
            values[param] = value
        end,
        getValue = function(param) return values[param] or 0 end,
        stopTracking = function() end,
        setTrackingDelay = function() end,
        setMultipleAdjustmentThreshold = function() end,
    }
    if opts.withoutCreateApi then controller.createNewMask = nil end

    if opts.unsavedTemplate then
        for _, photo in ipairs(photos) do
            local original = photo.getDevelopSettings
            photo.getDevelopSettings = function(self)
                local settings = original(self)
                local kept = {}
                for _, entry in ipairs(settings.MaskGroupBasedCorrections or {}) do
                    if tostring(entry.CorrectionID):sub(1, 5) ~= "mask-" then kept[#kept + 1] = entry end
                end
                settings.MaskGroupBasedCorrections = #kept > 0 and kept or nil
                return settings
            end
        end
    end

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
        LrDate = { currentTime = function() return clock.now end },
        LrDevelopController = controller,
        LrSelection = { selectNone = function() active = nil end },
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    for _, name in ipairs({
        "HandlerMaskBatch", "HandlerMaskCreate", "GuardedMaskWrite", "DevelopSession", "AIMaskData", "Log",
    }) do
        package.loaded[name] = nil
    end
    local Handler = require 'HandlerMaskBatch'
    return Handler, {
        calls = calls,
        stores = stores,
        catalog = catalog,
        activeIs = function(photo) return active == photo end,
        startPhoto = startPhoto,
        module = function() return module end,
        clock = clock,
    }
end

local function resultFor(response, photoId)
    for _, result in ipairs(response.results) do
        if result.photo_id == photoId then return result end
    end
    return nil
end

local function entriesOf(world, photoId)
    return world.stores[photoId].entries
end

describe("HandlerMaskBatch.createMaskBatch", function()
    it("creates the mask in Develop on the first photo only and reports every photo created", function()
        local Handler, world = setup({})

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" })

        assert.is_true(r.success)
        assert.is_true(r.complete)
        assert.are.equal("sky", r.type)
        assert.are.equal(3, r.created)
        assert.are.equal(0, r.failed)
        assert.are.equal(0, r.not_attempted)
        assert.are.same({}, r.missing)
        assert.are.same({ { photo = "1", subtype = "sky" } }, world.calls.created)
        for _, id in ipairs({ "1", "2", "3" }) do
            local result = resultFor(r, id)
            assert.are.equal("created", result.status)
            assert.is_true(result.created)
            assert.is_not_nil(result.mask_id)
        end
        assert.are.equal("mask-1", resultFor(r, "1").mask_id)
    end)

    it("strips the computed digests before writing to a target and recomputes it afterwards", function()
        local Handler, world = setup({})

        Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "subject" })

        for _, id in ipairs({ "2", "3" }) do
            local written = world.stores[id].writes[1]
            local component = aiComponentOf(written[#written])
            for _, key in ipairs(COMPUTED_KEYS) do
                assert.is_nil(component[key], id .. " was written with " .. key)
            end
            assert.is_false(world.calls.updateSawDigests[id])
        end
    end)

    it("calls updateAISettings once per target and never on the source photo", function()
        local Handler, world = setup({ photos = { { id = "1" }, { id = "2" }, { id = "3" }, { id = "4" } } })

        Handler.createMaskBatch({ photo_ids = { "1", "2", "3", "4" }, type = "background" })

        assert.are.same({ "2", "3", "4" }, world.calls.updates)
    end)

    it("gives each target its own computed mask data, not the source's", function()
        local Handler, world = setup({})

        Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "subject" })

        assert.are.equal("origin-1", aiComponentOf(entriesOf(world, "1")[1]).Origin)
        for _, id in ipairs({ "2", "3" }) do
            local component = aiComponentOf(entriesOf(world, id)[1])
            assert.are.equal("origin-" .. id, component.Origin)
            assert.are.equal("MaskDigest-" .. id, component.MaskDigest)
            assert.are.equal("InputDigest-" .. id, component.InputDigest)
        end
    end)

    it("gives targets fresh ids instead of the source mask ids", function()
        local Handler, world = setup({})

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2" }, type = "sky" })

        local written = world.stores["2"].writes[1][1]
        assert.is_nil(written.CorrectionID)
        assert.is_nil(written.CorrectionMasks[1].MaskID)
        assert.are.equal("C1", entriesOf(world, "2")[1].CorrectionID)
        assert.are.equal("C1", resultFor(r, "2").mask_id)
    end)

    it("carries the same local adjustments to every photo", function()
        local Handler, world = setup({})

        local r = Handler.createMaskBatch({
            photo_ids = { "1", "2", "3" },
            type = "sky",
            adjustments = { exposure = -1.5, contrast = 20 },
        })

        assert.are.same({ exposure = -1.5, contrast = 20 }, r.adjustments)
        for _, id in ipairs({ "1", "2", "3" }) do
            assert.are.equal(-1.5, entriesOf(world, id)[1]["Locallocal_Exposure"])
            assert.are.equal(20, entriesOf(world, id)[1]["Locallocal_Contrast"])
            assert.are.equal(0, entriesOf(world, id)[1]["Locallocal_Shadows"])
        end
    end)

    it("keeps the masks already on a target", function()
        local Handler, world = setup({
            photos = { { id = "1" }, { id = "2", entries = { gradientCorrection("C1") } } },
        })

        Handler.createMaskBatch({ photo_ids = { "1", "2" }, type = "sky" })

        local entries = entriesOf(world, "2")
        assert.are.equal(2, #entries)
        assert.are.equal("C1", entries[1].CorrectionID)
        assert.are.equal("Mask/Gradient", entries[1].CorrectionMasks[1].What)
        assert.are.equal("Mask/Image", entries[2].CorrectionMasks[1].What)
        assert.are.equal("C2", entries[2].CorrectionID)
    end)

    it("restores the module and the user's selection", function()
        local Handler, world = setup({ startIndex = 3 })

        Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" })

        assert.are.same({ "develop", "library" }, world.calls.modules)
        assert.are.equal("library", world.module())
        assert.is_true(world.activeIs(world.startPhoto))
    end)

    it("reports a target where nothing is found as failed, removes its mask and finishes the batch", function()
        local Handler, world = setup({
            photos = { { id = "1" }, { id = "2", aiMode = "nothing" }, { id = "3" } },
        })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" })

        assert.is_false(r.success)
        assert.is_true(r.complete)
        assert.are.equal(2, r.created)
        assert.are.equal(1, r.failed)
        local failed = resultFor(r, "2")
        assert.are.equal("failed", failed.status)
        assert.is_false(failed.created)
        assert.is_nil(failed.mask_id)
        assert.truthy(failed.reason:find("found no sky to select", 1, true))
        assert.are.same({}, entriesOf(world, "2"))
        assert.are.equal("created", resultFor(r, "3").status)
        assert.are.equal(1, #entriesOf(world, "3"))
        assert.are.same({ "2", "3" }, world.calls.updates)
    end)

    it("reports a target whose recompute raises as failed and removes its mask", function()
        local Handler, world = setup({
            photos = { { id = "1" }, { id = "2", aiMode = "fail" }, { id = "3" } },
        })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "subject" })

        local failed = resultFor(r, "2")
        assert.are.equal("failed", failed.status)
        assert.truthy(failed.reason:find("AI update failed", 1, true))
        assert.are.same({}, entriesOf(world, "2"))
        assert.are.equal("created", resultFor(r, "3").status)
        assert.are.equal(2, r.created)
    end)

    it("restores the previous masks of a failed target exactly", function()
        local Handler, world = setup({
            photos = { { id = "1" }, { id = "2", aiMode = "nothing", entries = { gradientCorrection("C1") } } },
        })

        Handler.createMaskBatch({ photo_ids = { "1", "2" }, type = "sky" })

        local entries = entriesOf(world, "2")
        assert.are.equal(1, #entries)
        assert.are.equal("C1", entries[1].CorrectionID)
        assert.are.equal("Mask/Gradient", entries[1].CorrectionMasks[1].What)
    end)

    it("stops at a first photo with nothing to select and reports the rest as not attempted", function()
        local Handler, world = setup({
            photos = { { id = "1", createBehavior = "nothing" }, { id = "2" }, { id = "3" } },
        })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" })

        assert.is_false(r.success)
        assert.is_false(r.complete)
        assert.are.equal(0, r.created)
        assert.are.equal(1, r.failed)
        assert.are.equal(2, r.not_attempted)
        assert.are.equal("failed", resultFor(r, "1").status)
        assert.truthy(resultFor(r, "1").reason:find("found no sky", 1, true))
        assert.are.equal("not_attempted", resultFor(r, "2").status)
        assert.truthy(resultFor(r, "2").reason:find("click OK", 1, true))
        assert.are.same({ "2", "3" }, r.remaining_ids)
        assert.truthy(r.message:find("No sky detected", 1, true))
        assert.are.same({ { photo = "1", subtype = "sky" } }, world.calls.created)
        assert.are.same({}, world.calls.updates)
        assert.are.same({}, world.stores["2"].writes)
        assert.are.equal("library", world.module())
        assert.is_true(world.activeIs(world.startPhoto))
    end)

    it("tries the next photo when the first fails for a reason that leaves no alert", function()
        local Handler, world = setup({
            photos = { { id = "1", createBehavior = "double" }, { id = "2" }, { id = "3" } },
        })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" })

        assert.are.equal("failed", resultFor(r, "1").status)
        assert.truthy(resultFor(r, "1").reason:find("added 2 masks", 1, true))
        assert.are.equal("created", resultFor(r, "2").status)
        assert.are.equal("created", resultFor(r, "3").status)
        assert.are.same({ "3" }, world.calls.updates)
        assert.are.same({}, r.remaining_ids or {})
        assert.are.equal("library", world.module())
    end)

    it("reports ids that match no photo and skips duplicates", function()
        local Handler, world = setup({})

        local r = Handler.createMaskBatch({ photo_ids = { "1", "999", "2", "2", "1" }, type = "sky" })

        assert.are.same({ "999" }, r.missing)
        assert.are.equal(2, #r.results)
        assert.are.equal(2, r.created)
        assert.are.same({ "2" }, world.calls.updates)
    end)

    it("does not open Develop when no id matches a photo", function()
        local Handler, world = setup({})

        local r = Handler.createMaskBatch({ photo_ids = { "998", "999" }, type = "sky" })

        assert.are.same({}, r.results)
        assert.are.same({ "998", "999" }, r.missing)
        assert.are.same({}, world.calls.modules)
        assert.are.same({}, world.calls.created)
    end)

    it("stops starting targets after the time budget and lists the rest", function()
        local Handler, world = setup({
            photos = { { id = "1" }, { id = "2" }, { id = "3" }, { id = "4" }, { id = "5" } },
            secondsPerUpdate = 100,
        })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3", "4", "5" }, type = "sky" })

        assert.is_false(r.success)
        assert.is_false(r.complete)
        assert.are.equal(4, r.created)
        assert.are.equal(1, r.not_attempted)
        assert.are.same({ "5" }, r.remaining_ids)
        assert.truthy(resultFor(r, "5").reason:find("call again", 1, true))
        assert.are.same({ "2", "3", "4" }, world.calls.updates)
    end)

    it("fails every target when Lightroom did not save the new mask", function()
        local Handler, world = setup({ unsavedTemplate = true })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" })

        assert.are.equal("created", resultFor(r, "1").status)
        assert.are.equal("failed", resultFor(r, "2").status)
        assert.truthy(resultFor(r, "2").reason:find("did not save", 1, true))
        assert.are.equal("failed", resultFor(r, "3").status)
        assert.are.same({}, world.calls.updates)
        assert.are.same({}, world.stores["2"].writes)
    end)

    it("fails photos on an untested Lightroom version without touching Develop", function()
        local Handler, world = setup({ version = { major = 15, minor = 5 } })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2" }, type = "sky" })

        assert.are.equal(0, r.created)
        assert.are.equal(2, r.failed)
        assert.truthy(resultFor(r, "1").reason:find("not a version this tool has been tested on", 1, true))
        assert.are.same({}, world.calls.modules)
        assert.are.same({}, world.calls.created)
    end)

    it("fails a photo whose existing masks do not match the tested format and continues", function()
        local odd = Store.correction("Odd", { { What = "Mask/Mystery", MaskActive = true } }, { CorrectionID = "C1" })
        local Handler, world = setup({
            photos = { { id = "1" }, { id = "2", entries = { odd } }, { id = "3" } },
        })

        local r = Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" })

        assert.are.equal("failed", resultFor(r, "2").status)
        assert.truthy(resultFor(r, "2").reason:find("do not match the format", 1, true))
        assert.are.same({}, world.stores["2"].writes)
        assert.are.equal("created", resultFor(r, "1").status)
        assert.are.equal("created", resultFor(r, "3").status)
        assert.are.same({ "3" }, world.calls.updates)
    end)

    it("rejects a call while another batch is running", function()
        local Handler, world = setup({})
        local nestedError
        local photo = world.catalog:getAllPhotos()[2]
        local original = photo.updateAISettings
        photo.updateAISettings = function(self)
            nestedError = errorOf(function()
                Handler.createMaskBatch({ photo_ids = { "1" }, type = "sky" })
            end)
            return original(self)
        end

        Handler.createMaskBatch({ photo_ids = { "1", "2" }, type = "sky" })

        assert.truthy(nestedError:find("already running", 1, true))
        assert.are.equal("library", world.module())
    end)

    it("allows a new call after a failed one", function()
        local Handler = setup({})

        assert.truthy(errorOf(function() Handler.createMaskBatch({ photo_ids = {}, type = "sky" }) end))
        local r = Handler.createMaskBatch({ photo_ids = { "1" }, type = "sky" })

        assert.are.equal(1, r.created)
    end)

    it("never reads or writes mask data outside the catalog gates", function()
        local Handler, world = setup({})

        Handler.createMaskBatch({ photo_ids = { "1", "2", "3" }, type = "sky" })

        for _, id in ipairs({ "1", "2", "3" }) do
            assert.are.equal(0, world.stores[id].readsOutsideGate)
            assert.are.equal(0, world.stores[id].writesOutsideGate)
        end
        assert.is_false(world.catalog.getQueriedInsideReadAccess())
        assert.is_false(world.catalog.getQueriedInsideWriteAccess())
    end)

    describe("argument validation", function()
        local function assertRejectedUntouched(args, expected)
            local Handler, world = setup({})
            local message = errorOf(function() Handler.createMaskBatch(args) end)
            assert.truthy(message:find(expected, 1, true), message)
            assert.are.same({}, world.calls.modules)
            assert.are.same({}, world.calls.created)
            assert.are.equal(0, world.stores["1"].reads)
        end

        it("requires a non-empty photo_ids array", function()
            assertRejectedUntouched({ type = "sky" }, "photo_ids is required")
            assertRejectedUntouched({ photo_ids = {}, type = "sky" }, "photo_ids is required")
            assertRejectedUntouched({ photo_ids = "1", type = "sky" }, "photo_ids is required")
        end)

        it("caps photo_ids at 200", function()
            local ids = {}
            for index = 1, 201 do ids[index] = tostring(index) end
            assertRejectedUntouched({ photo_ids = ids, type = "sky" }, "at most 200")
        end)

        it("rejects ids that are neither ids nor paths", function()
            assertRejectedUntouched({ photo_ids = { "1", {} }, type = "sky" }, "photo ids or file paths")
            assertRejectedUntouched({ photo_ids = { "" }, type = "sky" }, "photo ids or file paths")
        end)

        it("rejects an unknown mask type", function()
            assertRejectedUntouched({ photo_ids = { "1" }, type = "people" }, "type must be one of")
            assertRejectedUntouched({ photo_ids = { "1" } }, "type must be one of")
        end)

        it("shares create_mask validation of adjustments", function()
            assertRejectedUntouched(
                { photo_ids = { "1" }, type = "sky", adjustments = { exposure = 4.5 } },
                "exposure must be between -4 and 4")
            assertRejectedUntouched(
                { photo_ids = { "1" }, type = "sky", adjustments = { contrast = 101 } },
                "contrast must be between -100 and 100")
            assertRejectedUntouched(
                { photo_ids = { "1" }, type = "sky", adjustments = { vibrance = 1 } },
                "Unknown adjustment vibrance")
        end)

        it("needs the Lightroom mask API", function()
            local Handler, world = setup({ withoutCreateApi = true })
            local message = errorOf(function() Handler.createMaskBatch({ photo_ids = { "1" }, type = "sky" }) end)
            assert.truthy(message:find("create_mask_batch needs Lightroom Classic 11", 1, true), message)
            assert.are.same({}, world.calls.modules)
        end)

        it("needs updateAISettings and changes nothing without it", function()
            local Handler, world = setup({ withoutUpdateApi = true })
            local message = errorOf(function() Handler.createMaskBatch({ photo_ids = { "1", "2" }, type = "sky" }) end)
            assert.truthy(message:find("needs Lightroom Classic 13.3", 1, true), message)
            assert.are.same({}, world.calls.modules)
            assert.are.same({}, world.calls.created)
        end)
    end)
end)
