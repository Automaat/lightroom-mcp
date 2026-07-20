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

    it("exposes HSL develop settings with SDK keys", function()
        local photo = helper.fakePhoto({
            id = "43",
            path = "/p/portrait.jpg",
            fileName = "portrait.jpg",
            developSettings = {
                HueAdjustmentRed = -8,
                SaturationAdjustmentOrange = -15,
                LuminanceAdjustmentYellow = 6,
            },
        })
        local _, Handler = setup({ photo })

        local r = Handler.getPhotoMetadata({ photo_id = "43" })

        assert.are.equal(-8, r.developSettings.hsl.HueAdjustmentRed)
        assert.are.equal(-15, r.developSettings.hsl.SaturationAdjustmentOrange)
        assert.are.equal(6, r.developSettings.hsl.LuminanceAdjustmentYellow)
    end)

    it("omits HSL group when no HSL develop settings are present", function()
        local photo = helper.fakePhoto({
            id = "44",
            path = "/p/no-hsl.jpg",
            fileName = "no-hsl.jpg",
            developSettings = { Exposure2012 = 0.25 },
        })
        local _, Handler = setup({ photo })

        local r = Handler.getPhotoMetadata({ photo_id = "44" })

        assert.is_nil(r.developSettings.hsl)
    end)

    it("exposes IPTC location, GPS, and copyright metadata", function()
        local photo = helper.fakePhoto({
            id = "7",
            path = "/p/street.jpg",
            fileName = "street.jpg",
            title = "Main Street",
            caption = "Downtown at dusk",
            headline = "Evening commute",
            location = "5th Avenue",
            city = "New York",
            stateProvince = "NY",
            country = "USA",
            isoCountryCode = "US",
            gps = { latitude = 40.7128, longitude = -74.006 },
            gpsAltitude = 10.5,
            creator = "Jane Doe",
            copyright = "© Jane Doe",
            copyrightState = "Copyrighted",
            rightsUsageTerms = "All rights reserved",
        })
        local _, Handler = setup({ photo })

        local r = Handler.getPhotoMetadata({ photo_id = "7" })

        assert.are.equal("Main Street", r.title)
        assert.are.equal("Downtown at dusk", r.caption)
        assert.are.equal("5th Avenue", r.location.sublocation)
        assert.are.equal("New York", r.location.city)
        assert.are.equal("US", r.location.isoCountryCode)
        assert.are.equal(40.7128, r.gps.latitude)
        assert.are.equal(-74.006, r.gps.longitude)
        assert.are.equal(10.5, r.gps.altitude)
        assert.are.equal("Jane Doe", r.copyright.creator)
        assert.are.equal("Copyrighted", r.copyright.status)
    end)

    it("omits gps, location, and copyright groups when empty", function()
        local photo = helper.fakePhoto({ id = "8", path = "/p/no-gps.jpg", fileName = "no-gps.jpg" })
        local _, Handler = setup({ photo })

        local r = Handler.getPhotoMetadata({ photo_id = "8" })
        assert.is_nil(r.gps)
        assert.is_nil(r.location)
        assert.is_nil(r.copyright)
    end)

    it("omits the gps group when the raw table carries no coordinates", function()
        local photo = helper.fakePhoto({ id = "10", fileName = "empty-gps.jpg", gps = {} })
        local _, Handler = setup({ photo })

        local r = Handler.getPhotoMetadata({ photo_id = "10" })
        assert.is_nil(r.gps)
    end)

    it("reads only valid SDK metadata keys (mock rejects typos)", function()
        -- Guards against a typo'd key that would throw inside withReadAccessDo
        -- in real Lightroom. The mock errors on keys absent from the SDK allowlist.
        local photo = helper.fakePhoto({ id = "9", fileName = "f.jpg" })
        assert.has_error(function() photo:getFormattedMetadata("copyrightStatus") end)
        assert.has_no.errors(function() photo:getFormattedMetadata("copyrightState") end)
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
