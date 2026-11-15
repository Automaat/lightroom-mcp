require 'spec_helper'

local MaskState = require 'MaskState'

-- A field set to NONE is removed from the default component.
local NONE = {}

local function ai(fields)
    local component = { What = "Mask/Image", MaskSubType = 1, MaskDigest = "digest" }
    for key, value in pairs(fields or {}) do
        if value == NONE then component[key] = nil else component[key] = value end
    end
    return component
end

local function settingsWith(...)
    local groups = {}
    for i, components in ipairs({ ... }) do
        groups[i] = { What = "Correction", CorrectionID = "group-" .. i, CorrectionMasks = components }
    end
    return { MaskGroupBasedCorrections = groups }
end

describe("MaskState.summarize", function()
    it("reports no masks when the settings hold none or are not a table", function()
        assert.are.same({ count = 0, state = "none" }, MaskState.summarize({}))
        assert.are.same({ count = 0, state = "none" }, MaskState.summarize({ MaskGroupBasedCorrections = {} }))
        assert.are.same({ state = "unknown" }, MaskState.summarize(nil))
    end)

    it("calls an AI mask computed when a digest is saved and no error is", function()
        local summary = MaskState.summarize(settingsWith({ ai() }))
        assert.are.equal(1, summary.count)
        assert.are.equal("computed", summary.state)
        assert.are.same({
            id = "group-1",
            state = "computed",
            components = { { type = "Image", subtype = 1, state = "computed" } },
        }, summary.masks[1])
    end)

    it("treats a zero ErrorReason like an absent one", function()
        assert.are.equal("computed", MaskState.summarize(settingsWith({ ai({ ErrorReason = 0 }) })).state)
    end)

    it("calls an AI mask pending until it has a digest", function()
        assert.are.equal("pending", MaskState.summarize(settingsWith({ ai({ MaskDigest = NONE }) })).state)
        assert.are.equal("pending", MaskState.summarize(settingsWith({ ai({ MaskDigest = "" }) })).state)
    end)

    it("calls an AI mask failed on a nonzero ErrorReason and keeps the code", function()
        local summary = MaskState.summarize(settingsWith({ ai({ MaskDigest = NONE, ErrorReason = 3 }) }))
        assert.are.equal("failed", summary.state)
        assert.are.equal(3, summary.masks[1].components[1].error_reason)
    end)

    it("calls an AI mask unknown when a field has an unexpected type", function()
        assert.are.equal("unknown", MaskState.summarize(settingsWith({ ai({ MaskDigest = 7 }) })).state)
        assert.are.equal("unknown", MaskState.summarize(settingsWith({ ai({ ErrorReason = "x" }) })).state)
        assert.are.equal("unknown", MaskState.summarize(settingsWith({ ai({ ErrorReason = 0 / 0 }) })).state)
    end)

    it("never copies the digest out", function()
        local summary = MaskState.summarize(settingsWith({ ai({ MaskDigest = "secret-blob" }) }))
        assert.is_nil(string.find(require('JSON'):encode(summary), "secret-blob", 1, true))
    end)

    it("gives non-AI groups no state and reports inverted components", function()
        local summary = MaskState.summarize(settingsWith(
            { { What = "Mask/Gradient" } },
            { { What = "Mask/CircularGradient", MaskInverted = true }, { What = "Mask/Paint" } }))
        assert.are.equal(2, summary.count)
        assert.are.equal("none", summary.state)
        assert.is_nil(summary.masks[1].state)
        assert.are.same({ { type = "Gradient" } }, summary.masks[1].components)
        assert.are.same({ { type = "CircularGradient", inverted = true }, { type = "Paint" } },
            summary.masks[2].components)
    end)

    it("takes the worst state across components and groups", function()
        local mixed = MaskState.summarize(settingsWith({ ai(), ai({ MaskDigest = NONE }) }))
        assert.are.equal("pending", mixed.masks[1].state)
        assert.are.equal("pending", mixed.state)
        local failed = MaskState.summarize(settingsWith({ ai() }, { ai({ MaskDigest = NONE }) },
            { ai({ MaskDigest = NONE, ErrorReason = 1 }) }))
        assert.are.equal("failed", failed.state)
        assert.are.equal("computed", failed.masks[1].state)
        assert.are.equal("pending", failed.masks[2].state)
        assert.are.equal("failed", failed.masks[3].state)
        local manual = MaskState.summarize(settingsWith({ { What = "Mask/Gradient" } }, { ai() }))
        assert.are.equal("computed", manual.state)
    end)

    it("does not trust malformed or repeated saved structures", function()
        assert.are.same({ state = "unknown" },
            MaskState.summarize({ MaskGroupBasedCorrections = { a = {} } }))
        local broken = MaskState.summarize({ MaskGroupBasedCorrections = { "x", {}, { CorrectionMasks = {} },
            { CorrectionMasks = { "x", { What = 5 } } } } })
        assert.are.equal(4, broken.count)
        assert.are.equal("unknown", broken.state)
        for _, mask in ipairs(broken.masks) do assert.are.equal("unknown", mask.state) end
        local twice = MaskState.summarize({ MaskGroupBasedCorrections = {
            { CorrectionID = "same", CorrectionMasks = { ai() } },
            { CorrectionID = "same", CorrectionMasks = { ai() } } } })
        assert.are.equal("computed", twice.masks[1].state)
        assert.are.equal("unknown", twice.masks[2].state)
        assert.are.equal("unknown", twice.state)
    end)

    it("keeps people and landscape subtypes as Lightroom saved them", function()
        local summary = MaskState.summarize(settingsWith({ ai({ MaskSubType = 3 }) }, { ai({ MaskSubType = 0 }) }))
        assert.are.equal(3, summary.masks[1].components[1].subtype)
        assert.are.equal(0, summary.masks[2].components[1].subtype)
    end)
end)
