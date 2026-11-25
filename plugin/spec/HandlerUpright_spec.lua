local helper = require 'spec_helper'

local MATRIX = "0.979209567,-0.000233068,-0.013153076,-0.018833423,1.004780478,-0.000909743,-0.050577306,0.004300462,1.000000000"

local function guide(x1, y1, x2, y2)
    return { start = { x = x1, y = y1 }, ["end"] = { x = x2, y = y2 } }
end

local GUIDES = { guide(0.1323, 0.2935, 0.1266, 0.7453), guide(0.934, 0.2935, 0.9474, 0.7453) }

describe("HandlerUpright.setGuides", function()
    local Handler, photo, settings, calls, opts

    local function setup(options)
        opts = options or {}
        settings = opts.settings or { PerspectiveUpright = 0, UprightFourSegmentsCount = 0, UprightTransformCount = 6 }
        calls = { writes = {}, develop = 0, setValue = {}, histories = {} }
        photo = helper.fakePhoto({ id = '7115', orientation = opts.orientation or 'DA' })
        photo.getDevelopSettings = function()
            local copy = {}
            for k, v in pairs(settings) do copy[k] = v end
            return copy
        end
        photo.applyDevelopSettings = function(_, written, historyName)
            calls.writes[#calls.writes + 1] = written
            calls.histories[#calls.histories + 1] = historyName
            for k, v in pairs(written) do settings[k] = v end
            if opts.mangle and #calls.writes == 1 then settings.UprightFourSegments_1 = "0,0,0,0" end
            if opts.computeOnWrite then settings.UprightTransform_5 = MATRIX end
        end
        local catalog = helper.fakeCatalog({ photos = { photo } })
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrDevelopController = {
                setValue = function(name, value)
                    calls.setValue[#calls.setValue + 1] = { name, value }
                    if name == 'PerspectiveUpright' and value == 5 and not opts.neverCompute then
                        settings.UprightTransform_5 = MATRIX
                    end
                end,
            },
            LrTasks = { pcall = pcall, sleep = function() end },
            LrLogger = helper.defaultLrLogger(),
        })
        package.loaded.DevelopSession = {
            waitFor = function(predicate) return predicate() end,
            withPhoto = function(toolName, _, target, fn)
                assert.are.equal('set_upright_guides', toolName)
                assert.are.equal(photo, target)
                calls.develop = calls.develop + 1
                return fn()
            end,
        }
        for _, name in ipairs({ 'HandlerUpright', 'UprightGuides', 'ImageFrame', 'PhotoLookup' }) do
            package.loaded[name] = nil
        end
        Handler = require 'HandlerUpright'
    end

    after_each(function()
        package.loaded.DevelopSession = nil
        package.loaded.HandlerUpright = nil
    end)

    it("writes the guides in the stored frame and has Lightroom compute the Guided matrix", function()
        setup()
        local result = Handler.setGuides({ photo_id = 7115, guides = GUIDES })

        assert.are.same({ success = true, photo_id = '7115', guide_count = 2, transform_computed = true }, result)
        assert.are.equal(1, #calls.writes)
        assert.are.equal("Upright Guides", calls.histories[1])
        assert.are.equal(5, calls.writes[1].PerspectiveUpright)
        assert.are.equal(2, calls.writes[1].UprightFourSegmentsCount)
        assert.are.equal("0.706500000,0.132300000,0.254700000,0.126600000", calls.writes[1].UprightFourSegments_0)
        assert.are.equal("0.706500000,0.934000000,0.254700000,0.947400000", calls.writes[1].UprightFourSegments_1)
        assert.are.equal(1, calls.develop)
        assert.are.same({ { 'PerspectiveUpright', 5 } }, calls.setValue)
    end)

    it("skips Develop when Lightroom computes the matrix from the write", function()
        setup({ computeOnWrite = true })
        local result = Handler.setGuides({ photo_id = '7115', guides = GUIDES })
        assert.is_true(result.transform_computed)
        assert.are.equal(0, calls.develop)
    end)

    it("treats a matrix already computed for the same guides as current", function()
        setup({ settings = { PerspectiveUpright = 5, UprightFourSegmentsCount = 2,
            UprightFourSegments_0 = "0.706500000,0.132300000,0.254700000,0.126600000",
            UprightFourSegments_1 = "0.706500000,0.934000000,0.254700000,0.947400000",
            UprightTransform_5 = MATRIX } })
        local result = Handler.setGuides({ photo_id = '7115', guides = GUIDES })
        assert.is_true(result.transform_computed)
        assert.are.equal(0, calls.develop)
    end)

    it("waits for a new matrix when new guides replace computed ones", function()
        setup({ settings = { PerspectiveUpright = 5, UprightFourSegmentsCount = 2,
            UprightFourSegments_0 = "0.1,0.1,0.1,0.9", UprightFourSegments_1 = "0.9,0.1,0.9,0.9",
            UprightTransform_5 = "1,0,0,0,1,0,0,0,1" }, neverCompute = true })
        local result = Handler.setGuides({ photo_id = '7115', guides = GUIDES })
        assert.is_false(result.transform_computed)
        assert.are.equal(1, calls.develop)
    end)

    it("reports a matrix Lightroom never computes without failing the write", function()
        setup({ neverCompute = true })
        local result = Handler.setGuides({ photo_id = '7115', guides = GUIDES })
        assert.is_true(result.success)
        assert.is_false(result.transform_computed)
    end)

    it("restores the previous Upright settings when a guide reads back wrong", function()
        setup({ settings = { PerspectiveUpright = 3, UprightFourSegmentsCount = 0 }, mangle = true })
        assert.has_error(function()
            Handler.setGuides({ photo_id = '7115', guides = GUIDES })
        end, "Lightroom did not keep the guides (guide 2 reads back as 0,0,0,0); the previous Upright settings were restored")
        assert.are.equal(2, #calls.writes)
        assert.are.equal("Upright Guides (restore)", calls.histories[2])
        assert.are.equal(3, settings.PerspectiveUpright)
        assert.are.equal(0, settings.UprightFourSegmentsCount)
        assert.are.equal(0, calls.develop)
    end)

    it("refuses invalid guides before reading or writing the photo", function()
        setup()
        assert.has_error(function()
            Handler.setGuides({ photo_id = '7115', guides = { GUIDES[1] } })
        end, "guides must hold 2 to 4 guides, got 1")
        assert.has_error(function() Handler.setGuides({ guides = GUIDES }) end, "photo_id is required")
        assert.are.equal(0, #calls.writes)
    end)

    it("refuses an unknown photo", function()
        setup()
        assert.has_error(function()
            Handler.setGuides({ photo_id = '999', guides = GUIDES })
        end, "Photo not found: 999")
        assert.are.equal(0, #calls.writes)
    end)
end)
