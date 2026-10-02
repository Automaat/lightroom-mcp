local helper = require 'spec_helper'

local function setup(opts)
    opts = opts or {}
    local exportSessionCalls = {}
    local catalog = helper.fakeCatalog({ photos = opts.photos or {} })
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
        LrFileUtils = {},
        LrPathUtils = {},
        LrExportSession = function(args)
            table.insert(exportSessionCalls, args)
            return {
                doExportOnCurrentTask = function() end,
            }
        end,
    })
    package.loaded.HandlerExport = nil
    return catalog, require 'HandlerExport', exportSessionCalls
end

describe("HandlerExport.exportPhotos", function()
    it("exports found photos with default JPEG settings", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls = setup({ photos = { p } })

        local r = Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out" })

        assert.is_true(r.success)
        assert.are.equal(1, r.exported)
        assert.are.equal("/out", r.destination)
        assert.are.equal("JPEG", calls[1].exportSettings.LR_format)
    end)

    it("never lets Lightroom prompt about existing files", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls = setup({ photos = { p } })

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out" })
        assert.are.equal("rename", calls[1].exportSettings.LR_collisionHandling)

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", on_existing = "overwrite" })
        assert.are.equal("overwrite", calls[2].exportSettings.LR_collisionHandling)

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", on_existing = "skip" })
        assert.are.equal("skip", calls[3].exportSettings.LR_collisionHandling)
    end)

    it("rejects an unknown on_existing mode, including Lightroom's own ask", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p } })

        assert.has_error(function()
            Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", on_existing = "ask" })
        end, "on_existing must be one of: rename, overwrite, skip")
    end)

    it("rejects an unsupported format instead of silently exporting another", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p } })

        assert.has_error(function()
            Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", format = "bmp" })
        end, "format must be one of: jpeg, png, tiff, original")
        assert.has_error(function()
            Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", format = 7 })
        end, "format must be one of: jpeg, png, tiff, original")
    end)

    it("applies width/height constraint", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls = setup({ photos = { p } })

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", width = 2000 })

        local s = calls[1].exportSettings
        assert.is_true(s.LR_size_doConstrain)
        assert.are.equal(2000, s.LR_size_maxWidth)
    end)

    it("maps format strings", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls = setup({ photos = { p } })

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", format = "tiff" })
        assert.are.equal("TIFF", calls[1].exportSettings.LR_format)
    end)

    it("requires photo_ids and destination", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.exportPhotos({ destination = "/x" }) end)
        assert.has_error(function() Handler.exportPhotos({ photo_ids = { "1" } }) end)
    end)

    it("errors when no photos match", function()
        local _, Handler = setup({ photos = {} })
        assert.has_error(function()
            Handler.exportPhotos({ photo_ids = { "missing" }, destination = "/out" })
        end)
    end)

    it("runs the export after releasing catalog read access", function()
        -- Holding read access for the whole export wedged the bridge on
        -- macOS (issue #128). The lock must be released before
        -- doExportOnCurrentTask runs.
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local insideReadAccess = false
        local exportRanInsideReadAccess = nil
        local catalog = helper.fakeCatalog({ photos = { p } })
        local realWithRead = catalog.withReadAccessDo
        catalog.withReadAccessDo = function(self, fn)
            insideReadAccess = true
            realWithRead(self, fn)
            insideReadAccess = false
        end
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrLogger = helper.defaultLrLogger(),
            LrFileUtils = {},
            LrPathUtils = {},
            LrExportSession = function()
                return {
                    doExportOnCurrentTask = function()
                        exportRanInsideReadAccess = insideReadAccess
                    end,
                }
            end,
        })
        package.loaded.HandlerExport = nil
        local Handler = require 'HandlerExport'

        local r = Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out" })

        assert.is_true(r.success)
        assert.are.equal(1, r.exported)
        assert.is_false(exportRanInsideReadAccess)
    end)
end)

describe("HandlerExport.exportPhotoMetadata", function()
    local JSON = require 'JSON'
    local createdDirs

    local function setupMetadata(opts)
        opts = opts or {}
        createdDirs = {}
        local catalog = helper.fakeCatalog({ photos = opts.photos or {}, targetPhotos = opts.targetPhotos })
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrLogger = helper.defaultLrLogger(),
            LrFileUtils = {
                exists = function(path) return opts.existingDir == path end,
                createAllDirectories = function(path) table.insert(createdDirs, path) end,
            },
            LrPathUtils = {
                parent = function(path) return (path:match("^(.*)[/\\][^/\\]*$")) end,
            },
            LrExportSession = function() return { doExportOnCurrentTask = function() end } end,
        })
        package.loaded.HandlerExport = nil
        return catalog, require 'HandlerExport'
    end

    local function tempJson()
        return os.tmpname() .. ".json"
    end

    local function readJson(path)
        local file = assert(io.open(path, "r"))
        local text = file:read("*a")
        file:close()
        os.remove(path)
        return JSON:decode(text)
    end

    local function photoOne()
        local places = helper.fakeKeyword("Places")
        local paris = helper.fakeKeyword("Paris", { parent = places })
        return helper.fakePhoto({
            id = 11,
            uuid = "UUID-11",
            path = "/p/a.dng",
            fileName = "a.dng",
            fileFormat = "DNG",
            isVirtualCopy = false,
            dateTimeOriginalISO8601 = "2016-03-13T15:03:39",
            dimensions = { width = 3648, height = 5472 },
            croppedDimensions = { width = 3000, height = 4500 },
            rating = 4,
            title = "A title",
            caption = "",
            gps = { latitude = 51.5, longitude = -0.12 },
            gpsAltitude = 14,
            city = "London",
            keywords = { paris, helper.fakeKeyword("summer") },
        })
    end

    it("writes the given photos' metadata, with keyword paths, to the file", function()
        local p1 = photoOne()
        local p2 = helper.fakePhoto({ id = 12, path = "/p/b.jpg", fileName = "b.jpg", keywords = {} })
        local _, Handler = setupMetadata({ photos = { p1, p2 } })
        local out = tempJson()

        local r = Handler.exportPhotoMetadata({ photo_ids = { 11, 12 }, destination = out })

        assert.is_true(r.success)
        assert.are.equal(2, r.exported)
        assert.are.same({}, r.missing)

        local data = readJson(out)
        assert.are.equal(1, data.version)
        assert.are.equal(2, data.count)
        local a = data.photos[1]
        assert.are.equal(11, a.id)
        assert.are.equal("UUID-11", a.uuid)
        assert.are.equal("/p/a.dng", a.path)
        assert.are.equal("a.dng", a.filename)
        assert.are.equal("2016-03-13T15:03:39", a.captureTime)
        assert.are.same({ width = 3648, height = 5472 }, a.dimensions)
        assert.are.same({ width = 3000, height = 4500 }, a.croppedDimensions)
        assert.are.equal(4, a.rating)
        assert.are.equal("A title", a.title)
        assert.are.same({ latitude = 51.5, longitude = -0.12, altitude = 14 }, a.gps)
        assert.are.equal("London", a.location.city)
        assert.are.same({ "Paris", "summer" }, a.keywords)
        assert.are.same({ "Places|Paris", "summer" }, a.keywordPaths)
        assert.is_nil(a.developSettings)

        local b = data.photos[2]
        assert.are.equal(12, b.id)
        assert.is_nil(b.gps)
        assert.is_nil(b.location)
        assert.are.same({}, b.keywordPaths)
    end)

    it("exports the current selection when photo_ids is omitted", function()
        local p1 = photoOne()
        local p2 = helper.fakePhoto({ id = 12, path = "/p/b.jpg", fileName = "b.jpg", keywords = {} })
        local catalog, Handler = setupMetadata({ photos = { p1, p2 }, targetPhotos = { p2 } })
        local out = tempJson()

        local r = Handler.exportPhotoMetadata({ destination = out })

        assert.are.equal(1, r.exported)
        assert.are.equal(12, readJson(out).photos[1].id)
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)

    it("reports unknown ids and still writes the photos it found", function()
        local _, Handler = setupMetadata({ photos = { photoOne() } })
        local out = tempJson()

        local r = Handler.exportPhotoMetadata({ photo_ids = { 11, "nope" }, destination = out })

        assert.are.equal(1, r.exported)
        assert.are.same({ "nope" }, r.missing)
        assert.are.equal(1, readJson(out).count)
    end)

    it("creates the destination folder when it does not exist", function()
        local _, Handler = setupMetadata({ photos = { photoOne() } })
        local out = tempJson()
        local dir = out:match("^(.*)[/\\][^/\\]*$")

        Handler.exportPhotoMetadata({ photo_ids = { 11 }, destination = out })
        os.remove(out)

        assert.are.same({ dir }, createdDirs)
    end)

    it("validates destination and photo_ids, and refuses an empty export", function()
        local _, Handler = setupMetadata({ photos = { photoOne() }, targetPhotos = {} })

        assert.has_error(function() Handler.exportPhotoMetadata({}) end, "destination is required")
        assert.has_error(function() Handler.exportPhotoMetadata({ destination = "/tmp/out.txt" }) end,
            "destination must be a .json file path")
        assert.has_error(function()
            Handler.exportPhotoMetadata({ destination = "/tmp/out.json", photo_ids = {} })
        end, "photo_ids must be a non-empty array when given")
        assert.has_error(function() Handler.exportPhotoMetadata({ destination = "/tmp/out.json" }) end,
            "No photos found to export metadata for")
        assert.has_error(function()
            Handler.exportPhotoMetadata({ destination = "/tmp/out.json", photo_ids = { "nope" } })
        end, "No photos found to export metadata for")
    end)
end)
