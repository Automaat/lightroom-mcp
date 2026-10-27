local helper = require 'spec_helper'
local Store = require 'fake_mask_store'

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

local DIGEST = "ABCDEF0123456789ABCDEF0123456789"

local function computeEveryEntry(opts)
    return function(state)
        for _, entry in ipairs(state.entries) do
            local component = entry.CorrectionMasks[1]
            if component.What == "Mask/Image" and component.MaskDigest == nil then
                local category = component.MaskSubCategoryID
                if opts.absentCategories and opts.absentCategories[category] then
                    component.ErrorReason = 1
                elseif not opts.neverCompute then
                    component.MaskDigest = DIGEST
                    component.InputDigest = DIGEST
                    component.LocalInputDigest = DIGEST
                end
            end
        end
    end
end

local function existingGradient()
    return Store.correction("Sky gradient", { Store.linearComponent({ MaskID = "C1T1" }) }, { CorrectionID = "C1" })
end

local function setup(opts)
    opts = opts or {}
    local photo = helper.fakePhoto({ id = "1", path = "/1.jpg" })
    local store = Store.attach(photo, { entries = opts.entries, processVersion = opts.processVersion })
    local calls = { updateAI = 0, modules = {}, catalogs = 0 }
    if not opts.withoutUpdateAi then
        photo.updateAISettings = function()
            calls.updateAI = calls.updateAI + 1
            if opts.updateFails then error("AI update failed") end
            computeEveryEntry(opts)(store)
            if opts.dropLastEntry then store.entries[#store.entries] = nil end
        end
    end
    local catalog = helper.fakeCatalog({ photos = { photo } })
    Store.trackGates(store, catalog)

    helper.installImport({
        LrApplication = {
            activeCatalog = function() calls.catalogs = calls.catalogs + 1; return catalog end,
            versionTable = function() return opts.version or { major = 15, minor = 6 } end,
        },
        LrApplicationView = {
            getCurrentModuleName = function() return "library" end,
            switchToModule = function(name) calls.modules[#calls.modules + 1] = name end,
        },
        LrDevelopController = {},
        LrSelection = {},
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    for _, name in ipairs({
        "HandlerMaskCreate", "HandlerAiMasks", "AiMaskParts", "GuardedMaskWrite", "DevelopSession", "Log",
    }) do
        package.loaded[name] = nil
    end
    return require 'HandlerMaskCreate', store, calls
end

describe("HandlerMaskCreate.createMask people", function()
    it("writes one all-people mask per part and returns the ids", function()
        local Handler, store, calls = setup()

        local result = Handler.createMask({ type = "people", photo_id = "1", parts = { "hair", "face_skin" } })

        local written = store.writes[1]
        assert.are.equal(2, #written)
        local hair = written[1].CorrectionMasks[1]
        assert.are.equal("Mask/Image", hair.What)
        assert.are.equal(3, hair.MaskSubType)
        assert.are.equal(5, hair.MaskSubCategoryID)
        assert.is_nil(hair.InstanceIDs)
        assert.is_nil(hair.MaskDigest)
        assert.are.equal(2, written[2].CorrectionMasks[1].MaskSubCategoryID)
        assert.are.equal(1, calls.updateAI)
        assert.is_true(result.success)
        assert.are.equal("people", result.type)
        assert.is_nil(result.person)
        assert.are.equal("C1", result.mask_id)
        assert.are.same({
            { mask_id = "C1", part = "hair" },
            { mask_id = "C2", part = "face_skin" },
        }, result.masks)
        assert.are.equal(0, #calls.modules)
    end)

    it("writes entire_person as an all-people part and keeps the masks already on the photo", function()
        local Handler, store = setup({ entries = { existingGradient() } })

        local result = Handler.createMask({ type = "people", photo_id = "1", parts = { "face_skin", "entire_person" } })

        local written = store.writes[1]
        assert.are.equal(3, #written)
        assert.are.equal("Sky gradient", written[1].CorrectionName)
        assert.are.equal(3, written[2].CorrectionMasks[1].MaskSubType)
        assert.are.equal(3, written[3].CorrectionMasks[1].MaskSubType)
        assert.are.equal(13, written[3].CorrectionMasks[1].MaskSubCategoryID)
        assert.are.equal(3, #store.entries)
        assert.are.equal("C2", result.masks[1].mask_id)
    end)

    it("removes the new masks and reports it when the photo has no such part", function()
        local Handler, store = setup({ entries = { existingGradient() }, absentCategories = { [5] = true } })

        local message = errorOf(function()
            Handler.createMask({ type = "people", photo_id = "1", parts = { "face_skin", "hair" } })
        end)

        assert.matches("found no hair on any person in photo 1", message, 1, true)
        assert.matches("no mask was left", message, 1, true)
        assert.are.equal(1, #store.entries)
        assert.are.equal("Sky gradient", store.entries[1].CorrectionName)
    end)

    it("rejects unknown and duplicate parts and a single person before any write", function()
        local Handler, store, calls = setup()

        for _, case in ipairs({
            { { photo_id = "1", parts = { "ears" } }, "Unknown part ears" },
            { { photo_id = "1", parts = { "hair", "hair" } }, "Duplicate part hair" },
            { { photo_id = "1", parts = {} }, "part must be a non-empty list" },
            { { photo_id = "1" }, "part must be a non-empty list" },
            { { photo_id = "1", parts = { "hair" }, person = 2 }, "person is not supported" },
            { { parts = { "hair" } }, "photo_id is required" },
        }) do
            assert.matches(case[2], errorOf(function() case[1].type = "people"; Handler.createMask(case[1]) end), 1, true)
        end
        assert.are.equal(0, store.attempts)
        assert.are.equal(0, store.reads)
        assert.are.equal(0, calls.updateAI)
    end)

    it("fails on a photo that is not found without writing", function()
        local Handler, store = setup()

        assert.matches("Photo not found: 99",
            errorOf(function() Handler.createMask({ type = "people", photo_id = "99", parts = { "hair" } }) end), 1, true)
        assert.are.equal(0, store.attempts)
    end)

    it("refuses on a Lightroom without the AI update call", function()
        local Handler, store = setup({ withoutUpdateAi = true })

        assert.matches("needs Lightroom Classic 13.3 or later",
            errorOf(function() Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } }) end), 1, true)
        assert.are.equal(0, store.attempts)
    end)

    it("refuses on an untested Lightroom version without writing", function()
        local Handler, store = setup({ version = { major = 14, minor = 5 } })

        assert.matches("not a version this tool has been tested on",
            errorOf(function() Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } }) end), 1, true)
        assert.are.equal(0, store.attempts)
    end)

    it("removes the new masks when the AI update call fails", function()
        local Handler, store = setup({ updateFails = true })

        local message = errorOf(function() Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } }) end)

        assert.matches("Lightroom could not compute the masks", message, 1, true)
        assert.are.equal(0, #store.entries)
    end)

    it("leaves the masks alone and says so when Lightroom never finishes computing", function()
        local Handler, store, calls = setup({ neverCompute = true })

        local message = errorOf(function() Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } }) end)

        assert.matches("has not finished computing", message, 1, true)
        assert.matches("can freeze Lightroom", message, 1, true)
        assert.are.equal(1, #store.writes)
        assert.are.equal(1, #store.entries)
        assert.are.equal(1, calls.updateAI)
    end)

    it("removes the new masks when Lightroom drops one of them", function()
        local Handler, store = setup({ dropLastEntry = true })

        local message = errorOf(function()
            Handler.createMask({ type = "people", photo_id = "1", parts = { "hair", "lips" } })
        end)

        assert.matches("Lightroom kept 1 of the 2 requested masks", message, 1, true)
        assert.are.equal(0, #store.entries)
    end)

    it("does the catalog reads and writes only inside their gates", function()
        local Handler, store = setup()

        Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } })

        assert.are.equal(0, store.readsOutsideGate)
        assert.are.equal(0, store.writesOutsideGate)
    end)

    it("rejects a second Develop-driving call while one runs", function()
        local Handler, _, _ = setup()
        local DevelopSession = require 'DevelopSession'
        local message
        DevelopSession.run("other_tool", nil, false, function()
            message = errorOf(function() Handler.createMask({ type = "people", photo_id = "1", parts = { "hair" } }) end)
        end)

        assert.matches("other_tool is already running", message, 1, true)
    end)
end)

describe("HandlerMaskCreate.createMask landscape", function()
    it("writes one landscape mask per category and returns the ids", function()
        local Handler, store, calls = setup()

        local result = Handler.createMask({ type = "landscape", photo_id = "1", categories = { "sky", "water", "vegetation" } })

        local written = store.writes[1]
        assert.are.equal(3, #written)
        local sky = written[1].CorrectionMasks[1]
        assert.are.equal("Mask/Image", sky.What)
        assert.are.equal(0, sky.MaskSubType)
        assert.are.equal(50006, sky.MaskSubCategoryID)
        assert.are.equal(50007, written[2].CorrectionMasks[1].MaskSubCategoryID)
        assert.are.equal(50005, written[3].CorrectionMasks[1].MaskSubCategoryID)
        assert.are.equal("Sky", written[1].CorrectionName)
        assert.are.equal(1, calls.updateAI)
        assert.are.equal("landscape", result.type)
        assert.are.equal("C1", result.mask_id)
        assert.are.same({
            { mask_id = "C1", category = "sky" },
            { mask_id = "C2", category = "water" },
            { mask_id = "C3", category = "vegetation" },
        }, result.masks)
    end)

    it("removes every new mask when one category is absent", function()
        local Handler, store = setup({ entries = { existingGradient() }, absentCategories = { [50007] = true } })

        local message = errorOf(function()
            Handler.createMask({ type = "landscape", photo_id = "1", categories = { "sky", "water" } })
        end)

        assert.matches("found no water in photo 1", message, 1, true)
        assert.are.equal(1, #store.entries)
        assert.are.equal("Sky gradient", store.entries[1].CorrectionName)
    end)

    it("rejects unknown and duplicate categories before any write", function()
        local Handler, store = setup()

        for _, case in ipairs({
            { { photo_id = "1", categories = { "lava" } }, "Unknown category lava" },
            { { photo_id = "1", categories = { "sky", "sky" } }, "Duplicate category sky" },
            { { photo_id = "1", categories = {} }, "category must be a non-empty list" },
            { { photo_id = "1" }, "category must be a non-empty list" },
        }) do
            assert.matches(case[2], errorOf(function() case[1].type = "landscape"; Handler.createMask(case[1]) end), 1, true)
        end
        assert.are.equal(0, store.attempts)
        assert.are.equal(0, store.reads)
    end)
end)

describe("HandlerMaskCreate.createMask AI selectors", function()
    it("rejects selectors for another type and unsupported adjustments before catalog access", function()
        local Handler, store, calls = setup()
        for _, case in ipairs({
            { { type = "sky", parts = { "hair" } }, "parts" },
            { { type = "subject", categories = { "sky" } }, "categories" },
            { { type = "background", parts = {} }, "parts" },
            { { type = "people", parts = { "hair" }, categories = { "sky" } }, "categories" },
            { { type = "landscape", categories = { "sky" }, parts = { "hair" } }, "parts" },
            { { type = "people", parts = { "hair" }, adjustments = {} }, "adjustments" },
            { { type = "landscape", categories = { "sky" }, adjustments = { exposure = 1 } }, "adjustments" },
        }) do
            case[1].photo_id = "1"
            assert.matches(case[2], errorOf(function() Handler.createMask(case[1]) end), 1, true)
        end
        assert.are.equal(0, calls.catalogs)
        assert.are.equal(0, calls.updateAI)
        assert.are.equal(0, store.reads)
        assert.are.equal(0, store.attempts)
    end)

    it("keeps both guarded types off untested process versions without writing", function()
        for _, typeName in ipairs({ "people", "landscape" }) do
            local Handler, store, calls = setup({ processVersion = "11.0" })
            local args = { photo_id = "1", type = typeName }
            if typeName == "people" then args.parts = { "hair" } else args.categories = { "sky" } end
            assert.matches("process version", errorOf(function() Handler.createMask(args) end), 1, true)
            assert.are.equal(0, store.attempts)
            assert.are.equal(0, calls.updateAI)
        end
    end)

    it("keeps both guarded types off untested Lightroom versions without writing", function()
        for _, typeName in ipairs({ "people", "landscape" }) do
            local Handler, store, calls = setup({ version = { major = 14, minor = 5 } })
            local args = { photo_id = "1", type = typeName }
            if typeName == "people" then args.parts = { "hair" } else args.categories = { "sky" } end
            assert.matches("not a version this tool has been tested on",
                errorOf(function() Handler.createMask(args) end), 1, true)
            assert.are.equal(0, store.attempts)
            assert.are.equal(0, calls.updateAI)
        end
    end)
end)
