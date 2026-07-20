local helper = require 'spec_helper'

describe("HandlerSearch.searchPhotos", function()
    local catalog, Handler

    before_each(function()
        catalog = helper.fakeCatalog({
            photos = {
                helper.fakePhoto({ id = "1", path = "/a/sunset.jpg", fileName = "sunset.jpg", rating = 5, dateTimeOriginal = "2024-06-01" }),
                helper.fakePhoto({ id = "2", path = "/b/portrait.jpg", fileName = "portrait.jpg", rating = 3, dateTimeOriginal = "2024-06-02" }),
                helper.fakePhoto({ id = "3", path = "/c/landscape.jpg", fileName = "landscape.jpg", rating = 5, dateTimeOriginal = "2024-06-03" }),
            },
        })

        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrLogger = helper.defaultLrLogger(),
        })

        package.loaded.HandlerSearch = nil
        Handler = require 'HandlerSearch'
    end)

    it("returns all photos when no filters given", function()
        local result = Handler.searchPhotos({})
        assert.are.equal(3, result.count)
        assert.are.equal(3, #result.photos)
        assert.is_false(result.has_more)
    end)

    it("filters by rating", function()
        local result = Handler.searchPhotos({ rating = 5 })
        assert.are.equal(2, result.count)
        for _, p in ipairs(result.photos) do
            assert.are.equal(5, p.rating)
        end
    end)

    it("filters by filename substring (case-insensitive)", function()
        local result = Handler.searchPhotos({ filename = "PORTRAIT" })
        assert.are.equal(1, result.count)
        assert.are.equal("portrait.jpg", result.photos[1].filename)
    end)

    it("filters by date range", function()
        local result = Handler.searchPhotos({ start_date = "2024-06-02", end_date = "2024-06-02" })
        assert.are.equal(1, result.count)
        assert.are.equal("2", result.photos[1].id)
    end)

    it("filters inclusively by start date", function()
        local result = Handler.searchPhotos({ start_date = "2024-06-02" })
        assert.are.equal(2, result.count)
        assert.are.equal("2", result.photos[1].id)
        assert.are.equal("3", result.photos[2].id)
    end)

    it("filters inclusively by end date", function()
        local result = Handler.searchPhotos({ end_date = "2024-06-02" })
        assert.are.equal(2, result.count)
        assert.are.equal("1", result.photos[1].id)
        assert.are.equal("2", result.photos[2].id)
    end)

    it("rejects malformed date filters before querying Lightroom", function()
        local ok, err = pcall(function()
            Handler.searchPhotos({ start_date = "2024-6-02", end_date = "2024-06-03" })
        end)
        assert.is_false(ok)
        assert.matches("start_date must use YYYY%-MM%-DD format", err)
    end)

    it("rejects invalid calendar dates before querying Lightroom", function()
        local ok, err = pcall(function()
            Handler.searchPhotos({ start_date = "2024-02-30" })
        end)
        assert.is_false(ok)
        assert.matches("start_date must use a valid calendar date", err)
    end)

    it("rejects reversed date ranges before querying Lightroom", function()
        local ok, err = pcall(function()
            Handler.searchPhotos({ start_date = "2024-06-03", end_date = "2024-06-02" })
        end)
        assert.is_false(ok)
        assert.matches("start_date must be on or before end_date", err)
    end)

    it("returns empty when no photo matches", function()
        local result = Handler.searchPhotos({ rating = 1 })
        assert.are.equal(0, result.count)
        assert.are.same({}, result.photos)
        assert.is_false(result.has_more)
    end)

    it("runs findPhotos OUTSIDE the read-access gate (#124 deadlock guard)", function()
        Handler.searchPhotos({ filename = "sunset" })
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)

    it("runs getAllPhotos OUTSIDE the read-access gate when no filters", function()
        Handler.searchPhotos({})
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)
end)

describe("HandlerSearch.searchPhotos pagination", function()
    local Handler

    before_each(function()
        local photos = {}
        for i = 1, 250 do
            table.insert(photos, helper.fakePhoto({
                id = tostring(i),
                path = "/p/" .. i .. ".jpg",
                fileName = "p" .. i .. ".jpg",
                rating = 0,
                dateTimeOriginal = "2024-06-01",
            }))
        end
        local catalog = helper.fakeCatalog({ photos = photos })
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrLogger = helper.defaultLrLogger(),
        })
        package.loaded.HandlerSearch = nil
        Handler = require 'HandlerSearch'
    end)

    it("caps to 100 by default and signals has_more", function()
        local r = Handler.searchPhotos({})
        assert.are.equal(250, r.count)
        assert.are.equal(100, #r.photos)
        assert.is_true(r.has_more)
        assert.are.equal("1", r.photos[1].id)
        assert.are.equal("100", r.photos[100].id)
    end)

    it("respects explicit limit up to total", function()
        local r = Handler.searchPhotos({ limit = 500 })
        assert.are.equal(250, r.count)
        assert.are.equal(250, #r.photos)
        assert.is_false(r.has_more)
    end)

    it("paginates via offset", function()
        local r = Handler.searchPhotos({ limit = 50, offset = 100 })
        assert.are.equal(250, r.count)
        assert.are.equal(50, #r.photos)
        assert.are.equal("101", r.photos[1].id)
        assert.are.equal("150", r.photos[50].id)
        assert.is_true(r.has_more)
    end)

    it("returns empty slice past the end without erroring", function()
        local r = Handler.searchPhotos({ offset = 1000 })
        assert.are.equal(250, r.count)
        assert.are.equal(0, #r.photos)
        assert.is_false(r.has_more)
    end)
end)
