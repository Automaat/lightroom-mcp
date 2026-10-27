local helper = require 'spec_helper'

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

local function existingMask(id)
    return {
        ID = id,
        Name = "Mask " .. id,
        Hidden = false,
        Tools = { { ID = "tool-" .. id, Name = "Gradient", Type = "gradient", Hidden = false, Inverted = false } },
    }
end

local function aiMask(id, subtype)
    return {
        ID = id,
        Name = "Mask " .. id,
        Hidden = false,
        Tools = { { ID = "tool-" .. id, Name = subtype, Type = "aiSelection", Subtype = subtype, Hidden = false, Inverted = false } },
    }
end

local function setup(opts)
    opts = opts or {}
    local existing = opts.existing or {}
    local settingsGroups = {}
    for index = 1, opts.settingsMaskCount or #existing do settingsGroups[index] = { CorrectionID = tostring(index) } end
    local photo = helper.fakePhoto({
        id = "10",
        path = "/10.jpg",
        developSettings = { MaskGroupBasedCorrections = settingsGroups },
    })
    local other = helper.fakePhoto({ id = "11", path = "/11.jpg" })
    local masks = {}
    for index, mask in ipairs(existing) do masks[index] = mask end

    local calls = {
        created = {},
        setValue = {},
        selectMask = {},
        deleteMask = {},
        tools = {},
        trackingDelay = {},
        threshold = {},
        stopTracking = 0,
        modules = {},
    }
    local polls = 0
    local values = {}
    local module = "library"
    local active = photo
    local tool = opts.startTool or "loupe"
    local behavior = opts.behavior or "append"
    local pollsBeforeAppear = opts.pollsBeforeAppear or 0
    local newMaskId = "new-mask"

    local function appendNew()
        masks[#masks + 1] = aiMask(newMaskId, calls.created[#calls.created].subtype)
    end

    local controller = {
        getAllMasks = function()
            polls = polls + 1
            if module ~= "develop" then error("Develop module is not active") end
            if opts.notReadyPolls and polls <= opts.notReadyPolls then return {} end
            if calls.created[1] then
                local sinceCreate = polls - calls.createdAtPoll
                if behavior == "delayed" and sinceCreate == pollsBeforeAppear and #masks == #existing then
                    appendNew()
                elseif behavior == "vanishes" then
                    if sinceCreate == 1 then appendNew() end
                    if sinceCreate == 4 and #masks > #existing then masks[#masks] = nil end
                end
            end
            local reversed = {}
            for index = #masks, 1, -1 do reversed[#reversed + 1] = masks[index] end
            return reversed
        end,
        selectMask = function(id) calls.selectMask[#calls.selectMask + 1] = id end,
        selectMaskTool = function() end,
        selectTool = function(name)
            tool = name
            calls.tools[#calls.tools + 1] = name
        end,
        getSelectedTool = function() return tool end,
        createNewMask = function(maskType, subtype)
            if module ~= "develop" then error("Develop module is not active") end
            calls.created[#calls.created + 1] = { type = maskType, subtype = subtype }
            calls.createdAtPoll = polls
            if behavior == "append" then
                appendNew()
            elseif behavior == "empty" then
                masks[#masks + 1] = { ID = newMaskId, Name = "Mask", Hidden = false, Tools = {} }
            elseif behavior == "double" then
                appendNew()
                masks[#masks + 1] = aiMask("second-mask", subtype)
            end
        end,
        deleteMask = function(id)
            if opts.deleteFails then error("cannot delete") end
            calls.deleteMask[#calls.deleteMask + 1] = id
            for index = #masks, 1, -1 do
                if masks[index].ID == id then table.remove(masks, index) end
            end
        end,
        setValue = function(param, value)
            if opts.setValueFailsOn == param then error("setValue failed") end
            calls.setValue[#calls.setValue + 1] = { param = param, value = value }
            local clamp = opts.clampTo and opts.clampTo[param]
            values[param] = clamp and math.max(-clamp, math.min(clamp, value)) or value
        end,
        getValue = function(param) return values[param] or 0 end,
        stopTracking = function() calls.stopTracking = calls.stopTracking + 1 end,
        setTrackingDelay = function(seconds) calls.trackingDelay[#calls.trackingDelay + 1] = seconds end,
        setMultipleAdjustmentThreshold = function(seconds) calls.threshold[#calls.threshold + 1] = seconds end,
    }
    if opts.withoutCreateApi then controller.createNewMask = nil end
    if opts.withoutMaskApi then
        controller.getAllMasks, controller.selectMask, controller.selectMaskTool = nil, nil, nil
    end

    local catalog = helper.fakeCatalog({ photos = { photo, other } })
    local recordSelection = catalog.setSelectedPhotos
    catalog.setSelectedPhotos = function(self, selected, selection)
        recordSelection(self, selected, selection)
        active = selected
    end
    catalog.getTargetPhoto = function() return active end
    catalog.kAllPhotos = "all photographs"
    catalog.getActiveSources = function() return { "folder" } end
    catalog.setActiveSources = function() end

    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
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
    package.loaded.HandlerMaskCreate = nil
    package.loaded.DevelopSession = nil
    local Handler = require 'HandlerMaskCreate'
    return Handler, calls, masks, catalog
end

local function idsOf(masks)
    local ids = {}
    for _, mask in ipairs(masks) do ids[#ids + 1] = mask.ID end
    return ids
end

describe("HandlerMaskCreate.createMask", function()
    it("creates the matching AI mask for each type and returns its id", function()
        local expected = {
            subject = "subject",
            sky = "sky",
            background = "background",
        }
        for typeName, subtype in pairs(expected) do
            local Handler, calls = setup({})

            local r = Handler.createMask({ photo_id = "10", type = typeName })

            assert.is_true(r.success)
            assert.are.equal("10", r.photo_id)
            assert.are.equal(typeName, r.type)
            assert.are.equal("new-mask", r.mask_id)
            assert.are.same({ { type = "aiSelection", subtype = subtype } }, calls.created)
            assert.are.equal("new-mask", r.mask.id)
            assert.are.equal("aiSelection", r.mask.tools[1].type)
            assert.is_nil(r.adjustments)
        end
    end)

    it("leaves the masks already on the photo untouched", function()
        local Handler, calls, masks = setup({ existing = { existingMask("a"), existingMask("b") } })

        local r = Handler.createMask({ photo_id = "10", type = "sky" })

        assert.are.equal("new-mask", r.mask_id)
        assert.are.same({ "a", "b", "new-mask" }, idsOf(masks))
        assert.are.same({}, calls.deleteMask)
        assert.are.same({ "new-mask" }, calls.selectMask)
    end)

    it("starts every local slider from zero when no adjustments are given", function()
        local Handler, calls = setup({})

        Handler.createMask({ photo_id = "10", type = "subject" })

        assert.are.equal(14, #calls.setValue)
        for _, call in ipairs(calls.setValue) do
            assert.truthy(call.param:find("^local_"))
            assert.are.equal(0, call.value)
        end
    end)

    it("writes requested adjustments and zeroes the rest", function()
        local Handler, calls = setup({})

        local r = Handler.createMask({
            photo_id = "10",
            type = "sky",
            adjustments = {
                exposure = -1.5, contrast = 20, highlights = -30, shadows = 10, whites = 5, blacks = -5,
                texture = 12, clarity = 8, dehaze = 25, temperature = -10, tint = 4,
                saturation = 15, sharpness = 30, noise = 18,
            },
        })

        local written = {}
        for _, call in ipairs(calls.setValue) do written[call.param] = call.value end
        assert.are.same({
            local_Exposure = -1.5,
            local_Contrast = 20,
            local_Highlights = -30,
            local_Shadows = 10,
            local_Whites = 5,
            local_Blacks = -5,
            local_Texture = 12,
            local_Clarity = 8,
            local_Dehaze = 25,
            local_Temperature = -10,
            local_Tint = 4,
            local_Saturation = 15,
            local_Sharpness = 30,
            local_LuminanceNoise = 18,
        }, written)
        assert.are.equal(-1.5, r.adjustments.exposure)
        assert.are.equal(18, r.adjustments.noise)
    end)

    it("zeroes sliders that were not requested", function()
        local Handler, calls = setup({})

        Handler.createMask({ photo_id = "10", type = "subject", adjustments = { exposure = 0.7 } })

        local written = {}
        for _, call in ipairs(calls.setValue) do written[call.param] = call.value end
        assert.are.equal(0.7, written.local_Exposure)
        assert.are.equal(0, written.local_Contrast)
        assert.are.equal(0, written.local_LuminanceNoise)
    end)

    it("groups the writes into one history step and restores the grouping defaults", function()
        local Handler, calls = setup({})

        Handler.createMask({ photo_id = "10", type = "subject", adjustments = { exposure = 1 } })

        assert.are.same({ 10, 2 }, calls.trackingDelay)
        assert.are.same({ 10, 0.5 }, calls.threshold)
        assert.are.equal(1, calls.stopTracking)
    end)

    it("restores the grouping defaults when a slider write fails", function()
        local Handler, calls = setup({ setValueFailsOn = "local_Dehaze" })

        errorOf(function() Handler.createMask({ photo_id = "10", type = "subject" }) end)

        assert.are.same({ 10, 2 }, calls.trackingDelay)
        assert.are.same({ 10, 0.5 }, calls.threshold)
    end)

    it("removes the new mask and reports the failure when a slider write fails", function()
        local Handler, calls, masks = setup({
            existing = { existingMask("a") },
            setValueFailsOn = "local_Tint",
        })

        local err = errorOf(function()
            Handler.createMask({ photo_id = "10", type = "subject", adjustments = { tint = 5 } })
        end)

        assert.truthy(err:find("setValue failed", 1, true))
        assert.are.same({ "a" }, idsOf(masks))
        assert.are.same({ "new-mask" }, calls.deleteMask)
    end)

    it("removes the new mask when Lightroom reads back a different value than was written", function()
        local Handler, calls, masks = setup({
            existing = { existingMask("a") },
            clampTo = { local_Contrast = 5 },
        })

        local err = errorOf(function()
            Handler.createMask({ photo_id = "10", type = "subject", adjustments = { contrast = 20 } })
        end)

        assert.truthy(err:find("Lightroom did not keep contrast 20 (reads 5)", 1, true))
        assert.are.same({ "a" }, idsOf(masks))
        assert.are.same({ "new-mask" }, calls.deleteMask)
    end)

    it("tells the caller to dismiss Lightroom's alert when nothing is found", function()
        local Handler = setup({ behavior = "nothing" })

        local err = errorOf(function() Handler.createMask({ photo_id = "10", type = "sky" }) end)

        assert.truthy(err:find("click OK in Lightroom", 1, true))
    end)

    it("waits for a mask that Lightroom adds after detection finishes", function()
        local Handler, _, masks = setup({ behavior = "delayed", pollsBeforeAppear = 40 })

        local r = Handler.createMask({ photo_id = "10", type = "subject" })

        assert.are.equal("new-mask", r.mask_id)
        assert.are.same({ "new-mask" }, idsOf(masks))
    end)

    it("reports nothing found when no mask appears, and changes no masks", function()
        local Handler, calls, masks = setup({ behavior = "nothing", existing = { existingMask("a") } })

        local err = errorOf(function() Handler.createMask({ photo_id = "10", type = "sky" }) end)

        assert.truthy(err:find("Lightroom found no sky to select on photo 10", 1, true))
        assert.are.same({ "a" }, idsOf(masks))
        assert.are.same({}, calls.deleteMask)
        assert.are.same({}, calls.setValue)
    end)

    it("deletes an empty mask that Lightroom leaves behind", function()
        local Handler, calls, masks = setup({ behavior = "empty", existing = { existingMask("a") } })

        local err = errorOf(function() Handler.createMask({ photo_id = "10", type = "sky" }) end)

        assert.truthy(err:find("created an empty sky mask", 1, true))
        assert.are.same({ "a" }, idsOf(masks))
        assert.are.same({ "new-mask" }, calls.deleteMask)
        assert.are.same({}, calls.setValue)
    end)

    it("treats a mask that disappears again as nothing found", function()
        local Handler, _, masks = setup({ behavior = "vanishes" })

        local err = errorOf(function() Handler.createMask({ photo_id = "10", type = "background" }) end)

        assert.truthy(err:find("found no background to select", 1, true))
        assert.are.same({}, idsOf(masks))
    end)

    it("removes every new mask when Lightroom adds more than one", function()
        local Handler, calls, masks = setup({ behavior = "double", existing = { existingMask("a") } })

        local err = errorOf(function() Handler.createMask({ photo_id = "10", type = "subject" }) end)

        assert.truthy(err:find("added 2 masks", 1, true))
        assert.are.same({ "a" }, idsOf(masks))
        assert.are.equal(2, #calls.deleteMask)
    end)

    it("names a new mask it could not remove", function()
        local Handler = setup({ behavior = "empty", deleteFails = true })

        local err = errorOf(function() Handler.createMask({ photo_id = "10", type = "sky" }) end)

        assert.truthy(err:find("could not remove the new mask new-mask", 1, true))
    end)

    it("waits for the existing masks to load before taking its snapshot", function()
        local Handler, _, masks = setup({ existing = { existingMask("a") }, notReadyPolls = 12 })

        local r = Handler.createMask({ photo_id = "10", type = "subject" })

        assert.are.equal("new-mask", r.mask_id)
        assert.are.same({ "a", "new-mask" }, idsOf(masks))
    end)

    it("refuses to create when the existing masks never load", function()
        local Handler, calls = setup({ existing = { existingMask("a") }, notReadyPolls = 100000 })

        local err = errorOf(function() Handler.createMask({ photo_id = "10", type = "subject" }) end)

        assert.truthy(err:find("could not read the existing masks of photo 10", 1, true))
        assert.are.same({}, calls.created)
    end)

    it("opens the masking tool and puts the previous tool back", function()
        local Handler, calls = setup({ startTool = "crop" })

        Handler.createMask({ photo_id = "10", type = "subject" })

        assert.are.same({ "masking", "crop" }, calls.tools)
    end)

    it("puts the previous tool back after a failure", function()
        local Handler, calls = setup({ behavior = "nothing", startTool = "crop" })

        errorOf(function() Handler.createMask({ photo_id = "10", type = "sky" }) end)

        assert.are.same({ "masking", "crop" }, calls.tools)
    end)

    it("accepts a numeric photo id and a file path", function()
        local Handler = setup({})
        assert.are.equal("10", Handler.createMask({ photo_id = 10, type = "sky" }).photo_id)

        local PathHandler = setup({})
        assert.are.equal("/10.jpg", PathHandler.createMask({ photo_id = "/10.jpg", type = "sky" }).photo_id)
    end)

    it("rejects bad arguments before touching Lightroom", function()
        local cases = {
            { { type = "sky" }, "photo_id is required" },
            { { photo_id = "", type = "sky" }, "photo_id is required" },
            { { photo_id = "10" }, "type must be one of: subject, sky, background" },
            { { photo_id = "10", type = "unknown" }, "type must be one of: subject, sky, background" },
            { { photo_id = "10", type = "sky", adjustments = "bright" }, "adjustments must be an object" },
            { { photo_id = "10", type = "sky", adjustments = { gamma = 1 } }, "Unknown adjustment gamma" },
            { { photo_id = "10", type = "sky", adjustments = { exposure = "1" } }, "exposure must be a number between -4 and 4" },
            { { photo_id = "10", type = "sky", adjustments = { exposure = 4.5 } }, "exposure must be between -4 and 4 (got 4.5)" },
            { { photo_id = "10", type = "sky", adjustments = { exposure = -4.1 } }, "exposure must be between -4 and 4 (got -4.1)" },
            { { photo_id = "10", type = "sky", adjustments = { clarity = 101 } }, "clarity must be between -100 and 100 (got 101)" },
            { { photo_id = "10", type = "sky", adjustments = { noise = -101 } }, "noise must be between -100 and 100 (got -101)" },
            { { photo_id = "10", type = "sky", adjustments = { tint = 0 / 0 } }, "tint must be a number between -100 and 100" },
        }
        for _, case in ipairs(cases) do
            local Handler, calls, _, catalog = setup({})

            local err = errorOf(function() Handler.createMask(case[1]) end)

            assert.truthy(err:find(case[2], 1, true), err)
            assert.are.same({}, calls.modules)
            assert.are.same({}, calls.created)
            assert.are.equal(0, catalog.getQueryCount())
        end
    end)

    it("accepts the slider limits", function()
        local Handler, calls = setup({})

        Handler.createMask({
            photo_id = "10",
            type = "sky",
            adjustments = { exposure = 4, contrast = -100, dehaze = 100, noise = 100 },
        })

        assert.are.equal(14, #calls.setValue)
    end)

    it("names the photo id when the photo is unknown and never touches Develop", function()
        local Handler, calls = setup({})

        local err = errorOf(function() Handler.createMask({ photo_id = "404", type = "sky" }) end)

        assert.truthy(err:find("Photo not found: 404", 1, true))
        assert.are.same({}, calls.modules)
    end)

    it("names the minimum Lightroom version when the mask API is missing", function()
        for _, opts in ipairs({ { withoutMaskApi = true }, { withoutCreateApi = true } }) do
            local Handler, calls = setup(opts)

            local err = errorOf(function() Handler.createMask({ photo_id = "10", type = "sky" }) end)

            assert.truthy(err:find("create_mask needs Lightroom Classic 11 or later", 1, true))
            assert.are.same({}, calls.modules)
        end
    end)

    it("puts back the module afterwards", function()
        local Handler, calls = setup({})

        Handler.createMask({ photo_id = "10", type = "sky" })

        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("resolves photos and reads settings outside any query gate", function()
        local Handler, _, _, catalog = setup({})

        Handler.createMask({ photo_id = "10", type = "sky" })

        assert.are.equal(0, catalog.getWriteAccessCount())
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)
end)
