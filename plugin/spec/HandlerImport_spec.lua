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

describe("HandlerImport.importPhotos", function()
    it("cancel keeps imports already committed and returns unprocessed paths", function()
        local catalog, Handler = setup({ fs = {
            directories = { ["/dir"] = true },
            dirContents = { "/dir/a.jpg", "/dir/b.jpg", "/dir/c.jpg" },
        } })
        local done = 0
        local context = {
            isCanceled = function() return done >= 1 end,
            report = function(_, progress) done = progress end,
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
        assert.are.equal("Imported 10 photos", r.message)
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
            "Imported 1 photos; skipped 4 files with unsupported extensions ((none): 1, txt: 1, xmp: 2)",
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
