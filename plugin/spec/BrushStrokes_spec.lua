local helper = require 'spec_helper'

local BrushStrokes

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

local function point(x, y) return { x = x, y = y } end

local function stroke(overrides)
    local value = { points = { point(0.2, 0.3), point(0.3, 0.3) } }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
end

local function load()
    helper.installImport({})
    package.loaded.BrushStrokes = nil
    BrushStrokes = require 'BrushStrokes'
end

describe("BrushStrokes.parseStrokes", function()
    before_each(load)

    it("applies Lightroom's default radius and full flow", function()
        local parsed = BrushStrokes.parseStrokes({ stroke() })

        assert.are.equal(1, #parsed)
        assert.are.equal(0.14, parsed[1].radius)
        assert.are.equal(1, parsed[1].flow)
        assert.are.same({ point(0.2, 0.3), point(0.3, 0.3) }, parsed[1].points)
    end)

    it("rejects an empty or missing stroke list", function()
        assert.is_truthy(errorOf(function() BrushStrokes.parseStrokes({}) end):find("at least one stroke", 1, true))
        assert.is_truthy(errorOf(function() BrushStrokes.parseStrokes(nil) end):find("at least one stroke", 1, true))
    end)

    it("rejects a stroke without points", function()
        local message = errorOf(function() BrushStrokes.parseStrokes({ stroke({ points = {} }) }) end)

        assert.is_truthy(message:find("strokes[1].points must list at least one point", 1, true))
    end)

    it("rejects points outside the image and says which one", function()
        local message = errorOf(function()
            BrushStrokes.parseStrokes({ stroke(), stroke({ points = { point(0.5, 0.5), point(1.01, 0.5) } }) })
        end)

        assert.is_truthy(message:find("strokes[2].points[2].x is outside the image", 1, true))
    end)

    it("rejects malformed points", function()
        assert.is_truthy(errorOf(function()
            BrushStrokes.parseStrokes({ stroke({ points = { { 0.1, 0.2 } } }) })
        end):find("unknown property 1", 1, true))
        assert.is_truthy(errorOf(function()
            BrushStrokes.parseStrokes({ stroke({ points = { { x = 0.1, y = 0.2, z = 1 } } }) })
        end):find("unknown property z", 1, true))
        assert.is_truthy(errorOf(function()
            BrushStrokes.parseStrokes({ stroke({ points = { point(0 / 0, 0.2) } }) })
        end):find("must be a number", 1, true))
    end)

    it("bounds radius and flow", function()
        assert.is_truthy(errorOf(function() BrushStrokes.parseStrokes({ stroke({ radius = 0 }) }) end)
            :find("radius must be greater than 0", 1, true))
        assert.is_truthy(errorOf(function() BrushStrokes.parseStrokes({ stroke({ radius = 1.5 }) }) end)
            :find("radius", 1, true))
        assert.is_truthy(errorOf(function() BrushStrokes.parseStrokes({ stroke({ flow = 0 }) }) end)
            :find("flow must be between", 1, true))
        assert.is_truthy(errorOf(function() BrushStrokes.parseStrokes({ stroke({ flow = 1.1 }) }) end)
            :find("flow must be between", 1, true))
    end)

    it("rounds flow to the four decimals of the stored flow token", function()
        assert.are.equal(0.3333, BrushStrokes.parseStrokes({ stroke({ flow = 1 / 3 }) })[1].flow)
    end)

    it("explains why feather, density and erase are not accepted", function()
        local feather = errorOf(function() BrushStrokes.parseStrokes({ stroke({ feather = 50 }) }) end)
        local density = errorOf(function() BrushStrokes.parseStrokes({ stroke({ density = 50 }) }) end)
        local erase = errorOf(function() BrushStrokes.parseStrokes({ stroke({ erase = true }) }) end)
        local unknown = errorOf(function() BrushStrokes.parseStrokes({ stroke({ colour = "red" }) }) end)

        assert.is_truthy(feather:find("feather is not supported", 1, true))
        assert.is_truthy(density:find("density is not supported", 1, true))
        assert.is_truthy(erase:find("erase strokes are not supported", 1, true))
        assert.is_truthy(unknown:find("unknown property colour", 1, true))
    end)

    it("limits strokes, points and the dabs a path needs", function()
        local many = {}
        for index = 1, 51 do many[index] = stroke() end
        local longPath = {}
        for index = 1, 1001 do longPath[index] = point(0.5, 0.5) end

        assert.is_truthy(errorOf(function() BrushStrokes.parseStrokes(many) end):find("at most 50", 1, true))
        assert.is_truthy(errorOf(function()
            BrushStrokes.parseStrokes({ stroke({ points = longPath }) })
        end):find("at most 1000", 1, true))
        assert.is_truthy(errorOf(function()
            BrushStrokes.parseStrokes({ stroke({ points = { point(0, 0), point(1, 1) }, radius = 0.0001 }) })
        end):find("dabs along its path", 1, true))
    end)
end)

describe("BrushStrokes.newAggregate", function()
    before_each(load)

    it("builds an aggregate with one paint per stroke in the stored form", function()
        local aggregate = BrushStrokes.newAggregate(BrushStrokes.parseStrokes({
            stroke({ radius = 0.05 }), stroke({ points = { point(0.7, 0.8) } }),
        }))

        assert.are.equal("Mask/Aggregate", aggregate.What)
        assert.are.equal(0, aggregate.MaskBlendMode)
        assert.are.equal(2, #aggregate.Masks)
        local first = aggregate.Masks[1]
        assert.are.equal("Mask/Paint", first.What)
        assert.are.equal(0, first.MaskBlendMode)
        assert.are.equal(0.05, first.Radius)
        assert.are.equal(1, first.Flow)
        assert.are.equal(0, first.CenterWeight)
        assert.are.same({ "d 0.700000 0.800000" }, aggregate.Masks[2].Dabs)
    end)

    it("fills the gap between distant points so the stroke has no holes", function()
        local aggregate = BrushStrokes.newAggregate(BrushStrokes.parseStrokes({
            stroke({ points = { point(0.1, 0.5), point(0.5, 0.5) }, radius = 0.1 }),
        }))

        local dabs = aggregate.Masks[1].Dabs
        assert.are.equal(9, #dabs)
        assert.are.equal("d 0.100000 0.500000", dabs[1])
        assert.are.equal("d 0.150000 0.500000", dabs[2])
        assert.are.equal("d 0.500000 0.500000", dabs[9])
    end)

    it("does not repeat a dab for a repeated point", function()
        local aggregate = BrushStrokes.newAggregate(BrushStrokes.parseStrokes({
            stroke({ points = { point(0.5, 0.5), point(0.5, 0.5) } }),
        }))

        assert.are.same({ "d 0.500000 0.500000" }, aggregate.Masks[1].Dabs)
    end)

    it("encodes flow below 1 as a leading flow token next to the Flow field", function()
        local aggregate = BrushStrokes.newAggregate(BrushStrokes.parseStrokes({ stroke({ flow = 0.3 }) }))

        local paint = aggregate.Masks[1]
        assert.are.equal(0.3, paint.Flow)
        assert.are.equal("f 0.3000", paint.Dabs[1])
        assert.are.equal("d 0.200000 0.300000", paint.Dabs[2])
        assert.are.equal("d 0.300000 0.300000", paint.Dabs[4])
        assert.are.equal(4, #paint.Dabs)
    end)

    it("appends strokes to an existing aggregate and counts them", function()
        local aggregate = BrushStrokes.newAggregate(BrushStrokes.parseStrokes({ stroke() }))

        local count = BrushStrokes.appendStrokes(aggregate, BrushStrokes.parseStrokes({ stroke(), stroke() }))

        assert.are.equal(3, count)
        assert.are.equal(3, #aggregate.Masks)
    end)
end)
