local helper = require 'spec_helper'

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

local function setup(opts)
    opts = opts or {}
    local photos, valuesOf = {}, {}
    for _, spec in ipairs(opts.photos) do
        local p = helper.fakePhoto({ id = spec.id, path = "/" .. spec.id .. ".jpg" })
        photos[#photos + 1] = p
        valuesOf[p] = spec.masks or {}
    end
    local active = photos[1]
    local module = opts.startModule or "library"
    local storedOf, pendingCommits, sleepsSeen = {}, {}, 0
    local function storeFields(photo, maskId)
        storedOf[photo] = storedOf[photo] or {}
        local fields = {}
        for name, value in pairs(valuesOf[photo][maskId]) do fields["Local" .. name] = value end
        storedOf[photo][maskId] = fields
    end
    for _, photo in ipairs(photos) do
        for maskId in pairs(valuesOf[photo]) do storeFields(photo, maskId) end
        photo.getDevelopSettings = function()
            local entries = {}
            for maskId, fields in pairs(storedOf[photo] or {}) do
                local entry = { What = "Correction", CorrectionID = maskId }
                for key, value in pairs(fields) do entry[key] = value end
                entries[#entries + 1] = entry
            end
            if opts.maskMissingFromStore then entries = {} end
            return { MaskGroupBasedCorrections = entries }
        end
    end
    local selectedMaskOf = {}
    for index, spec in ipairs(opts.photos) do
        selectedMaskOf[photos[index]] = spec.selectedMask
    end
    local calls = {
        setValue = {},
        selectMask = {},
        modules = {},
        selections = {},
        goToMasking = 0,
        stopTracking = {},
    }
    local controller

    local function currentValues()
        local selected = selectedMaskOf[active]
        return selected and valuesOf[active][selected] or nil
    end

    controller = {
        getAllMasks = function()
            if module ~= "develop" then error("Develop module is not active") end
            local masks = {}
            for _, id in ipairs(opts.maskOrder or {}) do
                if valuesOf[active][id] then masks[#masks + 1] = { ID = id, Name = id, Tools = {} } end
            end
            if #masks == 0 then
                for id in pairs(valuesOf[active]) do masks[#masks + 1] = { ID = id, Name = id, Tools = {} } end
            end
            table.sort(masks, function(a, b) return a.ID < b.ID end)
            return masks
        end,
        goToMasking = function() calls.goToMasking = calls.goToMasking + 1 end,
        selectMaskTool = function() end,
        selectMask = function(id)
            calls.selectMask[#calls.selectMask + 1] = id
            if valuesOf[active][id] and not opts.selectIgnored then selectedMaskOf[active] = id end
        end,
        getSelectedMask = function()
            if calls.goToMasking == 0 then error("masking tool is not open") end
            return selectedMaskOf[active]
        end,
        getRange = function(name)
            local range = opts.ranges and opts.ranges[name]
            if range then return range[1], range[2] end
            error("no range")
        end,
        getValue = function(name)
            local values = currentValues()
            if not values then error("no mask selected") end
            if opts.unreadable and opts.unreadable[name] then return nil end
            return values[name]
        end,
        setValue = function(name, value)
            calls.setValue[#calls.setValue + 1] = { name, value }
            local values = currentValues()
            if not values then error("no mask selected") end
            if opts.rejectSet and opts.rejectSet[name] then error(opts.rejectSet[name]) end
            if opts.ignoreSet and opts.ignoreSet[name] then return end
            if opts.roundSet then value = math.floor(value + 0.5) end
            values[name] = value
            local commit = { photo = active, maskId = selectedMaskOf[active], dueAt = sleepsSeen + (opts.commitLagSleeps or 0) }
            if not opts.neverCommit then
                if commit.dueAt <= sleepsSeen then
                    storeFields(commit.photo, commit.maskId)
                else
                    pendingCommits[#pendingCommits + 1] = commit
                end
            end
            if opts.revertAfterSettle and opts.revertAfterSettle[name] then
                opts.revertQueue = opts.revertQueue or {}
                opts.revertQueue[#opts.revertQueue + 1] = function() values[name] = opts.revertAfterSettle[name] end
            end
            if opts.stealSelectionOnSet then selectedMaskOf[active] = opts.stealSelectionOnSet end
        end,
    }
    controller.stopTracking = function(commit)
        calls.stopTracking[#calls.stopTracking + 1] = commit
        for _, pending in ipairs(pendingCommits) do storeFields(pending.photo, pending.maskId) end
        pendingCommits = {}
    end
    if opts.withoutStopTracking then controller.stopTracking = nil end
    if opts.withoutSetValue then controller.setValue = nil end
    if opts.withoutMaskApi then
        controller.getAllMasks, controller.selectMask, controller.selectMaskTool = nil, nil, nil
    end

    local sources = { "folder" }
    local catalog = helper.fakeCatalog({ photos = photos })
    catalog.setSelectedPhotos = function(_, photo)
        active = photo
        calls.selections[#calls.selections + 1] = photo.localIdentifier
    end
    catalog.getTargetPhoto = function() return active end
    catalog.getTargetPhotos = function() return { active } end
    catalog.kAllPhotos = "all photographs"
    catalog.getActiveSources = function() return sources end
    catalog.setActiveSources = function(_, newSources) sources = newSources end

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
        LrTasks = {
            pcall = pcall,
            sleep = function()
                sleepsSeen = sleepsSeen + 1
                local stillPending = {}
                for _, commit in ipairs(pendingCommits) do
                    if commit.dueAt <= sleepsSeen then
                        storeFields(commit.photo, commit.maskId)
                    else
                        stillPending[#stillPending + 1] = commit
                    end
                end
                pendingCommits = stillPending
                for _, revert in ipairs(opts.revertQueue or {}) do revert() end
                opts.revertQueue = nil
            end,
        },
        LrLogger = helper.defaultLrLogger(),
    })
    for _, name in ipairs({ "HandlerMaskAdjustments", "DevelopSession", "LocalSliders", "MaskSettle", "GuardedMaskWrite" }) do
        package.loaded[name] = nil
    end
    local Handler = require 'HandlerMaskAdjustments'
    return Handler, calls, catalog, valuesOf, photos, selectedMaskOf
end

local function twoMasks()
    return {
        ["mask-a"] = { local_Exposure = 0.5, local_Contrast = 10, local_Shadows = 20 },
        ["mask-b"] = { local_Exposure = -1, local_Contrast = -30, local_Shadows = 5 },
    }
end

local function everyPhotoAndMask(masks)
    return { photos = { { id = "1", masks = masks, selectedMask = "mask-b" } } }
end

describe("HandlerMaskAdjustments.setMaskAdjustments", function()
    it("changes only the requested sliders of the requested mask", function()
        local Handler, calls, _, valuesOf, photos = setup(everyPhotoAndMask(twoMasks()))

        local r = Handler.setMaskAdjustments({
            photo_id = "1",
            mask_id = "mask-a",
            adjustments = { local_Exposure = 1.25, local_Shadows = -15 },
        })

        assert.is_true(r.success)
        assert.are.equal("1", r.photo_id)
        assert.are.equal("mask-a", r.mask_id)
        assert.are.same({ local_Exposure = 1.25, local_Shadows = -15 }, r.adjustments)
        assert.are.same({
            { slider = "local_Exposure", from = 0.5, to = 1.25 },
            { slider = "local_Shadows", from = 20, to = -15 },
        }, r.changed)
        assert.are.same({}, r.unchanged)
        assert.are.same({ local_Exposure = 1.25, local_Contrast = 10, local_Shadows = -15 }, valuesOf[photos[1]]["mask-a"])
        assert.are.same({ local_Exposure = -1, local_Contrast = -30, local_Shadows = 5 }, valuesOf[photos[1]]["mask-b"])
        assert.are.equal(2, #calls.setValue)
    end)

    it("writes sliders in a fixed order whatever the key order", function()
        local Handler, calls = setup(everyPhotoAndMask(twoMasks()))

        Handler.setMaskAdjustments({
            photo_id = "1",
            mask_id = "mask-a",
            adjustments = { local_Shadows = 1, local_Contrast = 2, local_Exposure = 3 },
        })

        assert.are.same({ "local_Exposure", "local_Contrast", "local_Shadows" },
            { calls.setValue[1][1], calls.setValue[2][1], calls.setValue[3][1] })
    end)

    it("skips a slider already at the value and writes nothing when all are", function()
        local Handler, calls = setup(everyPhotoAndMask(twoMasks()))

        local r = Handler.setMaskAdjustments({
            photo_id = "1",
            mask_id = "mask-a",
            adjustments = { local_Exposure = 0.5, local_Contrast = 10 },
        })

        assert.are.same({}, r.changed)
        assert.are.same({ "local_Exposure", "local_Contrast" }, r.unchanged)
        assert.are.equal(0, #calls.setValue)
    end)

    it("puts back the previously selected mask, module and photo selection", function()
        local Handler, calls, _, _, _, selectedMaskOf = setup({
            photos = {
                { id = "1" },
                { id = "2", masks = twoMasks(), selectedMask = "mask-b" },
            },
        })

        Handler.setMaskAdjustments({ photo_id = "2", mask_id = "mask-a", adjustments = { local_Contrast = 0 } })

        assert.are.same({ "develop", "library" }, calls.modules)
        assert.are.same({ "2", "1" }, calls.selections)
        assert.are.equal("mask-b", calls.selectMask[#calls.selectMask])
        local photoTwo
        for photo, id in pairs(selectedMaskOf) do
            if photo.localIdentifier == "2" then photoTwo = id end
        end
        assert.are.equal("mask-b", photoTwo)
    end)

    it("accepts a numeric photo id and a file path", function()
        local Handler = setup(everyPhotoAndMask(twoMasks()))

        local byNumber = Handler.setMaskAdjustments({ photo_id = 1, mask_id = "mask-a", adjustments = { local_Contrast = 10 } })
        local byPath = Handler.setMaskAdjustments({ photo_id = "/1.jpg", mask_id = "mask-a", adjustments = { local_Contrast = 10 } })

        assert.are.equal("1", byNumber.photo_id)
        assert.is_true(byPath.success)
    end)

    it("rejects an out-of-range value naming the slider and its range, writing nothing", function()
        local Handler, calls = setup(everyPhotoAndMask(twoMasks()))

        local err = errorOf(function()
            Handler.setMaskAdjustments({
                photo_id = "1",
                mask_id = "mask-a",
                adjustments = { local_Contrast = 30, local_Exposure = 9 },
            })
        end)

        assert.truthy(err:find("local_Exposure 9 is outside its range -4 to 4", 1, true))
        assert.is_nil(err:find("local_Contrast", 1, true))
        assert.are.equal(0, #calls.setValue)
    end)

    it("lists every out-of-range slider in one error", function()
        local Handler, calls = setup(everyPhotoAndMask(twoMasks()))

        local err = errorOf(function()
            Handler.setMaskAdjustments({
                photo_id = "1",
                mask_id = "mask-a",
                adjustments = { local_Contrast = 101, local_Shadows = -100.5 },
            })
        end)

        assert.truthy(err:find("local_Contrast 101 is outside its range -100 to 100", 1, true))
        assert.truthy(err:find("local_Shadows -100.5 is outside its range -100 to 100", 1, true))
        assert.are.equal(0, #calls.setValue)
    end)

    it("accepts the range ends", function()
        local Handler = setup(everyPhotoAndMask(twoMasks()))

        local r = Handler.setMaskAdjustments({
            photo_id = "1",
            mask_id = "mask-a",
            adjustments = { local_Exposure = -4, local_Contrast = 100 },
        })

        assert.are.same({ local_Exposure = -4, local_Contrast = 100 }, r.adjustments)
    end)

    it("prefers the range Lightroom reports for the slider", function()
        local Handler, calls = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            ranges = { local_Contrast = { -50, 50 } },
        })

        local err = errorOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Contrast = 60 } })
        end)

        assert.truthy(err:find("local_Contrast 60 is outside its range -50 to 50", 1, true))
        assert.are.equal(0, #calls.setValue)
    end)

    it("rejects an unknown slider, a non-number and missing arguments before touching Develop", function()
        local Handler, calls = setup(everyPhotoAndMask(twoMasks()))
        local function call(args)
            return errorOf(function() Handler.setMaskAdjustments(args) end)
        end

        assert.truthy(call({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Bogus = 1 } })
            :find("Unknown mask adjustment local_Bogus", 1, true))
        assert.truthy(call({ photo_id = "1", mask_id = "mask-a", adjustments = { Exposure2012 = 1 } })
            :find("valid sliders: local_Exposure", 1, true))
        assert.truthy(call({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Contrast = "5" } })
            :find("local_Contrast must be a number", 1, true))
        assert.truthy(call({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Contrast = 0 / 0 } })
            :find("local_Contrast must be a number", 1, true))
        assert.truthy(call({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Contrast = math.huge } })
            :find("local_Contrast must be a number", 1, true))
        assert.truthy(call({ photo_id = "1", mask_id = "mask-a", adjustments = {} })
            :find("adjustments is required", 1, true))
        assert.truthy(call({ photo_id = "1", mask_id = "mask-a" }):find("adjustments is required", 1, true))
        assert.truthy(call({ mask_id = "mask-a", adjustments = { local_Tint = 1 } })
            :find("photo_id is required", 1, true))
        assert.truthy(call({ photo_id = "1", adjustments = { local_Tint = 1 } })
            :find("mask_id is required", 1, true))
        assert.truthy(call({ photo_id = "1", mask_id = 5, adjustments = { local_Tint = 1 } })
            :find("mask_id is required", 1, true))
        assert.are.equal(0, #calls.modules)
    end)

    it("names the unknown mask, changes no mask and restores the view", function()
        local Handler, calls, _, valuesOf, photos = setup(everyPhotoAndMask(twoMasks()))

        local err = errorOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "nope", adjustments = { local_Contrast = 1 } })
        end)

        assert.truthy(err:find("Mask not found on photo 1: nope", 1, true))
        assert.truthy(err:find("mask-a, mask-b", 1, true))
        assert.are.equal(0, #calls.setValue)
        assert.are.equal(0, #calls.selectMask)
        assert.are.equal(10, valuesOf[photos[1]]["mask-a"].local_Contrast)
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("reports a photo without masks as having no such mask", function()
        local Handler, calls = setup({ photos = { { id = "1", masks = {} } } })

        local err = errorOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "m", adjustments = { local_Contrast = 1 } })
        end)

        assert.truthy(err:find("Mask not found on photo 1: m (masks on this photo: none)", 1, true))
        assert.are.equal(0, #calls.setValue)
    end)

    it("names the photo when it is unknown and never touches Develop", function()
        local Handler, calls = setup(everyPhotoAndMask(twoMasks()))

        local err = errorOf(function()
            Handler.setMaskAdjustments({ photo_id = "404", mask_id = "mask-a", adjustments = { local_Tint = 1 } })
        end)

        assert.truthy(err:find("Photo not found: 404", 1, true))
        assert.are.equal(0, #calls.modules)
    end)

    it("fails when Lightroom never selects the mask", function()
        local Handler, calls = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            selectIgnored = true,
        })

        local err = errorOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Contrast = 1 } })
        end)

        assert.truthy(err:find("Could not select mask mask-a on photo 1", 1, true))
        assert.are.equal(0, #calls.setValue)
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("fails before writing when a slider cannot be read on the mask", function()
        local Handler, calls = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            unreadable = { local_Shadows = true },
        })

        local err = errorOf(function()
            Handler.setMaskAdjustments({
                photo_id = "1",
                mask_id = "mask-a",
                adjustments = { local_Contrast = 1, local_Shadows = 2 },
            })
        end)

        assert.truthy(err:find("local_Shadows is not available on mask mask-a", 1, true))
        assert.are.equal(0, #calls.setValue)
    end)

    it("accepts a value Lightroom rounds to a whole number", function()
        local Handler = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            roundSet = true,
        })

        local r = Handler.setMaskAdjustments({
            photo_id = "1",
            mask_id = "mask-a",
            adjustments = { local_Contrast = 12.4 },
        })

        assert.are.same({ local_Contrast = 12 }, r.adjustments)
        assert.are.equal(12, r.changed[1].to)
    end)

    it("retries a write Lightroom ignored once, then fails naming the slider", function()
        local Handler, calls = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            ignoreSet = { local_Contrast = true },
        })

        local err = errorOf(function()
            Handler.setMaskAdjustments({
                photo_id = "1",
                mask_id = "mask-a",
                adjustments = { local_Exposure = 2, local_Contrast = 40 },
            })
        end)

        assert.truthy(err:find("Lightroom did not keep local_Contrast 40 (reads 10)", 1, true))
        assert.truthy(err:find("already written: local_Exposure", 1, true))
        assert.are.equal(3, #calls.setValue)
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("fails when Lightroom drops a change after showing it", function()
        local Handler = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            revertAfterSettle = { local_Contrast = 10 },
        })

        local err = errorOf(function()
            Handler.setMaskAdjustments({
                photo_id = "1",
                mask_id = "mask-a",
                adjustments = { local_Contrast = 40 },
            })
        end)

        assert.truthy(err:find("Lightroom did not keep local_Contrast 40 (reads 10)", 1, true))
    end)

    it("waits until Lightroom has saved the sliders to the photo's settings before returning", function()
        local Handler, _, _, _, photos = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            commitLagSleeps = 12,
        })

        local r = Handler.setMaskAdjustments({
            photo_id = "1",
            mask_id = "mask-a",
            adjustments = { local_Exposure = 2, local_Contrast = 40 },
        })

        assert.is_true(r.success)
        local stored = photos[1]:getDevelopSettings().MaskGroupBasedCorrections
        local savedExposure
        for _, entry in ipairs(stored) do
            if entry.CorrectionID == "mask-a" then savedExposure = entry["Locallocal_Exposure"] end
        end
        assert.are.equal(2, savedExposure)
    end)

    it("commits the sliders to the photo with a forced flush instead of waiting for Lightroom's own timer", function()
        local Handler, calls, _, _, photos = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            commitLagSleeps = 100000,
        })

        local r = Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Exposure = 2 } })

        assert.is_true(r.success)
        assert.are.same({ true }, calls.stopTracking)
        local savedExposure
        for _, entry in ipairs(photos[1]:getDevelopSettings().MaskGroupBasedCorrections) do
            if entry.CorrectionID == "mask-a" then savedExposure = entry["Locallocal_Exposure"] end
        end
        assert.are.equal(2, savedExposure)
    end)

    it("works on a Lightroom without stopTracking by waiting for the save", function()
        local Handler = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            commitLagSleeps = 12,
            withoutStopTracking = true,
        })

        local r = Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Exposure = 2 } })

        assert.is_true(r.success)
    end)

    it("flushes edits pending on a photo already open in Develop before touching it", function()
        local Handler, calls = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            startModule = "develop",
        })

        Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Exposure = 0.5 } })

        assert.are.same({ true }, calls.stopTracking)
    end)

    it("does not flush when it has to open the photo, which Lightroom saves on switching", function()
        local Handler, calls = setup({
            photos = {
                { id = "1" },
                { id = "2", masks = twoMasks(), selectedMask = "mask-b" },
            },
            startModule = "develop",
        })

        Handler.setMaskAdjustments({ photo_id = "2", mask_id = "mask-a", adjustments = { local_Exposure = 0.5 } })

        assert.are.same({}, calls.stopTracking)
    end)

    it("does not wait for a save when no slider changed", function()
        local Handler = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            neverCommit = true,
        })

        local r = Handler.setMaskAdjustments({
            photo_id = "1",
            mask_id = "mask-a",
            adjustments = { local_Exposure = 0.5 },
        })

        assert.are.same({}, r.changed)
    end)

    it("fails naming the late save when Lightroom never saves the sliders", function()
        local Handler = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            neverCommit = true,
        })

        local err = errorOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Exposure = 2 } })
        end)

        assert.truthy(err:find("had not saved them to the photo's settings after 8 s", 1, true))
        assert.truthy(err:find("already written: local_Exposure", 1, true))
    end)

    it("fails when the mask is absent from the photo's saved settings", function()
        local Handler = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            maskMissingFromStore = true,
        })

        local err = errorOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Exposure = 2 } })
        end)

        assert.truthy(err:find("had not saved them", 1, true))
    end)

    it("surfaces the error when Lightroom rejects a write", function()
        local Handler = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            rejectSet = { local_Contrast = "slider is disabled" },
        })

        local err = errorOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Contrast = 40 } })
        end)

        assert.truthy(err:find("Lightroom rejected local_Contrast 40", 1, true))
        assert.truthy(err:find("slider is disabled", 1, true))
    end)

    it("fails when another mask became selected while writing", function()
        local Handler = setup({
            photos = { { id = "1", masks = twoMasks(), selectedMask = "mask-b" } },
            stealSelectionOnSet = "mask-b",
        })

        local err = errorOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Exposure = 2 } })
        end)

        assert.truthy(err:find("Another mask became selected while writing", 1, true))
    end)

    it("names the minimum Lightroom version when the mask API is missing", function()
        local Handler, calls = setup({ photos = { { id = "1" } }, withoutMaskApi = true })

        local err = errorOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "m", adjustments = { local_Tint = 1 } })
        end)

        assert.truthy(err:find("set_mask_adjustments needs Lightroom Classic 11 or later", 1, true))
        assert.are.equal(0, #calls.modules)
    end)

    it("names the minimum Lightroom version when setValue is missing", function()
        local Handler = setup({ photos = { { id = "1" } }, withoutSetValue = true })

        local err = errorOf(function()
            Handler.setMaskAdjustments({ photo_id = "1", mask_id = "m", adjustments = { local_Tint = 1 } })
        end)

        assert.truthy(err:find("needs Lightroom Classic 11 or later", 1, true))
    end)

    it("opens no catalog gate", function()
        local Handler, _, catalog = setup(everyPhotoAndMask(twoMasks()))

        Handler.setMaskAdjustments({ photo_id = "1", mask_id = "mask-a", adjustments = { local_Contrast = 1 } })

        assert.are.equal(0, catalog.getWriteAccessCount())
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)
end)


describe("LocalSliders", function()
    it("lists unique local_ names with an ordered fallback range", function()
        local LocalSliders = require 'LocalSliders'
        local seen = {}

        for _, slider in ipairs(LocalSliders.list) do
            assert.truthy(slider.name:match("^local_%a+$"))
            assert.is_nil(seen[slider.name])
            seen[slider.name] = true
            assert.is_true(slider.fallbackMin < slider.fallbackMax)
            assert.is_true(slider.tolerance > 0)
            assert.are.equal(slider, LocalSliders.byName[slider.name])
        end
        assert.are.equal(#LocalSliders.list, #LocalSliders.names())
    end)
end)
