local fake = require 'fake_mask_develop'

local LINE = { 0, 0, 255, 255 }
local SWATCH = { SrcHue = 1, SrcSat = 0.5, SrcLum = 0.4, HueShift = 0.2 }

local function setup(overrides)
    local opts = {
        photos = {
            { id = "1", selectedMask = "mask-b", masks = {
                ["mask-a"] = { local_Exposure = 0.5, local_Contrast = 10,
                    local_Maincurve = LINE, local_Redcurve = LINE,
                    local_Greencurve = LINE, local_Bluecurve = { 0, 10, 255, 240 },
                    local_PointColors = { SWATCH } },
                ["mask-b"] = { local_Exposure = -1, local_Maincurve = LINE },
            } },
            { id = "2" },
        },
        modules = { "HandlerMaskRead", "HandlerMaskAdjustments", "HandlerMaskCurves", "HandlerMaskPointColors",
            "MaskSelection", "DevelopSession", "MaskSettle", "MaskCurves", "MaskPointColors" },
        handler = "HandlerMaskRead",
        extend = function(controller) controller.getSelectedPointColorSwatchIndex = function() return 0 end end,
    }
    for key, value in pairs(overrides or {}) do opts[key] = value end
    local ctx = fake.build(opts)
    ctx.reads, ctx.sessions = {}, 0
    local getValue = ctx.controller.getValue
    ctx.controller.getValue = function(name)
        ctx.reads[#ctx.reads + 1] = name
        return getValue(name)
    end
    local session = require 'DevelopSession'
    local withPhoto = session.withPhoto
    session.withPhoto = function(...)
        ctx.sessions = ctx.sessions + 1
        return withPhoto(...)
    end
    return ctx
end

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

describe("HandlerMaskRead.getMask", function()
    it("reads all three kinds once in one session and restores mask and view", function()
        local ctx = setup()
        local r = ctx.Handler.getMask({ photo_id = 1, mask_id = "mask-a" })
        assert.is_true(r.success)
        assert.are.equal("1", r.photo_id)
        assert.are.equal("mask-a", r.mask_id)
        assert.are.same({ local_Exposure = 0.5, local_Contrast = 10 }, r.adjustments)
        assert.are.same(LINE, r.curves.main)
        assert.are.same({ 0, 10, 255, 240 }, r.curves.blue)
        assert.are.equal(1, r.swatches[1].index)
        assert.are.equal(SWATCH.HueShift, r.swatches[1].HueShift)
        assert.are.equal(1, #r.swatches)
        assert.are.same({}, r.unavailable.curves)
        assert.is_true(#r.unavailable.adjustments > 0)
        assert.is_nil(r.errors)
        assert.are.equal(1, ctx.sessions)
        assert.are.same({ "develop", "library" }, ctx.calls.modules)
        assert.are.equal("mask-b", ctx.selectedMaskOf[ctx.photos[1]])
        assert.are.equal(0, #ctx.calls.setValue)
    end)

    for _, kind in ipairs({ "adjustments", "curves", "point_colors" }) do
        it("reads only " .. kind .. " when requested", function()
            local ctx = setup()
            local r = ctx.Handler.getMask({ photo_id = "/1.jpg", mask_id = "mask-a", kinds = { kind } })
            for _, name in ipairs(ctx.reads) do
                local actualKind = name == "local_PointColors" and "point_colors"
                    or name:find("curve", 1, true) and "curves" or "adjustments"
                assert.are.equal(kind, actualKind)
            end
            assert.are.equal(kind == "curves", r.curves ~= nil)
            assert.are.equal(kind == "adjustments", r.adjustments ~= nil)
            assert.are.equal(kind == "point_colors", r.swatches ~= nil)
            assert.are.equal(1, ctx.sessions)
        end)
    end

    it("returns supported kinds and names unavailable version requirements", function()
        local ctx = setup({ version = { major = 11, minor = 5 } })
        local r = ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-a" })
        assert.are.equal(0.5, r.adjustments.local_Exposure)
        assert.is_nil(r.curves)
        assert.is_nil(r.swatches)
        assert.truthy(r.errors.curves:find("Lightroom Classic 12.3", 1, true))
        assert.truthy(r.errors.point_colors:find("Lightroom Classic 13.2", 1, true))
        assert.are.equal(1, ctx.sessions)
    end)

    for _, entry in ipairs({ { "adjustments", 10, 9, "11" }, { "curves", 12, 2, "12.3" },
        { "point_colors", 13, 1, "13.2" } }) do
        it("rejects only unsupported " .. entry[1] .. " before Develop", function()
            local ctx = setup({ version = { major = entry[2], minor = entry[3] } })
            local err = errorOf(function()
                ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-a", kinds = { entry[1] } })
            end)
            assert.truthy(err:find(entry[1], 1, true))
            assert.truthy(err:find("Lightroom Classic " .. entry[4], 1, true))
            assert.are.equal(0, ctx.sessions)
            assert.are.same({}, ctx.reads)
        end)
    end

    it("reports missing Point Color API while still reading curves", function()
        local ctx = setup({ extend = function() end })
        local r = ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-a", kinds = { "curves", "point_colors" } })
        assert.are.same(LINE, r.curves.main)
        assert.truthy(r.errors.point_colors:find("13.2", 1, true))
        assert.is_nil(r.adjustments)
    end)

    it("keeps other results when curve parameters are unavailable", function()
        local ctx = setup()
        local r = ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-b" })
        assert.are.equal(-1, r.adjustments.local_Exposure)
        assert.are.same({ "red", "green", "blue" }, r.unavailable.curves)
        ctx.valuesOf[ctx.photos[1]]["mask-b"].local_Maincurve = nil
        r = ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-b" })
        assert.is_nil(r.curves)
        assert.truthy(r.errors.curves:find("12.3", 1, true))
        assert.are.equal(-1, r.adjustments.local_Exposure)
    end)

    it("fails when the only requested curve cannot be read", function()
        local ctx = setup()
        ctx.valuesOf[ctx.photos[1]]["mask-b"].local_Maincurve = { 0, 0, 255 }
        local err = errorOf(function()
            ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-b", kinds = { "curves" } })
        end)
        assert.truthy(err:find("curves", 1, true))
        assert.truthy(err:find("12.3", 1, true))
        assert.are.equal("mask-b", ctx.selectedMaskOf[ctx.photos[1]])
    end)

    it("returns empty swatches and reports malformed or throwing Point Color reads", function()
        local ctx = setup()
        local r = ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-b", kinds = { "point_colors" } })
        assert.are.same({}, r.swatches)
        ctx.valuesOf[ctx.photos[1]]["mask-a"].local_PointColors = { { SrcHue = "red" } }
        r = ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-a" })
        assert.truthy(r.errors.point_colors:find("unreadable Point Color swatch", 1, true))
        local original = ctx.controller.getValue
        ctx.controller.getValue = function(name)
            if name == "local_PointColors" then error("unknown parameter") end
            return original(name)
        end
        local err = errorOf(function()
            ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-a", kinds = { "point_colors" } })
        end)
        assert.truthy(err:find("13.2", 1, true))
    end)

    it("rejects missing photo or mask and unknown photo", function()
        local ctx = setup()
        for _, request in ipairs({ { mask_id = "mask-a" }, { photo_id = "1" },
            { photo_id = "404", mask_id = "mask-a" } }) do
            errorOf(function() ctx.Handler.getMask(request) end)
        end
        assert.are.equal(0, ctx.sessions)
        assert.are.same({}, ctx.reads)
    end)

    it("reads no values when the requested mask does not exist", function()
        local ctx = setup()
        local err = errorOf(function() ctx.Handler.getMask({ photo_id = "1", mask_id = "missing" }) end)
        assert.truthy(err:find("Mask not found", 1, true))
        assert.are.same({}, ctx.reads)
        assert.are.equal(0, #ctx.calls.setValue)
    end)

    for _, kinds in ipairs({ {}, "curves", { "nope" }, { "curves", "curves" },
        { [1] = "curves", [3] = "adjustments" }, { curves = true } }) do
        it("rejects malformed kinds before any session", function()
            local ctx = setup()
            assert.truthy(errorOf(function()
                ctx.Handler.getMask({ photo_id = "1", mask_id = "mask-a", kinds = kinds })
            end):find("kinds", 1, true))
            assert.are.equal(0, ctx.sessions)
        end)
    end
end)
