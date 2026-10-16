local helper = require 'spec_helper'

local function setup(opts)
    opts = opts or {}
    local catalog = helper.fakeCatalog(opts)
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerCollections = nil
    return catalog, require 'HandlerCollections'
end

describe("HandlerCollections.listCollections", function()
    it("lists top-level collections", function()
        local _, Handler = setup({
            collections = {
                helper.fakeCollection("Trip", { 1, 2, 3 }),
                helper.fakeCollection("Family", { 1 }),
            },
        })
        local r = Handler.listCollections({})
        assert.are.equal(2, r.count)
        assert.are.equal("Trip", r.collections[1].name)
        assert.are.equal(3, r.collections[1].photoCount)
        assert.is_false(r.has_more)
    end)

    it("caps and paginates", function()
        local cols = {}
        for i = 1, 150 do
            table.insert(cols, helper.fakeCollection("c" .. i, {}))
        end
        local _, Handler = setup({ collections = cols })

        local r1 = Handler.listCollections({})
        assert.are.equal(150, r1.count)
        assert.are.equal(100, #r1.collections)
        assert.is_true(r1.has_more)

        local r2 = Handler.listCollections({ limit = 50, offset = 100 })
        assert.are.equal(150, r2.count)
        assert.are.equal(50, #r2.collections)
        assert.are.equal("c101", r2.collections[1].name)
        assert.is_false(r2.has_more)
    end)

    it("descends into collection sets and prefixes names", function()
        local nested = helper.fakeCollection("Inside", {})
        local outerSet = {
            getName = function() return "Outer" end,
            getChildCollections = function() return { nested } end,
            getChildCollectionSets = function() return {} end,
        }
        local _, Handler = setup({ collectionSets = { outerSet } })
        local r = Handler.listCollections({})
        assert.are.equal(1, r.count)
        assert.are.equal("Outer / Inside", r.collections[1].name)
        assert.are.equal("Outer", r.collections[1].parent)
    end)
end)

describe("HandlerCollections.createCollection", function()
    it("creates a collection with the given name", function()
        local catalog, Handler = setup({})
        local r = Handler.createCollection({ name = "New Album" })
        assert.is_true(r.success)
        local created = catalog.getCreatedCollections()
        assert.are.equal(1, #created)
        assert.are.equal("New Album", created[1].getName())
    end)

    it("errors without name", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.createCollection({}) end)
    end)

    it("rejects an empty or whitespace-only name", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.createCollection({ name = "" }) end, "name is required")
        assert.has_error(function() Handler.createCollection({ name = "   " }) end, "name is required")
    end)

    it("rejects a duplicate name that would make lookup ambiguous", function()
        local existing = helper.fakeCollection("Album", {})
        local catalog, Handler = setup({ collections = { existing } })

        assert.has_error(
            function() Handler.createCollection({ name = "Album" }) end,
            "Collection already exists: Album")
        assert.is_nil(catalog.getCreatedCollections()[1])
    end)

    it("creates a top-level collection when parent is omitted", function()
        local catalog, Handler = setup({})
        local r = Handler.createCollection({ name = "Album" })
        assert.are.equal("Album", r.path)
        assert.are.equal(0, #catalog.getCreatedCollectionSets())
        assert.are.equal(1, #catalog.getChildCollections())
    end)

    it("creates missing collection sets along a parent path", function()
        local catalog, Handler = setup({})

        local r = Handler.createCollection({ name = "City", parent = "Trips / 2026 / Coast" })

        assert.is_true(r.success)
        assert.are.equal("Trips / 2026 / Coast / City", r.path)
        assert.are.equal(3, #catalog.getCreatedCollectionSets())
        assert.are.equal(0, #catalog.getChildCollections())
        local listed = Handler.listCollections({})
        assert.are.equal(1, listed.count)
        assert.are.equal("Trips / 2026 / Coast / City", listed.collections[1].name)
        assert.are.equal("Coast", listed.collections[1].parent)
    end)

    it("reuses existing collection sets instead of duplicating them", function()
        local trips = helper.fakeCollectionSet("Trips")
        local year = helper.fakeCollectionSet("2026", { parent = trips })
        local catalog, Handler = setup({ collectionSets = { trips } })

        Handler.createCollection({ name = "One", parent = "Trips / 2026" })
        Handler.createCollection({ name = "Two", parent = "Trips / 2026" })

        assert.are.equal(0, #catalog.getCreatedCollectionSets())
        assert.are.equal(1, #catalog.getChildCollectionSets())
        assert.are.equal(1, #trips.getChildCollectionSets())
        assert.are.equal(2, #year.getChildCollections())
    end)

    it("rejects a duplicate name within the same set", function()
        local trips = helper.fakeCollectionSet("Trips",
            { collections = { helper.fakeCollection("City", {}) } })
        local catalog, Handler = setup({ collectionSets = { trips } })

        assert.has_error(
            function() Handler.createCollection({ name = "City", parent = "Trips" }) end,
            "Collection already exists: Trips / City")
        assert.are.equal(0, #catalog.getCreatedCollections())
    end)

    it("allows the same name in different sets", function()
        local catalog, Handler = setup({ collections = { helper.fakeCollection("City", {}) } })

        Handler.createCollection({ name = "City", parent = "A" })
        Handler.createCollection({ name = "City", parent = "B" })

        assert.are.equal(2, #catalog.getCreatedCollections())
        local names = {}
        for _, c in ipairs(Handler.listCollections({}).collections) do
            table.insert(names, c.name)
        end
        assert.are.same({ "City", "A / City", "B / City" }, names)
    end)

    it("rejects a parent path with an empty set name", function()
        local catalog, Handler = setup({})
        for _, parent in ipairs({ "Trips /  / City", " / Trips", "Trips / " }) do
            assert.has_error(
                function() Handler.createCollection({ name = "X", parent = parent }) end,
                "parent contains an empty collection set name: " .. parent)
        end
        assert.are.equal(0, #catalog.getCreatedCollectionSets())
        assert.are.equal(0, #catalog.getCreatedCollections())
    end)

    it("rejects a parent that is not a set path instead of ignoring it", function()
        local catalog, Handler = setup({})
        assert.has_error(function() Handler.createCollection({ name = "X", parent = 5 }) end,
            "parent must be a collection set path")
        for _, parent in ipairs({ "", "   " }) do
            assert.has_error(
                function() Handler.createCollection({ name = "X", parent = parent }) end,
                "parent contains an empty collection set name: " .. parent)
        end
        assert.are.equal(0, #catalog.getCreatedCollections())
    end)

    it("rejects a set name left over from a malformed separator", function()
        local catalog, Handler = setup({})
        local cases = {
            { "Trips /", "Trips /" },
            { "Trips / /City", "/City" },
            { "Trips/ ", "Trips/ " },
            { "Trips /  City", " City" },
        }
        for _, case in ipairs(cases) do
            assert.has_error(
                function() Handler.createCollection({ name = "X", parent = case[1] }) end,
                string.format(
                    "parent has a malformed collection set name '%s'; separate sets with ' / ': %s",
                    case[2], case[1]))
        end
        assert.are.equal(0, #catalog.getCreatedCollectionSets())
        assert.are.equal(0, #catalog.getCreatedCollections())
    end)

    it("keeps slashes inside a set name", function()
        local _, Handler = setup({})
        local r = Handler.createCollection({ name = "X", parent = "AC/DC" })
        assert.are.equal("AC/DC / X", r.path)
    end)

    it("reuses an existing set whose name differs only in case", function()
        local trips = helper.fakeCollectionSet("Trips")
        local catalog, Handler = setup({ collectionSets = { trips } })

        local r = Handler.createCollection({ name = "City", parent = "trips / 2026" })

        assert.are.equal("Trips / 2026 / City", r.path)
        assert.are.equal(1, #catalog.getCreatedCollectionSets())
        assert.are.equal(1, #catalog.getChildCollectionSets())
        assert.are.equal(1, #trips.getChildCollectionSets())
    end)

    it("rejects a duplicate that differs only in case", function()
        local trips = helper.fakeCollectionSet("Trips",
            { collections = { helper.fakeCollection("City", {}) } })
        local catalog, Handler = setup({ collections = { helper.fakeCollection("Album", {}) },
            collectionSets = { trips } })

        assert.has_error(
            function() Handler.createCollection({ name = "city", parent = "Trips" }) end,
            "Collection already exists: Trips / city")
        assert.has_error(function() Handler.createCollection({ name = "ALBUM" }) end,
            "Collection already exists: ALBUM")
        assert.are.equal(0, #catalog.getCreatedCollections())
    end)

    it("rejects a collection named like a sibling set instead of reporting success", function()
        local inner = helper.fakeCollectionSet("Inner")
        local outer = helper.fakeCollectionSet("Outer", { sets = { inner } })
        local catalog, Handler = setup({ collectionSets = { outer } })

        assert.has_error(
            function() Handler.createCollection({ name = "inner", parent = "Outer" }) end,
            "A collection set named 'Inner' already exists in Outer")
        assert.has_error(function() Handler.createCollection({ name = "Outer" }) end,
            "A collection set named 'Outer' already exists at the top level")
        assert.are.equal(0, #catalog.getCreatedCollections())
    end)

    it("rejects a parent level that is a collection", function()
        local catalog, Handler = setup({ collections = { helper.fakeCollection("Album", {}) } })

        assert.has_error(
            function() Handler.createCollection({ name = "X", parent = "album / 2026" }) end,
            "parent 'album' names a collection, not a collection set")
        assert.are.equal(0, #catalog.getCreatedCollectionSets())
        assert.are.equal(0, #catalog.getCreatedCollections())
    end)

    it("fails when Lightroom returns no collection", function()
        local catalog, Handler = setup({})
        catalog.createCollection = function() return nil end

        assert.has_error(function() Handler.createCollection({ name = "X", parent = "Trips" }) end,
            "Lightroom did not create collection: Trips / X")
    end)

    it("rolls back the new sets when Lightroom returns no set", function()
        local catalog, Handler = setup({})
        local create = catalog.createCollectionSet
        catalog.createCollectionSet = function(self, name, parent, canReturnPrior)
            if name == "2026" then return nil end
            return create(self, name, parent, canReturnPrior)
        end

        assert.has_error(
            function() Handler.createCollection({ name = "X", parent = "Trips / 2026" }) end,
            "Lightroom did not create collection set: 2026")
        assert.are.equal(0, #catalog.getChildCollectionSets())
        assert.are.equal(0, #catalog.getCreatedCollections())
    end)

    -- Lightroom raises "Can't get collection information after creating
    -- collection inside the same withWriteAccessDo function" when a new set is
    -- read in the transaction that created it, so the handler needs separate
    -- gates. The fake raises the same error.
    it("does not read a new collection set in the gate that created it", function()
        local catalog, Handler = setup({})

        Handler.createCollection({ name = "City", parent = "Trips / 2026" })

        assert.are.equal(2, catalog.getWriteAccessCount())
        local naive = setup({})
        assert.has_error(function()
            naive:withWriteAccessDo("Single gate", function()
                local set = naive:createCollectionSet("Trips", nil, true)
                set:getChildCollections()
            end)
        end, "Can't get collection information after creating collection"
            .. " inside the same withWriteAccessDo function")
    end)
end)

describe("HandlerCollections.addToCollection", function()
    it("resolves photos OUTSIDE the write-access gate", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local target = helper.fakeCollection("Target", {})
        local catalog, Handler = setup({ photos = { p1 }, collections = { target } })

        Handler.addToCollection({ collection_name = "Target", photo_ids = { "1" } })

        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

    it("adds matching photos to the named collection", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg" })
        local target = helper.fakeCollection("Target", {})
        local _, Handler = setup({ photos = { p1, p2 }, collections = { target } })

        local r = Handler.addToCollection({
            collection_name = "Target",
            photo_ids = { "1", "2" },
        })

        assert.is_true(r.success)
        assert.are.equal(2, r.added)
        assert.are.equal(2, #target.getAddedPhotos())
    end)

    it("errors when collection not found", function()
        local _, Handler = setup({})
        assert.has_error(function()
            Handler.addToCollection({ collection_name = "Nope", photo_ids = { "1" } })
        end)
    end)

    -- Resolving ids scans the whole catalog, which on a large library outruns
    -- the server's request timeout. Paying that before noticing a typo'd
    -- collection name turns a clear "Collection not found" into no answer.
    it("rejects an unknown collection without scanning the catalog", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local catalog, Handler = setup({ photos = { p1 } })

        assert.has_error(function()
            Handler.addToCollection({ collection_name = "Nope", photo_ids = { "/missing.raw" } })
        end)

        assert.are.equal(0, catalog.getQueryCount())
    end)

    it("reports ids that matched no photo", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local target = helper.fakeCollection("Target", {})
        local _, Handler = setup({ photos = { p1 }, collections = { target } })

        local r = Handler.addToCollection({
            collection_name = "Target",
            photo_ids = { "1", "ghost" },
        })

        assert.are.equal(1, r.added)
        assert.are.same({ "ghost" }, r.missing)
        assert.is_not_nil(r.message:find("1 ids not found", 1, true))
    end)

    it("adds to a nested collection addressed by its listed path", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local top = helper.fakeCollection("Shared", {})
        local nested = helper.fakeCollection("Shared", {})
        local outer = helper.fakeCollectionSet("Outer", { collections = { nested } })
        local _, Handler = setup({ photos = { p1 }, collections = { top }, collectionSets = { outer } })

        local r = Handler.addToCollection({ collection_name = "Outer / Shared", photo_ids = { "1" } })

        assert.are.equal(1, r.added)
        assert.are.same({ p1 }, nested.getAddedPhotos())
        assert.are.same({}, top.getAddedPhotos())
    end)

    it("rejects an ambiguous name without adding to either collection", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local first = helper.fakeCollection("Shared", {})
        local second = helper.fakeCollection("Shared", {})
        local a = helper.fakeCollectionSet("A", { collections = { first } })
        local b = helper.fakeCollectionSet("B", { collections = { second } })
        local catalog, Handler = setup({ photos = { p1 }, collectionSets = { a, b } })

        assert.has_error(function()
            Handler.addToCollection({ collection_name = "Shared", photo_ids = { "1" } })
        end, "2 collections are named 'Shared'; use a collection path")

        assert.are.same({}, first.getAddedPhotos())
        assert.are.same({}, second.getAddedPhotos())
        assert.are.equal(0, catalog.getQueryCount())
    end)

    -- A top-level collection's listed path is its bare name, so it must win
    -- over nested namesakes or no name would reach it.
    it("adds to a top-level collection by name beside a nested namesake", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local top = helper.fakeCollection("Shared", {})
        local nested = helper.fakeCollection("Shared", {})
        local outer = helper.fakeCollectionSet("Outer", { collections = { nested } })
        local _, Handler = setup({ photos = { p1 }, collections = { top },
            collectionSets = { outer } })

        local r = Handler.addToCollection({ collection_name = "Shared", photo_ids = { "1" } })

        assert.are.equal(1, r.added)
        assert.are.same({ p1 }, top.getAddedPhotos())
        assert.are.same({}, nested.getAddedPhotos())
    end)

    it("errors without required args", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.addToCollection({ photo_ids = { "1" } }) end)
        assert.has_error(function() Handler.addToCollection({ collection_name = "X" }) end)
    end)
end)

describe("HandlerCollections.removeFromCollection", function()
    it("resolves photos OUTSIDE the write-access gate", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local target = helper.fakeCollection("Target", { p1 })
        local catalog, Handler = setup({ photos = { p1 }, collections = { target } })

        Handler.removeFromCollection({ collection_name = "Target", photo_ids = { "1" } })

        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

    it("removes member photos and leaves the rest of the collection", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg" })
        local p3 = helper.fakePhoto({ id = "3", path = "/c.jpg" })
        local target = helper.fakeCollection("Target", { p1, p2, p3 })
        local _, Handler = setup({ photos = { p1, p2, p3 }, collections = { target } })

        local r = Handler.removeFromCollection({ collection_name = "Target", photo_ids = { "1", "3" } })

        assert.is_true(r.success)
        assert.are.equal(2, r.removed)
        assert.are.same({ p2 }, target.getPhotos())
    end)

    it("counts photos that were not in the collection instead of claiming them removed", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg" })
        local target = helper.fakeCollection("Target", { p1 })
        local _, Handler = setup({ photos = { p1, p2 }, collections = { target } })

        local r = Handler.removeFromCollection({ collection_name = "Target", photo_ids = { "1", "2" } })

        assert.are.equal(1, r.removed)
        assert.are.equal(1, r.not_in_collection)
        assert.are.same({ p1 }, target.getRemovedPhotos())
    end)

    it("counts a photo once when its id and path are repeated", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg" })
        local target = helper.fakeCollection("Target", { p1, p2 })
        local _, Handler = setup({ photos = { p1, p2 }, collections = { target } })

        local r = Handler.removeFromCollection({
            collection_name = "Target",
            photo_ids = { "1", "/a.jpg", "1" },
        })

        assert.are.equal(1, r.removed)
        assert.are.equal(0, r.not_in_collection)
        assert.are.same({ p2 }, target.getPhotos())
    end)

    it("finds a collection inside a collection set", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local nested = helper.fakeCollection("Inside", { p1 })
        local outerSet = {
            getName = function() return "Outer" end,
            getChildCollections = function() return { nested } end,
            getChildCollectionSets = function() return {} end,
        }
        local _, Handler = setup({ photos = { p1 }, collectionSets = { outerSet } })

        local r = Handler.removeFromCollection({ collection_name = "Inside", photo_ids = { "1" } })

        assert.are.equal(1, r.removed)
    end)

    it("accepts a nested collection path returned by listing", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local nested = helper.fakeCollection("Inside", { p1 })
        local outerSet = {
            getName = function() return "Outer" end,
            getChildCollections = function() return { nested } end,
            getChildCollectionSets = function() return {} end,
        }
        local _, Handler = setup({ photos = { p1 }, collectionSets = { outerSet } })
        local listed = Handler.listCollections({})

        local r = Handler.removeFromCollection({
            collection_name = listed.collections[1].name,
            photo_ids = { "1" },
        })

        assert.are.equal(1, r.removed)
        assert.are.same({}, nested.getPhotos())
    end)

    it("rejects an ambiguous name without changing either collection", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local first = helper.fakeCollection("Shared", { p1 })
        local second = helper.fakeCollection("Shared", { p1 })
        local a = helper.fakeCollectionSet("A", { collections = { first } })
        local b = helper.fakeCollectionSet("B", { collections = { second } })
        local catalog, Handler = setup({ photos = { p1 }, collectionSets = { a, b } })

        assert.has_error(function()
            Handler.removeFromCollection({ collection_name = "Shared", photo_ids = { "1" } })
        end, "2 collections are named 'Shared'; use a collection path")

        assert.are.same({ p1 }, first.getPhotos())
        assert.are.same({ p1 }, second.getPhotos())
        assert.are.equal(0, catalog.getQueryCount())
    end)

    it("removes from a top-level collection by name beside a nested namesake", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local top = helper.fakeCollection("Shared", { p1 })
        local nested = helper.fakeCollection("Shared", { p1 })
        local outer = helper.fakeCollectionSet("Outer", { collections = { nested } })
        local _, Handler = setup({ photos = { p1 }, collections = { top },
            collectionSets = { outer } })

        local r = Handler.removeFromCollection({ collection_name = "Shared", photo_ids = { "1" } })

        assert.are.equal(1, r.removed)
        assert.are.same({}, top.getPhotos())
        assert.are.same({ p1 }, nested.getPhotos())
    end)

    it("reports ids that matched no photo", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local target = helper.fakeCollection("Target", { p1 })
        local _, Handler = setup({ photos = { p1 }, collections = { target } })

        local r = Handler.removeFromCollection({ collection_name = "Target", photo_ids = { "1", "ghost" } })

        assert.are.equal(1, r.removed)
        assert.are.same({ "ghost" }, r.missing)
        assert.is_not_nil(r.message:find("1 ids not found", 1, true))
    end)

    it("rejects an unknown or smart collection without scanning the catalog", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local smart = helper.fakeCollection("Five Stars", { p1 }, { smart = true })
        local catalog, Handler = setup({ photos = { p1 }, collections = { smart } })

        assert.has_error(function()
            Handler.removeFromCollection({ collection_name = "Nope", photo_ids = { "1" } })
        end, "Collection not found: Nope")
        assert.has_error(function()
            Handler.removeFromCollection({ collection_name = "Five Stars", photo_ids = { "1" } })
        end, "Cannot remove photos from a smart collection: Five Stars")

        assert.are.equal(0, catalog.getQueryCount())
        assert.are.same({}, smart.getRemovedPhotos())
    end)

    it("errors without required args", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.removeFromCollection({ photo_ids = { "1" } }) end,
            "collection_name is required")
        assert.has_error(function() Handler.removeFromCollection({ collection_name = "X" }) end,
            "photo_ids is required")
    end)
end)

describe("HandlerCollections.deleteCollection", function()
    it("deletes the named collection and reports how many photos it held", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg" })
        local target = helper.fakeCollection("Temp", { p1, p2 })
        local other = helper.fakeCollection("Keep", { p1 })
        local _, Handler = setup({ photos = { p1, p2 }, collections = { target, other } })

        local r = Handler.deleteCollection({ collection_name = "Temp" })

        assert.is_true(r.success)
        assert.are.equal(2, r.photo_count)
        assert.is_true(target.isDeleted())
        assert.is_false(other.isDeleted())
    end)

    it("refuses to guess when several nested collections share the name", function()
        local first = helper.fakeCollection("Temp", {})
        local second = helper.fakeCollection("Temp", {})
        local a = helper.fakeCollectionSet("A", { collections = { first } })
        local b = helper.fakeCollectionSet("B", { collections = { second } })
        local _, Handler = setup({ collectionSets = { a, b } })

        assert.has_error(function() Handler.deleteCollection({ collection_name = "Temp" }) end,
            "2 collections are named 'Temp'; use a collection path")
        assert.is_false(first.isDeleted())
        assert.is_false(second.isDeleted())
    end)

    it("deletes the top-level collection by name beside a nested namesake", function()
        local top = helper.fakeCollection("Temp", {})
        local nested = helper.fakeCollection("Temp", {})
        local outer = helper.fakeCollectionSet("Outer", { collections = { nested } })
        local _, Handler = setup({ collections = { top }, collectionSets = { outer } })

        Handler.deleteCollection({ collection_name = "Temp" })

        assert.is_true(top.isDeleted())
        assert.is_false(nested.isDeleted())
    end)

    it("deletes the nested collection selected by its listed path", function()
        local top = helper.fakeCollection("Temp", {})
        local nested = helper.fakeCollection("Temp", {})
        local outerSet = {
            getName = function() return "Outer" end,
            getChildCollections = function() return { nested } end,
            getChildCollectionSets = function() return {} end,
        }
        local _, Handler = setup({ collections = { top }, collectionSets = { outerSet } })

        local r = Handler.deleteCollection({ collection_name = "Outer / Temp" })

        assert.is_true(r.success)
        assert.is_false(top.isDeleted())
        assert.is_true(nested.isDeleted())
    end)

    it("errors on an unknown collection or a missing name", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.deleteCollection({ collection_name = "Nope" }) end,
            "Collection not found: Nope")
        assert.has_error(function() Handler.deleteCollection({}) end, "collection_name is required")
        assert.has_error(function() Handler.deleteCollection({ collection_name = "" }) end,
            "collection_name is required")
    end)
end)
