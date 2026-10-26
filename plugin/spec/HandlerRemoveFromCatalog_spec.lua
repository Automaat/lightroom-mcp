local helper = require 'spec_helper'

local function setup(opts)
    opts = opts or {}
    local photos = {}
    for i = 1, 4 do photos[i] = helper.fakePhoto({ id = tostring(i), path = "/" .. i .. ".jpg" }) end
    local catalog = helper.fakeCatalog({ photos = photos })
    local selected = opts.selected or { photos[4], photos[1] }
    local active = selected[1]
    local module = "develop"
    local sources = { "original source" }
    local alive = {}
    for _, p in ipairs(photos) do alive[p] = true end
    local calls = { selections = {}, removes = 0, sources = {}, grids = 0 }
    catalog.getTargetPhoto = function() return active end
    catalog.getTargetPhotos = function() return selected end
    catalog.getActiveSources = function() return sources end
    catalog.setActiveSources = function(_, value)
        sources = value
        calls.sources[#calls.sources + 1] = value
    end
    catalog.kAllPhotos = "all"
    catalog.setSelectedPhotos = function(_, p, value)
        calls.selections[#calls.selections + 1] = value
        if opts.ignoreSelection then return end
        active, selected = p, value
        if opts.extraSelection then selected = { p, photos[4] } end
    end
    local batch = catalog.batchGetRawMetadata
    catalog.batchGetRawMetadata = function(self, list, keys)
        local raw = batch(self, list, keys)
        for _, p in ipairs(list) do
            if not alive[p] then raw[p].uuid = nil end
            if opts.virtualCopies and p == photos[1] then raw[p].virtualCopies = { photos[2] } end
        end
        return raw
    end
    local selection = {
        selectNone = function() active, selected = nil, {} end,
        removeFromCatalog = function()
            assert.are.equal("library", module)
            assert.are.equal(1, calls.grids)
            calls.removes = calls.removes + 1
            calls.removed = selected
            if opts.onRemove then opts.onRemove() end
            if opts.failRemoval then error("removal failed") end
            if opts.ignoreRemoval then return end
            for _, p in ipairs(selected) do alive[p] = nil end
            active, selected = nil, {}
        end,
    }
    if opts.withoutApi then selection.removeFromCatalog = nil end
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrApplicationView = {
            getCurrentModuleName = function() return module end,
            switchToModule = function(value) module = value end,
            gridView = function() calls.grids = calls.grids + 1 end,
        },
        LrSelection = selection,
        LrDevelopController = {},
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.DevelopSession = nil
    package.loaded.HandlerRemoveFromCatalog = nil
    local handler = require 'HandlerRemoveFromCatalog'
    calls.state = function() return selected, active, module, sources end
    return handler, calls, photos, alive, catalog
end

local function failure(fn, text)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    assert.truthy(tostring(err):find(text, 1, true), tostring(err))
end

describe("HandlerRemoveFromCatalog.removePhotos", function()
    it("requires literal confirm true before touching selection or removal", function()
        local handler, calls = setup()
        for _, args in ipairs({ {}, { confirm = false }, { confirm = "true" }, { confirm = 1 } }) do
            args.photo_ids = { "1" }
            failure(function() handler.removePhotos(args) end, "confirm must be true")
        end
        assert.are.equal(0, calls.removes)
        assert.are.same({}, calls.selections)
        assert.are.same({}, calls.sources)
    end)

    it("requires Lightroom Classic 14.3 before touching the view", function()
        local handler, calls = setup({ withoutApi = true })
        failure(function() handler.removePhotos({ photo_ids = { "1" }, confirm = true }) end,
            "Lightroom Classic 14.3")
        assert.are.same({}, calls.selections)
        assert.are.same({}, calls.sources)
    end)

    it("selects only resolved unique photos and restores surviving selection and module", function()
        local handler, calls, photos, alive, catalog = setup()
        local result = handler.removePhotos({ photo_ids = { "1", "/1.jpg", 2, "999", "999" }, confirm = true })
        assert.are.same({ success = true, removed = 2, missing = { "999" } }, result)
        assert.are.same({ photos[1], photos[2] }, calls.removed)
        assert.are.same({ photos[1], photos[2] }, calls.selections[1])
        local selected, active, module, sources = calls.state()
        assert.are.same({ photos[4] }, selected)
        assert.are.equal(photos[4], active)
        assert.are.equal("develop", module)
        assert.are.same({ "original source" }, sources)
        assert.is_nil(alive[photos[1]])
        assert.is_true(alive[photos[3]])
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)

    it("makes a surviving photo active when the original active photo was removed", function()
        local handler, calls, photos = setup()
        handler.removePhotos({ photo_ids = { "4" }, confirm = true })
        local selected, active = calls.state()
        assert.are.same({ photos[1] }, selected)
        assert.are.equal(photos[1], active)
    end)

    it("restores an empty selection", function()
        local handler, calls = setup({ selected = {} })
        handler.removePhotos({ photo_ids = { "1" }, confirm = true })
        local selected, active = calls.state()
        assert.are.same({}, selected)
        assert.is_nil(active)
    end)

    it("errors without touching selection when no IDs resolve", function()
        local handler, calls = setup()
        failure(function() handler.removePhotos({ photo_ids = { "999" }, confirm = true }) end,
            "No photos matched")
        assert.are.same({}, calls.selections)
        assert.are.equal(0, calls.removes)
    end)

    it("rejects over 100 IDs and malformed arrays before changing the view", function()
        local handler, calls = setup()
        local ids = {}
        for i = 1, 101 do ids[i] = "1" end
        for _, bad in ipairs({ ids, {}, { true }, { "" }, { " " }, { [1] = "1", extra = "2" } }) do
            failure(function() handler.removePhotos({ photo_ids = bad, confirm = true }) end, "photo_ids")
        end
        assert.are.same({}, calls.selections)
        assert.are.equal(0, calls.removes)
    end)

    it("refuses both a rejected selection and one containing extra photos", function()
        for _, opts in ipairs({ { ignoreSelection = true }, { extraSelection = true } }) do
            local handler, calls = setup(opts)
            failure(function() handler.removePhotos({ photo_ids = { "1", "2" }, confirm = true }) end,
                "did not select exactly")
            assert.are.equal(0, calls.removes)
            local _, _, module, sources = calls.state()
            assert.are.equal("develop", module)
            assert.are.same({ "original source" }, sources)
        end
    end)

    it("restores the view after an SDK error and never reports ignored removal as success", function()
        for _, opts in ipairs({ { failRemoval = true }, { ignoreRemoval = true } }) do
            local handler, calls, photos = setup(opts)
            failure(function() handler.removePhotos({ photo_ids = { "2" }, confirm = true }) end,
                opts.failRemoval and "removal failed" or "did not remove every")
            local selected, active, module = calls.state()
            assert.are.same({ photos[4], photos[1] }, selected)
            assert.are.equal(photos[4], active)
            assert.are.equal("develop", module)
        end
    end)

    it("refuses a master whose virtual copies were not explicitly requested", function()
        local handler, calls = setup({ virtualCopies = true })
        failure(function() handler.removePhotos({ photo_ids = { "1" }, confirm = true }) end,
            "Include every virtual copy")
        assert.are.same({}, calls.selections)
        assert.are.equal(0, calls.removes)
    end)
end)
