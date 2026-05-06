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
end)
