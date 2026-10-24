local helper = require 'spec_helper'

local RangeMaskGeometry

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

local function sample(overrides)
    local value = { x = 0.2, y = 0.8, red = 0.462745, green = 0.4, blue = 0.1 }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
end

local function luminanceArgs(overrides)
    local args = { type = "luminance", luminance = { min = 0.3, max = 0.6, falloff = 0.1 } }
    for key, value in pairs(overrides or {}) do args[key] = value end
    return args
end

local function colorArgs(overrides)
    local args = { type = "color", color = { sample = sample(), amount = 0.4 } }
    for key, value in pairs(overrides or {}) do args[key] = value end
    return args
end

local function parseError(args)
    return errorOf(function() RangeMaskGeometry.parseCreate(args) end)
end

describe("RangeMaskGeometry", function()
    before_each(function()
        helper.installImport({})
        package.loaded.RangeMaskGeometry = nil
        RangeMaskGeometry = require 'RangeMaskGeometry'
    end)

    describe("parseCreate", function()
        it("parses a luminance range with defaults for mode and invert", function()
            local request = RangeMaskGeometry.parseCreate(luminanceArgs())

            assert.are.equal("luminance", request.kind)
            assert.are.same({ min = 0.3, max = 0.6, falloff = 0.1 }, request.range)
            assert.are.equal("add", request.mode)
            assert.is_false(request.invert)
            assert.is_nil(request.maskId)
        end)

        it("defaults the falloff", function()
            local request = RangeMaskGeometry.parseCreate(luminanceArgs({ luminance = { min = 0.3, max = 0.6 } }))

            assert.are.equal(0.1, request.range.falloff)
        end)

        it("parses a color range and defaults the amount", function()
            local request = RangeMaskGeometry.parseCreate(colorArgs({ color = { sample = sample() } }))

            assert.are.equal("color", request.kind)
            assert.are.equal(0.5, request.range.amount)
            assert.are.same(sample(), request.range.sample)
        end)

        it("accepts subtract on an existing mask, invert, and a name on a new one", function()
            local subtract = RangeMaskGeometry.parseCreate(
                luminanceArgs({ mask_id = "C1", mode = "subtract", invert = true }))
            local named = RangeMaskGeometry.parseCreate(colorArgs({ name = "Foliage" }))

            assert.are.equal("subtract", subtract.mode)
            assert.are.equal("C1", subtract.maskId)
            assert.is_true(subtract.invert)
            assert.are.equal("Foliage", named.name)
        end)

        it("rejects an unknown type including depth", function()
            assert.is_truthy(parseError({ type = "depth" }):find('type must be "luminance" or "color"', 1, true))
            assert.is_truthy(parseError({}):find("type must be", 1, true))
        end)

        it("needs the object of its own type and rejects the other one", function()
            assert.is_truthy(parseError({ type = "color" }):find("color is required for a color range mask", 1, true))
            assert.is_truthy(parseError(luminanceArgs({ color = { sample = sample() } }))
                :find("color only applies to color range masks", 1, true))
            assert.is_truthy(parseError(colorArgs({ luminance = { min = 0, max = 1 } }))
                :find("luminance only applies to luminance range masks", 1, true))
        end)

        it("rejects luminance values outside 0..1 or out of order", function()
            local function parse(luminance) return parseError(luminanceArgs({ luminance = luminance })) end

            assert.is_truthy(parse({ min = -0.1, max = 0.5 }):find("luminance.min must be between 0 and 1", 1, true))
            assert.is_truthy(parse({ min = 0.1, max = 1.5 }):find("luminance.max must be between 0 and 1", 1, true))
            assert.is_truthy(parse({ min = 0.6, max = 0.3 }):find("must not be greater", 1, true))
            assert.is_truthy(parse({ min = 0.1, max = 0.5, falloff = 2 }):find("luminance.falloff", 1, true))
            assert.is_truthy(parse({ min = 0.1, max = 0.5, falloff = "x" })
                :find("luminance.falloff must be a number", 1, true))
            assert.is_truthy(parse({ min = 0.1 }):find("needs min and max", 1, true))
            assert.is_truthy(parse({ min = 0.1, max = 0.2, extra = 1 }):find("unknown property extra", 1, true))
        end)

        it("rejects a zero-width range without falloff but accepts a triangle", function()
            assert.is_truthy(parseError(luminanceArgs({ luminance = { min = 0.5, max = 0.5, falloff = 0 } }))
                :find("selects nothing", 1, true))

            local triangle = RangeMaskGeometry.parseCreate(luminanceArgs({ luminance = { min = 0.5, max = 0.5 } }))

            assert.are.equal(0.5, triangle.range.min)
        end)

        it("rejects bad color samples and amounts", function()
            local function parse(color) return parseError(colorArgs({ color = color })) end

            assert.is_truthy(parse({ sample = sample({ x = 1.2 }) })
                :find("color.sample.x must be between 0 and 1", 1, true))
            assert.is_truthy(parse({ sample = sample({ red = -1 }) }):find("color.sample.red", 1, true))
            assert.is_truthy(parse({ sample = { x = 0.1, y = 0.1, red = 0.1, green = 0.1 } })
                :find("color.sample.blue is required", 1, true))
            assert.is_truthy(parse({ sample = sample({ extra = 1 }) }):find("unknown property extra", 1, true))
            assert.is_truthy(parse({ sample = sample(), amount = 0 }):find("color.amount", 1, true))
            assert.is_truthy(parse({ sample = sample(), amount = 1.5 }):find("color.amount", 1, true))
            assert.is_truthy(parse({ amount = 0.4 }):find("color.sample is required", 1, true))
        end)

        it("rejects more than one sample point", function()
            local message = parseError(colorArgs({
                color = { sample = { sample(), sample({ x = 0.5 }) } },
            }))

            assert.is_truthy(message:find("single sample point", 1, true))
        end)

        it("rejects bad mask options", function()
            assert.is_truthy(parseError(luminanceArgs({ mode = "intersect" }))
                :find('mode must be "add" or "subtract"', 1, true))
            assert.is_truthy(parseError(luminanceArgs({ mode = "subtract" })):find("needs mask_id", 1, true))
            assert.is_truthy(parseError(luminanceArgs({ name = "A", mask_id = "C1" }))
                :find("name applies to a new mask", 1, true))
            assert.is_truthy(parseError(luminanceArgs({ invert = "yes" })):find("invert must be true or false", 1, true))
            assert.is_truthy(parseError(luminanceArgs({ mask_id = "" }))
                :find("mask_id must be a non-empty string", 1, true))
        end)
    end)

    describe("newComponent", function()
        it("writes a luminance trapezoid with the ramps outside the full band", function()
            local component = RangeMaskGeometry.newComponent(RangeMaskGeometry.parseCreate(luminanceArgs()))

            assert.are.equal("Mask/RangeMask", component.What)
            assert.are.equal(2, component.CorrectionRangeMask.Type)
            assert.are.equal(3, component.CorrectionRangeMask.Version)
            assert.are.equal(0, component.CorrectionRangeMask.SampleType)
            assert.are.equal("0.200000 0.300000 0.600000 0.700000", component.CorrectionRangeMask.LumRange)
            assert.is_nil(component.CorrectionRangeMask.Invert)
            assert.is_false(component.MaskInverted)
            assert.are.equal(0, component.MaskBlendMode)
            assert.are.equal(1, component.MaskValue)
        end)

        it("clips the ramps at the ends of the tonal scale", function()
            local component = RangeMaskGeometry.newComponent(RangeMaskGeometry.parseCreate(
                luminanceArgs({ luminance = { min = 0.05, max = 0.95, falloff = 0.2 } })))

            assert.are.equal("0.000000 0.050000 0.950000 1.000000", component.CorrectionRangeMask.LumRange)
        end)

        it("always writes a LumRange ordered a <= b <= c <= d within 0..1", function()
            local cases = {
                { 0, 1, 0 }, { 0, 1, 1 }, { 0.5, 0.5, 0.3 }, { 0.3, 0.7, 0 }, { 0.999999, 1, 0.5 },
                { 0.1, 0.30000000000000004, 0.19999999999999998 }, { 0, 0, 0.1 }, { 1, 1, 0.1 },
            }
            for _, case in ipairs(cases) do
                local component = RangeMaskGeometry.newComponent(RangeMaskGeometry.parseCreate(
                    luminanceArgs({ luminance = { min = case[1], max = case[2], falloff = case[3] } })))
                local values = {}
                for token in component.CorrectionRangeMask.LumRange:gmatch("%S+") do
                    values[#values + 1] = tonumber(token)
                end
                assert.are.equal(4, #values)
                assert.is_true(values[1] >= 0 and values[1] <= values[2] and values[2] <= values[3]
                    and values[3] <= values[4] and values[4] <= 1)
            end
        end)

        it("writes exactly one PointModels entry for a color range", function()
            local component = RangeMaskGeometry.newComponent(RangeMaskGeometry.parseCreate(colorArgs()))

            local range = component.CorrectionRangeMask
            assert.are.equal(1, range.Type)
            assert.are.equal(3, range.Version)
            assert.are.equal(0, range.SampleType)
            assert.are.equal(0.4, range.ColorAmount)
            assert.are.equal(1, #range.PointModels)
            assert.are.equal("0.462745 0.400000 0.100000 0.200000 0.800000 0", range.PointModels[1])
            assert.is_nil(range.LumRange)
        end)

        it("maps invert and subtract onto the component", function()
            local component = RangeMaskGeometry.newComponent(RangeMaskGeometry.parseCreate(
                luminanceArgs({ mask_id = "C1", mode = "subtract", invert = true })))

            assert.is_true(component.MaskInverted)
            assert.are.equal(1, component.MaskBlendMode)
            assert.are.equal(0, component.MaskValue)
        end)
    end)

    describe("rangeOf", function()
        it("reads a luminance trapezoid back as min, max and the two falloffs", function()
            local kind, range = RangeMaskGeometry.rangeOf({
                What = "Mask/RangeMask",
                CorrectionRangeMask = { Type = 2, LumRange = "0.200000 0.300000 0.600000 0.900000" },
            })

            assert.are.equal("luminance", kind)
            assert.are.same({ min = 0.3, max = 0.6, lower_falloff = 0.1, upper_falloff = 0.3 }, range)
        end)

        it("reads a color sample back", function()
            local kind, range = RangeMaskGeometry.rangeOf({
                What = "Mask/RangeMask",
                CorrectionRangeMask = { Type = 1, ColorAmount = 0.4, PointModels = { "0.1 0.2 0.3 0.4 0.5 0" } },
            })

            assert.are.equal("color", kind)
            assert.are.same({ sample = { x = 0.4, y = 0.5, red = 0.1, green = 0.2, blue = 0.3 }, amount = 0.4 }, range)
        end)

        it("returns nil for other masks, other range types and malformed values", function()
            assert.is_nil(RangeMaskGeometry.rangeOf({ What = "Mask/Gradient" }))
            assert.is_nil(RangeMaskGeometry.rangeOf({ What = "Mask/RangeMask", CorrectionRangeMask = { Type = 3 } }))
            assert.is_nil(RangeMaskGeometry.rangeOf({
                What = "Mask/RangeMask", CorrectionRangeMask = { Type = 2, LumRange = "a b" },
            }))
            assert.is_nil(RangeMaskGeometry.rangeOf({
                What = "Mask/RangeMask", CorrectionRangeMask = { Type = 1, ColorAmount = 1, PointModels = {} },
            }))
        end)
    end)
end)
