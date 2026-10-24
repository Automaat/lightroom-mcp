require 'spec_helper'

local MaskTypes = require 'MaskTypes'

describe("MaskTypes", function()
    it("maps every listed name to an SDK tool type and subtype", function()
        for _, name in ipairs(MaskTypes.NAMES) do
            local spec = MaskTypes.SPECS[name]
            assert.is_string(spec.toolType)
            assert.is_string(spec.subtype)
        end
    end)

    it("lists exactly the names that have a spec", function()
        local count = 0
        for _ in pairs(MaskTypes.SPECS) do count = count + 1 end
        assert.are.equal(#MaskTypes.NAMES, count)
    end)

    it("returns the name and spec of a known type", function()
        local name, spec = MaskTypes.require("sky")

        assert.are.equal("sky", name)
        assert.are.same({ toolType = "aiSelection", subtype = "sky" }, spec)
    end)

    it("rejects an unknown or non-string type and names the valid ones", function()
        for _, bad in ipairs({ "people", "", 3, false }) do
            local ok, err = pcall(MaskTypes.require, bad)

            assert.is_false(ok)
            assert.truthy(tostring(err):find("type must be one of: subject, sky, background", 1, true))
        end
    end)
end)
