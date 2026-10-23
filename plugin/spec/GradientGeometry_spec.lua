local helper = require 'spec_helper'

local GradientGeometry

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

local function point(x, y) return { x = x, y = y } end

local function linearArgs(overrides)
    local args = { shape = "linear", start = point(0.5, 0.2), ["end"] = point(0.5, 0.6) }
    for key, value in pairs(overrides or {}) do args[key] = value end
    return args
end

local function radialArgs(overrides)
    local args = { shape = "radial", center = point(0.5, 0.5), width = 0.4, height = 0.6 }
    for key, value in pairs(overrides or {}) do args[key] = value end
    return args
end

describe("GradientGeometry.parseCreate", function()
    before_each(function()
        helper.installImport({})
        package.loaded.GradientGeometry = nil
        GradientGeometry = require 'GradientGeometry'
    end)

    it("parses a linear gradient into start and end", function()
        local request = GradientGeometry.parseCreate(linearArgs())

        assert.are.equal("linear", request.shape)
        assert.are.same({ start = point(0.5, 0.2), ["end"] = point(0.5, 0.6) }, request.geometry)
        assert.are.equal("add", request.mode)
        assert.is_nil(request.maskId)
    end)

    it("fills radial defaults", function()
        local request = GradientGeometry.parseCreate(radialArgs())

        assert.are.equal(0, request.geometry.rotation)
        assert.are.equal(50, request.geometry.feather)
        assert.are.equal("inside", request.geometry.area)
    end)

    it("keeps explicit radial rotation, feather and area", function()
        local request = GradientGeometry.parseCreate(radialArgs({ rotation = -45, feather = 0, area = "outside" }))

        assert.are.equal(-45, request.geometry.rotation)
        assert.are.equal(0, request.geometry.feather)
        assert.are.equal("outside", request.geometry.area)
    end)

    it("accepts the image edges", function()
        local request = GradientGeometry.parseCreate(linearArgs({ start = point(0, 0), ["end"] = point(1, 1) }))

        assert.are.equal(1, request.geometry["end"].x)
    end)

    local rejected = {
        { "a coordinate above 1", linearArgs({ ["end"] = point(0.5, 1.01) }), "end.y is outside the image" },
        { "a negative coordinate", linearArgs({ start = point(-0.01, 0.5) }), "start.x is outside the image" },
        { "a radial center outside the image", radialArgs({ center = point(1.5, 0.5) }), "center.x is outside the image" },
        { "a string coordinate", linearArgs({ start = point("0.5", 0.5) }), "start.x must be a number" },
        { "a boolean coordinate", linearArgs({ start = point(true, 0.5) }), "start.x must be a number" },
        { "a missing y", linearArgs({ start = { x = 0.5 } }), "start.y must be a number" },
        { "a point that is not an object", linearArgs({ start = 0.5 }), "start must be an object" },
        { "an unknown point property", linearArgs({ start = { x = 0.5, y = 0.5, z = 1 } }), "unknown property z" },
        { "identical start and end", linearArgs({ start = point(0.3, 0.3), ["end"] = point(0.3, 0.3) }),
            "same point" },
        { "a missing start", linearArgs({ start = false }), "start is required" },
        { "a missing center", radialArgs({ center = false }), "center is required" },
        { "zero width", radialArgs({ width = 0 }), "width must be greater than 0" },
        { "oversized height", radialArgs({ height = 2.5 }), "height must be greater than 0" },
        { "rotation beyond a full turn", radialArgs({ rotation = 361 }), "rotation must be between" },
        { "feather above 100", radialArgs({ feather = 101 }), "feather must be between 0 and 100" },
        { "an unknown area", radialArgs({ area = "around" }), 'area must be "inside" or "outside"' },
        { "a radial field on a linear gradient", linearArgs({ feather = 10 }), "feather only applies to radial" },
        { "a linear field on a radial gradient", radialArgs({ start = point(0, 0) }), "start only applies to linear" },
        { "an unknown shape", { shape = "brush" }, 'shape must be "linear" or "radial"' },
        { "an unknown mode", linearArgs({ mask_id = "m", mode = "intersect" }), 'mode must be "add" or "subtract"' },
        { "subtract without a mask", linearArgs({ mode = "subtract" }), "needs mask_id" },
        { "a name together with a mask id", linearArgs({ mask_id = "m", name = "Sky" }), "name applies to a new mask" },
        { "an empty mask id", linearArgs({ mask_id = "" }), "mask_id must be a non-empty string" },
        { "a numeric mask id", linearArgs({ mask_id = 4 }), "mask_id must be a non-empty string" },
    }
    for _, case in ipairs(rejected) do
        it("rejects " .. case[1], function()
            local args = case[2]
            for key, value in pairs(args) do
                if value == false then args[key] = nil end
            end

            local message = errorOf(function() GradientGeometry.parseCreate(args) end)

            assert.is_truthy(message:find(case[3], 1, true), message)
        end)
    end

    it("rejects NaN and infinite numbers", function()
        for _, bad in ipairs({ 0 / 0, math.huge, -math.huge }) do
            local message = errorOf(function() GradientGeometry.parseCreate(radialArgs({ rotation = bad })) end)

            assert.is_truthy(message:find("rotation must be a number", 1, true))
        end
    end)

    it("accepts a component request with subtract and an existing mask", function()
        local request = GradientGeometry.parseCreate(linearArgs({ mask_id = "C1", mode = "subtract" }))

        assert.are.equal("C1", request.maskId)
        assert.are.equal("subtract", request.mode)
    end)
end)

describe("GradientGeometry.parseUpdate", function()
    before_each(function()
        helper.installImport({})
        package.loaded.GradientGeometry = nil
        GradientGeometry = require 'GradientGeometry'
    end)

    it("collects only the fields that were given", function()
        local request = GradientGeometry.parseUpdate({ tool_id = "T1", center = point(0.4, 0.4), feather = 80 })

        assert.are.equal("T1", request.toolId)
        assert.are.same({ center = point(0.4, 0.4), feather = 80 }, request.changes)
    end)

    it("requires a tool id and at least one field", function()
        assert.is_truthy(errorOf(function() GradientGeometry.parseUpdate({ start = point(0, 0) }) end)
            :find("tool_id is required", 1, true))
        assert.is_truthy(errorOf(function() GradientGeometry.parseUpdate({ tool_id = "T1" }) end)
            :find("at least one geometry field", 1, true))
    end)

    it("validates each given field", function()
        assert.is_truthy(errorOf(function()
            GradientGeometry.parseUpdate({ tool_id = "T1", start = point(2, 0) })
        end):find("start.x is outside the image", 1, true))
    end)
end)

describe("GradientGeometry stored form", function()
    before_each(function()
        helper.installImport({})
        package.loaded.GradientGeometry = nil
        GradientGeometry = require 'GradientGeometry'
    end)

    it("stores a linear gradient with the full effect at start and none at end", function()
        local component = GradientGeometry.newComponent("linear", GradientGeometry.parseCreate(linearArgs()).geometry, "add")

        assert.are.equal("Mask/Gradient", component.What)
        assert.are.equal(0.5, component.FullX)
        assert.are.equal(0.2, component.FullY)
        assert.are.equal(0.5, component.ZeroX)
        assert.are.equal(0.6, component.ZeroY)
        assert.are.equal(0, component.MaskBlendMode)
        assert.is_false(component.MaskInverted)
    end)

    it("stores a radial gradient as a box around the center", function()
        local geometry = GradientGeometry.parseCreate(radialArgs({
            center = point(0.5, 0.4), rotation = 30, feather = 20, area = "outside",
        })).geometry

        local component = GradientGeometry.newComponent("radial", geometry, "add")

        assert.are.equal("Mask/CircularGradient", component.What)
        assert.is_true(math.abs(component.Left - 0.3) < 1e-9)
        assert.is_true(math.abs(component.Right - 0.7) < 1e-9)
        assert.is_true(math.abs(component.Top - 0.1) < 1e-9)
        assert.is_true(math.abs(component.Bottom - 0.7) < 1e-9)
        assert.are.equal(30, component.Angle)
        assert.are.equal(20, component.Feather)
        assert.are.equal(50, component.Midpoint)
        assert.are.equal(0, component.Roundness)
        assert.are.equal(2, component.Version)
        assert.is_true(component.MaskInverted)
        assert.is_nil(component.Flipped)
    end)

    it("marks a subtract component with blend mode 1", function()
        local geometry = GradientGeometry.parseCreate(linearArgs()).geometry

        local component = GradientGeometry.newComponent("linear", geometry, "subtract")

        assert.are.equal(1, component.MaskBlendMode)
        assert.are.equal(0, component.MaskValue)
    end)

    it("reads geometry back from a stored component", function()
        local geometry = GradientGeometry.parseCreate(radialArgs({ rotation = 15, area = "outside" })).geometry
        local component = GradientGeometry.newComponent("radial", geometry, "add")

        local shape, read = GradientGeometry.geometryOf(component)

        assert.are.equal("radial", shape)
        assert.are.same(geometry, read)
    end)

    it("reports no shape for other mask types", function()
        assert.is_nil(GradientGeometry.shapeOf({ What = "Mask/Aggregate" }))
        assert.are.equal("linear", GradientGeometry.shapeOf({ What = "Mask/Gradient" }))
    end)

    it("merges changes over the current geometry and re-checks it", function()
        local current = GradientGeometry.parseCreate(linearArgs()).geometry

        local merged = GradientGeometry.mergeChanges("linear", current, { ["end"] = point(0.9, 0.9) })

        assert.are.same(point(0.5, 0.2), merged.start)
        assert.are.same(point(0.9, 0.9), merged["end"])
        assert.are.same(point(0.5, 0.6), current["end"])
        assert.is_truthy(errorOf(function()
            GradientGeometry.mergeChanges("linear", current, { ["end"] = point(0.5, 0.2) })
        end):find("same point", 1, true))
    end)

    it("refuses a field of the other shape when merging", function()
        local current = GradientGeometry.parseCreate(linearArgs()).geometry

        local message = errorOf(function() GradientGeometry.mergeChanges("linear", current, { feather = 5 }) end)

        assert.is_truthy(message:find("feather only applies to radial gradients, but this tool is a linear", 1, true))
    end)

    it("clears the derived Flipped flag when it rewrites a radial component", function()
        local component = { What = "Mask/CircularGradient", Flipped = true, MaskInverted = false }
        local geometry = GradientGeometry.parseCreate(radialArgs({ area = "outside" })).geometry

        GradientGeometry.applyGeometry("radial", component, geometry)

        assert.is_nil(component.Flipped)
        assert.is_true(component.MaskInverted)
    end)
end)
