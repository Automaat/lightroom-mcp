local helper = require 'spec_helper'
local JSON = require 'JSON'

describe("HandlerStyleSummary", function()
    local catalog, Handler

    local function photo(id, rating, camera, iso, settings, exported)
        return helper.fakePhoto({ id = tostring(id), rating = rating, cameraModel = camera,
            isoSpeedRating = iso, developSettings = settings or {}, isExported = exported })
    end

    local function load(photos)
        catalog = helper.fakeCatalog({ photos = photos })
        helper.installImport({ LrApplication = { activeCatalog = function() return catalog end } })
        package.loaded.HandlerStyleSummary = nil
        Handler = require 'HandlerStyleSummary'
    end

    it("summarizes numeric settings with odd and even medians", function()
        load({ photo(1, 5, "Sony", 100, { Exposure2012 = 0.2, Contrast2012 = 10 }),
            photo(2, 4, "Sony", 100, { Exposure2012 = 0.5, Contrast2012 = 20 }),
            photo(3, 5, "Sony", 100, { Exposure2012 = 0.8 }) })
        local result = Handler.summarize({})
        assert.are.equal(3, result.scanned)
        assert.are.equal(3, result.matched)
        assert.is_false(result.truncated)
        assert.are.equal(1, #result.groups)
        local group = result.groups[1]
        assert.are.equal(3, group.count)
        assert.are.equal("Sony", group.camera_model)
        assert.are.equal("1-400", group.iso_bucket)
        assert.are.same({ min = 0.2, median = 0.5, max = 0.8 }, group.settings.Exposure2012)
        assert.are.same({ min = 10, median = 15, max = 20 }, group.settings.Contrast2012)
        assert.are.equal(0, catalog.getWriteAccessCount())
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)

    it("uses inclusive rating search outside the read gate", function()
        load({ photo(1, 5, "Sony", 100), photo(2, 4, "Sony", 100), photo(3, 3, "Sony", 100) })
        local search
        local inner = catalog.findPhotos
        catalog.findPhotos = function(self, args) search = args.searchDesc return inner(self, args) end
        assert.are.equal(2, Handler.summarize({ min_rating = 4 }).scanned)
        assert.are.same({ combine = "intersect", { criteria = "rating", operation = ">=", value = 4 } }, search)
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)

    it("intersects exported flags with rating before reading settings", function()
        local no = photo(2, 5, "Sony", 100, {}, false)
        no.getDevelopSettings = function() error("unexported settings read") end
        load({ photo(1, 4, "Sony", 100, {}, true), no, photo(3, 3, "Sony", 100, {}, true),
            photo(4, 5, "Sony", 100) })
        local result = Handler.summarize({ exported_only = true })
        assert.are.equal(1, result.matched)
        assert.are.equal(1, result.scanned)
    end)

    it("separates cameras and all ISO bucket boundaries including unknowns", function()
        local photos = {}
        for index, iso in ipairs({ 100, 400, 401, 1600, 1601, 6400, 6401 }) do
            photos[#photos + 1] = photo(index, 5, "Sony", iso)
        end
        photos[#photos + 1] = photo(8, 5, "Canon", 100)
        photos[#photos + 1] = photo(9, 5, nil, nil)
        photos[#photos + 1] = photo(10, 5, "Sony", nil)
        load(photos)
        local groups = Handler.summarize({}).groups
        assert.are.equal(7, #groups)
        local counts = {}
        for _, group in ipairs(groups) do counts[group.camera_model .. ":" .. group.iso_bucket] = group.count end
        assert.are.same({ ["Sony:1-400"] = 2, ["Sony:401-1600"] = 2, ["Sony:1601-6400"] = 2,
            ["Sony:6401+"] = 1, ["Canon:1-400"] = 1, ["unknown:unknown"] = 1, ["Sony:unknown"] = 1 }, counts)
    end)

    it("omits photo-specific, nonnumeric, nonfinite and all-zero settings", function()
        load({ photo(1, 5, "Sony", 100, { CropTop = 1, CropAngle = 1, CropUnknown = 1,
            PerspectiveVertical = 2, Temperature = 6000, Tint = 8, WhiteBalance = "Custom",
            ToneCurvePV2012 = { 0, 0, 255, 255 }, Contrast2012 = 0, Exposure2012 = -0.5,
            Flag = true, Infinite = math.huge, Nan = 0/0 }) })
        assert.are.same({ Exposure2012 = { min = -0.5, median = -0.5, max = -0.5 } },
            Handler.summarize({}).groups[1].settings)
    end)

    it("caps Develop reads at 200 by default and reports all matches", function()
        local photos, reads = {}, 0
        for index = 1, 205 do
            local p = photo(index, 5, "Sony", 100)
            p.getDevelopSettings = function() reads = reads + 1 return {} end
            photos[index] = p
        end
        load(photos)
        local result = Handler.summarize({})
        assert.are.equal(200, reads)
        assert.are.equal(200, result.scanned)
        assert.are.equal(205, result.matched)
        assert.is_true(result.truncated)
        result = Handler.summarize({ max_photos = 3 })
        assert.are.equal(3, result.scanned)
        assert.are.equal(205, result.matched)
    end)

    it("returns an empty list without a read gate when nothing matches", function()
        load({ photo(1, 3, "Sony", 100) })
        catalog.withReadAccessDo = function() error("unnecessary read gate") end
        local result = Handler.summarize({})
        assert.are.same({ groups = {}, scanned = 0, matched = 0, truncated = false }, result)
        assert.matches('"groups":%[%]', JSON:encode(result))
    end)

    it("bounds serialized groups and reports omitted settings", function()
        local settings = {}
        for index = 1, 300 do settings[string.rep("setting", 8) .. index] = 1.234567890123456e100 end
        load({ photo(1, 5, string.rep("Camera", 30), 100, settings) })
        local group = Handler.summarize({}).groups[1]
        assert.is_true(#JSON:encode(group) <= 6000)
        assert.is_true(group.settings_omitted > 0)
    end)

    for _, args in ipairs({ { min_rating = -1 }, { min_rating = 6 }, { min_rating = 4.5 },
        { min_rating = "4" }, { max_photos = 0 }, { max_photos = 201 }, { max_photos = math.huge },
        { max_photos = 0/0 }, { exported_only = "yes" } }) do
        it("rejects invalid arguments before querying", function()
            load({})
            assert.has_error(function() Handler.summarize(args) end)
            assert.are.equal(0, catalog.getQueryCount())
        end)
    end
end)
