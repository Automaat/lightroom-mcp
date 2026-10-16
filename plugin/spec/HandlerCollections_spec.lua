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
        local top = helper.fakeCollection("Shared", { p1 })
        local nested = helper.fakeCollection("Shared", { p1 })
        local outerSet = {
            getName = function() return "Outer" end,
            getChildCollections = function() return { nested } end,
            getChildCollectionSets = function() return {} end,
        }
        local catalog, Handler = setup({ photos = { p1 }, collections = { top },
            collectionSets = { outerSet } })

        assert.has_error(function()
            Handler.removeFromCollection({ collection_name = "Shared", photo_ids = { "1" } })
        end, "2 collections are named 'Shared'; use a collection path")

        assert.are.same({ p1 }, top.getPhotos())
        assert.are.same({ p1 }, nested.getPhotos())
        assert.are.equal(0, catalog.getQueryCount())
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

    it("refuses to guess when several collections share the name", function()
        local top = helper.fakeCollection("Temp", {})
        local nested = helper.fakeCollection("Temp", {})
        local outerSet = {
            getName = function() return "Outer" end,
            getChildCollections = function() return { nested } end,
            getChildCollectionSets = function() return {} end,
        }
        local _, Handler = setup({ collections = { top }, collectionSets = { outerSet } })

        assert.has_error(function() Handler.deleteCollection({ collection_name = "Temp" }) end,
            "2 collections are named 'Temp'; use a collection path")
        assert.is_false(top.isDeleted())
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

describe("HandlerCollections.getCollectionPhotos", function()
    local function photos(n)
        local out = {}
        for i = 1, n do
            out[i] = helper.fakePhoto({
                id = tostring(i), path = "/p" .. i .. ".jpg", fileName = "p" .. i .. ".jpg",
                rating = i % 5, dateTimeOriginal = "2026-01-0" .. (i % 9 + 1),
            })
        end
        return out
    end

    local function set(name, collections, childSets)
        return {
            getName = function() return name end,
            getChildCollections = function() return collections or {} end,
            getChildCollectionSets = function() return childSets or {} end,
        }
    end

    it("returns a regular collection's photos in the search_photos shape", function()
        local ps = photos(2)
        local _, Handler = setup({ photos = ps, collections = { helper.fakeCollection("Trip", ps) } })

        local r = Handler.getCollectionPhotos({ collection_name = "Trip" })

        assert.are.equal(2, r.count)
        assert.is_false(r.has_more)
        assert.are.same({
            id = "1", path = "/p1.jpg", filename = "p1.jpg", rating = 1, dateTimeOriginal = "2026-01-02",
        }, r.photos[1])
        assert.are.equal("2", r.photos[2].id)
    end)

    it("finds a collection nested two sets deep, by bare name or listed path", function()
        local ps = photos(1)
        local deep = helper.fakeCollection("Deep", ps)
        local _, Handler = setup({ photos = ps,
            collectionSets = { set("Outer", {}, { set("Inner", { deep }) }) } })

        assert.are.equal(1, Handler.getCollectionPhotos({ collection_name = "Deep" }).count)
        local listed = Handler.listCollections({}).collections[1].name
        assert.are.equal("Outer / Inner / Deep", listed)
        assert.are.equal("1", Handler.getCollectionPhotos({ collection_name = listed }).photos[1].id)
    end)

    it("returns a smart collection's photos, querying outside the read gate", function()
        local ps = photos(3)
        local smart = helper.fakeCollection("Five stars", ps, { smart = true })
        local catalog, Handler = setup({ photos = ps, collections = { smart } })
        local insideGate = nil
        smart.getPhotos = function()
            insideGate = catalog:isInsideReadAccess()
            return ps
        end

        local r = Handler.getCollectionPhotos({ collection_name = "Five stars" })

        assert.are.equal(3, r.count)
        assert.is_false(insideGate)
    end)

    it("pages with limit and offset, flooring fractions", function()
        local ps = photos(5)
        local _, Handler = setup({ photos = ps, collections = { helper.fakeCollection("Trip", ps) } })

        local r = Handler.getCollectionPhotos({ collection_name = "Trip", limit = 2, offset = 1.7 })
        assert.are.equal(5, r.count)
        assert.are.same({ "2", "3" }, { r.photos[1].id, r.photos[2].id })
        assert.is_true(r.has_more)

        local last = Handler.getCollectionPhotos({ collection_name = "Trip", limit = 2, offset = 4 })
        assert.are.equal(1, #last.photos)
        assert.is_false(last.has_more)

        local defaults = Handler.getCollectionPhotos({ collection_name = "Trip" })
        assert.are.equal(5, #defaults.photos)
    end)

    it("rejects an ambiguous bare name but accepts its path", function()
        local ps = photos(2)
        local top = helper.fakeCollection("Shared", { ps[1] })
        local nested = helper.fakeCollection("Shared", { ps[2] })
        local _, Handler = setup({ photos = ps, collections = { top },
            collectionSets = { set("Outer", { nested }) } })

        assert.has_error(function() Handler.getCollectionPhotos({ collection_name = "Shared" }) end,
            "2 collections are named 'Shared'; use a collection path")
        assert.are.equal("2", Handler.getCollectionPhotos({ collection_name = "Outer / Shared" }).photos[1].id)
    end)

    it("errors on an unknown collection or a missing name", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.getCollectionPhotos({ collection_name = "Nope" }) end,
            "Collection not found: Nope")
        assert.has_error(function() Handler.getCollectionPhotos({}) end, "collection_name is required")
        assert.has_error(function() Handler.getCollectionPhotos({ collection_name = "" }) end,
            "collection_name is required")
    end)
end)
