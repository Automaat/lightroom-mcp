local ImageFrame = require 'ImageFrame'

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

describe("ImageFrame.fromOrientation", function()
    local DISPLAYED_X, DISPLAYED_Y = 0.25, 0.75

    local STORED_BY_ORIENTATION = {
        AB = { 0.25, 0.75 },
        BA = { 0.75, 0.75 },
        CD = { 0.75, 0.25 },
        DC = { 0.25, 0.25 },
        CB = { 0.75, 0.25 },
        BC = { 0.75, 0.75 },
        AD = { 0.25, 0.75 },
        DA = { 0.25, 0.25 },
    }

    for orientation, expected in pairs(STORED_BY_ORIENTATION) do
        it("maps a displayed point into the stored frame for " .. orientation, function()
            local frame = ImageFrame.fromOrientation(orientation)

            local x, y = frame.toStored(DISPLAYED_X, DISPLAYED_Y)

            assert.is_true(math.abs(x - expected[1]) < 1e-12)
            assert.is_true(math.abs(y - expected[2]) < 1e-12)
        end)
    end

    it("keeps every corner of the displayed image inside the unit square", function()
        for orientation in pairs(STORED_BY_ORIENTATION) do
            local frame = ImageFrame.fromOrientation(orientation)
            for _, corner in ipairs({ { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }) do
                local x, y = frame.toStored(corner[1], corner[2])
                assert.is_true(x == 0 or x == 1)
                assert.is_true(y == 0 or y == 1)
            end
        end
    end)

    it("flags only the normal orientation as normal", function()
        assert.is_true(ImageFrame.fromOrientation("AB").isNormal)
        assert.is_false(ImageFrame.fromOrientation("BC").isNormal)
        assert.is_false(ImageFrame.fromOrientation("BA").isNormal)
    end)

    it("refuses an orientation it does not know", function()
        for _, bad in ipairs({ "AC", "XY", "ABC", "", "ab" }) do
            local message = errorOf(function() ImageFrame.fromOrientation(bad) end)
            assert.is_truthy(message:find("cannot map", 1, true))
        end
        assert.is_truthy(errorOf(function() ImageFrame.fromOrientation(nil) end):find("cannot map", 1, true))
        assert.is_truthy(errorOf(function() ImageFrame.fromOrientation(6) end):find("cannot map", 1, true))
    end)
end)

describe("ImageFrame axis facts", function()
    local FACTS = {
        AB = { swapsAxes = false, reversesTurnDirection = false },
        BA = { swapsAxes = false, reversesTurnDirection = true },
        CD = { swapsAxes = false, reversesTurnDirection = false },
        DC = { swapsAxes = false, reversesTurnDirection = true },
        CB = { swapsAxes = true, reversesTurnDirection = true },
        BC = { swapsAxes = true, reversesTurnDirection = false },
        AD = { swapsAxes = true, reversesTurnDirection = true },
        DA = { swapsAxes = true, reversesTurnDirection = false },
    }

    for orientation, expected in pairs(FACTS) do
        it("reports whether " .. orientation .. " swaps the axes and reverses the turn direction", function()
            local frame = ImageFrame.fromOrientation(orientation)

            assert.are.equal(expected.swapsAxes, frame.swapsAxes)
            assert.are.equal(expected.reversesTurnDirection, frame.reversesTurnDirection)
        end)

        it("maps a point to the stored frame and back for " .. orientation, function()
            local frame = ImageFrame.fromOrientation(orientation)

            local storedX, storedY = frame.toStored(0.2, 0.7)
            local x, y = frame.toDisplayed(storedX, storedY)

            assert.is_true(math.abs(x - 0.2) < 1e-12)
            assert.is_true(math.abs(y - 0.7) < 1e-12)
        end)
    end
end)

describe("ImageFrame.forPhoto", function()
    it("reads the orientation inside the read gate", function()
        local insideGate = false
        local readInsideGate
        local catalog = {
            withReadAccessDo = function(_, fn)
                insideGate = true
                fn()
                insideGate = false
            end,
        }
        local photo = {
            getRawMetadata = function(_, key)
                readInsideGate = insideGate
                assert.are.equal("orientation", key)
                return "BC"
            end,
        }

        local frame = ImageFrame.forPhoto(catalog, photo)

        assert.is_true(readInsideGate)
        assert.are.equal("BC", frame.orientation)
    end)
end)
