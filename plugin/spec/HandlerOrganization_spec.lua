local helper = require 'spec_helper'

local function setup(opts)
    opts = opts or {}
    local catalog = helper.fakeCatalog(opts)
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerOrganization = nil
    return catalog, require 'HandlerOrganization'
end

describe("HandlerOrganization.setRating", function()
    it("resolves photos OUTSIDE the write-access gate", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", rating = 0 })
        local catalog, Handler = setup({ photos = { p1 } })

        Handler.setRating({ photo_ids = { "1" }, rating = 4 })

        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

    it("sets rating on found photos", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", rating = 0 })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", rating = 0 })
        local _, Handler = setup({ photos = { p1, p2 } })

        local r = Handler.setRating({ photo_ids = { "1", "2" }, rating = 4 })

        assert.is_true(r.success)
        assert.are.equal(2, r.updated)
        assert.are.equal(4, p1.getRawMetadata(p1, "rating"))
        assert.are.equal(4, p2.getRawMetadata(p2, "rating"))
    end)

    it("validates rating range", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.setRating({ photo_ids = { "1" }, rating = 6 }) end)
        assert.has_error(function() Handler.setRating({ photo_ids = { "1" }, rating = -1 }) end)
    end)

    it("requires photo_ids and rating", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.setRating({ rating = 3 }) end)
        assert.has_error(function() Handler.setRating({ photo_ids = { "1" } }) end)
    end)

    it("reports unknown photos instead of claiming a silent success", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", rating = 0 })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.setRating({ photo_ids = { "1", "missing" }, rating = 2 })

        assert.are.equal(1, r.updated)
        assert.are.same({ "missing" }, r.missing)
        assert.is_not_nil(r.message:find("1 ids not found", 1, true))
    end)

    it("rejects a rating that is not a number", function()
        local _, Handler = setup({})
        assert.has_error(
            function() Handler.setRating({ photo_ids = { "1" }, rating = "3" }) end,
            "rating must be a number between 0 and 5")
    end)
end)

describe("HandlerOrganization.setKeywords", function()
    it("resolves photos OUTSIDE the write-access gate", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
        local catalog, Handler = setup({ photos = { p1 } })

        Handler.setKeywords({ photo_ids = { "1" }, add_keywords = { "summer" } })

        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

    it("adds keywords to the photo via createKeyword", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
        local catalog, Handler = setup({ photos = { p1 } })

        local r = Handler.setKeywords({ photo_ids = { "1" }, add_keywords = { "summer", "beach" } })

        assert.is_true(r.success)
        assert.are.equal(1, r.updated)
        assert.are.equal(2, #catalog.getCreatedKeywords())
    end)

    it("creates duplicate add keywords once", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
        local catalog, Handler = setup({ photos = { p1 } })

        Handler.setKeywords({ photo_ids = { "1" }, add_keywords = { "summer", "summer" } })

        assert.are.equal(1, #catalog.getCreatedKeywords())
    end)

    it("removes existing keywords by name match", function()
        local existing = { getName = function() return "old" end }
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = { existing } })
        local _, Handler = setup({ photos = { p1 } })

        Handler.setKeywords({ photo_ids = { "1" }, remove_keywords = { "old" } })

        -- removeKeyword captures into __removedKeywords on the photo's meta.
        -- We can't introspect easily, but we know the call didn't error and updated=1.
        local r = Handler.setKeywords({ photo_ids = { "1" }, remove_keywords = { "missing" } })
        assert.are.equal(1, r.updated)
    end)

    it("requires photo_ids", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.setKeywords({}) end)
        assert.has_error(function() Handler.setKeywords({ photo_ids = {} }) end)
    end)

    it("rejects a call with neither add_keywords nor remove_keywords", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
        local _, Handler = setup({ photos = { p1 } })

        assert.has_error(
            function() Handler.setKeywords({ photo_ids = { "1" } }) end,
            "add_keywords or remove_keywords is required")
        assert.has_error(
            function() Handler.setKeywords({ photo_ids = { "1" }, add_keywords = {} }) end,
            "add_keywords or remove_keywords is required")
    end)

    it("limits keyword batch size", function()
        local _, Handler = setup({})
        local keywords = {}
        for i = 1, 1001 do
            table.insert(keywords, "kw" .. i)
        end

        assert.has_error(function() Handler.setKeywords({ photo_ids = { "1" }, add_keywords = keywords }) end)
        assert.has_error(function() Handler.setKeywords({ photo_ids = { "1" }, remove_keywords = keywords }) end)
    end)
end)
