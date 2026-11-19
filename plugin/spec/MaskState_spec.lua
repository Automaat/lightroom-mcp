require 'spec_helper'

local MaskState = require 'MaskState'

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

local function firstComponent(summary)
    return summary.masks[1].components[1]
end

describe("MaskState.summarize", function()
    it("reports no masks when the settings hold none or are not a table", function()
        assert.are.same({ count = 0, state = "none" }, MaskState.summarize({}))
        assert.are.same({ count = 0, state = "none" }, MaskState.summarize({ MaskGroupBasedCorrections = {} }))
        assert.are.same({ state = "unknown" }, MaskState.summarize(nil))
    end)

    it("calls an AI mask computed when a digest is saved and no error is", function()
        local summary = MaskState.summarize({ MaskGroupBasedCorrections = { {
            What = "Correction", CorrectionID = "group-1", CorrectionName = "Mask 1",
            CorrectionMasks = { ai({ MaskID = "tool-1", MaskBlendMode = 0 }) },
        } } })
        assert.are.equal(1, summary.count)
        assert.are.equal("computed", summary.state)
        assert.are.same({
            id = "group-1",
            name = "Mask 1",
            state = "computed",
            components = { {
                id = "tool-1", type = "Image", mode = "add", subtype = 1, kind = "subject", state = "computed",
            } },
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
        assert.are.equal(3, firstComponent(summary).error_reason)
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

    it("tells add, subtract and intersect components apart", function()
        local components = MaskState.summarize(settingsWith({
            ai({ MaskSubType = 1 }),
            ai({ MaskSubType = 2, MaskBlendMode = 1 }),
            ai({ MaskSubType = 2, MaskBlendMode = 1, MaskInverted = true }),
            ai({ MaskSubType = 2, MaskBlendMode = 0, MaskInverted = true }),
            ai({ MaskSubType = 2, MaskBlendMode = 2 }),
        })).masks[1].components
        assert.are.same({ "add", "subtract", "subtract", "add", "unknown" },
            { components[1].mode, components[2].mode, components[3].mode, components[4].mode, components[5].mode })
        assert.is_nil(components[2].inverted)
        assert.is_true(components[3].inverted)
        assert.is_true(components[4].inverted)
    end)

    it("names subject, sky, background, people parts and landscape categories as create_mask does", function()
        local summary = MaskState.summarize(settingsWith(
            { ai({ MaskSubType = 1 }) },
            { ai({ MaskSubType = 2 }) },
            { ai({ MaskSubType = 3, MaskSubCategoryID = 2 }) },
            { ai({ MaskSubType = 3, MaskSubCategoryID = 12 }) },
            { ai({ MaskSubType = 0, MaskSubCategoryID = 50005 }) },
            { ai({ MaskSubType = 0, MaskSubCategoryID = 50006 }) },
            { ai({ MaskSubType = 3, MaskSubCategoryID = 99 }) },
            { ai({ MaskSubType = 9 }) },
            { ai({ MaskSubType = 0, MaskSubCategoryID = 22 }) },
            { ai({ MaskSubType = 0 }) }))
        local named = {}
        for i, mask in ipairs(summary.masks) do
            local component = mask.components[1]
            named[i] = { component.subtype, component.kind or false, component.part or false }
        end
        assert.are.same({
            { 1, "subject", false },
            { 2, "sky", false },
            { 3, "people", "face_skin" },
            { 3, "people", "teeth" },
            { 0, "landscape", "vegetation" },
            { 0, "landscape", "sky" },
            { 3, "people", false },
            { 9, false, false },
            { 0, "background", false },
            { 0, false, false },
        }, named)
    end)

    it("gives non-AI groups no state and reports inverted components", function()
        local summary = MaskState.summarize(settingsWith(
            { { What = "Mask/Gradient", MaskID = "g" } },
            { { What = "Mask/CircularGradient", MaskInverted = true, MaskBlendMode = 1 } }))
        assert.are.equal(2, summary.count)
        assert.are.equal("none", summary.state)
        assert.is_nil(summary.masks[1].state)
        assert.are.same({ { id = "g", type = "Gradient", mode = "add" } }, summary.masks[1].components)
        assert.are.same({ { type = "CircularGradient", mode = "subtract", inverted = true } },
            summary.masks[2].components)
    end)

    it("lists the strokes of a brush aggregate and gives it no state", function()
        local brush = {
            What = "Mask/Aggregate", MaskID = "brush", MaskBlendMode = 0, MaskName = "Brush",
            Masks = { { What = "Mask/Paint", MaskValue = 1 }, { What = "Mask/Paint", MaskValue = 0 } },
        }
        local summary = MaskState.summarize(settingsWith({ brush }))
        assert.are.equal("none", summary.state)
        assert.is_nil(summary.masks[1].state)
        assert.are.same({
            id = "brush", type = "Aggregate", mode = "add",
            components = { { type = "Paint", mode = "add" }, { type = "Paint", mode = "erase" } },
        }, firstComponent(summary))
    end)

    it("carries the state of AI components nested in an aggregate", function()
        local summary = MaskState.summarize(settingsWith(
            { { What = "Mask/Aggregate", Masks = { { What = "Mask/Paint" }, ai({ MaskDigest = NONE }) } } }))
        assert.are.equal("pending", summary.state)
        assert.are.equal("pending", summary.masks[1].state)
        assert.are.equal("pending", firstComponent(summary).state)
        assert.are.equal("pending", firstComponent(summary).components[2].state)
    end)

    it("does not trust a malformed or too deeply nested aggregate", function()
        assert.are.equal("unknown", MaskState.summarize(settingsWith(
            { { What = "Mask/Aggregate", Masks = { a = {} } } })).state)
        local nested = ai()
        for _ = 1, 4 do nested = { What = "Mask/Aggregate", Masks = { nested } } end
        assert.are.equal("unknown", MaskState.summarize(settingsWith({ nested })).state)
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
end)
