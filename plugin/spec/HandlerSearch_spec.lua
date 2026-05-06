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

    it("returns empty when no photo matches", function()
        local result = Handler.searchPhotos({ rating = 1 })
        assert.are.equal(0, result.count)
        assert.are.same({}, result.photos)
    end)
end)
