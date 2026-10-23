local helper = require 'spec_helper'

local Store = require 'fake_mask_store'

local linearComponent = Store.linearComponent
local radialComponent = Store.radialComponent
local correction = Store.correction

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

local function setup(opts)
    opts = opts or {}
    local photo = {}
    local state = Store.attach(photo, opts)
    state.sleeps = 0
    local version = opts.version or { major = 15, minor = 6, revision = 0 }
    local catalog = {
        withReadAccessDo = function(_, fn) fn() end,
        withWriteAccessDo = function(_, _, fn) fn() end,
    }
    Store.trackGates(state, catalog)
    helper.installImport({
        LrApplication = { versionTable = function() return version end },
        LrTasks = {
            pcall = pcall,
            sleep = function() state.sleeps = state.sleeps + 1 end,
        },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.GuardedMaskWrite = nil
    package.loaded.Log = nil
    local Guard = require 'GuardedMaskWrite'
    return Guard, catalog, photo, state
end

local function appendGradient(component)
    return function(entries)
        entries[#entries + 1] = correction("New", { component })
        return entries
    end
end

describe("GuardedMaskWrite.preflight", function()
    it("returns the existing entries on a tested Lightroom and process version", function()
        local Guard, catalog, photo = setup({ entries = { correction("A", { linearComponent() }) } })

        local entries = Guard.preflight(catalog, photo)

        assert.are.equal(1, #entries)
        assert.are.equal("A", entries[1].CorrectionName)
    end)

    it("returns an empty list for a photo without masks", function()
        local Guard, catalog, photo = setup()

        assert.are.same({}, Guard.preflight(catalog, photo))
    end)

    it("reads settings inside the read gate", function()
        local Guard, catalog, photo, state = setup()

        Guard.preflight(catalog, photo)

        assert.are.equal(0, state.readsOutsideGate)
        assert.are.equal(1, state.reads)
    end)

    it("refuses an untested Lightroom version and names it", function()
        local Guard, catalog, photo = setup({ version = { major = 15, minor = 7 } })

        local message = errorOf(function() Guard.preflight(catalog, photo) end)

        assert.is_truthy(message:find("15.7", 1, true))
        assert.is_truthy(message:find("tested: 15.6", 1, true))
        assert.is_truthy(message:find("Nothing was changed", 1, true))
    end)

    it("refuses an untested process version", function()
        local Guard, catalog, photo = setup({ processVersion = "11.0" })

        local message = errorOf(function() Guard.preflight(catalog, photo) end)

        assert.is_truthy(message:find("process version (11.0)", 1, true))
    end)

    it("refuses a photo that reports no process version", function()
        local Guard, catalog, photo = setup({ noProcessVersion = true })

        local message = errorOf(function() Guard.preflight(catalog, photo) end)

        assert.is_truthy(message:find("process version (nil)", 1, true))
    end)

    it("refuses when an existing component lost a pinned field to a rename", function()
        local renamed = linearComponent()
        renamed.FullY = nil
        renamed.FullYY = 0.2
        local Guard, catalog, photo = setup({ entries = { correction("A", { renamed }) } })

        local message = errorOf(function() Guard.preflight(catalog, photo) end)

        assert.is_truthy(message:find("15.6", 1, true))
        assert.is_truthy(message:find("missing FullY", 1, true))
        assert.is_truthy(message:find("unexpected field FullYY", 1, true))
    end)

    it("refuses when an existing entry has an unknown field", function()
        local entry = correction("A", { linearComponent() }, { CorrectionSomethingNew = 1 })
        local Guard, catalog, photo = setup({ entries = { entry } })

        local message = errorOf(function() Guard.preflight(catalog, photo) end)

        assert.is_truthy(message:find("unexpected field CorrectionSomethingNew", 1, true))
    end)

    it("accepts any Local adjustment slider on an existing entry", function()
        local entry = correction("A", { linearComponent() }, { LocalShadows2012 = 0.1, LocalTexture = 0.2 })
        local Guard, catalog, photo = setup({ entries = { entry } })

        assert.are.equal(1, #Guard.preflight(catalog, photo))
    end)

    it("refuses an existing component with an unknown mask type", function()
        local Guard, catalog, photo = setup({
            entries = { correction("A", { { What = "Mask/Teleport", MaskActive = true } }) },
        })

        local message = errorOf(function() Guard.preflight(catalog, photo) end)

        assert.is_truthy(message:find("unknown mask type Mask/Teleport", 1, true))
    end)

    it("treats an AI mask component as opaque", function()
        local ai = { What = "Mask/Image", MaskActive = true, SomethingOpaque = { 1, 2, 3 }, Whatever = "x" }
        local Guard, catalog, photo = setup({ entries = { correction("AI", { ai }) } })

        assert.are.equal(1, #Guard.preflight(catalog, photo))
    end)

    it("accepts existing brush and luminance range masks", function()
        local brush = {
            What = "Mask/Aggregate",
            MaskActive = true,
            Masks = {
                { What = "Mask/Paint", Dabs = { "d 0.1 0.2" }, Radius = 0.1, Flow = 1, CenterWeight = 0 },
            },
        }
        local range = {
            What = "Mask/RangeMask",
            MaskActive = true,
            CorrectionRangeMask = { Type = 2, Version = 3, SampleType = 0, LumRange = "0.1 0.2 0.3 0.4" },
        }
        local Guard, catalog, photo = setup({ entries = { correction("B", { brush }), correction("R", { range }) } })

        assert.are.equal(2, #Guard.preflight(catalog, photo))
    end)

    it("refuses an existing depth range mask", function()
        local range = {
            What = "Mask/RangeMask",
            CorrectionRangeMask = { Type = 3, DepthRange = "0 0 1 1" },
        }
        local Guard, catalog, photo = setup({ entries = { correction("D", { range }) } })

        local message = errorOf(function() Guard.preflight(catalog, photo) end)

        assert.is_truthy(message:find("unsupported range Type 3", 1, true))
    end)

    it("refuses an existing color range with two samples", function()
        local range = {
            What = "Mask/RangeMask",
            CorrectionRangeMask = { Type = 1, ColorAmount = 0.5, PointModels = { "a", "b" } },
        }
        local Guard, catalog, photo = setup({ entries = { correction("C", { range }) } })

        local message = errorOf(function() Guard.preflight(catalog, photo) end)

        assert.is_truthy(message:find("exactly one PointModels entry", 1, true))
    end)
end)

describe("GuardedMaskWrite.apply", function()
    local function applyAppend(Guard, catalog, photo, component, extra)
        local spec = {
            description = "Test write",
            build = appendGradient(component),
        }
        for key, value in pairs(extra or {}) do spec[key] = value end
        return Guard.apply(catalog, photo, spec)
    end

    it("writes the whole array, reads it back and returns the stored entries", function()
        local existing = correction("Old", { radialComponent({ MaskID = "OLDT1" }) }, { CorrectionID = "OLD" })
        local Guard, catalog, photo, state = setup({ entries = { existing } })

        local result = applyAppend(Guard, catalog, photo, linearComponent())

        assert.are.equal(1, #state.writes)
        assert.are.equal(2, #state.writes[1])
        assert.are.equal("OLD", state.writes[1][1].CorrectionID)
        assert.is_nil(state.writes[1][2].CorrectionID)
        assert.are.equal(2, #result.entries)
        assert.are.equal("C1", result.entries[2].CorrectionID)
        assert.are.equal("C1T1", result.entries[2].CorrectionMasks[1].MaskID)
        assert.are.equal(1, #result.previous)
        assert.are.equal(0, state.writesOutsideGate)
        assert.are.equal(0, state.readsOutsideGate)
    end)

    it("writes into a photo that has no masks yet", function()
        local Guard, catalog, photo, state = setup()

        local result = applyAppend(Guard, catalog, photo, linearComponent())

        assert.are.equal(1, #state.writes[1])
        assert.are.equal(1, #result.entries)
    end)

    it("hands build a copy so a failed build leaves the previous list intact", function()
        local Guard, catalog, photo, state = setup({ entries = { correction("A", { linearComponent() }) } })

        local message = errorOf(function()
            Guard.apply(catalog, photo, {
                description = "x",
                build = function(entries)
                    entries[1].CorrectionName = "changed"
                    error("build failed", 0)
                end,
            })
        end)

        assert.are.equal("build failed", message)
        assert.are.equal(0, #state.writes)
        assert.are.equal("A", state.entries[1].CorrectionName)
    end)

    it("accepts values Lightroom normalizes to six decimals and fills derived fields", function()
        local Guard, catalog, photo = setup({
            transformWrite = function(stored)
                for _, entry in ipairs(stored) do
                    for _, component in ipairs(entry.CorrectionMasks) do
                        if component.FullY then component.FullY = math.floor(component.FullY * 1e6 + 0.5) / 1e6 end
                        component.MaskValue = 0.5
                    end
                end
                return stored
            end,
        })

        local result = applyAppend(Guard, catalog, photo, linearComponent({ FullY = 0.2000004 }))

        assert.are.equal(1, #result.entries)
    end)

    it("waits for a read-back that lags behind the write", function()
        local Guard, catalog, photo, state = setup({ lagReadsAfterWrite = 3 })

        applyAppend(Guard, catalog, photo, linearComponent())

        assert.is_true(state.sleeps >= 3)
        assert.are.equal(1, #state.writes)
    end)

    it("refuses an untested version before reading or writing masks", function()
        local Guard, catalog, photo, state = setup({ version = { major = 16, minor = 0 } })

        errorOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.are.equal(0, #state.writes)
    end)

    it("refuses a new component with a string where a number belongs, writing nothing", function()
        local Guard, catalog, photo, state = setup()

        local message = errorOf(function()
            applyAppend(Guard, catalog, photo, linearComponent({ FullY = "0.2" }))
        end)

        assert.is_truthy(message:find("FullY must be a number", 1, true))
        assert.are.equal(0, #state.writes)
    end)

    it("refuses a boolean where a number belongs and a NaN", function()
        local Guard, catalog, photo, state = setup()

        local booleanMessage = errorOf(function()
            applyAppend(Guard, catalog, photo, linearComponent({ ZeroX = true }))
        end)
        local nanMessage = errorOf(function()
            applyAppend(Guard, catalog, photo, linearComponent({ ZeroX = 0 / 0 }))
        end)

        assert.is_truthy(booleanMessage:find("ZeroX must be a number", 1, true))
        assert.is_truthy(nanMessage:find("ZeroX must be a number", 1, true))
        assert.are.equal(0, #state.writes)
    end)

    it("refuses a component missing a defining field", function()
        local Guard, catalog, photo, state = setup()
        local component = linearComponent()
        component.FullY = nil

        local message = errorOf(function() applyAppend(Guard, catalog, photo, component) end)

        assert.is_truthy(message:find("missing FullY", 1, true))
        assert.are.equal(0, #state.writes)
    end)

    it("refuses a component with an unknown or absent type", function()
        local Guard, catalog, photo, state = setup()
        local absent = linearComponent()
        absent.What = nil

        local unknown = errorOf(function()
            applyAppend(Guard, catalog, photo, linearComponent({ What = "Mask/Nope" }))
        end)
        local missing = errorOf(function() applyAppend(Guard, catalog, photo, absent) end)

        assert.is_truthy(unknown:find("unknown mask type Mask/Nope", 1, true))
        assert.is_truthy(missing:find("unknown mask type nil", 1, true))
        assert.are.equal(0, #state.writes)
    end)

    it("refuses a color range with two samples and one with an unsupported type", function()
        local Guard, catalog, photo, state = setup()
        local function range(rangeTable)
            return { What = "Mask/RangeMask", MaskActive = true, CorrectionRangeMask = rangeTable }
        end

        local two = errorOf(function()
            applyAppend(Guard, catalog, photo, range({ Type = 1, ColorAmount = 0.4, PointModels = { "a", "b" } }))
        end)
        local depth = errorOf(function()
            applyAppend(Guard, catalog, photo, range({ Type = 3, DepthRange = "0 0 1 1" }))
        end)

        assert.is_truthy(two:find("exactly one PointModels entry", 1, true))
        assert.is_truthy(depth:find("unsupported range Type 3", 1, true))
        assert.are.equal(0, #state.writes)
    end)

    it("rolls back when Lightroom silently drops the component", function()
        local Guard, catalog, photo, state = setup({
            entries = { correction("Old", { linearComponent({ MaskID = "OLDT1" }) }, { CorrectionID = "OLD" }) },
            transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then stored[2].CorrectionMasks = {} end
                return stored
            end,
        })

        local message = errorOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.is_truthy(message:find("previous masks were restored", 1, true))
        assert.is_truthy(message:find("count changed from 1 to 0", 1, true))
        assert.are.equal(2, #state.writes)
        assert.are.equal(1, #state.writes[2])
        assert.are.equal("OLD", state.writes[2][1].CorrectionID)
        assert.are.equal(1, #state.entries)
    end)

    it("rolls back when Lightroom reads back different geometry", function()
        local Guard, catalog, photo, state = setup({
            transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then stored[1].CorrectionMasks[1].FullY = 0.9 end
                return stored
            end,
        })

        local message = errorOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.is_truthy(message:find("FullY: wrote 0.2, read back 0.9", 1, true))
        assert.are.same({}, state.writes[2])
        assert.are.equal(0, #state.entries)
    end)

    it("rolls back when an untouched existing mask changes under the write", function()
        local Guard, catalog, photo, state = setup({
            entries = { correction("Old", { radialComponent({ MaskID = "OLDT1" }) }, { CorrectionID = "OLD" }) },
            transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then stored[1].CorrectionMasks[1].Feather = 0 end
                return stored
            end,
        })

        local message = errorOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.is_truthy(message:find("Feather: wrote 50, read back 0", 1, true))
        assert.are.equal(2, #state.writes)
    end)

    it("rolls back when the entry count changes", function()
        local Guard, catalog, photo, state = setup({
            transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then return {} end
                return stored
            end,
        })

        local message = errorOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.is_truthy(message:find("mask count changed: wrote 1, read back 0", 1, true))
        assert.are.equal(2, #state.writes)
    end)

    it("reports when the rollback itself is not confirmed", function()
        local Guard, catalog, photo = setup({
            entries = { correction("Old", { linearComponent({ MaskID = "OLDT1" }) }, { CorrectionID = "OLD" }) },
            transformWrite = function(stored)
                stored[1].CorrectionMasks = {}
                return stored
            end,
        })

        local message = errorOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.is_truthy(message:find("could not be confirmed restored", 1, true))
    end)

    it("attempts a restore when the write call itself throws", function()
        local Guard, catalog, photo, state = setup({
            rejectWrite = function(writeNumber) return writeNumber == 1 end,
        })

        local message = errorOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.is_truthy(message:find("Lightroom rejected the write", 1, true))
        assert.are.equal(1, #state.writes)
        assert.are.same({}, state.writes[1])
    end)

    it("rolls back when the cross-check reports a problem", function()
        local Guard, catalog, photo, state = setup()

        local message = errorOf(function()
            applyAppend(Guard, catalog, photo, linearComponent(), {
                crossCheck = function() return "mask list does not show the tool" end,
            })
        end)

        assert.is_truthy(message:find("mask list does not show the tool", 1, true))
        assert.are.equal(2, #state.writes)
        assert.are.same({}, state.writes[2])
    end)

    it("rolls back when the cross-check throws", function()
        local Guard, catalog, photo, state = setup()

        local message = errorOf(function()
            applyAppend(Guard, catalog, photo, linearComponent(), {
                crossCheck = function() error("getAllMasks failed", 0) end,
            })
        end)

        assert.is_truthy(message:find("getAllMasks failed", 1, true))
        assert.are.equal(2, #state.writes)
    end)

    it("hands the cross-check the stored entries", function()
        local Guard, catalog, photo = setup()
        local seen

        applyAppend(Guard, catalog, photo, linearComponent(), {
            crossCheck = function(entries) seen = entries end,
        })

        assert.are.equal("C1", seen[1].CorrectionID)
    end)

    it("leaves an AI mask entry verbatim in the written array and ignores its internals on read-back", function()
        local ai = { What = "Mask/Image", MaskActive = true, MaskID = "AIT1", Payload = "abc" }
        local Guard, catalog, photo, state = setup({
            entries = { correction("AI", { ai }, { CorrectionID = "AI1" }) },
            transformWrite = function(stored)
                stored[1].CorrectionMasks[1].Payload = "recomputed"
                return stored
            end,
        })

        applyAppend(Guard, catalog, photo, linearComponent())

        assert.are.equal("abc", state.writes[1][1].CorrectionMasks[1].Payload)
        assert.are.equal(1, #state.writes)
    end)

    it("rolls back when an AI mask component changes type", function()
        local ai = { What = "Mask/Image", MaskActive = true, MaskID = "AIT1" }
        local Guard, catalog, photo, state = setup({
            entries = { correction("AI", { ai }, { CorrectionID = "AI1" }) },
            transformWrite = function(stored, writeNumber)
                if writeNumber == 1 then stored[1].CorrectionMasks[1].What = "Mask/Gradient" end
                return stored
            end,
        })

        local message = errorOf(function() applyAppend(Guard, catalog, photo, linearComponent()) end)

        assert.is_truthy(message:find("mask type changed", 1, true))
        assert.are.equal(2, #state.writes)
    end)
end)

describe("GuardedMaskWrite.compareEntries", function()
    local Guard = setup()

    local function oneEntry(component, overrides)
        return { correction("A", { component }, overrides) }
    end

    it("accepts numbers within 1e-5 and rejects 1e-4", function()
        local expected = oneEntry(linearComponent({ FullY = 0.2 }))

        assert.are.same({}, Guard.compareEntries(expected, oneEntry(linearComponent({ FullY = 0.200009 }))))
        assert.are_not.same({}, Guard.compareEntries(expected, oneEntry(linearComponent({ FullY = 0.2001 }))))
    end)

    it("ignores derived fields", function()
        local expected = oneEntry(radialComponent())
        local actual = oneEntry(radialComponent({ Flipped = true, MaskID = "x", MaskValue = 0 }), {
            CorrectionID = "Z",
            CorrectionReferenceX = 0.9,
            LocalCurveRefineSaturation = 100,
        })

        assert.are.same({}, Guard.compareEntries(expected, actual))
    end)

    it("catches a changed local slider and a changed name", function()
        local expected = oneEntry(linearComponent())

        local slider = Guard.compareEntries(expected, oneEntry(linearComponent(), { LocalExposure2012 = 0 }))
        local name = Guard.compareEntries(expected, oneEntry(linearComponent(), { CorrectionName = "B" }))

        assert.are.equal(1, #slider)
        assert.are.equal(1, #name)
    end)

    it("treats a false boolean that Lightroom omits as equal", function()
        local actualComponent = linearComponent()
        actualComponent.MaskInverted = nil

        assert.are.same({}, Guard.compareEntries(oneEntry(linearComponent()), oneEntry(actualComponent)))
    end)

    it("compares number lists as numbers and plain strings exactly", function()
        local range = function(lum, name)
            return {
                What = "Mask/RangeMask",
                MaskName = name,
                CorrectionRangeMask = { Type = 2, LumRange = lum },
            }
        end

        assert.are.same({}, Guard.compareEntries(oneEntry(range("0.3 0.4 0.5 0.6", "Lum 1")),
            oneEntry(range("0.300000 0.400000 0.500000 0.600000", "Lum 1"))))
        assert.are_not.same({}, Guard.compareEntries(oneEntry(range("0.3 0.4 0.5 0.6", "Lum 1")),
            oneEntry(range("0.3 0.4 0.5 0.7", "Lum 1"))))
        assert.are_not.same({}, Guard.compareEntries(oneEntry(range("0.3 0.4 0.5 0.6", "Lum 1")),
            oneEntry(range("0.3 0.4 0.5 0.6", "Lum 2"))))
    end)

    it("compares dab positions and tolerates a dropped third value", function()
        local brush = function(dabs)
            return {
                What = "Mask/Aggregate",
                Masks = { { What = "Mask/Paint", Dabs = dabs, Radius = 0.1, Flow = 1, CenterWeight = 0 } },
            }
        end

        assert.are.same({}, Guard.compareEntries(oneEntry(brush({ "d 0.1 0.2 0.5" })),
            oneEntry(brush({ "d 0.100000 0.200000" }))))
        assert.are_not.same({}, Guard.compareEntries(oneEntry(brush({ "d 0.1 0.2" })), oneEntry(brush({ "d 0.1 0.3" }))))
        assert.are_not.same({}, Guard.compareEntries(oneEntry(brush({ "d 0.1 0.2" })),
            oneEntry(brush({ "d 0.1 0.2", "d 0.3 0.3" }))))
    end)

    it("ignores a flow token one side lacks but compares it when both have it", function()
        local brush = function(dabs)
            return {
                What = "Mask/Aggregate",
                Masks = { { What = "Mask/Paint", Dabs = dabs, Radius = 0.1, Flow = 0.3, CenterWeight = 0 } },
            }
        end

        assert.are.same({}, Guard.compareEntries(oneEntry(brush({ "f 0.3000", "d 0.1 0.2" })),
            oneEntry(brush({ "d 0.100000 0.200000" }))))
        assert.are.same({}, Guard.compareEntries(oneEntry(brush({ "d 0.1 0.2" })),
            oneEntry(brush({ "f 0.3000", "d 0.100000 0.200000" }))))
        assert.are.same({}, Guard.compareEntries(oneEntry(brush({ "f 0.3000", "d 0.1 0.2" })),
            oneEntry(brush({ "f 0.299998", "d 0.100000 0.200000" }))))
        assert.are_not.same({}, Guard.compareEntries(oneEntry(brush({ "f 0.3000", "d 0.1 0.2" })),
            oneEntry(brush({ "f 0.5000", "d 0.100000 0.200000" }))))
        assert.are_not.same({}, Guard.compareEntries(oneEntry(brush({ "f 0.3000", "d 0.1 0.2" })),
            oneEntry(brush({ "f 0.3000", "d 0.1 0.3" }))))
    end)

    it("reports a lost table", function()
        local actual = oneEntry(linearComponent())
        actual[1].CorrectionMasks = nil

        local problems = Guard.compareEntries(oneEntry(linearComponent()), actual)

        assert.are.same({ "masks[1].CorrectionMasks: lost after the write" }, problems)
    end)
end)

describe("GuardedMaskWrite lookups", function()
    local Guard = setup()
    local entries = {
        correction("A", { linearComponent({ MaskID = "T1" }), radialComponent({ MaskID = "T2" }) }, { CorrectionID = "C1" }),
        correction("B", { linearComponent({ MaskID = "T3" }) }, { CorrectionID = "C2" }),
    }

    it("finds a correction by mask id", function()
        local index, entry = Guard.findCorrection(entries, "C2")

        assert.are.equal(2, index)
        assert.are.equal("B", entry.CorrectionName)
        assert.is_nil(Guard.findCorrection(entries, "C9"))
    end)

    it("finds a component by tool id and reports where it is", function()
        local entryIndex, componentIndex, component = Guard.findComponent(entries, "T2")

        assert.are.equal(1, entryIndex)
        assert.are.equal(2, componentIndex)
        assert.are.equal("Mask/CircularGradient", component.What)
        assert.is_nil(Guard.findComponent(entries, "T9"))
    end)

    it("builds a new correction with the fields Lightroom needs", function()
        local entry = Guard.newCorrection("Sky", { linearComponent() })

        assert.are.equal("Correction", entry.What)
        assert.are.equal("Sky", entry.CorrectionName)
        assert.is_true(entry.CorrectionActive)
        assert.are.equal(1, entry.CorrectionAmount)
    end)
end)
