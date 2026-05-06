local function fakePhoto(id, path)
    return {
        localIdentifier = id,
        getRawMetadata = function(_, key)
            if key == 'path' then return path end
            return nil
        end,
    }
end

local function fakeCatalog(photos)
    local state = { getAllPhotosCalls = 0 }
    local catalog = {
        getAllPhotos = function()
            state.getAllPhotosCalls = state.getAllPhotosCalls + 1
            return photos
        end,
    }
    return catalog, state
end

local PhotoLookup
local function loadModule()
    package.loaded.PhotoLookup = nil
    PhotoLookup = require 'PhotoLookup'
end

describe("PhotoLookup.resolveMany", function()
    before_each(loadModule)

    it("resolves numeric localIdentifier ids in one catalog scan", function()
        local p1 = fakePhoto(1, "/a.jpg")
        local p2 = fakePhoto(2, "/b.jpg")
        local catalog, state = fakeCatalog({ p1, p2 })

        local r = PhotoLookup.resolveMany(catalog, { "1", "2" })

        assert.are.equal(p1, r[1].photo)
        assert.are.equal(p2, r[2].photo)
        assert.are.equal(1, state.getAllPhotosCalls)
    end)

    it("resolves by path", function()
        local p1 = fakePhoto(1, "/a.jpg")
        local p2 = fakePhoto(2, "/b.jpg")
        local catalog, state = fakeCatalog({ p1, p2 })

        local r = PhotoLookup.resolveMany(catalog, { "/a.jpg", "/b.jpg" })

        assert.are.equal(p1, r[1].photo)
        assert.are.equal(p2, r[2].photo)
        assert.are.equal(1, state.getAllPhotosCalls)
    end)

    it("resolves a mixed batch (some by id, some by path)", function()
        local p1 = fakePhoto(1, "/a.jpg")
        local p2 = fakePhoto(2, "/b.jpg")
        local p3 = fakePhoto(3, "/c.jpg")
        local catalog, state = fakeCatalog({ p1, p2, p3 })

        local r = PhotoLookup.resolveMany(catalog, { "1", "/b.jpg", "3" })

        assert.are.equal(p1, r[1].photo)
        assert.are.equal(p2, r[2].photo)
        assert.are.equal(p3, r[3].photo)
        assert.are.equal(1, state.getAllPhotosCalls)
    end)

    it("returns nil for unknown ids without erroring", function()
        local p1 = fakePhoto(1, "/a.jpg")
        local catalog, _ = fakeCatalog({ p1 })

        local r = PhotoLookup.resolveMany(catalog, { "1", "999", "/missing.jpg" })

        assert.are.equal(p1, r[1].photo)
        assert.is_nil(r[2].photo)
        assert.is_nil(r[3].photo)
    end)

    it("preserves input order in results", function()
        local p1 = fakePhoto(1, "/a.jpg")
        local p2 = fakePhoto(2, "/b.jpg")
        local catalog, _ = fakeCatalog({ p1, p2 })

        local r = PhotoLookup.resolveMany(catalog, { "/b.jpg", "1", "/a.jpg", "2" })

        assert.are.equal(p2, r[1].photo)
        assert.are.equal(p1, r[2].photo)
        assert.are.equal(p1, r[3].photo)
        assert.are.equal(p2, r[4].photo)
    end)

    it("handles empty input", function()
        local catalog, _ = fakeCatalog({})
        local r = PhotoLookup.resolveMany(catalog, {})
        assert.are.equal(0, #r)
    end)
end)

describe("PhotoLookup.resolveOne", function()
    before_each(loadModule)

    it("returns the matching photo by local id", function()
        local p1 = fakePhoto(1, "/a.jpg")
        local catalog, _ = fakeCatalog({ p1 })
        assert.are.equal(p1, PhotoLookup.resolveOne(catalog, "1"))
    end)

    it("returns the matching photo by path", function()
        local p1 = fakePhoto(1, "/a.jpg")
        local catalog, _ = fakeCatalog({ p1 })
        assert.are.equal(p1, PhotoLookup.resolveOne(catalog, "/a.jpg"))
    end)

    it("returns nil when nothing matches", function()
        local catalog, _ = fakeCatalog({})
        assert.is_nil(PhotoLookup.resolveOne(catalog, "missing"))
    end)
end)
