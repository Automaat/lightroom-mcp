local helper = require 'spec_helper'

local RangeMaskGeometry

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

local function sample(overrides)
    local value = { x = 0.2, y = 0.8, l = 0.462745, a = 0.4, b = 0.1 }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
end

local LIGHTROOM_AUTHORED_SAMPLES = {
    { photo = "chart one", srgb = { 0, 0, 0 }, stored = "0.000000 0.412168 0.482436 0.050000 0.062000 0" },
    { photo = "chart one", srgb = { 255, 255, 255 }, stored = "1.000000 0.412168 0.482436 0.950000 0.062000 0" },
    { photo = "chart one", srgb = { 142, 142, 142 }, stored = "0.526449 0.507206 0.517751 0.550000 0.062000 0" },
    { photo = "chart one", srgb = { 255, 0, 0 }, stored = "0.522527 0.888059 0.758296 0.050000 0.188000 0" },
    { photo = "chart one", srgb = { 0, 255, 0 }, stored = "0.877652 0.042200 0.948882 0.150000 0.188000 0" },
    { photo = "chart one", srgb = { 0, 0, 255 }, stored = "0.203667 0.847788 0.000076 0.250000 0.188000 0" },
    { photo = "chart one", srgb = { 0, 255, 255 }, stored = "0.937129 0.000085 0.412180 0.350000 0.188000 0" },
    { photo = "chart one", srgb = { 255, 0, 255 }, stored = "0.705572 1.000000 0.260581 0.450000 0.188000 0" },
    { photo = "chart one", srgb = { 255, 255, 0 }, stored = "0.999979 0.382554 1.000000 0.550000 0.188000 0" },
    { photo = "chart one", srgb = { 128, 80, 40 }, stored = "0.295014 0.570518 0.616284 0.950000 0.188000 0" },
    { photo = "chart two", srgb = { 0, 0, 0 }, stored = "0.000000 0.487187 0.520188 0.016250 0.062000 0" },
    { photo = "chart two", srgb = { 132, 132, 132 }, stored = "0.715088 0.499362 0.525540 0.516250 0.062000 0" },
    { photo = "chart two", srgb = { 255, 255, 255 }, stored = "1.000000 0.487187 0.520188 0.985000 0.062000 0" },
    { photo = "chart two", srgb = { 255, 0, 0 }, stored = "0.722002 0.866458 0.751496 0.985000 0.188000 0" },
}

local function sampleOf(stored)
    local values = {}
    for token in stored:gmatch("%S+") do values[#values + 1] = tonumber(token) end
    return { l = values[1], a = values[2], b = values[3], x = values[4], y = values[5] }
end

local function luminanceArgs(overrides)
    local args = { type = "luminance", luminance = { min = 0.3, max = 0.6, falloff = 0.1 } }
    for key, value in pairs(overrides or {}) do args[key] = value end
    return args
end

local function depthArgs(overrides)
    local args = { type = "depth", depth = { min = 0, max = 0.1, falloff = 0.25 } }
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

        it("parses a depth range", function()
            local request = RangeMaskGeometry.parseCreate(depthArgs())

            assert.are.equal("depth", request.kind)
            assert.are.same({ min = 0, max = 0.1, falloff = 0.25 }, request.range)
        end)

        it("rejects an unknown type", function()
            assert.is_truthy(parseError({ type = "hue" }):find('type must be "luminance", "color" or "depth"', 1, true))
            assert.is_truthy(parseError({}):find("type must be", 1, true))
        end)

        it("needs the object of its own type and rejects the other one", function()
            assert.is_truthy(parseError({ type = "color" }):find("color is required for a color range mask", 1, true))
            assert.is_truthy(parseError(luminanceArgs({ color = { sample = sample() } }))
                :find("color only applies to color range masks", 1, true))
            assert.is_truthy(parseError(colorArgs({ luminance = { min = 0, max = 1 } }))
                :find("luminance only applies to luminance range masks", 1, true))
            assert.is_truthy(parseError({ type = "depth" }):find("depth is required for a depth range mask", 1, true))
            assert.is_truthy(parseError(depthArgs({ luminance = { min = 0, max = 1 } }))
                :find("luminance only applies to luminance range masks", 1, true))
            assert.is_truthy(parseError(luminanceArgs({ depth = { min = 0, max = 1 } }))
                :find("depth only applies to depth range masks", 1, true))
        end)

        it("rejects depth values outside 0..1 or out of order", function()
            local function parse(depth) return parseError(depthArgs({ depth = depth })) end

            assert.is_truthy(parse({ min = -0.1, max = 0.5 }):find("depth.min must be between 0 and 1", 1, true))
            assert.is_truthy(parse({ min = 0.6, max = 0.3 }):find("depth.min must not be greater", 1, true))
            assert.is_truthy(parse({ min = 0.1, max = 0.5, falloff = 2 }):find("depth.falloff", 1, true))
            assert.is_truthy(parse({ min = 0.1 }):find("depth needs min and max", 1, true))
            assert.is_truthy(parse({ min = 0.1, max = 0.2, sample = 1 }):find("unknown property sample", 1, true))
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

        it("rejects a full-strength band narrower than Lightroom keeps, for luminance and depth", function()
            local function narrow(kind, min, max, falloff)
                return parseError({ type = kind, [kind] = { min = min, max = max, falloff = falloff } })
            end

            for _, kind in ipairs({ "luminance", "depth" }) do
                assert.is_truthy(narrow(kind, 0.5, 0.5, 0):find(kind .. ".max must be at least 0.01 above", 1, true))
                assert.is_truthy(narrow(kind, 0.5, 0.5, 0.1):find("replaces a narrower range", 1, true))
                assert.is_truthy(narrow(kind, 0.5, 0.505, 0.1):find("at least 0.01", 1, true))
                assert.is_truthy(narrow(kind, 1, 1, 0.1):find("at least 0.01", 1, true))
            end
        end)

        it("rejects a depth range that covers the whole scene but accepts it for luminance", function()
            local message = parseError(depthArgs({ depth = { min = 0, max = 1, falloff = 0.3 } }))

            assert.is_truthy(message:find("covers the whole scene", 1, true))
            assert.are.equal("luminance", RangeMaskGeometry.parseCreate(
                luminanceArgs({ luminance = { min = 0, max = 1 } })).kind)
            assert.are.equal("depth", RangeMaskGeometry.parseCreate(
                depthArgs({ depth = { min = 0, max = 0.99 } })).kind)
        end)

        it("accepts a full-strength band of exactly 0.01 despite float noise", function()
            for _, bounds in ipairs({ { 0.5, 0.51 }, { 0.14, 0.15 }, { 0, 0.01 }, { 0.99, 1 } }) do
                local request = RangeMaskGeometry.parseCreate(depthArgs({
                    depth = { min = bounds[1], max = bounds[2], falloff = 0 },
                }))

                assert.are.equal(bounds[2], request.range.max)
            end
        end)

        it("rejects bad color samples and amounts", function()
            local function parse(color) return parseError(colorArgs({ color = color })) end

            assert.is_truthy(parse({ sample = sample({ x = 1.2 }) })
                :find("color.sample.x must be between 0 and 1", 1, true))
            assert.is_truthy(parse({ sample = sample({ l = -1 }) }):find("color.sample.l must be between 0 and 1", 1, true))
            assert.is_truthy(parse({ sample = { x = 0.1, y = 0.1, l = 0.1, a = 0.1 } })
                :find("color.sample.b is required", 1, true))
            assert.is_truthy(parse({ sample = sample({ extra = 1 }) }):find("unknown property extra", 1, true))
            assert.is_truthy(parse({ sample = sample(), amount = 0 }):find("color.amount", 1, true))
            assert.is_truthy(parse({ sample = sample(), amount = 1.5 }):find("color.amount", 1, true))
            assert.is_truthy(parse({ amount = 0.4 }):find("color.sample is required", 1, true))
        end)

        it("rejects the sRGB fields, which Lightroom does not store", function()
            for _, field in ipairs({ "red", "green", "blue" }) do
                local message = parseError(colorArgs({ color = { sample = sample({ [field] = 0.5 }) } }))

                assert.is_truthy(message:find("color.sample." .. field .. " is not supported", 1, true))
                assert.is_truthy(message:find("give l, a and b", 1, true))
            end
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

        it("writes a depth trapezoid as a DepthRange with the stored type Lightroom uses for depth", function()
            local component = RangeMaskGeometry.newComponent(RangeMaskGeometry.parseCreate(depthArgs()))

            assert.are.equal("Mask/RangeMask", component.What)
            assert.are.equal("Depth Range", component.MaskName)
            assert.are.equal(-1, component.CorrectionRangeMask.Type)
            assert.are.equal(3, component.CorrectionRangeMask.Version)
            assert.are.equal(0, component.CorrectionRangeMask.SampleType)
            assert.are.equal("0.000000 0.000000 0.100000 0.350000", component.CorrectionRangeMask.DepthRange)
            assert.is_nil(component.CorrectionRangeMask.LumRange)
            assert.is_nil(component.CorrectionRangeMask.LuminanceDepthSampleInfo)
        end)

        it("always writes a LumRange and a DepthRange ordered a <= b <= c <= d within 0..1", function()
            local cases = {
                { 0, 0.99, 0 }, { 0.01, 1, 1 }, { 0.5, 0.6, 0.3 }, { 0.3, 0.7, 0 }, { 0.99, 1, 0.5 },
                { 0.1, 0.30000000000000004, 0.19999999999999998 }, { 0, 0.01, 0.1 }, { 0.99, 1, 0.1 },
            }
            for _, case in ipairs(cases) do
                for _, kind in ipairs({ "luminance", "depth" }) do
                    local component = RangeMaskGeometry.newComponent(RangeMaskGeometry.parseCreate(
                        { type = kind, [kind] = { min = case[1], max = case[2], falloff = case[3] } }))
                    local range = component.CorrectionRangeMask
                    local values = {}
                    for token in (range.LumRange or range.DepthRange):gmatch("%S+") do
                        values[#values + 1] = tonumber(token)
                    end
                    assert.are.equal(4, #values)
                    assert.is_true(values[1] >= 0 and values[1] <= values[2] and values[2] <= values[3]
                        and values[3] <= values[4] and values[4] <= 1)
                end
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

        it("writes the stored triple of every Lightroom-authored sample unchanged", function()
            for _, authored in ipairs(LIGHTROOM_AUTHORED_SAMPLES) do
                local component = RangeMaskGeometry.newComponent(RangeMaskGeometry.parseCreate(
                    colorArgs({ color = { sample = sampleOf(authored.stored), amount = 0.5 } })))

                assert.are.equal(authored.stored, component.CorrectionRangeMask.PointModels[1])
            end
        end)

        it("maps invert and subtract onto the component", function()
            local component = RangeMaskGeometry.newComponent(RangeMaskGeometry.parseCreate(
                luminanceArgs({ mask_id = "C1", mode = "subtract", invert = true })))

            assert.is_true(component.MaskInverted)
            assert.are.equal(1, component.MaskBlendMode)
            assert.are.equal(0, component.MaskValue)
        end)
    end)

    describe("copy_sample_from", function()
        local function copyArgs(overrides)
            local args = { type = "color", copy_sample_from = { mask_id = "C1", tool_id = "C1T1" } }
            for key, item in pairs(overrides or {}) do args[key] = item end
            return args
        end

        it("takes the source ids and leaves the sample and the amount to the source", function()
            local request = RangeMaskGeometry.parseCreate(copyArgs())

            assert.are.same({ maskId = "C1", toolId = "C1T1" }, request.copy)
            assert.is_nil(request.range.sample)
            assert.is_nil(request.range.amount)
        end)

        it("accepts a source photo and tweaks the amount, invert and mode", function()
            local request = RangeMaskGeometry.parseCreate(copyArgs({
                color = { amount = 0.2 }, invert = true, mask_id = "C2", mode = "subtract",
                copy_sample_from = { mask_id = "C1", tool_id = "C1T1", photo_id = 77 },
            }))

            assert.are.equal("77", request.copy.photoId)
            assert.are.equal(0.2, request.range.amount)
            assert.is_true(request.invert)
            assert.are.equal("subtract", request.mode)
        end)

        it("refuses to combine with a sample or with another range type", function()
            assert.is_truthy(errorOf(function()
                RangeMaskGeometry.parseCreate(copyArgs({ color = { sample = sample() } }))
            end):find("both give the sample", 1, true))
            assert.is_truthy(errorOf(function()
                RangeMaskGeometry.parseCreate(copyArgs({ type = "luminance" }))
            end):find("only applies to color range masks, not luminance ones", 1, true))
            assert.is_truthy(errorOf(function()
                RangeMaskGeometry.parseCreate(copyArgs({ type = "depth" }))
            end):find("only applies to color range masks", 1, true))
        end)

        it("requires both ids and rejects unknown properties", function()
            assert.is_truthy(errorOf(function()
                RangeMaskGeometry.parseCreate(copyArgs({ copy_sample_from = { tool_id = "C1T1" } }))
            end):find("copy_sample_from.mask_id must be a non-empty string", 1, true))
            assert.is_truthy(errorOf(function()
                RangeMaskGeometry.parseCreate(copyArgs({ copy_sample_from = { mask_id = "C1" } }))
            end):find("copy_sample_from.tool_id must be a non-empty string", 1, true))
            assert.is_truthy(errorOf(function()
                RangeMaskGeometry.parseCreate(copyArgs({ copy_sample_from = { mask_id = "C1", tool_id = "T", x = 1 } }))
            end):find("copy_sample_from has an unknown property x", 1, true))
            assert.is_truthy(errorOf(function()
                RangeMaskGeometry.parseCreate(copyArgs({ copy_sample_from = "C1T1" }))
            end):find("copy_sample_from must be an object", 1, true))
        end)

        it("still needs a sample when nothing is copied", function()
            assert.is_truthy(errorOf(function()
                RangeMaskGeometry.parseCreate({ type = "color", color = { amount = 0.3 } })
            end):find("color.sample is required unless copy_sample_from", 1, true))
            assert.is_truthy(errorOf(function()
                RangeMaskGeometry.parseCreate({ type = "color" })
            end):find("color is required for a color range mask", 1, true))
        end)

        it("reads every Lightroom-authored color range as copiable", function()
            for _, authored in ipairs(LIGHTROOM_AUTHORED_SAMPLES) do
                local range = RangeMaskGeometry.copiableColorRange({
                    What = "Mask/RangeMask",
                    CorrectionRangeMask = { Type = 1, ColorAmount = 0.494949, PointModels = { authored.stored } },
                })

                assert.are.same(sampleOf(authored.stored), range.sample)
                assert.are.equal(0.494949, range.amount)
            end
        end)

        it("names why another component cannot be copied", function()
            local function reason(component)
                local range, problem = RangeMaskGeometry.copiableColorRange(component)
                assert.is_nil(range)
                return problem
            end

            assert.are.equal("is not a range mask", reason({ What = "Mask/Gradient" }))
            assert.are.equal("is a luminance range, not a color range", reason({
                What = "Mask/RangeMask", CorrectionRangeMask = { Type = 2, LumRange = "0 0.1 0.2 0.3" },
            }))
            assert.are.equal("is a depth range, not a color range", reason({
                What = "Mask/RangeMask", CorrectionRangeMask = { Type = -1, DepthRange = "0 0.1 0.2 0.3" },
            }))
            assert.are.equal("is a range of an unsupported type, not a color range", reason({
                What = "Mask/RangeMask", CorrectionRangeMask = { Type = 3 },
            }))
            assert.are.equal("has 2 color sample points; exactly one can be copied", reason({
                What = "Mask/RangeMask",
                CorrectionRangeMask = { Type = 1, PointModels = { "0.1 0.2 0.3 0.4 0.5 0", "0.2 0.2 0.3 0.4 0.5 0" } },
            }))
            assert.are.equal("has 0 color sample points; exactly one can be copied", reason({
                What = "Mask/RangeMask", CorrectionRangeMask = { Type = 1, PointModels = {} },
            }))
            assert.are.equal("has a color sample that cannot be read", reason({
                What = "Mask/RangeMask", CorrectionRangeMask = { Type = 1, ColorAmount = 0.5, PointModels = { "a b" } },
            }))
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
            assert.are.same({ sample = { x = 0.4, y = 0.5, l = 0.1, a = 0.2, b = 0.3 }, amount = 0.4 }, range)
        end)

        it("reads every Lightroom-authored sample back as the l, a and b it stored", function()
            for _, authored in ipairs(LIGHTROOM_AUTHORED_SAMPLES) do
                local kind, range = RangeMaskGeometry.rangeOf({
                    What = "Mask/RangeMask",
                    CorrectionRangeMask = { Type = 1, ColorAmount = 0.494949, PointModels = { authored.stored } },
                })
                local expected = sampleOf(authored.stored)

                assert.are.equal("color", kind)
                for field, value in pairs(expected) do
                    assert.is_true(math.abs(range.sample[field] - value) < 1e-6)
                end
            end
        end)

        it("shows the stored triple is not a function of sRGB: one color stores different triples per photo", function()
            local function storedFor(photo, srgb)
                for _, authored in ipairs(LIGHTROOM_AUTHORED_SAMPLES) do
                    if authored.photo == photo and authored.srgb[1] == srgb[1] and authored.srgb[2] == srgb[2]
                        and authored.srgb[3] == srgb[3] then
                        return sampleOf(authored.stored)
                    end
                end
            end

            for _, srgb in ipairs({ { 0, 0, 0 }, { 255, 255, 255 }, { 255, 0, 0 } }) do
                local one, two = storedFor("chart one", srgb), storedFor("chart two", srgb)

                assert.is_true(math.abs(one.a - two.a) > 0.01 or math.abs(one.l - two.l) > 0.01)
            end
        end)

        it("reads a depth trapezoid back from the stored depth type", function()
            local kind, range = RangeMaskGeometry.rangeOf({
                What = "Mask/RangeMask",
                CorrectionRangeMask = { Type = -1, DepthRange = "0.000000 0.000000 0.100000 0.350000" },
            })

            assert.are.equal("depth", kind)
            assert.are.same({ min = 0, max = 0.1, lower_falloff = 0, upper_falloff = 0.25 }, range)
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
