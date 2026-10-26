local helper = require 'spec_helper'

local function setup(opts)
    local catalog = helper.fakeCatalog(opts)
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerFolders = nil
    return catalog, require 'HandlerFolders'
end

describe("HandlerFolders", function()
    it("lists paths in tree order with direct photo counts", function()
        local grandchild = helper.fakeFolder("/root/child/grandchild", { 3 })
        local child = helper.fakeFolder("/root/child", { 2 }, { grandchild })
        local root = helper.fakeFolder("/root", { 1 }, { child })
        local _, handler = setup({ folders = { root } })
        local result = handler.listFolders({})
        assert.are.equal(3, result.count)
        assert.are.same({
            { path = "/root", name = "root", photo_count = 1 },
            { path = "/root/child", name = "child", photo_count = 1 },
            { path = "/root/child/grandchild", name = "grandchild", photo_count = 1 },
        }, result.folders)
        assert.is_false(result.has_more)
        local page = handler.listFolders({ limit = 1, offset = 1 })
        assert.are.equal("/root/child", page.folders[1].path)
        assert.is_true(page.has_more)
        assert.is_false(handler.listFolders({ offset = 3 }).has_more)
    end)

    it("counts exactly the returned folders outside read access", function()
        local folders, reads = {}, {}
        local catalog
        for i = 1, 50 do
            local folder = helper.fakeFolder("/folder" .. i)
            folder.getPhotos = function(_, recursive)
                assert.is_false(catalog:isInsideReadAccess())
                assert.is_false(recursive)
                table.insert(reads, i)
                return {}
            end
            table.insert(folders, folder)
        end
        local handler
        catalog, handler = setup({ folders = folders })
        local result = handler.listFolders({ limit = 5, offset = 10 })
        assert.are.equal(50, result.count)
        assert.are.same({ 11, 12, 13, 14, 15 }, reads)
        handler.listFolders({ limit = 0 })
        assert.are.equal(5, #reads)
    end)

    it("returns folder photos with optional descendants outside read access", function()
        local one = helper.fakePhoto({ id = "1", path = "/root/a.jpg" })
        local two = helper.fakePhoto({ id = "2", path = "/root/child/b.jpg" })
        local child = helper.fakeFolder("/root/child", { two })
        local folder = helper.fakeFolder("/root", { one }, { child })
        local original = folder.getPhotos
        local catalog, handler = setup({ folders = { folder }, photos = { one, two } })
        local flags = {}
        folder.getPhotos = function(self, recursive)
            assert.is_false(catalog:isInsideReadAccess())
            table.insert(flags, recursive)
            return original(self, recursive)
        end
        local direct = handler.getFolderPhotos({ folder_path = "/root" })
        assert.are.equal(1, direct.count)
        assert.are.equal("1", direct.photos[1].id)
        local nested = handler.getFolderPhotos({ folder_path = "/root", include_subfolders = true, limit = 1 })
        assert.are.equal(2, nested.count)
        assert.is_true(nested.has_more)
        local tail = handler.getFolderPhotos({ folder_path = "/root", include_subfolders = true, offset = 1 })
        assert.are.equal("2", tail.photos[1].id)
        assert.is_false(tail.has_more)
        assert.are.same({ false, true, true }, flags)
        local empty = handler.getFolderPhotos({ folder_path = "/root", limit = 0 })
        assert.are.equal(0, #empty.photos)
        assert.is_true(empty.has_more)
        assert.are.equal(0, #handler.getFolderPhotos({ folder_path = "/root", offset = 10 }).photos)
    end)

    it("names unknown paths and rejects a missing path", function()
        local _, handler = setup({})
        assert.has_error(function() handler.getFolderPhotos({ folder_path = "/missing" }) end,
            "Folder not found: /missing")
        assert.has_error(function() handler.getFolderPhotos({}) end, "folder_path is required")
    end)

    it("refuses duplicate paths and missing roots in a populated catalog", function()
        local _, handler = setup({ folders = { helper.fakeFolder("/same"), helper.fakeFolder("/same") } })
        assert.has_error(function() handler.listFolders({}) end, "Duplicate folder path in catalog: /same")
        _, handler = setup({ photos = { helper.fakePhoto({ id = "1" }) } })
        assert.has_error(function() handler.listFolders({}) end, "Catalog has photos but returned no root folders")
    end)
end)
