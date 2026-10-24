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

    it("explains why size is not accepted and rejects unknown properties", function()
        local size = errorOf(function() BrushStrokes.parseStrokes({ stroke({ size = 30 }) }) end)
        local unknown = errorOf(function() BrushStrokes.parseStrokes({ stroke({ colour = "red" }) }) end)

        assert.is_truthy(size:find("size is not supported", 1, true))
        assert.is_truthy(size:find("use radius", 1, true))
        assert.is_truthy(unknown:find("unknown property colour", 1, true))
    end)

    it("defaults to the soft, full density add brush Lightroom starts with", function()
        local parsed = BrushStrokes.parseStrokes({ stroke() })[1]

        assert.are.equal(0, parsed.centerWeight)
        assert.are.equal(1, parsed.density)
        assert.is_false(parsed.erase)
    end)

    it("bounds feather, density and erase and keeps density off erase strokes", function()
        assert.is_truthy(errorOf(function() BrushStrokes.parseStrokes({ stroke({ feather = -1 }) }) end)
            :find("feather must be between 0 (hard) and 100 (soft)", 1, true))
        assert.is_truthy(errorOf(function() BrushStrokes.parseStrokes({ stroke({ feather = 101 }) }) end)
            :find("feather must be between", 1, true))
        assert.is_truthy(errorOf(function() BrushStrokes.parseStrokes({ stroke({ density = 0 }) }) end)
            :find("density must be between 0.01 and 1", 1, true))
        assert.is_truthy(errorOf(function() BrushStrokes.parseStrokes({ stroke({ density = 1.1 }) }) end)
            :find("density must be between", 1, true))
        assert.is_truthy(errorOf(function() BrushStrokes.parseStrokes({ stroke({ erase = "yes" }) }) end)
            :find("erase must be true or false", 1, true))
        assert.is_truthy(errorOf(function() BrushStrokes.parseStrokes({ stroke({ erase = true, density = 0.5 }) }) end)
            :find("density does not apply to an erase stroke", 1, true))
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

describe("BrushStrokes feather, density and erase", function()
    before_each(load)

    local LIGHTROOM_BRUSH_RADIUS = 0.411904

    local lightroomSamples = {
        { feather = 0, radius = 0.161488, centerWeight = 1 },
        { feather = 25, radius = 0.185645, centerWeight = 0.419401 },
        { feather = 50, radius = 0.270214, centerWeight = 0.16214 },
        { feather = 75, radius = 0.362112, centerWeight = 0.049246 },
        { feather = 100, radius = 0.411904, centerWeight = 0 },
    }

    it("reproduces the radius and center weight Lightroom stores for the same brush at each feather", function()
        for _, sample in ipairs(lightroomSamples) do
            local parsed = BrushStrokes.parseStrokes({
                stroke({ radius = LIGHTROOM_BRUSH_RADIUS, feather = sample.feather }),
            })[1]

            assert.is_true(math.abs(parsed.radius - sample.radius) < 1e-5, "radius at feather " .. sample.feather)
            assert.is_true(math.abs(parsed.centerWeight - sample.centerWeight) < 1e-5,
                "center weight at feather " .. sample.feather)
        end
    end)

    it("interpolates between Lightroom's samples within a fraction of a percent", function()
        local heldOut = {
            { feather = 1, scale = 0.39303, centerWeight = 0.966779 },
            { feather = 3, scale = 0.39518, centerWeight = 0.903418 },
            { feather = 7, scale = 0.40040, centerWeight = 0.788186 },
            { feather = 12.5, scale = 0.41022, centerWeight = 0.652021 },
            { feather = 32.5, scale = 0.49366, centerWeight = 0.319102 },
            { feather = 37.5, scale = 0.53241, centerWeight = 0.264706 },
            { feather = 62.5, scale = 0.78036, centerWeight = 0.094215 },
            { feather = 87.5, scale = 0.95057, centerWeight = 0.019522 },
        }
        for _, sample in ipairs(heldOut) do
            local parsed = BrushStrokes.parseStrokes({ stroke({ radius = 1, feather = sample.feather }) })[1]

            assert.is_true(math.abs(parsed.radius - sample.scale) < 0.002, "radius at feather " .. sample.feather)
            assert.is_true(math.abs(parsed.centerWeight - sample.centerWeight) < 0.003,
                "center weight at feather " .. sample.feather)
        end
    end)

    it("writes the center weight, the radius and Lightroom's center weight token", function()
        local aggregate = BrushStrokes.newAggregate(BrushStrokes.parseStrokes({
            stroke({ radius = 0.411904, feather = 50, points = { point(0.5, 0.5) } }),
        }))

        local paint = aggregate.Masks[1]
        assert.is_true(math.abs(paint.Radius - 0.270214) < 1e-5)
        assert.is_true(math.abs(paint.CenterWeight - 0.16214) < 1e-5)
        assert.are.same({ "h 0.1621", "d 0.500000 0.500000" }, paint.Dabs)
    end)

    it("writes no center weight token for a fully soft or fully hard brush", function()
        local aggregate = BrushStrokes.newAggregate(BrushStrokes.parseStrokes({
            stroke({ feather = 0, points = { point(0.5, 0.5) } }),
            stroke({ feather = 100, points = { point(0.5, 0.5) } }),
        }))

        assert.are.same({ "d 0.500000 0.500000" }, aggregate.Masks[1].Dabs)
        assert.are.equal(1, aggregate.Masks[1].CenterWeight)
        assert.are.same({ "d 0.500000 0.500000" }, aggregate.Masks[2].Dabs)
        assert.are.equal(0, aggregate.Masks[2].CenterWeight)
    end)

    it("puts the flow token before the center weight token as Lightroom does", function()
        local aggregate = BrushStrokes.newAggregate(BrushStrokes.parseStrokes({
            stroke({ flow = 0.6, feather = 30, points = { point(0.5, 0.5) } }),
        }))

        assert.are.same({ "f 0.6000", "h 0.3498", "d 0.500000 0.500000" }, aggregate.Masks[1].Dabs)
    end)

    it("spaces dabs by the stored radius, so a hard brush needs more of them", function()
        local soft = BrushStrokes.newAggregate(BrushStrokes.parseStrokes({
            stroke({ points = { point(0.1, 0.5), point(0.5, 0.5) }, radius = 0.1 }),
        }))
        local hard = BrushStrokes.newAggregate(BrushStrokes.parseStrokes({
            stroke({ points = { point(0.1, 0.5), point(0.5, 0.5) }, radius = 0.1, feather = 0 }),
        }))

        assert.is_true(#hard.Masks[1].Dabs > #soft.Masks[1].Dabs)
    end)

    it("stores density as the paint value", function()
        local aggregate = BrushStrokes.newAggregate(BrushStrokes.parseStrokes({
            stroke({ density = 0.3 }), stroke(),
        }))

        assert.are.equal(0.3, aggregate.Masks[1].MaskValue)
        assert.are.equal(1, aggregate.Masks[2].MaskValue)
    end)

    it("stores an erase stroke as a paint with value 0 and the add blend mode", function()
        local aggregate = BrushStrokes.newAggregate(BrushStrokes.parseStrokes({ stroke({ erase = true }) }))

        assert.are.equal(0, aggregate.Masks[1].MaskValue)
        assert.are.equal(0, aggregate.Masks[1].MaskBlendMode)
    end)

    it("budgets dabs on the stored radius, so a hard brush on a long path is refused", function()
        local points = { point(0, 0), point(1, 1) }

        assert.is_true(pcall(BrushStrokes.parseStrokes, { stroke({ points = points, radius = 0.0016 }) }))
        assert.is_false(pcall(BrushStrokes.parseStrokes, { stroke({ points = points, radius = 0.0016, feather = 0 }) }))
    end)
end)

describe("BrushStrokes.toStoredFrame", function()
    before_each(load)

    local function frameOf(orientation)
        helper.installImport({})
        package.loaded.ImageFrame = nil
        return require('ImageFrame').fromOrientation(orientation)
    end

    it("returns the strokes untouched for a normal photo", function()
        local parsed = BrushStrokes.parseStrokes({ stroke() })

        assert.are.equal(parsed, BrushStrokes.toStoredFrame(parsed, frameOf("AB")))
    end)

    it("maps every point and keeps the brush for a rotated photo", function()
        local parsed = BrushStrokes.parseStrokes({
            stroke({ points = { point(0, 0), point(1, 0) }, radius = 0.2, flow = 0.5, feather = 0, density = 0.4 }),
        })

        local mapped = BrushStrokes.toStoredFrame(parsed, frameOf("BC"))

        assert.are.same({ point(0, 1), point(0, 0) }, mapped[1].points)
        assert.are.equal(parsed[1].radius, mapped[1].radius)
        assert.are.equal(0.5, mapped[1].flow)
        assert.are.equal(1, mapped[1].centerWeight)
        assert.are.equal(0.4, mapped[1].density)
    end)

    it("encodes dabs along the stored path", function()
        local parsed = BrushStrokes.parseStrokes({
            stroke({ points = { point(0, 0.5), point(0.1, 0.5) }, radius = 0.1 }),
        })

        local aggregate = BrushStrokes.newAggregate(BrushStrokes.toStoredFrame(parsed, frameOf("BC")))

        assert.are.same({ "d 0.500000 1.000000", "d 0.500000 0.950000", "d 0.500000 0.900000" }, aggregate.Masks[1].Dabs)
    end)
end)
