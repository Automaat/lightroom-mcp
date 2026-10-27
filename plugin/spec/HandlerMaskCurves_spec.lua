local fake = require 'fake_mask_develop'

local LINE = { 0, 0, 255, 255 }

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

local function setup(overrides)
    local opts = {
        photos = {
            {
                id = "1",
                selectedMask = "mask-b",
                masks = {
                    ["mask-a"] = {
                        local_Maincurve = { 0, 0, 255, 255 },
                        local_Redcurve = { 0, 0, 255, 255 },
                        local_Greencurve = { 0, 0, 255, 255 },
                        local_Bluecurve = { 0, 0, 255, 255 },
                        local_Exposure = 0.5,
                    },
                    ["mask-b"] = {
                        local_Maincurve = { 0, 0, 100, 120, 255, 255 },
                        local_Redcurve = { 0, 0, 255, 255 },
                        local_Greencurve = { 0, 0, 255, 255 },
                        local_Bluecurve = { 0, 0, 255, 255 },
                    },
                },
            },
            { id = "2" },
        },
        modules = { "HandlerMaskCurves", "MaskCurves", "MaskSelection", "DevelopSession", "MaskSettle" },
        handler = "HandlerMaskCurves",
    }
    for key, value in pairs(overrides or {}) do opts[key] = value end
    return fake.build(opts)
end

describe("HandlerMaskCurves.setMaskCurves", function()
    it("sets the requested channels of the requested mask only", function()
        local ctx = setup()
        local before = fake.deepCopy(ctx.valuesOf[ctx.photos[1]]["mask-b"])

        local r = ctx.Handler.setMaskCurves({
            photo_id = "1",
            mask_id = "mask-a",
            curves = { main = { 0, 0, 64, 48, 192, 210, 255, 255 }, blue = { 0, 10, 255, 240 } },
        })

        assert.is_true(r.success)
        assert.are.equal("mask-a", r.mask_id)
        assert.are.same({ 0, 0, 64, 48, 192, 210, 255, 255 }, r.curves.main)
        assert.are.same({ 0, 10, 255, 240 }, r.curves.blue)
        assert.are.same({ "main", "blue" }, { r.changed[1].channel, r.changed[2].channel })
        assert.are.same(LINE, r.changed[1].from)
        assert.are.same({}, r.unchanged)
        local maskA = ctx.valuesOf[ctx.photos[1]]["mask-a"]
        assert.are.same({ 0, 0, 64, 48, 192, 210, 255, 255 }, maskA.local_Maincurve)
        assert.are.same(LINE, maskA.local_Redcurve)
        assert.are.equal(0.5, maskA.local_Exposure)
        assert.are.same(before, ctx.valuesOf[ctx.photos[1]]["mask-b"])
        assert.are.equal(2, #ctx.calls.setValue)
    end)

    it("writes channels in a fixed order whatever the key order", function()
        local ctx = setup()

        ctx.Handler.setMaskCurves({
            photo_id = "1",
            mask_id = "mask-a",
            curves = { blue = { 0, 5, 255, 255 }, red = { 0, 6, 255, 255 }, main = { 0, 7, 255, 255 } },
        })

        local order = {}
        for _, call in ipairs(ctx.calls.setValue) do order[#order + 1] = call[1] end
        assert.are.same({ "local_Maincurve", "local_Redcurve", "local_Bluecurve" }, order)
    end)

    it("skips a channel already at the value and writes nothing when all are", function()
        local ctx = setup()

        local r = ctx.Handler.setMaskCurves({
            photo_id = "1",
            mask_id = "mask-a",
            curves = { main = LINE, red = LINE },
        })

        assert.are.same({}, r.changed)
        assert.are.same({ "main", "red" }, r.unchanged)
        assert.are.equal(0, #ctx.calls.setValue)
    end)

    it("puts back the previously selected mask, module and photo selection", function()
        local ctx = setup()

        ctx.Handler.setMaskCurves({ photo_id = "1", mask_id = "mask-a", curves = { main = { 0, 9, 255, 255 } } })

        assert.are.same({ "develop", "library" }, ctx.calls.modules)
        assert.are.equal("mask-b", ctx.calls.selectMask[#ctx.calls.selectMask])
        assert.are.equal("mask-b", ctx.selectedMaskOf[ctx.photos[1]])
    end)

    it("rejects an unknown mask naming the masks on the photo, writing nothing", function()
        local ctx = setup()

        local err = errorOf(function()
            ctx.Handler.setMaskCurves({ photo_id = "1", mask_id = "nope", curves = { main = LINE } })
        end)

        assert.truthy(err:find("Mask not found on photo 1: nope", 1, true))
        assert.truthy(err:find("mask-a, mask-b", 1, true))
        assert.are.equal(0, #ctx.calls.setValue)
    end)

    it("rejects an unknown photo", function()
        local ctx = setup()

        local err = errorOf(function()
            ctx.Handler.setMaskCurves({ photo_id = "99", mask_id = "mask-a", curves = { main = LINE } })
        end)

        assert.truthy(err:find("Photo not found: 99", 1, true))
    end)

    local invalidCurves = {
        { "a non-table", "bad", "curves is required" },
        { "an empty table", {}, "curves is required" },
        { "an unknown channel", { alpha = LINE }, "Unknown curve channel alpha" },
        { "a single point", { main = { 0, 0 } }, "curves.main must contain 2 to 32 input/output pairs" },
        { "an odd count", { main = { 0, 0, 100, 255, 255 } }, "curves.main must contain 2 to 32 input/output pairs" },
        { "too many pairs", { main = (function()
            local points = {}
            for index = 0, 32 do
                points[#points + 1] = index * 7
                points[#points + 1] = index * 7
            end
            return points
        end)() }, "curves.main must contain 2 to 32 input/output pairs" },
        { "a value over 255", { main = { 0, 0, 255, 256 } }, "curves.main[4] must be an integer from 0 to 255" },
        { "a fractional value", { main = { 0, 0, 12.5, 100, 255, 255 } }, "curves.main[3] must be an integer from 0 to 255" },
        { "a string value", { main = { 0, 0, "x", 100, 255, 255 } }, "curves.main[3] must be an integer from 0 to 255" },
        { "a first input over 0", { main = { 1, 0, 255, 255 } }, "must start at input 0 and end at input 255" },
        { "a last input under 255", { main = { 0, 0, 200, 255 } }, "must start at input 0 and end at input 255" },
        { "inputs not increasing", { main = { 0, 0, 100, 50, 100, 60, 255, 255 } }, "inputs must be strictly increasing" },
        { "a sparse array", { main = { [1] = 0, [2] = 0, [4] = 255, [5] = 255 } }, "must be an array" },
    }
    for _, case in ipairs(invalidCurves) do
        it("rejects " .. case[1] .. " before opening Develop", function()
            local ctx = setup()

            local err = errorOf(function()
                ctx.Handler.setMaskCurves({ photo_id = "1", mask_id = "mask-a", curves = case[2] })
            end)

            assert.truthy(err:find(case[3], 1, true), err)
            assert.are.equal(0, #ctx.calls.setValue)
            assert.are.same({}, ctx.calls.modules)
        end)
    end

    it("requires photo_id and mask_id", function()
        local ctx = setup()

        assert.truthy(errorOf(function() ctx.Handler.setMaskCurves({ mask_id = "mask-a", curves = { main = LINE } }) end)
            :find("photo_id is required", 1, true))
        assert.truthy(errorOf(function() ctx.Handler.setMaskCurves({ photo_id = "1", curves = { main = LINE } }) end)
            :find("mask_id is required", 1, true))
    end)

    it("names the minimum version when Lightroom is older, before any Develop work", function()
        local ctx = setup({ version = { major = 12, minor = 2 } })

        local err = errorOf(function()
            ctx.Handler.setMaskCurves({ photo_id = "1", mask_id = "mask-a", curves = { main = LINE } })
        end)

        assert.truthy(err:find("set_mask_curves needs Lightroom Classic 12.3 or later", 1, true))
        assert.truthy(err:find("this is Lightroom Classic 12.2", 1, true))
        assert.are.same({}, ctx.calls.modules)
    end)

    it("accepts Lightroom Classic 12.3 exactly", function()
        local ctx = setup({ version = { major = 12, minor = 3 } })

        local r = ctx.Handler.setMaskCurves({ photo_id = "1", mask_id = "mask-a", curves = { main = { 0, 9, 255, 255 } } })

        assert.is_true(r.success)
    end)

    it("names the minimum version when the controller lacks the mask API", function()
        local ctx = setup({ extend = function(controller)
            controller.getAllMasks, controller.selectMask, controller.selectMaskTool = nil, nil, nil
        end })

        local err = errorOf(function()
            ctx.Handler.setMaskCurves({ photo_id = "1", mask_id = "mask-a", curves = { main = LINE } })
        end)

        assert.truthy(err:find("needs Lightroom Classic 11 or later", 1, true))
    end)

    it("fails naming the minimum version when Lightroom returns no curve, writing nothing", function()
        local ctx = setup({ photos = {
            { id = "1", selectedMask = "mask-a", masks = { ["mask-a"] = { local_Exposure = 0 } } },
        } })

        local err = errorOf(function()
            ctx.Handler.setMaskCurves({ photo_id = "1", mask_id = "mask-a", curves = { main = LINE, red = LINE } })
        end)

        assert.truthy(err:find("Local tone curve main, red of mask mask-a on photo 1 cannot be read", 1, true))
        assert.truthy(err:find("local curves need Lightroom Classic 12.3 or later", 1, true))
        assert.truthy(err:find("nothing was written", 1, true))
        assert.are.equal(0, #ctx.calls.setValue)
    end)

    it("reports a write Lightroom rejects and keeps earlier channels restored", function()
        local ctx = setup({ rejectSet = { local_Bluecurve = "curve refused" } })

        local err = errorOf(function()
            ctx.Handler.setMaskCurves({
                photo_id = "1",
                mask_id = "mask-a",
                curves = { main = { 0, 9, 255, 255 }, blue = { 0, 9, 255, 255 } },
            })
        end)

        assert.truthy(err:find("Lightroom rejected the blue curve: ", 1, true))
        assert.truthy(err:find("curve refused", 1, true))
    end)

    it("restores written channels when Lightroom ignores a later write", function()
        local ctx = setup({ ignoreSet = { local_Redcurve = true } })

        local err = errorOf(function()
            ctx.Handler.setMaskCurves({
                photo_id = "1",
                mask_id = "mask-a",
                curves = { main = { 0, 9, 255, 255 }, red = { 0, 9, 255, 255 } },
            })
        end)

        assert.truthy(err:find("Lightroom did not keep the red curve; restored: main, red", 1, true))
        assert.are.same(LINE, ctx.valuesOf[ctx.photos[1]]["mask-a"].local_Maincurve)
    end)

    it("fails and restores when a change is dropped after the settle wait", function()
        local ctx = setup({ onSleep = function(state)
            if #state.calls.setValue > 0 then
                state.valuesOf[state.photos[1]]["mask-a"].local_Maincurve = { 0, 0, 255, 255 }
            end
        end })

        local err = errorOf(function()
            ctx.Handler.setMaskCurves({ photo_id = "1", mask_id = "mask-a", curves = { main = { 0, 9, 255, 255 } } })
        end)

        assert.truthy(err:find("Lightroom did not keep the main curve", 1, true), err)
        assert.are.same(LINE, ctx.valuesOf[ctx.photos[1]]["mask-a"].local_Maincurve)
    end)

    it("waits until Lightroom has saved the curves to the photo's settings before returning", function()
        local ctx = setup({ commitLagSleeps = 15 })

        ctx.Handler.setMaskCurves({ photo_id = "1", mask_id = "mask-a", curves = { main = { 0, 9, 255, 255 } } })

        local saved
        for _, entry in ipairs(ctx.photos[1]:getDevelopSettings().MaskGroupBasedCorrections) do
            if entry.CorrectionID == "mask-a" then saved = entry.Stored_local_Maincurve end
        end
        assert.are.same({ 0, 9, 255, 255 }, saved)
    end)

    it("commits the curves to the photo with a forced flush", function()
        local ctx = setup({ commitLagSleeps = 100000 })

        ctx.Handler.setMaskCurves({ photo_id = "1", mask_id = "mask-a", curves = { main = { 0, 9, 255, 255 } } })

        assert.are.same({ true }, ctx.calls.stopTracking)
    end)

    it("fails naming the late save when Lightroom never saves the curves", function()
        local ctx = setup({ neverCommit = true })

        local err = errorOf(function()
            ctx.Handler.setMaskCurves({ photo_id = "1", mask_id = "mask-a", curves = { main = { 0, 9, 255, 255 } } })
        end)

        assert.truthy(err:find("had not saved them to the photo's settings after 8 s", 1, true))
        assert.truthy(err:find("written: main", 1, true))
    end)

    it("does not wait for a save when no curve changed", function()
        local ctx = setup({ neverCommit = true })

        local r = ctx.Handler.setMaskCurves({ photo_id = "1", mask_id = "mask-a", curves = { main = LINE } })

        assert.are.same({}, r.changed)
    end)

    it("fails when another mask becomes selected while writing", function()
        local ctx = setup()
        ctx.controller.setValue = (function(original)
            return function(name, value)
                original(name, value)
                ctx.selectedMaskOf[ctx.photos[1]] = "mask-b"
            end
        end)(ctx.controller.setValue)

        local err = errorOf(function()
            ctx.Handler.setMaskCurves({ photo_id = "1", mask_id = "mask-a", curves = { main = { 0, 9, 255, 255 } } })
        end)

        assert.truthy(err:find("Another mask became selected while writing", 1, true), err)
    end)
end)
