local helper = require 'spec_helper'

-- Mirrors the real SDK: LrFileUtils.exists returns 'file' / 'directory' / false,
-- and LrFileUtils.isDirectory is intentionally absent (nil on some Lightroom
-- Classic runtimes -- issue #129).
--
-- Two omissions here are deliberate and load-bearing:
--   * no `extension` -- that field lives on LrPathUtils, not LrFileUtils.
--   * no `files`     -- the handler must walk nested subfolders via
--                       recursiveFiles; a plain files() walk misses them.
-- Providing either would let a regression to the wrong API pass green, which
-- is precisely how both bugs shipped.
local function fakeFileUtils(opts)
    return {
        exists = function(p)
            if opts.directories and opts.directories[p] then return 'directory' end
            if opts.exists and opts.exists[p] then return 'file' end
            return false
        end,
        recursiveFiles = function(_)
            local i = 0
            local list = opts.dirContents or {}
            return function()
                i = i + 1
                return list[i]
            end
        end,
    }
end

-- extension() belongs to LrPathUtils in the real SDK.
local function fakePathUtils()
    return {
        extension = function(p) return p:match("%.([^.]+)$") or "" end,
        removeExtension = function(p) return (p:gsub("%.[^.]+$", "")) end,
    }
end

local function setup(opts)
    local catalog = helper.fakeCatalog({ collections = opts.collections or {} })
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
        LrTasks = {},
        LrFileUtils = fakeFileUtils(opts.fs or {}),
        LrPathUtils = fakePathUtils(),
    })
    package.loaded.HandlerImport = nil
    return catalog, require 'HandlerImport'
end

local function importedPaths(catalog)
    local paths = {}
    for _, photo in ipairs(catalog:getAllPhotos()) do
        paths[#paths + 1] = photo:getRawMetadata('path')
    end
    return paths
end

describe("HandlerImport.importPhotos", function()
    describe("RAW+JPEG pairs", function()
        local function importFolder(dirContents, args)
            local catalog, Handler = setup({ fs = {
                directories = { ["/dir"] = true },
                dirContents = dirContents,
            } })
            args = args or {}
            args.source_path = "/dir"
            return Handler.importPhotos(args), importedPaths(catalog)
        end

        for _, case in ipairs({
            { name = "lowercase pair", files = { "/dir/a.cr3", "/dir/a.jpg" }, kept = { "/dir/a.cr3" } },
            { name = "mixed extension case", files = { "/dir/a.CR3", "/dir/a.jpg" }, kept = { "/dir/a.CR3" } },
            { name = "mixed extension case on a jpeg", files = { "/dir/A.nef", "/dir/A.jpg" }, kept = { "/dir/A.nef" } },
            { name = "jpeg listed before the raw", files = { "/dir/a.JPEG", "/dir/a.arw" }, kept = { "/dir/a.arw" } },
            { name = "jpe extension", files = { "/dir/a.nef", "/dir/a.jpe" }, kept = { "/dir/a.nef" } },
            { name = "several jpegs for one raw", files = { "/dir/a.raf", "/dir/a.jpg", "/dir/a.jpeg" }, kept = { "/dir/a.raf" } },
        }) do
            it("leaves out the JPEG: " .. case.name, function()
                local r, paths = importFolder(case.files)

                assert.are.same(case.kept, paths)
                assert.are.equal(1, r.imported)
                assert.are.equal(#case.files - 1, r.skipped_sidecar_jpegs)
                assert.are.equal(0, r.skipped)
                assert.is_nil(r.message)
            end)
        end

        for _, case in ipairs({
            { name = "JPEG without a raw", files = { "/dir/a.jpg", "/dir/b.cr3" } },
            { name = "same name in another folder", files = { "/dir/one/a.cr3", "/dir/two/a.jpg" } },
            { name = "non-JPEG next to a raw", files = { "/dir/a.cr3", "/dir/a.tif", "/dir/a.heic" } },
            { name = "JPEG next to a non-raw", files = { "/dir/a.png", "/dir/a.jpg" } },
            { name = "name differing in case", files = { "/dir/A.nef", "/dir/a.JPG" } },
            { name = "JPEG next to a DNG", files = { "/dir/a.dng", "/dir/a.jpg" } },
            { name = "JPEG next to an uppercase DNG", files = { "/dir/a.DNG", "/dir/a.JPEG" } },
        }) do
            it("keeps every file: " .. case.name, function()
                local r, paths = importFolder(case.files)

                assert.are.same(case.files, paths)
                assert.is_nil(r.skipped_sidecar_jpegs)
            end)
        end

        it("keeps the JPEG as its own photo with separate_jpegs", function()
            local files = { "/dir/a.cr3", "/dir/a.jpg" }

            local r, paths = importFolder(files, { separate_jpegs = true })

            assert.are.same(files, paths)
            assert.is_nil(r.skipped_sidecar_jpegs)
        end)

        it("adds only the raw to the collection and to remaining_paths", function()
            local added = {}
            local collection = {
                getName = function() return "Shoot" end,
                addPhotos = function(_, photos) added = photos end,
            }
            local catalog, Handler = setup({
                collections = { collection },
                fs = {
                    directories = { ["/dir"] = true },
                    dirContents = { "/dir/a.cr3", "/dir/a.jpg", "/dir/b.cr3", "/dir/b.jpg" },
                },
            })
            local context = {
                isCanceled = function() return #catalog:getAllPhotos() >= 1 end,
                report = function() end,
            }

            local r = Handler.importPhotos({ source_path = "/dir", collection_name = "Shoot" }, context)

            assert.are.same({ "/dir/b.cr3" }, r.remaining_paths)
            assert.are.equal(1, #added)
            assert.are.equal("/dir/a.cr3", added[1]:getRawMetadata('path'))
            assert.are.equal(2, r.skipped_sidecar_jpegs)
        end)

        for _, case in ipairs({
            { name = "lowercase raw", jpeg = "/dir/a.jpg", raw = "/dir/a.cr3" },
            { name = "uppercase raw", jpeg = "/dir/a.JPG", raw = "/dir/a.CR3" },
            { name = "jpeg extension", jpeg = "/dir/a.jpeg", raw = "/dir/a.nef" },
        }) do
            it("refuses a lone JPEG beside its raw and names the raw: " .. case.name, function()
                local catalog, Handler = setup({ fs = { exists = { [case.jpeg] = true, [case.raw] = true } } })

                local ok, err = pcall(Handler.importPhotos, { source_path = case.jpeg })

                assert.is_false(ok)
                assert.truthy(tostring(err):find(case.raw, 1, true))
                assert.are.same({}, importedPaths(catalog))
            end)
        end

        it("imports a lone JPEG beside its raw with separate_jpegs", function()
            local catalog, Handler = setup({ fs = { exists = { ["/dir/a.jpg"] = true, ["/dir/a.cr3"] = true } } })

            local r = Handler.importPhotos({ source_path = "/dir/a.jpg", separate_jpegs = true })

            assert.are.equal(1, r.imported)
            assert.are.same({ "/dir/a.jpg" }, importedPaths(catalog))
        end)

        for _, case in ipairs({
            { name = "JPEG with no raw beside it", source = "/dir/a.jpg", others = { "/dir/a.png" } },
            { name = "JPEG beside a DNG", source = "/dir/a.jpg", others = { "/dir/a.dng", "/dir/a.DNG" } },
            { name = "raw with a JPEG beside it", source = "/dir/a.cr3", others = { "/dir/a.jpg" } },
            { name = "folder named like the raw", source = "/dir/a.jpg", directoryNamed = "/dir/a.cr3" },
        }) do
            it("imports a single file: " .. case.name, function()
                local exists = { [case.source] = true }
                for _, other in ipairs(case.others or {}) do exists[other] = true end
                local catalog, Handler = setup({ fs = {
                    exists = exists,
                    directories = case.directoryNamed and { [case.directoryNamed] = true } or {},
                } })

                local r = Handler.importPhotos({ source_path = case.source })

                assert.are.equal(1, r.imported)
                assert.are.same({ case.source }, importedPaths(catalog))
            end)
        end
    end)

    it("cancel keeps imports already committed and returns unprocessed paths", function()
        local catalog, Handler = setup({ fs = {
            directories = { ["/dir"] = true },
            dirContents = { "/dir/a.jpg", "/dir/b.jpg", "/dir/c.jpg" },
        } })
        local context = {
            isCanceled = function() return #catalog:getAllPhotos() >= 1 end,
            report = function() end,
        }

        local r = Handler.importPhotos({ source_path = "/dir" }, context)

        assert.are.equal(1, r.imported)
        assert.is_false(r.complete)
        assert.are.same({ "/dir/b.jpg", "/dir/c.jpg" }, r.remaining_paths)
        assert.are.equal(1, #catalog:getAllPhotos())
    end)

    it("imports a single photo", function()
        local catalog, Handler = setup({
            fs = { exists = { ["/photo.jpg"] = true }, directories = {} },
        })

        local r = Handler.importPhotos({ source_path = "/photo.jpg" })

        assert.is_true(r.success)
        assert.are.equal(1, r.imported)
    end)

    it("errors when source path does not exist", function()
        local _, Handler = setup({ fs = { exists = {} } })
        assert.has_error(function()
            Handler.importPhotos({ source_path = "/missing.jpg" })
        end)
    end)

    it("errors without source_path", function()
        local _, Handler = setup({ fs = {} })
        assert.has_error(function() Handler.importPhotos({}) end)
    end)

    it("imports multiple photos from directory and filters extensions", function()
        local catalog, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = { "/dir/a.jpg", "/dir/b.txt", "/dir/c.png", "/dir/d.dng" },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" })
        assert.are.equal(3, r.imported)
    end)

    it("imports photos nested in subfolders", function()
        -- Photo libraries are organized as shoot/roll subfolders, so the source
        -- directory usually holds no photos itself. An immediate-directory walk
        -- enumerated nothing and failed with "No photos found to import"; the
        -- walk has to recurse.
        local _, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = {
                    "/dir/roll1/a.jpg",
                    "/dir/roll1/scans/b.tif",
                    "/dir/roll2/c.arw",
                },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" })

        assert.is_true(r.success)
        assert.are.equal(3, r.imported)
    end)

    it("imports camera raw formats beyond Canon, Nikon and Sony, in any case", function()
        local _, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = {
                    "/dir/a.RAF", "/dir/b.CR3", "/dir/c.orf", "/dir/d.rw2", "/dir/e.pef",
                    "/dir/f.srw", "/dir/g.3fr", "/dir/h.iiq", "/dir/i.HEIC", "/dir/j.hif",
                },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" })

        assert.are.equal(10, r.imported)
        assert.are.equal(0, r.skipped)
        assert.is_nil(r.skipped_by_extension)
        assert.is_nil(r.message)
    end)

    it("reports the files it skipped by extension", function()
        local _, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = { "/dir/a.raf", "/dir/a.xmp", "/dir/b.xmp", "/dir/notes.txt", "/dir/README" },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" })

        assert.are.equal(1, r.imported)
        assert.are.equal(4, r.skipped)
        assert.are.same({ xmp = 2, txt = 1, [""] = 1 }, r.skipped_by_extension)
        assert.are.equal(
            "Skipped 4 files with unsupported extensions ((none): 1, txt: 1, xmp: 2)",
            r.message)
    end)

    it("names the skipped extensions when a folder has no importable photos", function()
        local _, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = { "/dir/clip.mov", "/dir/clip.xmp" },
            },
        })

        local ok, err = pcall(Handler.importPhotos, { source_path = "/dir" })

        assert.is_false(ok)
        assert.truthy(tostring(err):find("skipped files by extension: mov: 1, xmp: 1", 1, true))
    end)

    it("acquires catalog write access per photo, not once for the batch", function()
        -- A batch-wide write lock wedges the bridge for the whole multi-minute
        -- import (issue #128); each photo must get its own short transaction so
        -- the exclusive lock is released between photos.
        local catalog, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = { "/dir/a.jpg", "/dir/b.png", "/dir/c.dng" },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" })

        assert.are.equal(3, r.imported)
        assert.are.equal(3, catalog:getWriteAccessCount())
    end)
end)
