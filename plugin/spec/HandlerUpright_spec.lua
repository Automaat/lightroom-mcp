local helper = require 'spec_helper'

local function guide(x1, y1, x2, y2)
    return { start = { x = x1, y = y1 }, ["end"] = { x = x2, y = y2 } }
end

-- Left and right edges of the 175 painting as displayed (orientation DA).
local GUIDES = { guide(0.1323, 0.2935, 0.1266, 0.7453), guide(0.934, 0.2935, 0.9474, 0.7453) }
local STORED_0 = "0.706500000,0.132300000,0.254700000,0.126600000"
local STORED_1 = "0.706500000,0.934000000,0.254700000,0.947400000"

-- Lightroom's matrix depends only on the guides; model it as a function of them.
local function matrixFor(settings)
    return "M[" .. tostring(settings.UprightFourSegments_0) .. "|" .. tostring(settings.UprightFourSegments_1) .. "]"
end

describe("HandlerUpright.setGuides", function()
    local Handler, photo, settings, calls, opts

    local function setup(options)
        opts = options or {}
        settings = opts.settings or { PerspectiveUpright = 0, UprightFourSegmentsCount = 0, UprightTransformCount = 6 }
        calls = { writes = {}, histories = {}, develop = 0, setValue = 0, reads = 0 }
        photo = helper.fakePhoto({ id = '7115', orientation = opts.orientation or 'DA' })
        photo.getDevelopSettings = function()
            calls.reads = calls.reads + 1
            if opts.failReadsAfterWrite and #calls.writes == 1 then error("catalog busy") end
            local copy = {}
            for k, v in pairs(settings) do copy[k] = v end
            return copy
        end
        photo.applyDevelopSettings = function(_, written, historyName)
            calls.writes[#calls.writes + 1] = written
            calls.histories[#calls.histories + 1] = historyName
            if opts.ignoreRestore and #calls.writes > 1 then return end
            for k, v in pairs(written) do settings[k] = v end
            if opts.mangle and #calls.writes == 1 then settings.UprightFourSegments_1 = "0,0,0,0" end
        end
        local catalog = helper.fakeCatalog({ photos = { photo } })
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrDevelopController = {
                setValue = function(name, value)
                    assert.are.equal('PerspectiveUpright', name)
                    assert.are.equal(5, value)
                    calls.setValue = calls.setValue + 1
                    if opts.failComputes and calls.setValue <= opts.failComputes then return end
                    settings.UprightTransform_5 = matrixFor(settings)
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
                if opts.busy then error("create_mask is already running; wait for it to finish, then call again", 0) end
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

    it("writes the guides in the stored frame inside Develop and has Lightroom compute the matrix", function()
        setup()
        local result = Handler.setGuides({ photo_id = 7115, guides = GUIDES })

        assert.are.same({ success = true, photo_id = '7115', guide_count = 2 }, result)
        assert.are.equal(1, calls.develop)
        assert.are.equal(1, #calls.writes)
        assert.are.equal("Upright Guides", calls.histories[1])
        assert.are.equal(5, calls.writes[1].PerspectiveUpright)
        assert.are.equal(2, calls.writes[1].UprightFourSegmentsCount)
        assert.are.equal(STORED_0, calls.writes[1].UprightFourSegments_0)
        assert.are.equal(STORED_1, calls.writes[1].UprightFourSegments_1)
        assert.are.equal(1, calls.setValue)
        assert.are.equal(matrixFor(settings), settings.UprightTransform_5)
    end)

    it("writes nothing when another Develop call holds the session", function()
        setup({ busy = true })
        assert.has_error(function()
            Handler.setGuides({ photo_id = '7115', guides = GUIDES })
        end, "create_mask is already running; wait for it to finish, then call again")
        assert.are.equal(0, #calls.writes)
    end)

    it("computes on a second Guided request when the first is lost", function()
        setup({ failComputes = 1 })
        local result = Handler.setGuides({ photo_id = '7115', guides = GUIDES })
        assert.is_true(result.success)
        assert.are.equal(2, calls.setValue)
        assert.are.equal(1, #calls.writes)
    end)

    it("rewrites the guides and asks again when two requests are lost", function()
        setup({ failComputes = 2 })
        local result = Handler.setGuides({ photo_id = '7115', guides = GUIDES })
        assert.is_true(result.success)
        assert.are.equal(3, calls.setValue)
        assert.are.same({ "Upright Guides", "Upright Guides (restore)", "Upright Guides" }, calls.histories)
        assert.are.equal(matrixFor(settings), settings.UprightTransform_5)
    end)

    it("fails and restores when Lightroom does not compute the correction", function()
        setup({ failComputes = 3 })
        assert.has_error(function()
            Handler.setGuides({ photo_id = '7115', guides = GUIDES })
        end, "Lightroom did not compute the Guided correction within 20 s, even after choosing Guided again and"
            .. " rewriting the guides. It computes only for the photo active in Develop and slows down while"
            .. " Lightroom is in the background: bring Lightroom to the front and call again. If it keeps"
            .. " failing in front, check that Develop offers Upright for this photo;"
            .. " the previous Upright settings were restored")
        assert.are.equal(4, #calls.writes)
        assert.are.equal("Upright Guides (restore)", calls.histories[4])
        assert.are.equal(0, settings.PerspectiveUpright)
        assert.are.equal(0, settings.UprightFourSegmentsCount)
    end)

    it("recomputes the previous Guided matrix when it restores a Guided photo", function()
        local previous = { PerspectiveUpright = 5, UprightFourSegmentsCount = 2,
            UprightFourSegments_0 = "0.7,0.1,0.25,0.1", UprightFourSegments_1 = "0.7,0.9,0.25,0.9" }
        previous.UprightTransform_5 = matrixFor(previous)
        local previousMatrix = previous.UprightTransform_5
        setup({ settings = previous, failComputes = 3 })

        assert.has_error(function()
            Handler.setGuides({ photo_id = '7115', guides = GUIDES })
        end, "Lightroom did not compute the Guided correction within 20 s, even after choosing Guided again and"
            .. " rewriting the guides. It computes only for the photo active in Develop and slows down while"
            .. " Lightroom is in the background: bring Lightroom to the front and call again. If it keeps"
            .. " failing in front, check that Develop offers Upright for this photo;"
            .. " the previous Upright settings were restored")
        assert.are.equal("0.7,0.1,0.25,0.1", settings.UprightFourSegments_0)
        assert.are.equal(previousMatrix, settings.UprightTransform_5)
        assert.are.equal(4, calls.setValue)
    end)

    it("never reports a stale matrix as the new correction", function()
        local previous = { PerspectiveUpright = 5, UprightFourSegmentsCount = 2,
            UprightFourSegments_0 = "0.7,0.1,0.25,0.1", UprightFourSegments_1 = "0.7,0.9,0.25,0.9",
            UprightTransform_5 = "stale" }
        setup({ settings = previous, failComputes = 99 })
        assert.has_error(function() Handler.setGuides({ photo_id = '7115', guides = GUIDES }) end)
        assert.are.equal("0.7,0.1,0.25,0.1", settings.UprightFourSegments_0)
    end)

    it("accepts an unchanged matrix for guides on the same lines after Upright was turned off", function()
        local previous = { PerspectiveUpright = 0, UprightFourSegmentsCount = 2,
            UprightFourSegments_0 = STORED_1, UprightFourSegments_1 = "0.254700000,0.126600000,0.706500000,0.132300000" }
        -- same lines, other order and direction: Lightroom gives the same matrix
        previous.UprightTransform_5 = matrixFor({ UprightFourSegments_0 = STORED_0, UprightFourSegments_1 = STORED_1 })
        setup({ settings = previous })
        local result = Handler.setGuides({ photo_id = '7115', guides = GUIDES })
        assert.is_true(result.success)
        assert.are.equal(1, #calls.writes)
    end)

    it("restores when a guide reads back wrong, without asking for a correction", function()
        setup({ settings = { PerspectiveUpright = 3, UprightFourSegmentsCount = 0 }, mangle = true })
        assert.has_error(function()
            Handler.setGuides({ photo_id = '7115', guides = GUIDES })
        end, "Lightroom did not keep the guides (guide 2 reads back as 0,0,0,0); the previous Upright settings were restored")
        assert.are.equal(0, calls.setValue)
        assert.are.equal(3, settings.PerspectiveUpright)
    end)

    it("restores when reading the photo back throws", function()
        setup({ failReadsAfterWrite = true })
        local ok, err = pcall(Handler.setGuides, { photo_id = '7115', guides = GUIDES })
        assert.is_false(ok)
        assert.truthy(tostring(err):find("reading the photo back failed", 1, true), tostring(err))
        assert.are.equal(2, #calls.writes)
        assert.are.equal("Upright Guides (restore)", calls.histories[2])
    end)

    it("says so when the restore does not take", function()
        setup({ failComputes = 3, ignoreRestore = true })
        local ok, err = pcall(Handler.setGuides, { photo_id = '7115', guides = GUIDES })
        assert.is_false(ok)
        assert.truthy(tostring(err):find("restoring the previous Upright settings failed: Upright mode reads back as 5, not 0",
            1, true), tostring(err))
    end)

    it("refuses invalid guides before opening Develop", function()
        setup()
        assert.has_error(function()
            Handler.setGuides({ photo_id = '7115', guides = { GUIDES[1] } })
        end, "guides must hold 2 to 4 guides, got 1")
        assert.has_error(function() Handler.setGuides({ guides = GUIDES }) end, "photo_id is required")
        assert.are.equal(0, calls.develop)
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

describe("HandlerUpright.setGuides with items", function()
    local Handler, photos, active, calls

    local function setup(options)
        options = options or {}
        photos, calls = {}, { opened = {}, sessions = 0 }
        for _, id in ipairs({ '1', '2', '3' }) do
            local photo = helper.fakePhoto({ id = id, orientation = 'AB' })
            local settings = { PerspectiveUpright = 0, UprightFourSegmentsCount = 0 }
            photo.getDevelopSettings = function()
                local copy = {}
                for k, v in pairs(settings) do copy[k] = v end
                return copy
            end
            photo.applyDevelopSettings = function(_, written)
                for k, v in pairs(written) do settings[k] = v end
            end
            photo.settings = settings
            photos[id] = photo
        end
        local catalog = helper.fakeCatalog({ photos = { photos['1'], photos['2'], photos['3'] } })
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrDate = { currentTime = function() return options.clock and options.clock() or 0 end },
            LrDevelopController = {
                setValue = function()
                    if options.neverComputes and options.neverComputes[active.localIdentifier] then return end
                    active.settings.UprightTransform_5 = "M" .. tostring(active.settings.UprightFourSegments_0)
                end,
            },
            LrTasks = { pcall = pcall, sleep = function() end },
            LrLogger = helper.defaultLrLogger(),
        })
        package.loaded.DevelopSession = {
            waitFor = function(predicate) return predicate() end,
            run = function(toolName, _, restore, fn)
                assert.are.equal('set_upright_guides', toolName)
                assert.is_true(restore)
                calls.sessions = calls.sessions + 1
                return fn({})
            end,
            openPhoto = function(_, photo)
                active = photo
                calls.opened[#calls.opened + 1] = photo.localIdentifier
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

    local item = function(id) return { photo_id = id, guides = GUIDES } end

    it("writes every photo in one Develop session and keeps going past a failure", function()
        setup({ neverComputes = { ['2'] = true } })
        local result = Handler.setGuides({ items = { item('1'), item(2), item('missing'), item('1'), item('3') } })

        assert.are.equal(1, calls.sessions)
        assert.are.same({ '1', '2', '3' }, calls.opened)
        assert.is_false(result.success)
        assert.are.same({ 2, 1, 2 }, { result.applied, result.failed, result.skipped })
        assert.is_true(result.complete)
        assert.are.same({ status = "applied", guide_count = 2, seconds = 0, photo_id = '1' }, result.results[1])
        assert.are.equal("failed", result.results[2].status)
        assert.truthy(result.results[2].error:find("previous Upright settings were restored", 1, true))
        assert.are.same({ status = "skipped", error = "photo not found", photo_id = 'missing' }, result.results[3])
        assert.are.same({ status = "skipped", error = "duplicate of an earlier entry", photo_id = '1' }, result.results[4])
        assert.are.equal("applied", result.results[5].status)
        assert.are.equal(0, photos['2'].settings.PerspectiveUpright)
        assert.are.equal(5, photos['3'].settings.PerspectiveUpright)
    end)

    it("returns the photos it had no time for in remaining_ids", function()
        local now = 0
        setup({ clock = function() now = now + 100; return now end })
        local result = Handler.setGuides({ items = { item('1'), item('2'), item('3') } })
        assert.is_false(result.complete)
        assert.are.equal(1, result.applied)
        assert.are.same({ '2', '3' }, result.remaining_ids)
    end)

    it("validates every entry before opening Develop", function()
        setup()
        assert.has_error(function()
            Handler.setGuides({ items = { item('1'), { photo_id = '2', guides = { GUIDES[1] } } } })
        end, "items.1: guides must hold 2 to 4 guides, got 1")
        assert.has_error(function()
            Handler.setGuides({ items = { item('1') }, photo_id = '1' })
        end, "Give photo_id and guides, or items, not both")
        assert.has_error(function() Handler.setGuides({ items = {} }) end, "items must hold 1 to 50 entries")
        assert.are.equal(0, calls.sessions)
    end)
end)
