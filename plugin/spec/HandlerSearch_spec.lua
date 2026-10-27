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

    it("omits paths by default and includes them only on request", function()
        local slim = Handler.searchPhotos({ limit = 1 })
        local full = Handler.searchPhotos({ limit = 1, include_path = true })
        local explicit = Handler.searchPhotos({ limit = 1, include_path = false })

        assert.are.same({ id = "1", filename = "sunset.jpg", rating = 5,
            dateTimeOriginal = "2024-06-01" }, slim.photos[1])
        assert.are.same(slim, explicit)
        assert.are.equal("/a/sunset.jpg", full.photos[1].path)
        full.photos[1].path = nil
        assert.are.same(slim, full)
    end)

    it("encodes a default 100-row page within 65 percent of rows with paths", function()
        local photos = {}
        for i = 1, 100 do
            photos[i] = helper.fakePhoto({ id = tostring(i), path = "/" .. string.rep("a", 48) .. "/sunset.jpg",
                fileName = "sunset.jpg", rating = 5, dateTimeOriginal = "2024-06-01" })
        end
        catalog = helper.fakeCatalog({ photos = photos })
        local JSON = require 'JSON'

        local slim = JSON:encode(Handler.searchPhotos({}))
        local full = JSON:encode(Handler.searchPhotos({ include_path = true }))

        assert.is_true(#slim <= #full * 0.65)
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

    for _, case in ipairs({
        { args = { camera = "Sony ILCE-7M3" }, criterion = { criteria = "camera", operation = "==", value = "Sony ILCE-7M3" } },
        { args = { lens = "24-70mm" }, criterion = { criteria = "lens", operation = "==", value = "24-70mm" } },
        { args = { iso = 100 }, criterion = { criteria = "isoSpeedRating", operation = "==", value = 100 } },
        { args = { focal_length = 32 }, criterion = { criteria = "focalLength", operation = "==", value = 32 } },
        { args = { flag = "pick" }, criterion = { criteria = "pick", operation = "==", value = 1 } },
        { args = { flag = "reject" }, criterion = { criteria = "pick", operation = "==", value = -1 } },
        { args = { flag = "none" }, criterion = { criteria = "pick", operation = "==", value = 0 } },
        { args = { color_label = "red" }, criterion = { criteria = "labelColor", operation = "==", value = 1 } },
        { args = { color_label = "yellow" }, criterion = { criteria = "labelColor", operation = "==", value = 2 } },
        { args = { color_label = "green" }, criterion = { criteria = "labelColor", operation = "==", value = 3 } },
        { args = { color_label = "blue" }, criterion = { criteria = "labelColor", operation = "==", value = 4 } },
        { args = { color_label = "purple" }, criterion = { criteria = "labelColor", operation = "==", value = 5 } },
        { args = { color_label = "none" }, criterion = { criteria = "labelColor", operation = "==", value = "none" } },
        { args = { edited = true }, criterion = { criteria = "hasAdjustments", operation = "isTrue", value = true } },
        { args = { edited = false }, criterion = { criteria = "hasAdjustments", operation = "isFalse", value = false } },
        { args = { file_type = "RAW" }, criterion = { criteria = "fileFormat", operation = "==", value = "RAW" } },
        { args = { folder = "Photos Travel" }, criterion = { criteria = "folder", operation = "all", value = "Photos Travel" } },
    }) do
        it("passes the Library criterion for " .. case.criterion.criteria .. " " .. tostring(case.criterion.value), function()
            local queried
            catalog.findPhotos = function(_, opts) queried = opts.searchDesc return {} end
            local result = Handler.searchPhotos(case.args)
            assert.are.same({ combine = "intersect", case.criterion }, queried)
            assert.are.equal(0, result.count)
            assert.are.same({}, result.photos)
            assert.is_false(result.has_more)
        end)
    end

    it("intersects flag and rating with other Library filters", function()
        local photos = {
            helper.fakePhoto({ id = "1", rating = 5, pickStatus = 1, fileFormat = "RAW", __hasAdjustments = false }),
            helper.fakePhoto({ id = "2", rating = 5, pickStatus = -1, fileFormat = "RAW", __hasAdjustments = false }),
            helper.fakePhoto({ id = "3", rating = 3, pickStatus = 1, fileFormat = "RAW", __hasAdjustments = false }),
            helper.fakePhoto({ id = "4", rating = 5, pickStatus = 1, fileFormat = "JPG", __hasAdjustments = false }),
            helper.fakePhoto({ id = "5", rating = 5, pickStatus = 1, fileFormat = "RAW", __hasAdjustments = true }),
        }
        catalog = helper.fakeCatalog({ photos = photos })
        local result = Handler.searchPhotos({ flag = "pick", rating = 5, file_type = "RAW", edited = false })
        assert.are.equal(1, result.count)
        assert.are.equal("1", result.photos[1].id)
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)

    for _, args in ipairs({
        { flag = "maybe" }, { file_type = "GIF" }, { color_label = "pink" },
        { camera = "" }, { lens = 42 }, { folder = "  " }, { iso = -1 }, { iso = math.huge },
        { iso = 0/0 }, { edited = "false" },
        { focal_length = 0 }, { focal_length = -32 }, { focal_length = math.huge },
        { focal_length = 0/0 }, { focal_length = "32 mm" },
    }) do
        it("rejects invalid Library filters before a catalog query", function()
            assert.has_error(function() Handler.searchPhotos(args) end)
            assert.are.equal(0, catalog.getQueryCount())
        end)
    end

    it("intersects native focal length with other filters", function()
        catalog = helper.fakeCatalog({ photos = {
            helper.fakePhoto({ id = "1", focalLength = 32, rating = 5 }),
            helper.fakePhoto({ id = "2", focalLength = 32, rating = 3 }),
            helper.fakePhoto({ id = "3", focalLength = 24, rating = 5 }),
        } })
        local result = Handler.searchPhotos({ focal_length = 32, rating = 5 })
        assert.are.equal(1, result.count)
        assert.are.equal("1", result.photos[1].id)
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)

    it("preserves existing criterion tables", function()
        assert.are.same({ combine = "intersect",
            { criteria = "filename", operation = "any", value = "sun" },
            { criteria = "rating", operation = "==", value = 5 },
            { criteria = "keywords", operation = "all", value = "travel" },
        }, Handler.buildSearchDesc({ filename = "sun", rating = 5, keywords = { "travel" } }))
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
    local Handler, catalog

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
        catalog = helper.fakeCatalog({ photos = photos })
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

    it("reads a page's metadata in one batch call per kind", function()
        local calls = {}
        for _, name in ipairs({ "batchGetRawMetadata", "batchGetFormattedMetadata" }) do
            local inner = catalog[name]
            catalog[name] = function(self, photos, keys)
                calls[#calls + 1] = { name = name, size = #photos, first = photos[1].localIdentifier }
                return inner(self, photos, keys)
            end
        end

        local r = Handler.searchPhotos({ limit = 50, offset = 100, include_path = true })

        assert.are.equal(50, #r.photos)
        assert.are.same({
            { name = "batchGetRawMetadata", size = 50, first = "101" },
            { name = "batchGetFormattedMetadata", size = 50, first = "101" },
        }, calls)
        assert.are.equal("/p/101.jpg", r.photos[1].path)
    end)
end)
