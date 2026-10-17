local function fakePhoto(id, path, state)
    local meta = { path = path, uuid = path and ("uuid-" .. tostring(id)) or nil }
    return {
        localIdentifier = id,
        __path = path,
        __meta = meta,
        getRawMetadata = function(_, key)
            if key == 'path' and state then state.pathReads = state.pathReads + 1 end
            return meta[key]
        end,
    }
end

-- Makes `copies` virtual copies of `master`, as Lightroom reports them: each
-- copy reports the master's path.
local function linkCopies(master, copies)
    master.__meta.virtualCopies = copies
    for _, copy in ipairs(copies) do copy.__meta.masterPhoto = master end
end

-- Counts how many photos the scan actually touches. The scan reads
-- localIdentifier on every photo it visits, so proxying that field measures how
-- far it got -- which a path-read counter cannot do for an all-numeric batch.
local function countingPhoto(id, path, state)
    local inner = fakePhoto(id, path, state)
    return setmetatable({}, {
        __index = function(_, key)
            if key == 'localIdentifier' then
                state.visits = state.visits + 1
                state.furthest = math.max(state.furthest or 0, id)
            end
            return inner[key]
        end,
    })
end

local function fakeCatalog(photos)
    local state = { getAllPhotosCalls = 0, pathReads = 0, findPhotoByPathCalls = 0 }
    local catalog = {
        getAllPhotos = function()
            state.getAllPhotosCalls = state.getAllPhotosCalls + 1
            return photos
        end,
        -- One photo per path: for a master and its virtual copies, whichever
        -- comes first here.
        findPhotoByPath = function(_, path)
            state.findPhotoByPathCalls = state.findPhotoByPathCalls + 1
            for _, p in ipairs(photos) do
                if p.__path == path then return p end
            end
            return nil
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

    it("resolves by path without scanning the catalog", function()
        local p1 = fakePhoto(1, "/a.jpg")
        local p2 = fakePhoto(2, "/b.jpg")
        local catalog, state = fakeCatalog({ p1, p2 })

        local r = PhotoLookup.resolveMany(catalog, { "/a.jpg", "/b.jpg" })

        assert.are.equal(p1, r[1].photo)
        assert.are.equal(p2, r[2].photo)
        assert.are.equal(0, state.getAllPhotosCalls)
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

    it("looks each distinct path up once", function()
        local p1 = fakePhoto(1, "/a.jpg")
        local catalog, state = fakeCatalog({ p1 })

        local r = PhotoLookup.resolveMany(catalog, { "/a.jpg", "/a.jpg" })

        assert.are.equal(p1, r[1].photo)
        assert.are.equal(p1, r[2].photo)
        assert.are.equal(1, state.findPhotoByPathCalls)
    end)

    it("does not resolve a path that differs only in case", function()
        local p1 = fakePhoto(1, "/a.jpg")
        local catalog, _ = fakeCatalog({ p1 })
        -- Lightroom may match a path ignoring case; the full scan this
        -- replaced compared exactly.
        catalog.findPhotoByPath = function() return p1 end

        assert.is_nil(PhotoLookup.resolveOne(catalog, "/A.JPG"))
    end)

    -- The lookup runs per call on every handler that resolves ids, so on a
    -- large catalog its cost is the handler's cost. These pin that down.
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

    it("reads only the requested photo's path when resolving a path", function()
        local state = { pathReads = 0, visits = 0 }
        local photos = {}
        for i = 1, 100 do photos[i] = countingPhoto(i, "/" .. i .. ".jpg", state) end
        local catalog = fakeCatalog(photos)

        local r = PhotoLookup.resolveMany(catalog, { "/2.jpg" })

        assert.are.equal(photos[2], r[1].photo)
        assert.are.equal(1, state.pathReads)
        assert.are.equal(0, state.visits)
    end)

    it("does not scan the catalog for a path that matches nothing", function()
        local state = { pathReads = 0 }
        local photos = {}
        for i = 1, 10 do photos[i] = fakePhoto(i, "/" .. i .. ".jpg", state) end
        local catalog, catalogState = fakeCatalog(photos)

        local r = PhotoLookup.resolveMany(catalog, { "/missing.jpg" })

        assert.is_nil(r[1].photo)
        assert.are.equal(0, state.pathReads)
        assert.are.equal(0, catalogState.getAllPhotosCalls)
    end)

    -- Paths are not unique: a virtual copy reports its master's source path.
    -- Resolving one to the FIRST match instead of the last would silently hand
    -- a path-addressed write tool a different photo than the catalog's own
    -- ordering names.
    it("resolves a duplicate path to the last matching photo", function()
        local master = fakePhoto(1, "/shared.nef")
        local virtualCopy = fakePhoto(2, "/shared.nef")
        linkCopies(master, { virtualCopy })
        local catalog, _ = fakeCatalog({ master, virtualCopy })

        local r = PhotoLookup.resolveMany(catalog, { "/shared.nef" })

        assert.are.equal(virtualCopy, r[1].photo)
    end)

    it("takes the last in catalog order, whichever photo the path lookup returns", function()
        local master = fakePhoto(1, "/shared.nef")
        local copyA = fakePhoto(2, "/shared.nef")
        local copyB = fakePhoto(3, "/shared.nef")
        linkCopies(master, { copyA, copyB })
        -- findPhotoByPath returns copyB, the first here; copyA comes last.
        local catalog = fakeCatalog({ copyB, master, copyA })

        assert.are.equal(copyA, PhotoLookup.resolveOne(catalog, "/shared.nef"))
    end)

    it("stops the scan once it has seen a master and all its virtual copies", function()
        local state = { pathReads = 0, visits = 0 }
        local photos = {}
        for i = 1, 100 do
            local path = (i == 2 or i == 3) and "/shared.nef" or ("/" .. i .. ".jpg")
            photos[i] = countingPhoto(i, path, state)
        end
        linkCopies(photos[2], { photos[3] })
        local catalog = fakeCatalog(photos)

        local r = PhotoLookup.resolveMany(catalog, { "/shared.nef" })

        assert.are.equal(photos[3], r[1].photo)
        assert.are.equal(3, state.furthest)
    end)
end)

local function withDirectLookup(catalog, state, photos)
    state.directCalls = 0
    state.batchCalls = 0
    catalog.getPhotoByLocalId = function(_, id)
        state.directCalls = state.directCalls + 1
        assert.are.equal("number", type(id))
        for _, p in ipairs(photos) do
            if p.localIdentifier == id then return p end
        end
        return fakePhoto(id, nil)
    end
    catalog.batchGetRawMetadata = function(_, list, keys)
        state.batchCalls = state.batchCalls + 1
        local out = {}
        for _, p in ipairs(list) do
            local values = {}
            for _, key in ipairs(keys) do values[key] = p:getRawMetadata(key) end
            out[p] = values
        end
        return out
    end
    return catalog, state
end

describe("PhotoLookup.resolveMany with getPhotoByLocalId", function()
    before_each(loadModule)

    local function setup(n)
        local photos = {}
        for i = 1, n do photos[i] = fakePhoto(i, "/" .. i .. ".jpg") end
        local catalog, state = fakeCatalog(photos)
        withDirectLookup(catalog, state, photos)
        return photos, catalog, state
    end

    it("resolves numeric ids without scanning the catalog", function()
        local photos, catalog, state = setup(5)

        local r = PhotoLookup.resolveMany(catalog, { "2", 5, "999" })

        assert.are.equal(photos[2], r[1].photo)
        assert.are.equal(photos[5], r[2].photo)
        assert.is_nil(r[3].photo)
        assert.are.equal(0, state.getAllPhotosCalls)
        assert.are.equal(3, state.directCalls)
        assert.are.equal(1, state.batchCalls)
    end)

    it("looks each distinct id up once", function()
        local photos, catalog, state = setup(3)

        local r = PhotoLookup.resolveMany(catalog, { "1", "1", "1" })

        assert.are.equal(photos[1], r[3].photo)
        assert.are.equal(1, state.directCalls)
    end)

    for _, id in ipairs({ "1.0", "0x1", " 1", "01", "001" }) do
        it("does not resolve the non-canonical id '" .. id .. "'", function()
            local _, catalog, state = setup(3)

            assert.is_nil(PhotoLookup.resolveOne(catalog, id))
            assert.are.equal(0, state.directCalls)
        end)
    end

    for _, ids in ipairs({ { "1", "01" }, { "01", "1" }, { 1, "001" } }) do
        local label = tostring(ids[1]) .. "' and '" .. tostring(ids[2])
        it("resolves only the canonical id of '" .. label .. "'", function()
            local photos, catalog = setup(3)

            local r = PhotoLookup.resolveMany(catalog, ids)

            for i, id in ipairs(ids) do
                local canonical = type(id) == "number" or id == "1"
                assert.are.equal(canonical and photos[1] or nil, r[i].photo)
            end
        end)
    end

    it("keeps last-in-catalog-order for a shared path when its photos are also named by id", function()
        local master = fakePhoto(1, "/shared.nef")
        local copyA = fakePhoto(2, "/shared.nef")
        local copyB = fakePhoto(3, "/shared.nef")
        linkCopies(master, { copyA, copyB })
        local photos = { copyB, master, copyA }
        local catalog, state = fakeCatalog(photos)
        withDirectLookup(catalog, state, photos)

        local r = PhotoLookup.resolveMany(catalog, { "2", "/shared.nef", "3" })

        assert.are.equal(copyA, r[1].photo)
        assert.are.equal(copyA, r[2].photo)
        assert.are.equal(copyB, r[3].photo)
        assert.are.equal(1, state.getAllPhotosCalls)
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
