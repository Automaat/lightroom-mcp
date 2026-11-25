local helper = require 'spec_helper'

-- Guides drawn by hand in Develop on Lightroom Classic 16.0.1, a portrait
-- Sony ARW reporting orientation DA: the four edges of a painting.
local AUTHORED = {
    UprightFourSegmentsCount = 4,
    UprightFourSegments_0 = "0.912274492,0.163484967,0.905106361,0.877666512",
    UprightFourSegments_1 = "0.837533113,0.966450193,0.247268993,0.952880797",
    UprightFourSegments_2 = "0.080352546,0.243423151,0.075170413,0.772793804",
    UprightFourSegments_3 = "0.684857657,0.072719372,0.289169402,0.063735441",
}

local function guide(x1, y1, x2, y2)
    return { start = { x = x1, y = y1 }, ["end"] = { x = x2, y = y2 } }
end

describe("UprightGuides", function()
    local UprightGuides, ImageFrame

    before_each(function()
        helper.installImport({ LrLogger = helper.defaultLrLogger() })
        package.loaded.UprightGuides = nil
        package.loaded.ImageFrame = nil
        UprightGuides = require 'UprightGuides'
        ImageFrame = require 'ImageFrame'
    end)

    describe("parseGuides", function()
        it("returns each guide as x1, y1, x2, y2", function()
            local parsed = UprightGuides.parseGuides({ guide(0.1, 0.2, 0.1, 0.8), guide(0.2, 0.1, 0.8, 0.1) })
            assert.are.same({ { 0.1, 0.2, 0.1, 0.8 }, { 0.2, 0.1, 0.8, 0.1 } }, parsed)
        end)

        it("accepts four guides and refuses one or five", function()
            local four = { guide(0.1, 0.2, 0.1, 0.8), guide(0.9, 0.2, 0.9, 0.8),
                guide(0.2, 0.1, 0.8, 0.1), guide(0.2, 0.9, 0.8, 0.9) }
            assert.are.equal(4, #UprightGuides.parseGuides(four))
            assert.has_error(function() UprightGuides.parseGuides({ four[1] }) end,
                "guides must hold 2 to 4 guides, got 1")
            four[5] = four[1]
            assert.has_error(function() UprightGuides.parseGuides(four) end,
                "guides must hold 2 to 4 guides, got 5")
        end)

        it("refuses a non-array", function()
            assert.has_error(function() UprightGuides.parseGuides("x") end,
                "guides must be an array of 2 to 4 guides")
            assert.has_error(function() UprightGuides.parseGuides({ a = guide(0, 0, 1, 1) }) end,
                "guides must be an array of 2 to 4 guides")
        end)

        it("refuses points outside the frame or without numbers", function()
            assert.has_error(function()
                UprightGuides.parseGuides({ guide(0.1, 0.2, 0.1, 1.2), guide(0.2, 0.1, 0.8, 0.1) })
            end, "guides.0.end must lie within 0 to 1")
            assert.has_error(function()
                UprightGuides.parseGuides({ guide(0.1, 0.2, 0.1, 0.8), { start = { x = 0.2 }, ["end"] = { x = 0.8, y = 0.1 } } })
            end, "guides.1.start needs numeric x and y")
            assert.has_error(function()
                UprightGuides.parseGuides({ guide(0.1, 0.2, 0.1, 0.8), { start = { x = 0.2, y = 0.1 } } })
            end, "guides.1.end must be an object with x and y")
        end)

        it("refuses an array with a hole", function()
            local holey = { [1] = guide(0.1, 0.2, 0.1, 0.8), [3] = guide(0.9, 0.2, 0.9, 0.8), [4] = guide(0.2, 0.1, 0.8, 0.1) }
            assert.has_error(function() UprightGuides.parseGuides(holey) end, "guides must be an array of 2 to 4 guides")
        end)

        it("refuses unknown properties on a guide or point", function()
            local extra = guide(0.1, 0.2, 0.1, 0.8); extra.mode = "vertical"
            assert.has_error(function()
                UprightGuides.parseGuides({ extra, guide(0.2, 0.1, 0.8, 0.1) })
            end, "guides.0 has unknown property mode")
            local point = guide(0.1, 0.2, 0.1, 0.8); point.start.z = 1
            assert.has_error(function()
                UprightGuides.parseGuides({ point, guide(0.2, 0.1, 0.8, 0.1) })
            end, "guides.0.start has unknown property z")
        end)

        it("refuses a guide too short to give a direction", function()
            assert.has_error(function()
                UprightGuides.parseGuides({ guide(0.5, 0.5, 0.51, 0.505), guide(0.2, 0.1, 0.8, 0.1) })
            end, "guides.0 is shorter than 0.02 of the frame; draw it along a longer stretch of the edge")
        end)
    end)

    describe("frames", function()
        it("maps Lightroom-authored guides on a DA photo to the edges as displayed", function()
            local frame = ImageFrame.fromOrientation("DA")
            local displayed = {}
            for i = 1, 4 do
                local s = UprightGuides.parse(AUTHORED[UprightGuides.segmentKey(i)])
                local x1, y1 = frame.toDisplayed(s[1], s[2])
                local x2, y2 = frame.toDisplayed(s[3], s[4])
                displayed[i] = { x1, y1, x2, y2 }
            end
            -- top, right, bottom and left edges of the painting as shown in Library
            assert.is_true(math.abs(displayed[1][2] - 0.088) < 0.01 and math.abs(displayed[1][4] - 0.095) < 0.01)
            assert.is_true(math.abs(displayed[2][1] - 0.966) < 0.01 and math.abs(displayed[2][3] - 0.953) < 0.01)
            assert.is_true(math.abs(displayed[3][2] - 0.920) < 0.01 and math.abs(displayed[3][4] - 0.925) < 0.01)
            assert.is_true(math.abs(displayed[4][1] - 0.073) < 0.01 and math.abs(displayed[4][3] - 0.064) < 0.01)
        end)

        it("converts displayed guides to the stored frame and back", function()
            local frame = ImageFrame.fromOrientation("DA")
            local stored = UprightGuides.toStored(frame, { { 0.1323, 0.2935, 0.1266, 0.7453 } })
            assert.is_true(math.abs(stored[1][1] - 0.7065) < 1e-9)
            assert.is_true(math.abs(stored[1][2] - 0.1323) < 1e-9)
            assert.is_true(math.abs(stored[1][3] - 0.2547) < 1e-9)
            assert.is_true(math.abs(stored[1][4] - 0.1266) < 1e-9)
            local normal = UprightGuides.toStored(ImageFrame.fromOrientation("AB"), { { 0.1, 0.2, 0.3, 0.4 } })
            assert.are.same({ { 0.1, 0.2, 0.3, 0.4 } }, normal)
        end)
    end)

    describe("format and parse", function()
        it("round-trips Lightroom's comma-separated segment text", function()
            local text = UprightGuides.format({ 0.912274492, 0.163484967, 0.905106361, 0.877666512 })
            assert.are.equal(AUTHORED.UprightFourSegments_0, text)
            assert.are.same({ 0.912274492, 0.163484967, 0.905106361, 0.877666512 }, UprightGuides.parse(text))
        end)

        it("returns nil for text that is not four numbers", function()
            assert.is_nil(UprightGuides.parse("0.1,0.2,0.3"))
            assert.is_nil(UprightGuides.parse("0.1,0.2,0.3,nan"))
            assert.is_nil(UprightGuides.parse("0.1,0.2,inf,0.4"))
            assert.is_nil(UprightGuides.parse("0.1,0.2,x,0.4"))
            assert.is_nil(UprightGuides.parse(nil))
        end)
    end)

    describe("settingsFor and problems", function()
        local stored = { { 0.7, 0.13, 0.25, 0.12 }, { 0.85, 0.29, 0.86, 0.78 } }

        it("turns on Guided mode with the guides and their count", function()
            assert.are.same({
                PerspectiveUpright = 5,
                UprightFourSegmentsCount = 2,
                UprightFourSegments_0 = "0.700000000,0.130000000,0.250000000,0.120000000",
                UprightFourSegments_1 = "0.850000000,0.290000000,0.860000000,0.780000000",
            }, UprightGuides.settingsFor(stored))
        end)

        it("finds no problem when the settings read back as written", function()
            assert.are.same({}, UprightGuides.problems(stored, UprightGuides.settingsFor(stored)))
        end)

        it("names a wrong mode, count or guide", function()
            local settings = UprightGuides.settingsFor(stored)
            settings.PerspectiveUpright = 0
            settings.UprightFourSegmentsCount = 4
            settings.UprightFourSegments_1 = "0.1,0.2,0.3,0.4"
            assert.are.same({
                "Upright mode reads back as 0, not Guided",
                "guide count reads back as 4, not 2",
                "guide 2 reads back as 0.1,0.2,0.3,0.4",
            }, UprightGuides.problems(stored, settings))
            settings.UprightFourSegments_1 = nil
            assert.are.equal("guide 2 is missing", UprightGuides.problems(stored, settings)[3])
        end)

        it("treats guides on the same lines, in any order or direction, as the same", function()
            local current = UprightGuides.settingsFor(stored)
            current.UprightFourSegments_0, current.UprightFourSegments_1 =
                "0.860000000,0.780000000,0.850000000,0.290000000", "0.250000000,0.120000000,0.700000000,0.130000000"
            assert.is_true(UprightGuides.sameLines(stored, current))
            -- a point further along the same line is still on it
            local along = { { 0.475, 0.125, 0.25, 0.12 }, stored[2] }
            assert.is_true(UprightGuides.sameLines(along, UprightGuides.settingsFor(stored)))
        end)

        it("treats moved, missing or extra guides as different", function()
            local current = UprightGuides.settingsFor(stored)
            assert.is_false(UprightGuides.sameLines({ { 0.7, 0.14, 0.25, 0.12 }, stored[2] }, current))
            assert.is_false(UprightGuides.sameLines({ stored[1] }, current))
            assert.is_false(UprightGuides.sameLines(stored, { UprightFourSegmentsCount = 0 }))
            assert.is_false(UprightGuides.sameLines(stored, { UprightFourSegmentsCount = 2, UprightFourSegments_0 = "x" }))
        end)

        it("checks a restore by number and ignores slots above the count", function()
            local saved = UprightGuides.snapshot(AUTHORED)
            local back = {}
            for k, v in pairs(AUTHORED) do back[k] = v end
            back.UprightFourSegments_0 = "0.9122744920,0.163484967,0.905106361,0.877666512"
            back.UprightFourSegments_5 = "stale"
            assert.are.same({}, UprightGuides.restoreProblems(saved, back))
            back.PerspectiveUpright = 5
            back.UprightFourSegments_3 = "0.1,0.1,0.1,0.1"
            assert.are.same({ "Upright mode reads back as 5, not 0", "guide 4 reads back as 0.1,0.1,0.1,0.1" },
                UprightGuides.restoreProblems(saved, back))
        end)

        it("snapshots the Upright keys a write can change", function()
            local saved = UprightGuides.snapshot(AUTHORED)
            assert.are.equal(0, saved.PerspectiveUpright)
            assert.are.equal(4, saved.UprightFourSegmentsCount)
            assert.are.equal(AUTHORED.UprightFourSegments_3, saved.UprightFourSegments_3)
            assert.are.same({ PerspectiveUpright = 0, UprightFourSegmentsCount = 0 }, UprightGuides.snapshot(nil))
        end)
    end)
end)
