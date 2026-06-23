local helper = require 'spec_helper'

local function fakeFileUtils(opts)
    return {
        exists = function(p) return opts.exists and opts.exists[p] end,
        isDirectory = function(p) return opts.directories and opts.directories[p] end,
        files = function(_)
            local i = 0
            local list = opts.dirContents or {}
            return function()
                i = i + 1
                return list[i]
            end
        end,
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
    })
    package.loaded.HandlerImport = nil
    return catalog, require 'HandlerImport'
end

describe("HandlerImport.importPhotos", function()
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
