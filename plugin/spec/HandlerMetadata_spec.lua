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
                helper.fakeKeyword("summer"),
                helper.fakeKeyword("beach", { parent = helper.fakeKeyword("Places") }),
            },
            cameraMake = "Canon",
            cameraModel = "R5",
            developSettings = {
                Exposure2012 = 0.5,
                WhiteBalance = "Custom",
                ConvertToGrayscale = true,
                ToneCurveName2012 = "Custom",
                ToneCurvePV2012 = { 0, 0, 64, 48, 255, 255 },
                ToneCurvePV2012Red = { 0, 0, 255, 250 },
            },
        })
        local _, Handler = setup({ photo })

        local r = Handler.getPhotoMetadata({ photo_id = "42" })

        assert.are.equal("/p/sunset.jpg", r.path)
        assert.are.equal(5, r.rating)
        assert.are.equal("Canon", r.cameraMake)
        assert.are.equal(0.5, r.developSettings.exposure)
        assert.is_true(r.developSettings.convertToGrayscale)
        assert.are.equal("Custom", r.developSettings.toneCurveName)
        assert.are.same({ 0, 0, 64, 48, 255, 255 }, r.developSettings.toneCurve)
        assert.are.same({ 0, 0, 255, 250 }, r.developSettings.toneCurveRed)
        assert.are.same({ "summer", "beach" }, r.keywords)
        assert.are.same({ "summer", "Places|beach" }, r.keywordPaths)
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

describe("HandlerMetadata.setGps", function()
    it("writes latitude and longitude to found photos", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", gps = { latitude = 1, longitude = 2 } })
        local _, Handler = setup({ p1, p2 })

        local r = Handler.setGps({ photo_ids = { "1", "2" }, latitude = 48.5818, longitude = 7.7509 })

        assert.is_true(r.success)
        assert.are.equal(2, r.updated)
        assert.are.same({ latitude = 48.5818, longitude = 7.7509 }, p1:getRawMetadata("gps"))
        assert.are.same({ latitude = 48.5818, longitude = 7.7509 }, p2:getRawMetadata("gps"))
    end)

    it("leaves altitude alone unless one is given", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", gpsAltitude = 12 })
        local _, Handler = setup({ p1 })

        Handler.setGps({ photo_ids = { "1" }, latitude = 0, longitude = 0 })
        assert.are.equal(12, p1:getRawMetadata("gpsAltitude"))

        local r = Handler.setGps({ photo_ids = { "1" }, latitude = 0, longitude = 0, altitude = 140.5 })
        assert.are.equal(140.5, p1:getRawMetadata("gpsAltitude"))
        assert.are.equal(140.5, r.altitude)
    end)

    it("clears altitude with clear_altitude", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", gpsAltitude = 3000 })
        local _, Handler = setup({ p1 })

        local r = Handler.setGps({ photo_ids = { "1" }, latitude = 54.4, longitude = 18.6, clear_altitude = true })

        assert.is_nil(p1:getRawMetadata("gpsAltitude"))
        assert.is_true(r.altitude_cleared)
        assert.is_nil(r.altitude)
    end)

    it("rejects an out-of-range altitude and a conflicting or bad clear_altitude", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", gpsAltitude = 12 })
        local catalog, Handler = setup({ p1 })
        local base = { photo_ids = { "1" }, latitude = 1, longitude = 1 }
        local function with(extra)
            local args = {}
            for k, v in pairs(base) do args[k] = v end
            for k, v in pairs(extra) do args[k] = v end
            return args
        end

        assert.has_error(function() Handler.setGps(with({ altitude = math.huge })) end,
            "altitude must be a number between -20000 and 100000 (metres)")
        assert.has_error(function() Handler.setGps(with({ altitude = -20001 })) end,
            "altitude must be a number between -20000 and 100000 (metres)")
        assert.has_error(function() Handler.setGps(with({ altitude = 5, clear_altitude = true })) end,
            "altitude and clear_altitude cannot be used together")
        assert.has_error(function() Handler.setGps(with({ clear_altitude = "yes" })) end,
            "clear_altitude must be a boolean")

        assert.are.equal(0, catalog.getQueryCount())
        assert.are.equal(12, p1:getRawMetadata("gpsAltitude"))
    end)

    it("resolves photos OUTSIDE the write-access gate", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local catalog, Handler = setup({ p1 })

        Handler.setGps({ photo_ids = { "1" }, latitude = 1, longitude = 1 })

        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

    it("reports unknown photos instead of claiming a silent success", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ p1 })

        local r = Handler.setGps({ photo_ids = { "1", "missing" }, latitude = 1, longitude = 1 })

        assert.are.equal(1, r.updated)
        assert.are.same({ "missing" }, r.missing)
    end)

    it("rejects missing, non-numeric and out-of-range coordinates before scanning", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local catalog, Handler = setup({ p1 })

        assert.has_error(function() Handler.setGps({ latitude = 1, longitude = 1 }) end)
        assert.has_error(function() Handler.setGps({ photo_ids = { "1" }, longitude = 1 }) end,
            "latitude must be a number between -90 and 90")
        assert.has_error(function() Handler.setGps({ photo_ids = { "1" }, latitude = "1", longitude = 1 }) end,
            "latitude must be a number between -90 and 90")
        assert.has_error(function() Handler.setGps({ photo_ids = { "1" }, latitude = 90.1, longitude = 1 }) end,
            "latitude must be a number between -90 and 90")
        assert.has_error(function() Handler.setGps({ photo_ids = { "1" }, latitude = 1, longitude = -181 }) end,
            "longitude must be a number between -180 and 180")
        assert.has_error(function()
            Handler.setGps({ photo_ids = { "1" }, latitude = 1, longitude = 1, altitude = "high" })
        end, "altitude must be a number between -20000 and 100000 (metres)")

        assert.are.equal(0, catalog.getQueryCount())
        assert.is_nil(p1:getRawMetadata("gps"))
    end)
end)

describe("HandlerMetadata.setLocation", function()
    it("writes the given IPTC location fields to found photos", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", city = "Paris" })
        local _, Handler = setup({ p1, p2 })

        local r = Handler.setLocation({
            photo_ids = { "1", "2" },
            sublocation = "Nelson-Atkins Museum of Art",
            city = "Kansas City",
            state_province = "Missouri",
            country = "United States",
            iso_country_code = "US",
        })

        assert.is_true(r.success)
        assert.are.equal(2, r.updated)
        assert.are.same({ "sublocation", "city", "state_province", "country", "iso_country_code" }, r.fields)
        for _, p in ipairs({ p1, p2 }) do
            assert.are.equal("Nelson-Atkins Museum of Art", p:getRawMetadata("location"))
            assert.are.equal("Kansas City", p:getRawMetadata("city"))
            assert.are.equal("Missouri", p:getRawMetadata("stateProvince"))
            assert.are.equal("United States", p:getRawMetadata("country"))
            assert.are.equal("US", p:getRawMetadata("isoCountryCode"))
        end
    end)

    it("leaves fields that are not given unchanged", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", city = "Sydney", country = "Australia" })
        local _, Handler = setup({ p1 })

        local r = Handler.setLocation({ photo_ids = { "1" }, sublocation = "Bondi Beach" })

        assert.are.same({ "sublocation" }, r.fields)
        assert.are.equal("Bondi Beach", p1:getRawMetadata("location"))
        assert.are.equal("Sydney", p1:getRawMetadata("city"))
        assert.are.equal("Australia", p1:getRawMetadata("country"))
    end)

    it("clears a field given as an empty string", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", location = "Old venue", city = "Berlin" })
        local _, Handler = setup({ p1 })

        Handler.setLocation({ photo_ids = { "1" }, sublocation = "" })

        -- Not nil: Lightroom stores nil on these fields as the text "nil".
        assert.are.equal("", p1:getRawMetadata("location"))
        assert.are.equal("Berlin", p1:getRawMetadata("city"))
    end)

    it("does not touch GPS", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", gps = { latitude = 1, longitude = 2 } })
        local _, Handler = setup({ p1 })

        Handler.setLocation({ photo_ids = { "1" }, city = "Rotorua" })

        assert.are.same({ latitude = 1, longitude = 2 }, p1:getRawMetadata("gps"))
    end)

    it("resolves photos OUTSIDE the write-access gate", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local catalog, Handler = setup({ p1 })

        Handler.setLocation({ photo_ids = { "1" }, city = "Memphis" })

        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

    it("reports unknown photos instead of claiming a silent success", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ p1 })

        local r = Handler.setLocation({ photo_ids = { "1", "missing" }, city = "Munich" })

        assert.are.equal(1, r.updated)
        assert.are.same({ "missing" }, r.missing)
    end)

    it("rejects missing ids, no fields and non-string values before scanning", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", city = "Salzburg" })
        local catalog, Handler = setup({ p1 })

        assert.has_error(function() Handler.setLocation({ city = "Vienna" }) end, "photo_ids is required")
        assert.has_error(function() Handler.setLocation({ photo_ids = { "1" } }) end,
            "give at least one of sublocation, city, state_province, country, iso_country_code")
        assert.has_error(function() Handler.setLocation({ photo_ids = { "1" }, city = 42 }) end,
            "city must be a string")
        assert.has_error(function() Handler.setLocation({ photo_ids = { "1" }, iso_country_code = true }) end,
            "iso_country_code must be a string")

        assert.are.equal(0, catalog.getQueryCount())
        assert.are.equal("Salzburg", p1:getRawMetadata("city"))
    end)
end)
