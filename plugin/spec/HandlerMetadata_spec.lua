local helper = require 'spec_helper'

local function setup(photos)
    local catalog = helper.fakeCatalog({ photos = photos or {} })
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerMetadata = nil
    return catalog, require 'HandlerMetadata'
end

describe("HandlerMetadata.getPhotoMetadata", function()
    it("returns full metadata for a found photo", function()
        local photo = helper.fakePhoto({
            id = "42",
            path = "/p/sunset.jpg",
            fileName = "sunset.jpg",
            rating = 5,
            colorNameForLabel = "red",
            pickStatus = 1,
            keywords = {
                { getName = function() return "summer" end },
                { getName = function() return "beach" end },
            },
            cameraMake = "Canon",
            cameraModel = "R5",
            developSettings = { Exposure2012 = 0.5, WhiteBalance = "Custom" },
        })
        local _, Handler = setup({ photo })

        local r = Handler.getPhotoMetadata({ photo_id = "42" })

        assert.are.equal("/p/sunset.jpg", r.path)
        assert.are.equal(5, r.rating)
        assert.are.equal("Canon", r.cameraMake)
        assert.are.equal(0.5, r.developSettings.exposure)
        assert.are.same({ "summer", "beach" }, r.keywords)
    end)

    it("falls back to lookup by path when local id misses", function()
        local photo = helper.fakePhoto({
            id = "99",
            path = "/match-by-path.jpg",
            fileName = "f.jpg",
        })
        local _, Handler = setup({ photo })

        local r = Handler.getPhotoMetadata({ photo_id = "/match-by-path.jpg" })
        assert.are.equal("/match-by-path.jpg", r.path)
    end)

    it("errors when photo not found", function()
        local _, Handler = setup({})
        assert.has_error(function()
            Handler.getPhotoMetadata({ photo_id = "missing" })
        end)
    end)

    it("errors without photo_id", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.getPhotoMetadata({}) end)
    end)
end)
