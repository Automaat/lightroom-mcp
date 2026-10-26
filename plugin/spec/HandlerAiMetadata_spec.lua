local helper = require 'spec_helper'

local function setup(count)
    local photos, stored, writes = {}, {}, {}
    for i = 1, count or 2 do
        photos[i] = helper.fakePhoto({ id = tostring(i), path = '/' .. i .. '.jpg' })
        stored[photos[i]] = {}
    end
    local catalog = helper.fakeCatalog({ photos = photos })
    local inWrite = false
    local originalWrite = catalog.withWriteAccessDo
    catalog.withWriteAccessDo = function(self, name, fn)
        return originalWrite(self, name, function()
            inWrite = true
            fn()
            inWrite = false
        end)
    end
    _G._PLUGIN = { id = 'com.lightroom.mcp' }
    for _, photo in ipairs(photos) do
        photo.setPropertyForPlugin = function(self, plugin, field, value)
            assert.is_true(inWrite)
            assert.are.equal(_PLUGIN, plugin)
            writes[#writes + 1] = { photo = self, field = field, value = value }
            stored[self][field] = value
        end
        photo.setRawMetadata = function() error('standard metadata write') end
        photo.addKeyword = function() error('keyword add') end
        photo.removeKeyword = function() error('keyword remove') end
        photo.getPropertyForPlugin = function() error('single property read') end
    end
    local batches = {}
    catalog.batchGetPropertyForPlugin = function(_, batch, plugin, fields)
        assert.are.equal(_PLUGIN, plugin)
        assert.are.same({ 'aiScore', 'aiReason' }, fields)
        batches[#batches + 1] = batch
        return stored
    end
    helper.installImport({ LrApplication = { activeCatalog = function() return catalog end } })
    package.loaded.HandlerAiMetadata = nil
    return require 'HandlerAiMetadata', photos, stored, writes, catalog, batches
end

describe('HandlerAiMetadata', function()
    it('sets two photos in one gate without standard metadata writes', function()
        local handler, photos, stored, writes, catalog = setup()
        local result = handler.setAiMetadata({ photo_ids = { '1', '2', 'missing' }, score = 72, reason = 'eyes closed' })
        assert.are.equal(2, result.updated)
        assert.are.same({ 'missing' }, result.missing)
        assert.are.equal(1, catalog.getWriteAccessCount())
        assert.is_false(catalog.getQueriedInsideWriteAccess())
        assert.are.equal(4, #writes)
        for _, photo in ipairs(photos) do
            assert.are.same({ aiScore = '72', aiReason = 'eyes closed' }, stored[photo])
        end
    end)

    it('preserves omitted values and clears each field with nil', function()
        local handler, photos, stored, writes = setup(1)
        handler.setAiMetadata({ photo_ids = { '1' }, score = 0, reason = 'keep' })
        handler.setAiMetadata({ photo_ids = { '1' }, score = 100 })
        assert.are.same({ aiScore = '100', aiReason = 'keep' }, stored[photos[1]])
        handler.setAiMetadata({ photo_ids = { '1' }, score = '', reason = '' })
        assert.is_nil(writes[#writes].value)
        assert.is_nil(writes[#writes - 1].value)
        assert.are.same({}, stored[photos[1]])
    end)

    it('rejects invalid input before opening a write gate', function()
        local handler, _, _, writes, catalog = setup()
        for _, fields in ipairs({
            {}, { score = -1 }, { score = 101 }, { score = 1.5 }, { score = '72' },
            { score = false }, { score = 0 / 0 }, { reason = false },
            { reason = string.rep('a', 1025) }, { reason = string.rep('é', 1025) },
        }) do
            fields.photo_ids = { '1' }
            assert.has_error(function() handler.setAiMetadata(fields) end)
        end
        assert.are.equal(0, #writes)
        assert.are.equal(0, catalog.getWriteAccessCount())
    end)

    it('reads 200 photos in one property batch, preserving missing and unset results', function()
        local handler, photos, stored, _, _, batches = setup(200)
        local ids = {}
        for i = 1, 200 do ids[i] = tostring(i) end
        ids[201] = 'missing'
        stored[photos[1]] = { aiScore = '72', aiReason = 'eyes closed' }
        local result = handler.getAiMetadata({ photo_ids = ids })
        assert.are.equal(1, #batches)
        assert.are.equal(200, #batches[1])
        assert.are.equal(200, #result.photos)
        assert.are.same({ photo_id = '1', score = 72, reason = 'eyes closed' }, result.photos[1])
        assert.are.same({ photo_id = '2' }, result.photos[2])
        assert.are.same({ 'missing' }, result.missing)
    end)

    it('counts multibyte reason characters consistently', function()
        local handler = setup(1)
        handler.setAiMetadata({ photo_ids = { '1' }, reason = string.rep('é', 1024) })
    end)
end)
