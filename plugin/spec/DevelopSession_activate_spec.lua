local helper = require 'spec_helper'

-- Photos live in /a and /b. A photo is selectable when the active source is
-- All Photographs or its own folder; opts.unknownFolder hides the folders.
local function setup(opts)
    opts = opts or {}
    local first = helper.fakePhoto({ id = "1", path = "/a/1.jpg" })
    local second = helper.fakePhoto({ id = "2", path = "/b/2.jpg" })
    local inSource = helper.fakePhoto({ id = "3", path = "/c/3.jpg" })
    local catalog = helper.fakeCatalog({ photos = { first, second, inSource } })
    local original = { "original source" }
    local sources = original
    local active, selected = inSource, { inSource }
    local calls = { sources = {}, folderLookups = {}, selections = 0 }
    catalog.kAllPhotos = "all photographs"
    catalog.getTargetPhoto = function() return active end
    catalog.getTargetPhotos = function() return selected end
    catalog.getActiveSources = function() return sources end
    catalog.setActiveSources = function(_, value)
        if opts.folderSwitchFails and value[1] ~= catalog.kAllPhotos and value ~= original then
            error("cannot show folder")
        end
        sources = value
        calls.sources[#calls.sources + 1] = value[1]
    end
    catalog.getFolderByPath = function(_, path)
        calls.folderLookups[#calls.folderLookups + 1] = path
        if opts.unknownFolder then return nil end
        return path
    end
    local function visible(photo)
        if photo == inSource and sources == original then return true end
        if sources[1] == catalog.kAllPhotos then return not opts.hiddenEverywhere end
        if opts.hiddenInFolder then return false end
        local folder = photo:getRawMetadata('path'):gsub("/[^/]*$", "")
        for _, source in ipairs(sources) do
            if source == folder then return true end
        end
        return false
    end
    catalog.setSelectedPhotos = function(_, photo, selection)
        calls.selections = calls.selections + 1
        if visible(photo) then active, selected = photo, selection end
    end
    local clock = { now = 0 }
    helper.installImport({
        LrApplicationView = { getCurrentModuleName = function() return "library" end, switchToModule = function() end },
        LrDevelopController = {},
        LrPathUtils = { parent = function(path) return (path:gsub("/[^/]*$", "")) end },
        LrFileUtils = { exists = function() return not opts.offline and "directory" end },
        LrSelection = { selectNone = function() active, selected = nil, {} end },
        LrTasks = { pcall = pcall, sleep = function(seconds) clock.now = clock.now + seconds end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.DevelopSession = nil
    package.loaded.PhotoSources = nil
    local DevelopSession = require 'DevelopSession'
    return DevelopSession, catalog, calls, clock, { first = first, second = second, inSource = inSource,
        original = original, sources = function() return sources end, active = function() return active end }
end

describe("DevelopSession.activate", function()
    it("selects a photo of the active source without switching sources", function()
        local DevelopSession, catalog, calls, _, p = setup()
        local state = {}

        assert.is_true(DevelopSession.activate(catalog, p.inSource, state))
        assert.are.same({}, calls.sources)
        assert.is_nil(state.switchedSource)
    end)

    it("switches to the photo's own folder after a short try, not to All Photographs", function()
        local DevelopSession, catalog, calls, clock, p = setup()
        local state = {}

        assert.is_true(DevelopSession.activate(catalog, p.first, state))
        assert.are.same({ "/a" }, calls.sources)
        assert.are.same({ "/a" }, calls.folderLookups)
        assert.is_true(state.switchedSource)
        assert.is_nil(state.allPhotos)
        assert.is_true(clock.now < 5)
    end)

    it("loads All Photographs once for a batch that mixes folders", function()
        local DevelopSession, catalog, calls, _, p = setup()
        local state = {}

        assert.is_true(DevelopSession.activate(catalog, p.first, state))
        assert.is_true(DevelopSession.activate(catalog, p.second, state))
        assert.is_true(DevelopSession.activate(catalog, p.first, state))
        assert.are.same({ "/a", "all photographs" }, calls.sources)
        assert.are.same({ "/a" }, calls.folderLookups)
        assert.are.equal(p.first, p.active())
    end)

    it("falls back to All Photographs when the folder cannot be shown", function()
        local DevelopSession, catalog, calls, _, p = setup({ folderSwitchFails = true })

        DevelopSession.run("tool", catalog, true, function(state)
            assert.is_true(DevelopSession.activate(catalog, p.first, state))
            assert.is_true(state.switchedSource and state.allPhotos)
        end)

        assert.are.same({ "all photographs", "original source" }, calls.sources)
        assert.are.equal(p.original, p.sources())
    end)

    it("falls back to All Photographs when the folder is not found", function()
        local DevelopSession, catalog, calls, _, p = setup({ unknownFolder = true })
        local state = {}

        assert.is_true(DevelopSession.activate(catalog, p.first, state))
        assert.are.same({ "all photographs" }, calls.sources)
        assert.is_true(state.switchedSource and state.allPhotos)
    end)

    it("goes straight to All Photographs when the folder is on an unmounted drive", function()
        local DevelopSession, catalog, calls, _, p = setup({ offline = true })
        local state = {}

        assert.is_true(DevelopSession.activate(catalog, p.first, state))
        assert.are.same({ "all photographs" }, calls.sources)
        assert.are.same({}, calls.folderLookups)
    end)

    it("falls back to All Photographs when the photo stays hidden in its folder", function()
        local DevelopSession, catalog, calls, _, p = setup({ hiddenInFolder = true })
        local state = {}

        assert.is_true(DevelopSession.activate(catalog, p.first, state))
        assert.are.same({ "/a", "all photographs" }, calls.sources)
    end)

    it("gives up without switching again once All Photographs did not show the photo", function()
        local DevelopSession, catalog, calls, _, p = setup({ hiddenInFolder = true, hiddenEverywhere = true })
        local state = {}

        assert.is_false(DevelopSession.activate(catalog, p.first, state))
        assert.is_false(DevelopSession.activate(catalog, p.second, state))
        assert.are.same({ "/a", "all photographs" }, calls.sources)
    end)

    it("restores the original sources after reaching a photo through its folder", function()
        local DevelopSession, catalog, _, _, p = setup()

        DevelopSession.run("tool", catalog, true, function(state)
            assert.is_true(DevelopSession.activate(catalog, p.first, state))
        end)

        assert.are.equal(p.original, p.sources())
        assert.are.equal(p.inSource, p.active())
    end)

    it("restores the original sources after going through the folder to All Photographs", function()
        local DevelopSession, catalog, _, _, p = setup({ hiddenInFolder = true })

        DevelopSession.run("tool", catalog, true, function(state)
            assert.is_true(DevelopSession.activate(catalog, p.first, state))
        end)

        assert.are.equal(p.original, p.sources())
        assert.are.equal(p.inSource, p.active())
    end)
end)
