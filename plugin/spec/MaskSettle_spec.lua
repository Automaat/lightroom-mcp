local helper = require 'spec_helper'

local function setup(entriesNow)
    local state = { entries = entriesNow, sleeps = 0, updates = {} }
    local photo = {
        getDevelopSettings = function() return { MaskGroupBasedCorrections = state.entries } end,
    }
    local catalog = { withReadAccessDo = function(_, fn) fn() end }
    helper.installImport({
        LrApplication = { versionTable = function() return { major = 15, minor = 6, revision = 0 } end },
        LrApplicationView = {},
        LrDevelopController = {},
        LrSelection = {},
        LrTasks = {
            pcall = pcall,
            sleep = function()
                state.sleeps = state.sleeps + 1
                local update = state.updates[state.sleeps]
                if update then state.entries = update end
            end,
        },
        LrLogger = helper.defaultLrLogger(),
    })
    for _, name in ipairs({ "MaskSettle", "DevelopSession", "GuardedMaskWrite", "Log" }) do
        package.loaded[name] = nil
    end
    return require 'MaskSettle', catalog, photo, state
end

local function entry(id, fields)
    local built = { What = "Correction", CorrectionID = id, CorrectionMasks = {} }
    for key, value in pairs(fields or {}) do built[key] = value end
    return built
end

describe("MaskSettle.storedAdjustmentFields", function()
    it("returns the adjustment fields of the requested mask, not its shape", function()
        local Settle, catalog, photo = setup({
            entry("a", { LocalExposure2012 = 0.25, CorrectionName = "A" }),
            entry("b", { LocalContrast2012 = 0.5 }),
        })

        assert.are.same({ LocalExposure2012 = 0.25, CorrectionName = "A", CorrectionID = "a", What = "Correction" },
            Settle.storedAdjustmentFields(catalog, photo, "a"))
    end)

    it("returns nil for a mask the photo does not store", function()
        local Settle, catalog, photo = setup({ entry("a") })

        assert.is_nil(Settle.storedAdjustmentFields(catalog, photo, "missing"))
    end)
end)

describe("MaskSettle.sameFields", function()
    it("compares numbers, nested tables and absence", function()
        local Settle = setup({})

        assert.is_true(Settle.sameFields({ LocalExposure2012 = 0.25 }, { LocalExposure2012 = 0.25 }))
        assert.is_false(Settle.sameFields({ LocalExposure2012 = 0.25 }, { LocalExposure2012 = 0.5 }))
        assert.is_false(Settle.sameFields({ LocalExposure2012 = 0.25 }, {}))
        assert.is_false(Settle.sameFields({}, { LocalExposure2012 = 0.25 }))
        assert.is_true(Settle.sameFields({ LocalCurve = { 1, 2 } }, { LocalCurve = { 1, 2 } }))
        assert.is_false(Settle.sameFields({ LocalCurve = { 1, 2 } }, { LocalCurve = { 1, 3 } }))
        assert.is_true(Settle.sameFields(nil, nil))
        assert.is_false(Settle.sameFields(nil, {}))
    end)
end)

describe("MaskSettle.waitForCommit", function()
    it("returns at once when the stored fields already differ", function()
        local Settle, catalog, photo, state = setup({ entry("a", { LocalExposure2012 = 0.5 }) })

        assert.is_true(Settle.waitForCommit(catalog, photo, "a", { LocalExposure2012 = 0.25 }))
        assert.are.equal(0, state.sleeps)
    end)

    it("waits for a save that lands later", function()
        local Settle, catalog, photo, state = setup({ entry("a", { LocalExposure2012 = 0.25 }) })
        local before = Settle.storedAdjustmentFields(catalog, photo, "a")
        state.updates[7] = { entry("a", { LocalExposure2012 = 0.5 }) }

        assert.is_true(Settle.waitForCommit(catalog, photo, "a", before))
        assert.are.equal(7, state.sleeps)
    end)

    it("gives up when the stored fields never change", function()
        local Settle, catalog, photo, state = setup({ entry("a", { LocalExposure2012 = 0.25 }) })
        local before = Settle.storedAdjustmentFields(catalog, photo, "a")

        assert.is_false(Settle.waitForCommit(catalog, photo, "a", before))
        assert.is_true(state.sleeps >= Settle.COMMIT_TIMEOUT_SECONDS * 10 - 1)
    end)

    it("sees a changed curve as a save", function()
        local Settle, catalog, photo, state = setup({ entry("a", { MainCurve = { 0, 0, 255, 255 } }) })
        local before = Settle.storedAdjustmentFields(catalog, photo, "a")
        state.updates[2] = { entry("a", { MainCurve = { 0, 0, 128, 200, 255, 255 } }) }

        assert.is_true(Settle.waitForCommit(catalog, photo, "a", before))
    end)

    it("ignores a change to the mask shape", function()
        local Settle, catalog, photo, state = setup({ entry("a", { LocalExposure2012 = 0.25 }) })
        local before = Settle.storedAdjustmentFields(catalog, photo, "a")
        local reshaped = entry("a", { LocalExposure2012 = 0.25 })
        reshaped.CorrectionMasks = { { What = "Mask/Gradient" } }
        state.updates[2] = { reshaped }

        assert.is_false(Settle.waitForCommit(catalog, photo, "a", before))
    end)

    it("treats a mask that appears in the saved settings as saved", function()
        local Settle, catalog, photo, state = setup({})
        state.updates[3] = { entry("a", { LocalExposure2012 = 0.5 }) }

        assert.is_true(Settle.waitForCommit(catalog, photo, "a", nil))
    end)
end)
