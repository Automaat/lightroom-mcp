local helper = require 'spec_helper'

describe("HandlerSelection.getSelectedPhotos", function()
    local Handler

    local lastCatalog

    local function setup(opts)
        local catalog = helper.fakeCatalog(opts)
        lastCatalog = catalog
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrLogger = helper.defaultLrLogger(),
        })
        package.loaded.HandlerSelection = nil
        Handler = require 'HandlerSelection'
    end

    it("returns selected photos when selection is non-empty", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", fileName = "a.jpg", rating = 5 })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", fileName = "b.jpg", rating = 3 })
        local p3 = helper.fakePhoto({ id = "3", path = "/c.jpg", fileName = "c.jpg", rating = 0 })
        setup({ photos = { p1, p2, p3 }, targetPhotos = { p1, p3 } })

        local r = Handler.getSelectedPhotos({})
        assert.are.equal(2, r.count)
        assert.are.equal("1", r.photos[1].id)
        assert.are.equal("3", r.photos[2].id)
        assert.is_false(r.has_more)
    end)

    it("falls back to filmstrip when no selection (targetPhotos defaults to all)", function()
        setup({
            photos = {
                helper.fakePhoto({ id = "1", fileName = "a.jpg" }),
                helper.fakePhoto({ id = "2", fileName = "b.jpg" }),
            },
        })
        local r = Handler.getSelectedPhotos({})
        assert.are.equal(2, r.count)
        assert.are.equal(2, #r.photos)
    end)

    it("returns serialized photo fields", function()
        setup({
            photos = { helper.fakePhoto({
                id = "42", path = "/x.jpg", fileName = "x.jpg",
                rating = 4, dateTimeOriginal = "2026-05-06",
            }) },
        })
        local r = Handler.getSelectedPhotos({})
        local p = r.photos[1]
        assert.are.equal("42", p.id)
        assert.are.equal("/x.jpg", p.path)
        assert.are.equal("x.jpg", p.filename)
        assert.are.equal(4, p.rating)
        assert.are.equal("2026-05-06", p.dateTimeOriginal)
    end)

    it("paginates via limit and offset", function()
        local photos = {}
        for i = 1, 250 do
            table.insert(photos, helper.fakePhoto({ id = tostring(i), fileName = "p" .. i .. ".jpg" }))
        end
        setup({ photos = photos })

        local r = Handler.getSelectedPhotos({ limit = 50, offset = 100 })
        assert.are.equal(250, r.count)
        assert.are.equal(50, #r.photos)
        assert.are.equal("101", r.photos[1].id)
        assert.is_true(r.has_more)
    end)

    it("caps to 100 by default", function()
        local photos = {}
        for i = 1, 150 do
            table.insert(photos, helper.fakePhoto({ id = tostring(i), fileName = "p.jpg" }))
        end
        setup({ photos = photos })

        local r = Handler.getSelectedPhotos({})
        assert.are.equal(150, r.count)
        assert.are.equal(100, #r.photos)
        assert.is_true(r.has_more)
    end)

    it("returns empty when nothing is targeted", function()
        setup({ photos = {}, targetPhotos = {} })
        local r = Handler.getSelectedPhotos({})
        assert.are.equal(0, r.count)
        assert.are.same({}, r.photos)
        assert.is_false(r.has_more)
    end)

    it("calls getTargetPhotos OUTSIDE the read-access gate (#134 deadlock guard)", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", fileName = "a.jpg", rating = 5 })
        setup({ photos = { p1 }, targetPhotos = { p1 } })
        Handler.getSelectedPhotos({})
        assert.is_false(lastCatalog.getQueriedInsideReadAccess())
    end)

    describe("setSelection", function()
        local function threePhotos()
            return
                helper.fakePhoto({ id = "1", path = "/a.jpg", fileName = "a.jpg" }),
                helper.fakePhoto({ id = "2", path = "/b.jpg", fileName = "b.jpg" }),
                helper.fakePhoto({ id = "3", path = "/c.jpg", fileName = "c.jpg" })
        end

        it("selects the resolved photos and makes the first one active", function()
            local p1, p2, p3 = threePhotos()
            setup({ photos = { p1, p2, p3 }, targetPhotos = { p3, p1 } })

            local r = Handler.setSelection({ photo_ids = { "3", "1" } })

            assert.are.equal(2, r.selected)
            assert.is_nil(r.warning)
            assert.are.equal("3", r.active)
            assert.are.same({}, r.missing)
            local call = lastCatalog.getSelectionCall()
            assert.are.equal(p3, call.active)
            assert.are.same({ p3, p1 }, call.photos)
        end)

        it("resolves by file path as well as local identifier", function()
            local p1, p2 = threePhotos()
            setup({ photos = { p1, p2 }, targetPhotos = { p2 } })

            local r = Handler.setSelection({ photo_ids = { "/b.jpg" } })

            assert.are.equal(1, r.selected)
            assert.are.equal(p2, lastCatalog.getSelectionCall().active)
        end)

        it("warns when Lightroom ignores photos outside the current view source", function()
            local p1, p2, p3 = threePhotos()
            setup({ photos = { p1, p2, p3 }, targetPhotos = { p2 } })

            local r = Handler.setSelection({ photo_ids = { "1", "3" } })

            assert.are.equal(0, r.selected)
            assert.are.equal(2, r.requested)
            assert.is_not_nil(r.warning)
            assert.is_not_nil(r.warning:find("current view source", 1, true))
        end)

        it("reports ids that matched no photo", function()
            local p1 = threePhotos()
            setup({ photos = { p1 } })

            local r = Handler.setSelection({ photo_ids = { "1", "999" } })

            assert.are.equal(1, r.selected)
            assert.are.same({ "999" }, r.missing)
        end)

        it("errors when photo_ids is missing or empty", function()
            setup({ photos = { threePhotos() } })
            assert.has_error(function() Handler.setSelection({}) end, "photo_ids is required")
            assert.has_error(function() Handler.setSelection({ photo_ids = {} }) end,
                "photo_ids is required")
        end)

        it("errors when no id resolves, leaving the selection untouched", function()
            setup({ photos = { threePhotos() } })

            assert.has_error(function() Handler.setSelection({ photo_ids = { "999" } }) end,
                "No photos matched photo_ids")
            assert.is_nil(lastCatalog.getSelectionCall())
        end)

        it("calls setSelectedPhotos OUTSIDE the read-access gate (#134 deadlock guard)", function()
            local p1 = threePhotos()
            setup({ photos = { p1 } })
            Handler.setSelection({ photo_ids = { "1" } })
            assert.is_false(lastCatalog.getQueriedInsideReadAccess())
        end)
    end)
end)
