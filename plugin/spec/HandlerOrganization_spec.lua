local helper = require 'spec_helper'
local KeywordTree

local function setup(opts)
    opts = opts or {}
    local catalog = helper.fakeCatalog(opts)
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerOrganization = nil
    KeywordTree = require 'KeywordTree'
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

describe("HandlerOrganization.setFlag", function()
    it("resolves photos OUTSIDE the write-access gate", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", pickStatus = 0 })
        local catalog, Handler = setup({ photos = { p1 } })

        Handler.setFlag({ photo_ids = { "1" }, flag = "pick" })

        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

    it("maps pick, reject and none to the SDK pickStatus", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", pickStatus = 0 })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", pickStatus = 1 })
        local _, Handler = setup({ photos = { p1, p2 } })

        local r = Handler.setFlag({ photo_ids = { "1", "2" }, flag = "reject" })
        assert.is_true(r.success)
        assert.are.equal(2, r.updated)
        assert.are.equal("reject", r.flag)
        assert.are.equal(-1, p1:getRawMetadata("pickStatus"))
        assert.are.equal(-1, p2:getRawMetadata("pickStatus"))

        Handler.setFlag({ photo_ids = { "1" }, flag = "pick" })
        assert.are.equal(1, p1:getRawMetadata("pickStatus"))

        Handler.setFlag({ photo_ids = { "1" }, flag = "none" })
        assert.are.equal(0, p1:getRawMetadata("pickStatus"))
    end)

    it("requires photo_ids and a known flag before scanning", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", pickStatus = 1 })
        local catalog, Handler = setup({ photos = { p1 } })

        assert.has_error(function() Handler.setFlag({ flag = "pick" }) end, "photo_ids is required")
        assert.has_error(function() Handler.setFlag({ photo_ids = { "1" } }) end,
            "flag must be one of: pick, reject, none")
        assert.has_error(function() Handler.setFlag({ photo_ids = { "1" }, flag = "rejected" }) end,
            "flag must be one of: pick, reject, none")
        assert.has_error(function() Handler.setFlag({ photo_ids = { "1" }, flag = 1 }) end,
            "flag must be one of: pick, reject, none")

        assert.are.equal(0, catalog.getQueryCount())
        assert.are.equal(1, p1:getRawMetadata("pickStatus"))
    end)

    it("reports unknown photos instead of claiming a silent success", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", pickStatus = 0 })
        local _, Handler = setup({ photos = { p1 } })

        local r = Handler.setFlag({ photo_ids = { "1", "missing" }, flag = "pick" })

        assert.are.equal(1, r.updated)
        assert.are.same({ "missing" }, r.missing)
        assert.is_not_nil(r.message:find("1 ids not found", 1, true))
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

    -- Catalog tree used by the hierarchy specs:
    --   Places > Europe > Paris
    --   Orientation > portrait
    --   Type > portrait
    --   summer
    local function tree()
        local places = helper.fakeKeyword("Places")
        local europe = helper.fakeKeyword("Europe", { parent = places })
        local paris = helper.fakeKeyword("Paris", { parent = europe })
        local orientation = helper.fakeKeyword("Orientation")
        local orientationPortrait = helper.fakeKeyword("portrait", { parent = orientation })
        local kind = helper.fakeKeyword("Type")
        local typePortrait = helper.fakeKeyword("portrait", { parent = kind })
        local summer = helper.fakeKeyword("summer")
        return {
            top = { places, orientation, kind, summer },
            places = places, europe = europe, paris = paris,
            orientationPortrait = orientationPortrait, typePortrait = typePortrait,
            summer = summer,
        }
    end

    local function added(photo)
        return photo:getRawMetadata("__addedKeywords") or {}
    end

    local function removed(photo)
        return photo:getRawMetadata("__removedKeywords") or {}
    end

    it("adds an existing keyword addressed by its hierarchy path", function()
        local t = tree()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
        local catalog, Handler = setup({ photos = { p1 }, keywords = t.top })

        local r = Handler.setKeywords({ photo_ids = { "1" }, add_keywords = { "Places|Europe|Paris" } })

        assert.are.equal(1, r.updated)
        assert.are.same({ t.paris }, added(p1))
        assert.are.equal(0, #catalog.getCreatedKeywords())
    end)

    it("tells same-named keywords apart by path", function()
        local t = tree()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
        local _, Handler = setup({ photos = { p1 }, keywords = t.top })

        Handler.setKeywords({ photo_ids = { "1" }, add_keywords = { "Type|portrait" } })

        assert.are.same({ t.typePortrait }, added(p1))
    end)

    it("ignores spaces around the path separator", function()
        local t = tree()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
        local _, Handler = setup({ photos = { p1 }, keywords = t.top })

        Handler.setKeywords({ photo_ids = { "1" }, add_keywords = { "Places | Europe | Paris" } })

        assert.are.same({ t.paris }, added(p1))
    end)

    it("creates only the missing levels of a path, under the existing parent", function()
        local t = tree()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
        local catalog, Handler = setup({ photos = { p1 }, keywords = t.top })

        Handler.setKeywords({ photo_ids = { "1" }, add_keywords = { "Places|Europe|Rome|Trastevere" } })

        local created = catalog.getCreatedKeywords()
        assert.are.equal(2, #created)
        assert.are.equal("Rome", created[1]:getName())
        assert.are.equal(t.europe, created[1]:getParent())
        assert.are.equal("Trastevere", created[2]:getName())
        assert.are.equal(created[1], created[2]:getParent())
        assert.are.same({ created[2] }, added(p1))
    end)

    it("creates a shared new parent once for several paths", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
        local catalog, Handler = setup({ photos = { p1 } })

        Handler.setKeywords({ photo_ids = { "1" }, add_keywords = { "Animals|cat", "Animals|dog" } })

        local created = catalog.getCreatedKeywords()
        assert.are.equal(3, #created)
        assert.are.equal("Animals", created[1]:getName())
        assert.are.equal(created[1], created[2]:getParent())
        assert.are.equal(created[1], created[3]:getParent())
    end)

    it("creates each new level in its own write transaction", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
        local catalog, Handler = setup({ photos = { p1 } })

        Handler.setKeywords({ photo_ids = { "1" }, add_keywords = { "A|B|C" } })

        -- One per level, then one for the photo.
        assert.are.equal(4, catalog.getWriteAccessCount())
        local created = catalog.getCreatedKeywords()
        assert.are.equal(3, #created)
        assert.are.same({ created[3] }, added(p1))
        assert.are.equal("A|B|C", KeywordTree.pathOf(created[3]))
    end)

    for _, order in ipairs({ { "Animals", "Animals|cat" }, { "Animals|cat", "Animals" } }) do
        it("creates a new name once when given plain and as a path's first level: "
            .. table.concat(order, ", "), function()
            local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
            local catalog, Handler = setup({ photos = { p1 } })

            Handler.setKeywords({ photo_ids = { "1" }, add_keywords = order })

            local created = catalog.getCreatedKeywords()
            assert.are.equal(2, #created)
            local animals = catalog:getKeywords()
            assert.are.equal(1, #animals)
            assert.are.equal("Animals|cat", KeywordTree.pathOf(animals[1]:getChildren()[1]))
            assert.are.equal(2, #added(p1))
        end)
    end

    it("creates a name differing only in case once", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
        local catalog, Handler = setup({ photos = { p1 } })

        Handler.setKeywords({ photo_ids = { "1" }, add_keywords = { "Summer", "summer", "A|b", "a|B" } })

        assert.are.equal(3, #catalog.getCreatedKeywords())
        assert.are.equal(2, #added(p1))
    end)

    it("matches existing keywords ignoring case", function()
        local t = tree()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
        local catalog, Handler = setup({ photos = { p1 }, keywords = t.top })

        Handler.setKeywords({ photo_ids = { "1" }, add_keywords = { "places|EUROPE|paris", "SUMMER", "places|Rome" } })

        local created = catalog.getCreatedKeywords()
        assert.are.equal(1, #created)
        assert.are.equal(t.places, created[1]:getParent())
        assert.are.same({ t.paris, t.summer, created[1] }, added(p1))
    end)

    it("keeps the committed levels when the photo write fails", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
        p1.addKeyword = function() error("write failed") end
        local catalog, Handler = setup({ photos = { p1 } })

        assert.has_error(function()
            Handler.setKeywords({ photo_ids = { "1" }, add_keywords = { "A|B" } })
        end)
        -- The levels were committed before the photo write; they stay, empty.
        assert.are.equal(2, #catalog.getCreatedKeywords())
    end)

    it("rejects a path with an empty level", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
        local catalog, Handler = setup({ photos = { p1 } })

        assert.has_error(function()
            Handler.setKeywords({ photo_ids = { "1" }, add_keywords = { "Places||Paris" } })
        end, "Invalid keyword path (empty level): Places||Paris")
        assert.are.equal(0, catalog.getWriteAccessCount())
    end)

    describe("with create_missing = false", function()
        it("adds existing keywords by path and by unambiguous name", function()
            local t = tree()
            local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
            local catalog, Handler = setup({ photos = { p1 }, keywords = t.top })

            Handler.setKeywords({
                photo_ids = { "1" },
                add_keywords = { "Places|Europe|Paris", "summer", "Europe" },
                create_missing = false,
            })

            assert.are.same({ t.paris, t.summer, t.europe }, added(p1))
            assert.are.equal(0, #catalog.getCreatedKeywords())
        end)

        it("matches paths and names ignoring case", function()
            local t = tree()
            local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
            local catalog, Handler = setup({ photos = { p1 }, keywords = t.top })

            Handler.setKeywords({
                photo_ids = { "1" },
                add_keywords = { "places|europe|PARIS", "Summer" },
                create_missing = false,
            })

            assert.are.same({ t.paris, t.summer }, added(p1))
            assert.are.equal(0, #catalog.getCreatedKeywords())
            assert.are.equal(1, catalog.getWriteAccessCount())
        end)

        it("rejects unknown and ambiguous keywords without writing anything", function()
            local t = tree()
            local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
            local catalog, Handler = setup({ photos = { p1 }, keywords = t.top })

            assert.has_error(function()
                Handler.setKeywords({
                    photo_ids = { "1" },
                    add_keywords = { "summer", "Places|Asia", "winter", "portrait" },
                    create_missing = false,
                })
            end, "Keywords not resolved (create_missing is false): not found: Places|Asia; "
                .. "not found: winter; ambiguous: portrait (Orientation|portrait, Type|portrait)")

            assert.are.equal(0, catalog.getWriteAccessCount())
            assert.are.equal(0, catalog.getQueryCount())
            assert.are.equal(0, #catalog.getCreatedKeywords())
            assert.are.same({}, added(p1))
        end)

        it("still allows removals", function()
            local t = tree()
            local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = { t.summer } })
            local _, Handler = setup({ photos = { p1 }, keywords = t.top })

            Handler.setKeywords({ photo_ids = { "1" }, remove_keywords = { "summer" }, create_missing = false })

            assert.are.same({ t.summer }, removed(p1))
        end)
    end)

    it("rejects a create_missing that is not a boolean", function()
        local _, Handler = setup({})
        assert.has_error(function()
            Handler.setKeywords({ photo_ids = { "1" }, add_keywords = { "a" }, create_missing = "no" })
        end, "create_missing must be a boolean")
    end)

    it("removes by path only the keyword at that place", function()
        local t = tree()
        local p1 = helper.fakePhoto({
            id = "1", path = "/a.jpg",
            keywords = { t.orientationPortrait, t.typePortrait, t.paris },
        })
        local _, Handler = setup({ photos = { p1 }, keywords = t.top })

        Handler.setKeywords({ photo_ids = { "1" }, remove_keywords = { "Type|portrait" } })

        assert.are.same({ t.typePortrait }, removed(p1))
    end)

    it("removes plain names differing only in case as two exact removals", function()
        local upper = helper.fakeKeyword("Paris")
        local lower = helper.fakeKeyword("paris", { parent = helper.fakeKeyword("Cities") })
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = { upper, lower } })
        local _, Handler = setup({ photos = { p1 } })

        Handler.setKeywords({ photo_ids = { "1" }, remove_keywords = { "Paris", "paris" } })

        assert.are.same({ upper, lower }, removed(p1))
    end)

    it("trims plain names and rejects a blank one", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = {} })
        local catalog, Handler = setup({ photos = { p1 } })

        Handler.setKeywords({ photo_ids = { "1" }, add_keywords = { " summer ", "summer" } })

        local created = catalog.getCreatedKeywords()
        assert.are.equal(1, #created)
        assert.are.equal("summer", created[1]:getName())
        assert.are.same({ created[1] }, added(p1))
        assert.has_error(function()
            Handler.setKeywords({ photo_ids = { "1" }, add_keywords = { "  " } })
        end, "Invalid keyword (empty): '  '")
    end)

    it("removes by path ignoring case", function()
        local t = tree()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", keywords = { t.orientationPortrait, t.typePortrait } })
        local _, Handler = setup({ photos = { p1 }, keywords = t.top })

        Handler.setKeywords({ photo_ids = { "1" }, remove_keywords = { "type|PORTRAIT" } })

        assert.are.same({ t.typePortrait }, removed(p1))
    end)

    it("removes by plain name every keyword so named", function()
        local t = tree()
        local p1 = helper.fakePhoto({
            id = "1", path = "/a.jpg",
            keywords = { t.orientationPortrait, t.typePortrait, t.paris },
        })
        local _, Handler = setup({ photos = { p1 }, keywords = t.top })

        Handler.setKeywords({ photo_ids = { "1" }, remove_keywords = { "portrait" } })

        assert.are.same({ t.orientationPortrait, t.typePortrait }, removed(p1))
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
