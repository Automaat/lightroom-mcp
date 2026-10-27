local fake = require 'fake_mask_develop'

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

local function swatch(hue, extra)
    local value = {
        SrcHue = hue,
        SrcSat = 0.5,
        SrcLum = 0.5,
        HueShift = 0,
        SatScale = 0,
        LumScale = 0,
        RangeAmount = 0.5,
        HueRange = { LowerNone = 0, LowerFull = 0.2, UpperFull = 0.8, UpperNone = 1 },
        SatRange = { LowerNone = 0, LowerFull = 0.2, UpperFull = 0.8, UpperNone = 1 },
        LumRange = { LowerNone = 0, LowerFull = 0.2, UpperFull = 0.8, UpperNone = 1 },
    }
    for key, item in pairs(extra or {}) do value[key] = item end
    return value
end

local function setup(overrides)
    overrides = overrides or {}
    local selectedSwatch = {}
    local controllerCalls = { add = 0, update = 0, delete = 0, select = {} }

    local function swatchesOf(ctx)
        local values = ctx.requireMask()
        values.local_PointColors = values.local_PointColors or {}
        return values.local_PointColors
    end

    local function requireMasking(forMasking)
        if forMasking ~= true then error("isForMasking must be true") end
    end

    local opts = {
        photos = {
            {
                id = "1",
                selectedMask = "mask-b",
                masks = {
                    ["mask-a"] = { local_PointColors = { swatch(1), swatch(2, { SrcSat = 0.9 }) } },
                    ["mask-b"] = { local_PointColors = { swatch(3) } },
                    ["mask-c"] = {},
                },
            },
            { id = "2" },
        },
        modules = { "HandlerMaskPointColors", "MaskPointColors", "MaskSelection", "DevelopSession" },
        handler = "HandlerMaskPointColors",
        extend = function(controller, ctx)
            ctx.controllerCalls = controllerCalls
            ctx.selectedSwatch = selectedSwatch
            controller.getSelectedPointColorSwatchIndex = function(forMasking)
                requireMasking(forMasking)
                return selectedSwatch[ctx.selectedMaskOf[ctx.active]] or 0
            end
            controller.selectPointColorSwatch = function(index, forMasking)
                requireMasking(forMasking)
                controllerCalls.select[#controllerCalls.select + 1] = index
                if index <= #swatchesOf(ctx) then
                    selectedSwatch[ctx.selectedMaskOf[ctx.active]] = index
                end
            end
            controller.addPointColorSwatch = function(wanted, forMasking)
                requireMasking(forMasking)
                controllerCalls.add = controllerCalls.add + 1
                if overrides.rejectAdd then error(overrides.rejectAdd) end
                if overrides.refuseAdd then return false, overrides.refuseAdd end
                local list = swatchesOf(ctx)
                for index, existing in ipairs(list) do
                    if existing.SrcHue == wanted.SrcHue and existing.SrcSat == wanted.SrcSat
                        and existing.SrcLum == wanted.SrcLum then
                        selectedSwatch[ctx.selectedMaskOf[ctx.active]] = index
                        return true
                    end
                end
                if overrides.ignoreAdd then return true end
                local added = swatch(wanted.SrcHue, fake.deepCopy(wanted))
                if overrides.alterAdd then added.HueShift = overrides.alterAdd end
                list[#list + 1] = added
                selectedSwatch[ctx.selectedMaskOf[ctx.active]] = #list
                return true
            end
            controller.updateSelectedPointColorSwatch = function(updated, forMasking)
                requireMasking(forMasking)
                controllerCalls.update = controllerCalls.update + 1
                if overrides.refuseUpdate then return false, overrides.refuseUpdate end
                if overrides.ignoreUpdate then return true end
                local index = selectedSwatch[ctx.selectedMaskOf[ctx.active]]
                swatchesOf(ctx)[index] = fake.deepCopy(updated)
                return true
            end
            controller.deletePointColorSwatch = function(deleteAll, index, forMasking)
                requireMasking(forMasking)
                controllerCalls.delete = controllerCalls.delete + 1
                if overrides.ignoreDelete then return true end
                local list = swatchesOf(ctx)
                if deleteAll then
                    while #list > 0 do table.remove(list) end
                    return true
                end
                if index < 1 or index > #list then return false end
                table.remove(list, index)
                return true
            end
            if overrides.extend then overrides.extend(controller, ctx) end
        end,
        onSleep = overrides.onSleep,
        version = overrides.version,
    }
    return fake.build(opts)
end

local function listOf(ctx, photoIndex, maskId)
    return ctx.valuesOf[ctx.photos[photoIndex or 1]][maskId].local_PointColors
end

describe("HandlerMaskPointColors.editMaskPointColors add", function()
    it("adds a swatch to the requested mask only", function()
        local ctx = setup()
        local otherBefore = fake.deepCopy(listOf(ctx, 1, "mask-b"))

        local r = ctx.Handler.editMaskPointColors({
            photo_id = "1",
            mask_id = "mask-a",
            action = "add",
            swatch = { SrcHue = 4, SrcSat = 0.3, SrcLum = 0.7, HueShift = 0.25 },
        })

        assert.is_true(r.success)
        assert.are.equal("add", r.action)
        assert.are.equal(3, r.index)
        assert.is_true(r.changed)
        assert.are.equal(3, #r.swatches)
        assert.are.equal(3, r.swatches[3].index)
        assert.are.equal(0.25, r.swatches[3].HueShift)
        assert.are.equal(3, #listOf(ctx, 1, "mask-a"))
        assert.are.same(otherBefore, listOf(ctx, 1, "mask-b"))
        assert.are.equal(1, ctx.controllerCalls.add)
    end)

    it("works on a mask that has no swatch list yet", function()
        local ctx = setup()

        local r = ctx.Handler.editMaskPointColors({
            photo_id = "1",
            mask_id = "mask-c",
            action = "add",
            swatch = { SrcHue = 1, SrcSat = 0.2, SrcLum = 0.2 },
        })

        assert.are.equal(1, r.index)
        assert.are.equal(1, #r.swatches)
    end)

    it("refuses a duplicate source color without adding", function()
        local ctx = setup()

        local err = errorOf(function()
            ctx.Handler.editMaskPointColors({
                photo_id = "1",
                mask_id = "mask-a",
                action = "add",
                swatch = { SrcHue = 1, SrcSat = 0.5, SrcLum = 0.5 },
            })
        end)

        assert.truthy(err:find("already has a swatch with that source color at index 1", 1, true), err)
        assert.are.equal(2, #listOf(ctx, 1, "mask-a"))
    end)

    it("refuses a ninth swatch before calling Lightroom", function()
        local list = {}
        for index = 1, 8 do list[index] = swatch(index / 2) end
        local ctx = setup({ extend = function(_, state)
            state.valuesOf[state.photos[1]]["mask-c"].local_PointColors = list
        end })

        local err = errorOf(function()
            ctx.Handler.editMaskPointColors({
                photo_id = "1",
                mask_id = "mask-c",
                action = "add",
                swatch = { SrcHue = 5.5, SrcSat = 0.1, SrcLum = 0.1 },
            })
        end)

        assert.truthy(err:find("already holds 8 Point Color swatches", 1, true))
        assert.are.equal(0, ctx.controllerCalls.add)
    end)

    it("reports a refusal from Lightroom with its message", function()
        local ctx = setup({ refuseAdd = "swatch not allowed" })

        local err = errorOf(function()
            ctx.Handler.editMaskPointColors({
                photo_id = "1",
                mask_id = "mask-a",
                action = "add",
                swatch = { SrcHue = 4, SrcSat = 0.3, SrcLum = 0.7 },
            })
        end)

        assert.truthy(err:find("Lightroom refused the new Point Color swatch: swatch not allowed", 1, true))
    end)

    it("reports a call Lightroom rejects", function()
        local ctx = setup({ rejectAdd = "boom" })

        local err = errorOf(function()
            ctx.Handler.editMaskPointColors({
                photo_id = "1",
                mask_id = "mask-a",
                action = "add",
                swatch = { SrcHue = 4, SrcSat = 0.3, SrcLum = 0.7 },
            })
        end)

        assert.truthy(err:find("Lightroom rejected the new Point Color swatch: ", 1, true))
        assert.truthy(err:find("boom", 1, true))
    end)

    it("fails when Lightroom says yes but adds nothing", function()
        local ctx = setup({ ignoreAdd = true })

        local err = errorOf(function()
            ctx.Handler.editMaskPointColors({
                photo_id = "1",
                mask_id = "mask-a",
                action = "add",
                swatch = { SrcHue = 4, SrcSat = 0.3, SrcLum = 0.7 },
            })
        end)

        assert.truthy(err:find("Lightroom did not add the Point Color swatch to mask mask-a", 1, true))
    end)

    it("removes the new swatch when Lightroom stores other values", function()
        local ctx = setup({ alterAdd = -0.9 })

        local err = errorOf(function()
            ctx.Handler.editMaskPointColors({
                photo_id = "1",
                mask_id = "mask-a",
                action = "add",
                swatch = { SrcHue = 4, SrcSat = 0.3, SrcLum = 0.7, HueShift = 0.25 },
            })
        end)

        assert.truthy(err:find("the new swatch was removed", 1, true))
        assert.are.equal(2, #listOf(ctx, 1, "mask-a"))
    end)
end)

describe("HandlerMaskPointColors.editMaskPointColors update", function()
    it("changes only the given fields of the numbered swatch", function()
        local ctx = setup()
        local untouched = fake.deepCopy(listOf(ctx, 1, "mask-a")[1])

        local r = ctx.Handler.editMaskPointColors({
            photo_id = "1",
            mask_id = "mask-a",
            action = "update",
            index = 2,
            swatch = {
                SatScale = 0.4,
                HueRange = { LowerNone = 0.1, LowerFull = 0.3, UpperFull = 0.7, UpperNone = 0.9 },
            },
        })

        assert.is_true(r.changed)
        assert.are.equal(2, r.index)
        local list = listOf(ctx, 1, "mask-a")
        assert.are.equal(0.4, list[2].SatScale)
        assert.are.equal(0.9, list[2].SrcSat)
        assert.are.equal(0.9, list[2].HueRange.UpperNone)
        assert.are.equal(0.8, list[2].SatRange.UpperFull)
        assert.are.same(untouched, list[1])
        assert.are.equal(1, ctx.controllerCalls.update)
    end)

    it("selects the numbered swatch, then restores the previous selection", function()
        local ctx = setup()
        ctx.selectedSwatch["mask-a"] = 2

        ctx.Handler.editMaskPointColors({
            photo_id = "1",
            mask_id = "mask-a",
            action = "update",
            index = 1,
            swatch = { LumScale = -0.5 },
        })

        assert.are.same({ 1, 2 }, ctx.controllerCalls.select)
        assert.are.equal(2, ctx.selectedSwatch["mask-a"])
    end)

    it("does not call Lightroom when nothing changes", function()
        local ctx = setup()

        local r = ctx.Handler.editMaskPointColors({
            photo_id = "1",
            mask_id = "mask-b",
            action = "update",
            index = 1,
            swatch = { HueShift = 0, SrcHue = 3 },
        })

        assert.is_false(r.changed)
        assert.are.equal(0, ctx.controllerCalls.update)
    end)

    it("rejects an index past the last swatch naming the count", function()
        local ctx = setup()

        local err = errorOf(function()
            ctx.Handler.editMaskPointColors({
                photo_id = "1",
                mask_id = "mask-b",
                action = "update",
                index = 2,
                swatch = { HueShift = 0.1 },
            })
        end)

        assert.truthy(err:find("No swatch at index 2 on mask mask-b (the mask has 1)", 1, true))
    end)

    it("restores the original swatch when Lightroom drops the update", function()
        local ctx = setup({ ignoreUpdate = true })

        local err = errorOf(function()
            ctx.Handler.editMaskPointColors({
                photo_id = "1",
                mask_id = "mask-b",
                action = "update",
                index = 1,
                swatch = { HueShift = 0.3 },
            })
        end)

        assert.truthy(err:find("Lightroom did not keep the update of swatch 1", 1, true))
        assert.are.equal(2, ctx.controllerCalls.update - 1)
        assert.are.equal(0, listOf(ctx, 1, "mask-b")[1].HueShift)
    end)

    it("reports a refusal from Lightroom", function()
        local ctx = setup({ refuseUpdate = "nope" })

        local err = errorOf(function()
            ctx.Handler.editMaskPointColors({
                photo_id = "1",
                mask_id = "mask-b",
                action = "update",
                index = 1,
                swatch = { HueShift = 0.3 },
            })
        end)

        assert.truthy(err:find("Lightroom refused the Point Color swatch update: nope", 1, true))
    end)

    it("fails when the update is dropped after the settle wait", function()
        local ctx = setup({ onSleep = function(state)
            if state.controllerCalls.update > 0 then
                state.valuesOf[state.photos[1]]["mask-b"].local_PointColors[1].HueShift = 0
            end
        end })

        local err = errorOf(function()
            ctx.Handler.editMaskPointColors({
                photo_id = "1",
                mask_id = "mask-b",
                action = "update",
                index = 1,
                swatch = { HueShift = 0.3 },
            })
        end)

        assert.truthy(err:find("Lightroom did not keep the update of swatch 1", 1, true), err)
    end)
end)

describe("HandlerMaskPointColors.editMaskPointColors delete and clear", function()
    it("deletes the numbered swatch and keeps the others in order", function()
        local ctx = setup()

        local r = ctx.Handler.editMaskPointColors({
            photo_id = "1",
            mask_id = "mask-a",
            action = "delete",
            index = 1,
        })

        assert.is_true(r.changed)
        assert.are.equal(1, #r.swatches)
        assert.are.equal(2, r.swatches[1].SrcHue)
        assert.are.equal(1, #listOf(ctx, 1, "mask-b"))
    end)

    it("rejects an index past the last swatch without deleting", function()
        local ctx = setup()

        local err = errorOf(function()
            ctx.Handler.editMaskPointColors({ photo_id = "1", mask_id = "mask-b", action = "delete", index = 3 })
        end)

        assert.truthy(err:find("No swatch at index 3 on mask mask-b (the mask has 1)", 1, true))
        assert.are.equal(0, ctx.controllerCalls.delete)
    end)

    it("fails when Lightroom says yes but deletes nothing", function()
        local ctx = setup({ ignoreDelete = true })

        local err = errorOf(function()
            ctx.Handler.editMaskPointColors({ photo_id = "1", mask_id = "mask-a", action = "delete", index = 1 })
        end)

        assert.truthy(err:find("Lightroom did not delete swatch 1 of mask mask-a", 1, true))
    end)

    it("clears every swatch of the mask only", function()
        local ctx = setup()

        local r = ctx.Handler.editMaskPointColors({ photo_id = "1", mask_id = "mask-a", action = "clear" })

        assert.is_true(r.changed)
        assert.are.same({}, r.swatches)
        assert.are.equal(1, #listOf(ctx, 1, "mask-b"))
    end)

    it("does not call Lightroom to clear a mask without swatches", function()
        local ctx = setup()

        local r = ctx.Handler.editMaskPointColors({ photo_id = "1", mask_id = "mask-c", action = "clear" })

        assert.is_false(r.changed)
        assert.are.equal(0, ctx.controllerCalls.delete)
    end)

    it("fails when Lightroom does not clear", function()
        local ctx = setup({ ignoreDelete = true })

        local err = errorOf(function()
            ctx.Handler.editMaskPointColors({ photo_id = "1", mask_id = "mask-a", action = "clear" })
        end)

        assert.truthy(err:find("Lightroom did not clear the Point Color swatches of mask mask-a", 1, true))
    end)
end)

describe("HandlerMaskPointColors.editMaskPointColors validation", function()
    local invalid = {
        { "a missing action", {}, "action is required" },
        { "an unknown action", { action = "rename" }, "action is required" },
        { "add without a swatch", { action = "add" }, "swatch is required" },
        { "add without a source color", { action = "add", swatch = { SrcHue = 1, SrcSat = 0.5 } }, "swatch.SrcLum is required" },
        { "add with an index", { action = "add", index = 1, swatch = { SrcHue = 1, SrcSat = 0.5, SrcLum = 0.5 } }, "index is not used by add" },
        { "a hue over 6", { action = "add", swatch = { SrcHue = 6.5, SrcSat = 0.5, SrcLum = 0.5 } }, "swatch.SrcHue 6.5 is outside its range 0 to 6" },
        { "a shift under -1", { action = "update", index = 1, swatch = { HueShift = -1.5 } }, "swatch.HueShift -1.5 is outside its range -1 to 1" },
        { "a string number", { action = "update", index = 1, swatch = { SatScale = "x" } }, "swatch.SatScale must be a number" },
        { "an unknown swatch field", { action = "update", index = 1, swatch = { Brightness = 1 } }, "Unknown swatch field Brightness" },
        { "an incomplete range", { action = "update", index = 1, swatch = { HueRange = { LowerNone = 0 } } }, "swatch.HueRange.LowerFull must be a number" },
        { "an unknown range field", { action = "update", index = 1, swatch = { HueRange = { Middle = 1 } } }, "Unknown field swatch.HueRange.Middle" },
        { "update without an index", { action = "update", swatch = { HueShift = 0.1 } }, "index is required for update" },
        { "an index of zero", { action = "delete", index = 0 }, "index is required for delete" },
        { "an index over 8", { action = "delete", index = 9 }, "index is required for delete" },
        { "a fractional index", { action = "delete", index = 1.5 }, "index is required for delete" },
        { "delete with a swatch", { action = "delete", index = 1, swatch = { HueShift = 0 } }, "swatch is not used by delete" },
        { "clear with an index", { action = "clear", index = 1 }, "clear takes no index or swatch" },
    }
    for _, case in ipairs(invalid) do
        it("rejects " .. case[1] .. " before opening Develop", function()
            local ctx = setup()
            local args = { photo_id = "1", mask_id = "mask-a" }
            for key, value in pairs(case[2]) do args[key] = value end

            local err = errorOf(function() ctx.Handler.editMaskPointColors(args) end)

            assert.truthy(err:find(case[3], 1, true), err)
            assert.are.same({}, ctx.calls.modules)
        end)
    end

    it("rejects an unknown mask without touching any swatch", function()
        local ctx = setup()

        local err = errorOf(function()
            ctx.Handler.editMaskPointColors({ photo_id = "1", mask_id = "nope", action = "clear" })
        end)

        assert.truthy(err:find("Mask not found on photo 1: nope", 1, true))
        assert.are.equal(0, ctx.controllerCalls.delete)
    end)
end)

describe("HandlerMaskPointColors version gate", function()
    it("names the minimum version when Lightroom is older, before any Develop work", function()
        local ctx = setup({ version = { major = 13, minor = 1 } })

        local err = errorOf(function()
            ctx.Handler.editMaskPointColors({ photo_id = "1", mask_id = "mask-a", action = "clear" })
        end)

        assert.truthy(err:find("edit_mask_point_colors needs Lightroom Classic 13.2 or later", 1, true))
        assert.truthy(err:find("this is Lightroom Classic 13.1", 1, true))
        assert.are.same({}, ctx.calls.modules)
    end)

    it("names the minimum version when the Point Color calls do not exist", function()
        local ctx = setup({ extend = function(controller)
            controller.addPointColorSwatch = nil
        end })

        local err = errorOf(function()
            ctx.Handler.editMaskPointColors({ photo_id = "1", mask_id = "mask-a", action = "clear" })
        end)

        assert.truthy(err:find("edit_mask_point_colors needs Lightroom Classic 13.2 or later", 1, true))
        assert.are.same({}, ctx.calls.modules)
    end)

end)
