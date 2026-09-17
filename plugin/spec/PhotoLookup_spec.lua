local function fakePhoto(id, path, state)
    return {
        localIdentifier = id,
        getRawMetadata = function(_, key)
            if key == 'path' then
                if state then state.pathReads = state.pathReads + 1 end
                return path
            end
            return nil
        end,
    }
end

-- Counts how many photos the scan actually touches. The scan reads
-- localIdentifier on every photo it visits, so proxying that field measures how
-- far it got -- which a path-read counter cannot do for an all-numeric batch.
local function countingPhoto(id, path, state)
    local inner = fakePhoto(id, path, state)
    return setmetatable({}, {
        __index = function(_, key)
            if key == 'localIdentifier' then state.visits = state.visits + 1 end
            return inner[key]
        end,
    })
end

local function fakeCatalog(photos)
    local state = { getAllPhotosCalls = 0, pathReads = 0 }
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

    -- The scan runs per call on every handler that resolves ids, so on a large
    -- catalog its cost is the handler's cost. These two pin that down.
    it("never reads paths when every id is numeric", function()
        local state = { pathReads = 0 }
        local photos = {}
        for i = 1, 5 do photos[i] = fakePhoto(i, "/" .. i .. ".jpg", state) end
        local catalog = fakeCatalog(photos)

        PhotoLookup.resolveMany(catalog, { "1", "2" })

        assert.are.equal(0, state.pathReads)
    end)

    it("stops scanning once every requested numeric id is found", function()
        local state = { pathReads = 0, visits = 0 }
        local photos = {}
        for i = 1, 100 do photos[i] = countingPhoto(i, "/" .. i .. ".jpg", state) end
        local catalog = fakeCatalog(photos)

        local r = PhotoLookup.resolveMany(catalog, { "2" })

        assert.are.equal(photos[2], r[1].photo)
        assert.are.equal(2, state.visits)
    end)

    -- Paths are not unique: a virtual copy reports its master's source path.
    -- Resolving one to the FIRST match instead of the last would silently hand
    -- a path-addressed write tool a different photo than the catalog's own
    -- ordering names.
    it("resolves a duplicate path to the last matching photo", function()
        local master = fakePhoto(1, "/shared.nef")
        local virtualCopy = fakePhoto(2, "/shared.nef")
        local catalog, _ = fakeCatalog({ master, virtualCopy })

        local r = PhotoLookup.resolveMany(catalog, { "/shared.nef" })

        assert.are.equal(virtualCopy, r[1].photo)
    end)

    it("scans the whole catalog when a path is requested, even after a match", function()
        local state = { pathReads = 0, visits = 0 }
        local photos = {}
        for i = 1, 100 do photos[i] = countingPhoto(i, "/" .. i .. ".jpg", state) end
        local catalog = fakeCatalog(photos)

        -- The match is the 2nd photo, but a later one could still claim the
        -- same path, so stopping there would be a guess.
        local r = PhotoLookup.resolveMany(catalog, { "/2.jpg" })

        assert.are.equal(photos[2], r[1].photo)
        assert.are.equal(100, state.pathReads)
        assert.are.equal(100, state.visits)
    end)

    it("still scans the whole catalog for an id that matches nothing", function()
        local state = { pathReads = 0 }
        local photos = {}
        for i = 1, 10 do photos[i] = fakePhoto(i, "/" .. i .. ".jpg", state) end
        local catalog = fakeCatalog(photos)

        local r = PhotoLookup.resolveMany(catalog, { "/missing.jpg" })

        assert.is_nil(r[1].photo)
        assert.are.equal(10, state.pathReads)
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
