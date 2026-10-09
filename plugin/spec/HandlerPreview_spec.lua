local helper = require 'spec_helper'

-- thumbnail(photo, w, h, callback) stands in for Lightroom's renderer: it may
-- call back at once, keep the callback for later, or never call it.
local function previewPhoto(meta, thumbnail)
    local photo = helper.fakePhoto(meta)
    photo.requestJpegThumbnail = function(self, w, h, callback)
        meta.__requested = { w, h }
        thumbnail(self, w, h, callback)
        return { request = true }
    end
    return photo
end

-- SOI, an APP0 segment to skip, then SOF0 for a 855x570 image.
local function fakeJpeg()
    local app0 = string.char(0xFF, 0xE0, 0x00, 0x10) .. string.rep("\0", 14)
    local sof0 = string.char(0xFF, 0xC0, 0x00, 0x11, 0x08, 0x02, 0x3A, 0x03, 0x57) .. string.rep("\0", 10)
    return string.char(0xFF, 0xD8) .. app0 .. sof0
end

local function setup(photos, onSleep)
    local catalog = helper.fakeCatalog({ photos = photos or {} })
    local sleeps = { count = 0 }
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
        LrStringUtils = { encodeBase64 = function(s) return "b64(" .. s .. ")" end },
        LrTasks = {
            sleep = function()
                sleeps.count = sleeps.count + 1
                if onSleep then onSleep(sleeps.count) end
            end,
        },
    })
    package.loaded.HandlerPreview = nil
    return catalog, require 'HandlerPreview', sleeps
end

describe("HandlerPreview.getPhotoPreview", function()
    it("returns the rendered JPEG base64-encoded with its mime type", function()
        local meta = { id = "1", path = "/a.nef" }
        local photo = previewPhoto(meta, function(_, _, _, cb) cb("JPEGDATA") end)
        local _, Handler, sleeps = setup({ photo })

        local r = Handler.getPhotoPreview({ photo_id = "1" })

        assert.are.equal("1", r.photo_id)
        assert.are.equal(8, r.bytes)
        assert.are.same({ mime_type = "image/jpeg", data = "b64(JPEGDATA)" }, r.image)
        assert.are.same({ 512, 512 }, meta.__requested)
        assert.are.equal(0, sleeps.count)
    end)

    it("reports the dimensions Lightroom actually returned", function()
        local jpeg = fakeJpeg()
        local photo = previewPhoto({ id = "1", path = "/a.nef" }, function(_, _, _, cb) cb(jpeg) end)
        local _, Handler = setup({ photo })

        local r = Handler.getPhotoPreview({ photo_id = "1", size = 512 })

        assert.are.equal(512, r.requested_size)
        assert.are.equal(855, r.width)
        assert.are.equal(570, r.height)
    end)

    it("leaves dimensions out when the data has no readable JPEG header", function()
        local photo = previewPhoto({ id = "1", path = "/a.nef" }, function(_, _, _, cb) cb("NOTAJPEG") end)
        local _, Handler = setup({ photo })

        local r = Handler.getPhotoPreview({ photo_id = "1" })

        assert.is_nil(r.width)
        assert.is_nil(r.height)
        assert.are.equal(8, r.bytes)
    end)

    it("waits for a callback that arrives after the request returns", function()
        local pending
        local photo = previewPhoto({ id = "1", path = "/a.nef" }, function(_, _, _, cb) pending = cb end)
        local _, Handler, sleeps = setup({ photo }, function(n)
            if n == 3 then pending("LATE") end
        end)

        local r = Handler.getPhotoPreview({ photo_id = "1" })

        assert.are.equal("b64(LATE)", r.image.data)
        assert.are.equal(3, sleeps.count)
    end)

    it("keeps the first image when Lightroom calls back twice", function()
        local photo = previewPhoto({ id = "1", path = "/a.nef" }, function(_, _, _, cb)
            cb("FIRST")
            cb("SECOND")
        end)
        local _, Handler = setup({ photo })

        assert.are.equal("b64(FIRST)", Handler.getPhotoPreview({ photo_id = "1" }).image.data)
    end)

    it("passes the requested size, rounded down, to Lightroom", function()
        local meta = { id = "1", path = "/a.nef" }
        local photo = previewPhoto(meta, function(_, _, _, cb) cb("J") end)
        local _, Handler = setup({ photo })

        local r = Handler.getPhotoPreview({ photo_id = "1", size = 700.7 })

        assert.are.equal(700, r.requested_size)
        assert.are.same({ 700, 700 }, meta.__requested)
    end)

    it("asks for smaller previews until the image fits the size limit", function()
        local big = string.rep("x", 3.5 * 1024 * 1024 + 1)
        local edges = {}
        local photo = previewPhoto({ id = "1", path = "/a.nef" }, function(_, w, _, cb)
            edges[#edges + 1] = w
            cb(w > 500 and big or "SMALL")
        end)
        local _, Handler = setup({ photo })

        local r = Handler.getPhotoPreview({ photo_id = "1", size = 2048 })

        assert.are.same({ 2048, 1024, 512, 256 }, edges)
        assert.are.equal("b64(SMALL)", r.image.data)
        assert.are.equal(2048, r.requested_size)
    end)

    it("gives up when even the smallest preview is over the size limit", function()
        local big = string.rep("x", 3.5 * 1024 * 1024 + 1)
        local edges = {}
        local photo = previewPhoto({ id = "1", path = "/a.nef" }, function(_, w, _, cb)
            edges[#edges + 1] = w
            cb(big)
        end)
        local _, Handler = setup({ photo })

        assert.has_error(function() Handler.getPhotoPreview({ photo_id = "1", size = 300 }) end,
            "Preview is 3670017 bytes, over the 3670016 byte limit even at size 64")
        assert.are.same({ 300, 150, 75, 64 }, edges)
    end)

    it("reports the renderer's error instead of an empty image", function()
        local photo = previewPhoto({ id = "1", path = "/a.nef" }, function(_, _, _, cb)
            cb(nil, "file is offline")
        end)
        local _, Handler = setup({ photo })

        assert.has_error(function() Handler.getPhotoPreview({ photo_id = "1" }) end,
            "Preview failed: file is offline")
    end)

    it("gives up when Lightroom never calls back", function()
        local photo = previewPhoto({ id = "1", path = "/a.nef" }, function() end)
        local _, Handler, sleeps = setup({ photo })

        assert.has_error(function() Handler.getPhotoPreview({ photo_id = "1" }) end,
            "Preview not ready after 20s")
        assert.is_true(sleeps.count >= 400)
    end)

    it("reports an unknown photo", function()
        local _, Handler = setup({})

        assert.has_error(function() Handler.getPhotoPreview({ photo_id = "missing" }) end,
            "Photo not found: missing")
    end)

    it("rejects a missing id or an out-of-range size before scanning", function()
        local meta = { id = "1", path = "/a.nef" }
        local photo = previewPhoto(meta, function(_, _, _, cb) cb("J") end)
        local catalog, Handler = setup({ photo })

        assert.has_error(function() Handler.getPhotoPreview({}) end, "photo_id is required")
        for _, size in ipairs({ 63, 2049, "big" }) do
            assert.has_error(function() Handler.getPhotoPreview({ photo_id = "1", size = size }) end,
                "size must be a number between 64 and 2048")
        end

        assert.are.equal(0, catalog.getQueryCount())
        assert.is_nil(meta.__requested)
    end)
end)
