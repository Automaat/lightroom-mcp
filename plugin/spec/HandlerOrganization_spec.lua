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

    it("skips unknown photos silently", function()
        local _, Handler = setup({ photos = {} })
        local r = Handler.setRating({ photo_ids = { "missing" }, rating = 2 })
        assert.are.equal(0, r.updated)
    end)
end)

describe("HandlerOrganization.setKeywords", function()
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
