local helper = require 'spec_helper'

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

local function tool(id, type, inverted)
    return { ID = id, Name = type .. " " .. id, Type = type, Hidden = false, Inverted = inverted }
end

local function mask(id, name, tools)
    return { ID = id, Name = name, Hidden = false, Tools = tools }
end

local function copyMask(source, newId)
    local tools = {}
    for index, original in ipairs(source.Tools) do
        tools[index] = {
            ID = newId .. "-tool-" .. index,
            Name = original.Name,
            Type = original.Type,
            Hidden = original.Hidden,
            Inverted = not original.Inverted,
        }
    end
    return mask(newId, source.Name .. " Inverted", tools)
end

local function setup(opts)
    local photos, masksOf = {}, {}
    for _, spec in ipairs(opts.photos) do
        local p = helper.fakePhoto({ id = spec.id, path = "/" .. spec.id .. ".jpg" })
        photos[#photos + 1] = p
        masksOf[p] = spec.masks or {}
    end
    local active = photos[1]
    local module = "library"
    local calls = { modules = {}, selections = {}, goToMasking = 0, invert = {}, duplicate = {}, deleted = {}, setValue = {}, selectedMasks = {}, stopTracking = {} }
    local copiesMade = 0
    local selected = opts.startSelected
    local values = {}
    for maskId, sliders in pairs(opts.values or {}) do values[maskId] = sliders end

    local function currentMasks() return masksOf[active] end
    local function findCurrent(id)
        for _, m in ipairs(currentMasks()) do
            if m.ID == id then return m end
        end
        return nil
    end

    local controller = {
        getAllMasks = function()
            if module ~= "develop" then error("Develop module is not active") end
            return currentMasks()
        end,
        selectMask = function(id)
            selected = id
            calls.selectedMasks[#calls.selectedMasks + 1] = id
        end,
        getSelectedMask = function() return selected end,
        getValue = function(param) return values[selected] and values[selected][param] or 0 end,
        setValue = function(param, value)
            if opts.setValueFails then error("setValue failed") end
            calls.setValue[#calls.setValue + 1] = { mask = selected, param = param, value = value }
            values[selected] = values[selected] or {}
            values[selected][param] = opts.copyIgnoresValues and 0 or value
        end,
        stopTracking = function(commit) calls.stopTracking[#calls.stopTracking + 1] = commit end,
        deleteMask = function(id)
            calls.deleted[#calls.deleted + 1] = id
            for index = #currentMasks(), 1, -1 do
                if currentMasks()[index].ID == id then table.remove(currentMasks(), index) end
            end
        end,
        selectMaskTool = function() end,
        goToMasking = function() calls.goToMasking = calls.goToMasking + 1 end,
        invertMask = function(id)
            calls.invert[#calls.invert + 1] = id
            if opts.invertReturns ~= nil then return opts.invertReturns end
            if opts.invertThrows then error(opts.invertThrows) end
            if opts.invertIsIgnored then return true end
            local target = findCurrent(id)
            for _, t in ipairs(target.Tools) do t.Inverted = not t.Inverted end
            return true
        end,
        duplicateAndInvertMask = function(id)
            calls.duplicate[#calls.duplicate + 1] = id
            if opts.duplicateReturns ~= nil then return opts.duplicateReturns end
            if opts.duplicateIsIgnored then return true end
            local source = findCurrent(id)
            local created = opts.copiesPerCall or 1
            for _ = 1, created do
                copiesMade = copiesMade + 1
                table.insert(currentMasks(), 1, copyMask(source, "copy-" .. copiesMade))
            end
            if opts.damageOriginalOnCopy then source.Tools[1].Inverted = not source.Tools[1].Inverted end
            return true
        end,
    }
    for _, name in ipairs(opts.withoutFunctions or {}) do controller[name] = nil end

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
        active = photo
        calls.selections[#calls.selections + 1] = photo.localIdentifier
    end
    catalog.getTargetPhoto = function() return active end
    catalog.kAllPhotos = "all photographs"
    catalog.getActiveSources = function() return { "folder" } end
    catalog.setActiveSources = function() end

    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrApplicationView = view,
        LrDevelopController = controller,
        LrSelection = { selectNone = function() active = nil end },
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerMaskInvert = nil
    package.loaded.DevelopSession = nil
    local Handler = require 'HandlerMaskInvert'
    return Handler, calls, masksOf, catalog
end

local function subjectMasks()
    return {
        mask("m-1", "Subject", { tool("t-1", "aiSelection", false), tool("t-2", "brush", false) }),
        mask("m-2", "Sky", { tool("t-3", "aiSelection", false) }),
    }
end

local function args(overrides)
    local base = { photo_id = "1", mask_id = "m-1", mode = "in_place" }
    for key, value in pairs(overrides or {}) do base[key] = value end
    return base
end

describe("HandlerMaskInvert.invertMask in place", function()
    it("inverts the chosen mask and reports the new tool states", function()
        local Handler, calls = setup({ photos = { { id = "1", masks = subjectMasks() } } })

        local r = Handler.invertMask(args())

        assert.is_true(r.success)
        assert.are.equal("1", r.photo_id)
        assert.are.equal("in_place", r.mode)
        assert.are.equal("m-1", r.mask_id)
        assert.is_nil(r.source_mask_id)
        assert.are.same({
            id = "m-1",
            name = "Subject",
            tools = { { id = "t-1", inverted = true }, { id = "t-2", inverted = true } },
        }, r.mask)
        assert.are.same({ "m-1" }, calls.invert)
        assert.are.same({}, calls.duplicate)
    end)

    it("leaves the other masks of the photo unchanged", function()
        local Handler, _, masksOf = setup({ photos = { { id = "1", masks = subjectMasks() } } })

        Handler.invertMask(args())

        local masks = masksOf[next(masksOf)]
        assert.is_false(masks[2].Tools[1].Inverted)
    end)

    it("opens the masking tool before inverting and puts back module and selection", function()
        local Handler, calls = setup({
            photos = { { id = "1" }, { id = "2", masks = subjectMasks() } },
        })

        Handler.invertMask(args({ photo_id = "2" }))

        assert.are.equal(1, calls.goToMasking)
        assert.are.same({ "develop", "library" }, calls.modules)
        assert.are.same({ "2", "1" }, calls.selections)
    end)

    it("chooses the mask by id and not by position", function()
        local Handler, calls = setup({ photos = { { id = "1", masks = subjectMasks() } } })

        local r = Handler.invertMask(args({ mask_id = "m-2" }))

        assert.are.equal("m-2", r.mask_id)
        assert.are.same({ "m-2" }, calls.invert)
        assert.are.same({ { id = "t-3", inverted = true } }, r.mask.tools)
    end)

    it("errors for an unknown mask id without calling invertMask", function()
        local Handler, calls = setup({ photos = { { id = "1", masks = subjectMasks() } } })

        local err = errorOf(function() Handler.invertMask(args({ mask_id = "nope" })) end)

        assert.truthy(err:find("Mask not found on photo 1: nope", 1, true))
        assert.are.same({}, calls.invert)
        assert.are.same({}, calls.duplicate)
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("errors when the photo has no masks at all", function()
        local Handler, calls = setup({ photos = { { id = "1" } } })

        local err = errorOf(function() Handler.invertMask(args()) end)

        assert.truthy(err:find("Mask not found on photo 1: m-1", 1, true))
        assert.are.same({}, calls.invert)
    end)

    it("errors when Lightroom says the inversion failed", function()
        local Handler = setup({ photos = { { id = "1", masks = subjectMasks() } }, invertReturns = false })

        local err = errorOf(function() Handler.invertMask(args()) end)

        assert.truthy(err:find("Lightroom refused invertMask on mask m-1", 1, true))
    end)

    it("reports the reason when invertMask raises", function()
        local Handler = setup({ photos = { { id = "1", masks = subjectMasks() } }, invertThrows = "boom" })

        local err = errorOf(function() Handler.invertMask(args()) end)

        assert.truthy(err:find("could not run invertMask on mask m-1", 1, true))
        assert.truthy(err:find("boom", 1, true))
    end)

    it("errors when Lightroom accepts the call but the mask never changes", function()
        local Handler, calls = setup({
            photos = { { id = "1", masks = subjectMasks() } },
            invertIsIgnored = true,
        })

        local err = errorOf(function() Handler.invertMask(args()) end)

        assert.truthy(err:find("may not have been saved", 1, true))
        assert.are.same({ "develop", "library" }, calls.modules)
    end)
end)

describe("HandlerMaskInvert.invertMask as a copy", function()
    it("returns the new mask id and leaves the original unchanged", function()
        local Handler, calls, masksOf = setup({ photos = { { id = "1", masks = subjectMasks() } } })

        local r = Handler.invertMask(args({ mode = "copy" }))

        assert.is_true(r.success)
        assert.are.equal("copy", r.mode)
        assert.are.equal("m-1", r.source_mask_id)
        assert.are.equal("copy-1", r.mask_id)
        assert.are.same({
            id = "copy-1",
            name = "Subject Inverted",
            tools = { { id = "copy-1-tool-1", inverted = true }, { id = "copy-1-tool-2", inverted = true } },
        }, r.mask)
        assert.are.same({ "m-1" }, calls.duplicate)
        assert.are.same({}, calls.invert)
        local masks = masksOf[next(masksOf)]
        assert.are.equal(3, #masks)
        assert.are.equal("m-1", masks[2].ID)
        assert.is_false(masks[2].Tools[1].Inverted)
        assert.is_false(masks[2].Tools[2].Inverted)
    end)

    it("copies the local adjustments of the original, which Lightroom's duplicate leaves at 0", function()
        local Handler, calls = setup({
            photos = { { id = "1", masks = subjectMasks() } },
            values = { ["m-1"] = { local_Exposure = 1.25, local_Contrast = 10 } },
        })

        local r = Handler.invertMask(args({ mode = "copy" }))

        assert.are.equal(2, r.adjustments_copied)
        assert.are.same({
            { mask = "copy-1", param = "local_Exposure", value = 1.25 },
            { mask = "copy-1", param = "local_Contrast", value = 10 },
        }, calls.setValue)
    end)

    it("commits the copied adjustments to the photo before returning", function()
        local Handler, calls = setup({
            photos = { { id = "1", masks = subjectMasks() } },
            values = { ["m-1"] = { local_Exposure = 1.25 } },
        })

        Handler.invertMask(args({ mode = "copy" }))

        assert.are.same({ true }, calls.stopTracking)
    end)

    it("does not force a commit when nothing was copied", function()
        local Handler, calls = setup({ photos = { { id = "1", masks = subjectMasks() } } })

        Handler.invertMask(args({ mode = "copy" }))

        assert.are.same({}, calls.stopTracking)
    end)

    it("writes nothing to the copy when the original has no adjustments", function()
        local Handler, calls = setup({ photos = { { id = "1", masks = subjectMasks() } } })

        local r = Handler.invertMask(args({ mode = "copy" }))

        assert.are.equal(0, r.adjustments_copied)
        assert.are.same({}, calls.setValue)
    end)

    it("removes the copy and fails when Lightroom does not keep the copied adjustments", function()
        local Handler, calls, masksOf = setup({
            photos = { { id = "1", masks = subjectMasks() } },
            values = { ["m-1"] = { local_Exposure = 1.25 } },
            copyIgnoresValues = true,
        })

        local err = errorOf(function() Handler.invertMask(args({ mode = "copy" })) end)

        assert.truthy(err:find("did not keep local_Exposure 1.25", 1, true))
        assert.truthy(err:find("the copy was removed", 1, true))
        assert.are.same({ "copy-1" }, calls.deleted)
        assert.are.equal(2, #masksOf[next(masksOf)])
    end)

    it("selects the previously selected mask again after copying", function()
        local Handler, calls = setup({
            photos = { { id = "1", masks = subjectMasks() } },
            startSelected = "m-2",
        })

        Handler.invertMask(args({ mode = "copy", mask_id = "m-1" }))

        assert.are.equal("m-2", calls.selectedMasks[#calls.selectedMasks])
    end)

    it("picks the copy of the requested mask when other masks exist", function()
        local Handler = setup({ photos = { { id = "1", masks = subjectMasks() } } })

        local r = Handler.invertMask(args({ mode = "copy", mask_id = "m-2" }))

        assert.are.equal("m-2", r.source_mask_id)
        assert.are.equal("Sky Inverted", r.mask.name)
    end)

    it("errors for an unknown mask id without duplicating anything", function()
        local Handler, calls, masksOf = setup({ photos = { { id = "1", masks = subjectMasks() } } })

        local err = errorOf(function() Handler.invertMask(args({ mode = "copy", mask_id = "nope" })) end)

        assert.truthy(err:find("Mask not found on photo 1: nope", 1, true))
        assert.are.same({}, calls.duplicate)
        assert.are.equal(2, #masksOf[next(masksOf)])
    end)

    it("errors when Lightroom says the duplication failed", function()
        local Handler = setup({ photos = { { id = "1", masks = subjectMasks() } }, duplicateReturns = false })

        local err = errorOf(function() Handler.invertMask(args({ mode = "copy" })) end)

        assert.truthy(err:find("Lightroom refused duplicateAndInvertMask on mask m-1", 1, true))
    end)

    it("errors when no new mask appears", function()
        local Handler, calls = setup({
            photos = { { id = "1", masks = subjectMasks() } },
            duplicateIsIgnored = true,
        })

        local err = errorOf(function() Handler.invertMask(args({ mode = "copy" })) end)

        assert.truthy(err:find("did not create an inverted copy of mask m-1", 1, true))
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("errors instead of guessing when several new masks appear", function()
        local Handler = setup({
            photos = { { id = "1", masks = subjectMasks() } },
            copiesPerCall = 2,
        })

        local err = errorOf(function() Handler.invertMask(args({ mode = "copy" })) end)

        assert.truthy(err:find("created 2 new masks", 1, true))
        assert.truthy(err:find("cannot tell which is the copy", 1, true))
    end)

    it("still returns the copy when the original looks changed afterwards", function()
        local Handler = setup({
            photos = { { id = "1", masks = subjectMasks() } },
            damageOriginalOnCopy = true,
        })

        local r = Handler.invertMask(args({ mode = "copy" }))

        assert.are.equal("copy-1", r.mask_id)
    end)
end)

describe("HandlerMaskInvert.invertMask arguments", function()
    it("requires a photo id, a mask id and a mode", function()
        local Handler = setup({ photos = { { id = "1", masks = subjectMasks() } } })

        assert.truthy(errorOf(function() Handler.invertMask(args({ photo_id = "" })) end)
            :find("photo_id is required", 1, true))
        assert.truthy(errorOf(function() Handler.invertMask(args({ mask_id = "" })) end)
            :find("mask_id is required", 1, true))
        assert.truthy(errorOf(function() Handler.invertMask(args({ mask_id = 5 })) end)
            :find("mask_id is required", 1, true))
        assert.truthy(errorOf(function() Handler.invertMask(args({ mode = "toggle" })) end)
            :find("mode must be", 1, true))
        assert.truthy(errorOf(function() Handler.invertMask(args({ mode = false })) end)
            :find("mode must be", 1, true))
    end)

    it("accepts a numeric photo id and a file path", function()
        local Handler = setup({ photos = { { id = "7", masks = subjectMasks() } } })

        assert.are.equal("7", Handler.invertMask(args({ photo_id = 7 })).photo_id)
        assert.is_true(Handler.invertMask(args({ photo_id = "/7.jpg", mask_id = "m-2" })).success)
    end)

    it("names the photo id when the photo is unknown and never touches Develop", function()
        local Handler, calls = setup({ photos = { { id = "1" } } })

        local err = errorOf(function() Handler.invertMask(args({ photo_id = "404" })) end)

        assert.truthy(err:find("Photo not found: 404", 1, true))
        assert.are.equal(0, #calls.modules)
    end)

    it("names the minimum Lightroom version when an invert function is missing", function()
        for _, missing in ipairs({ "invertMask", "duplicateAndInvertMask", "goToMasking" }) do
            local Handler, calls = setup({
                photos = { { id = "1", masks = subjectMasks() } },
                withoutFunctions = { missing },
            })

            local err = errorOf(function() Handler.invertMask(args()) end)

            assert.truthy(err:find("invert_mask needs Lightroom Classic 11.4 or later", 1, true))
            assert.are.equal(0, #calls.modules)
        end
    end)

    it("names the older mask API requirement when mask reading is missing", function()
        local Handler = setup({
            photos = { { id = "1" } },
            withoutFunctions = { "getAllMasks" },
        })

        local err = errorOf(function() Handler.invertMask(args()) end)

        assert.truthy(err:find("invert_mask needs Lightroom Classic 11 or later", 1, true))
    end)

    it("never opens a catalog gate", function()
        local Handler, _, _, catalog = setup({ photos = { { id = "1", masks = subjectMasks() } } })

        Handler.invertMask(args())

        assert.are.equal(0, catalog.getWriteAccessCount())
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)
end)
