local helper = require 'spec_helper'

describe('reference style matching', function()
    local handler, catalog, reference, targets, applied, events, snapshotState
    local previous = {}
    before_each(function()
        for _, name in ipairs({ 'HandlerDevelop', 'HandlerSnapshots', 'DevelopSession' }) do
            previous[name] = package.loaded[name]
            package.loaded[name] = nil
        end
        applied, events, snapshotState = {}, {}, {}
        reference = helper.fakePhoto({ id = '1', path = '/reference.raw', developSettings = {
            Exposure2012 = 0.5, Contrast2012 = 20, ToneCurvePV2012 = { 0, 0, 255, 255 },
            CropTop = 0.1, CropLeft = 0.2, CropBottom = 0.9, CropRight = 0.8, CropAngle = 10,
            PerspectiveVertical = 20, PerspectiveFuture = 99,
            WhiteBalance = 'Custom', Temperature = 6000, Tint = 10,
            LensProfileEnable = 1, LensManualDistortionAmount = 10,
            MaskGroupBasedCorrections = { { unsafe = true } }, UnknownSetting = 1,
        } })
        targets = {}
        for index = 2, 4 do
            local id = tostring(index)
            local photo = helper.fakePhoto({ id = id, developSettings = {
                Exposure2012 = 0, Contrast2012 = 0, ToneCurvePV2012 = { 0, 0, 255, 255 },
            } })
            snapshotState[id] = {}
            photo.getDevelopSnapshots = function() return snapshotState[id] end
            photo.createDevelopSnapshot = function(_, name)
                events[#events + 1] = 'snapshot:' .. id
                snapshotState[id][#snapshotState[id] + 1] = { snapshotID = id .. '-snapshot', name = name }
                return true
            end
            photo.applyDevelopSettings = function(_, settings)
                events[#events + 1] = 'apply:' .. id
                applied[id] = settings
            end
            targets[#targets + 1] = photo
        end
        catalog = helper.fakeCatalog({ photos = { reference, targets[1], targets[2], targets[3] } })
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrDate = { currentTime = function() return 123 end },
            LrTasks = { pcall = pcall }, LrLogger = helper.defaultLrLogger(),
            LrDevelopController = {}, LrFileUtils = {}, LrPathUtils = {},
            LrApplicationView = {}, LrSelection = {},
        })
        handler = require 'HandlerDevelop'
    end)
    after_each(function()
        for _, name in ipairs({ 'HandlerDevelop', 'HandlerSnapshots', 'DevelopSession' }) do
            package.loaded[name] = previous[name]
        end
    end)

    it('snapshots before applying global style and counts changed values', function()
        local result = handler.matchPhotoStyle({ reference_id = '1', target_ids = { '2', '3' } })
        assert.same({ 'snapshot:2', 'apply:2', 'snapshot:3', 'apply:3' }, events)
        assert.same({ Exposure2012 = 0.5, Contrast2012 = 20, ToneCurvePV2012 = { 0, 0, 255, 255 } }, applied['2'])
        assert.equals(2, result.matched)
        assert.equals(2, result.results[1].settings_changed)
        assert.equals('2-snapshot', result.results[1].snapshot.id)
        assert.matches('Style match from 1', result.results[1].snapshot.name)
        assert.is_true(result.success)
        assert.is_false(catalog:getQueriedInsideReadAccess())
    end)

    it('continues after a snapshot failure without writing that target', function()
        targets[2].createDevelopSnapshot = function() error('snapshot refused') end
        local result = handler.matchPhotoStyle({ reference_id = '1', target_ids = { '2', '3', '4', '999' } })
        assert.same({ 'snapshot:2', 'apply:2', 'snapshot:4', 'apply:4' }, events)
        assert.is_nil(applied['3'])
        assert.same({ '999' }, result.missing)
        assert.equals('3', result.failures[1].photo_id)
        assert.matches('snapshot refused', result.failures[1].reason)
        assert.is_false(result.success)
    end)

    it('requires snapshot readback before writing', function()
        targets[1].getDevelopSnapshots = function() return {} end
        local result = handler.matchPhotoStyle({ reference_id = '1', target_ids = { '2' } })
        assert.equals(0, result.matched)
        assert.is_nil(applied['2'])
        assert.matches('could not be read back', result.failures[1].reason)
    end)

    it('rejects reference aliases anywhere in the targets before snapshotting', function()
        for _, id in ipairs({ '1', '/reference.raw' }) do
            assert.has_error(function()
                handler.matchPhotoStyle({ reference_id = 1, target_ids = { '2', id } })
            end)
        end
        assert.same({}, events)
    end)

    it('retains a recovery snapshot when applying fails and continues', function()
        targets[1].applyDevelopSettings = function() error('write refused') end
        local result = handler.matchPhotoStyle({ reference_id = '1', target_ids = { '2', '3' } })
        assert.equals('2-snapshot', result.failures[1].snapshot.id)
        assert.equals(1, result.matched)
        assert.is_not_nil(applied['3'])
    end)
end)
