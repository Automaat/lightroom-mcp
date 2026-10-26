local helper = require 'spec_helper'

describe('develop snapshots', function()
    local handler, photo, other, state, calls
    before_each(function()
        state, calls = {}, {}
        photo = helper.fakePhoto({ localIdentifier = '1' })
        other = helper.fakePhoto({ localIdentifier = '2' })
        local serial = 0
        photo.getDevelopSnapshots = function() return state end
        other.getDevelopSnapshots = function() return {} end
        photo.createDevelopSnapshot = function(_, name, replace)
            for _, item in ipairs(state) do
                if item.name == name then
                    if not replace then return false end
                    calls.replaced = item.snapshotID
                    return true
                end
            end
            serial = serial + 1
            state[#state + 1] = { snapshotID = 'snapshot-' .. serial, id_global = 'global-' .. serial, name = name }
            return true
        end
        photo.applyDevelopSnapshot = function(_, id) calls.applied = id end
        photo.deleteDevelopSnapshot = function(_, id)
            calls.deleted = id
            for i, item in ipairs(state) do
                if item.snapshotID == id then table.remove(state, i) return end
            end
        end
        local catalog = helper.fakeCatalog({ photos = { photo, other } })
        helper.installImport({ LrApplication = { activeCatalog = function() return catalog end } })
        package.loaded.HandlerSnapshots = nil
        handler = require 'HandlerSnapshots'
    end)

    it('lists an empty photo and returns created ids and names', function()
        assert.same({}, handler.list({ photo_id = '1' }).snapshots)
        local result = handler.create({ photo_id = '1', name = 'before' })
        assert.same({ id = 'snapshot-1', name = 'before' }, result.snapshot)
        assert.same({ result.snapshot }, handler.list({ photo_id = '1' }).snapshots)
    end)

    it('rejects duplicate names unless replacement is requested', function()
        local first = handler.create({ photo_id = '1', name = 'before' }).snapshot
        assert.has_error(function() handler.create({ photo_id = '1', name = 'before' }) end)
        assert.same({ first }, handler.list({ photo_id = '1' }).snapshots)
        assert.is_nil(calls.replaced)
        assert.same(first, handler.create({ photo_id = '1', name = 'before', replace = true }).snapshot)
        assert.equals(first.id, calls.replaced)
    end)

    it('applies and deletes only the requested snapshot', function()
        local first = handler.create({ photo_id = '1', name = 'a' }).snapshot
        local second = handler.create({ photo_id = '1', name = 'b' }).snapshot
        handler.apply({ photo_id = '1', snapshot_id = first.id })
        assert.equals(first.id, calls.applied)
        handler.delete({ photo_id = '1', snapshot_id = first.id })
        assert.equals(first.id, calls.deleted)
        assert.same({ second }, handler.list({ photo_id = '1' }).snapshots)
    end)

    for _, action in ipairs({ 'apply', 'delete' }) do
        it('rejects unknown and foreign snapshot ids for ' .. action, function()
            local first = handler.create({ photo_id = '1', name = 'a' }).snapshot
            assert.has_error(function() handler[action]({ photo_id = '1', snapshot_id = 'missing' }) end)
            assert.has_error(function() handler[action]({ photo_id = '2', snapshot_id = first.id }) end)
            assert.same({}, calls)
            assert.same({ first }, handler.list({ photo_id = '1' }).snapshots)
        end)
    end

    it('rejects unknown photos for every operation', function()
        for _, action in ipairs({ 'create', 'list', 'apply', 'delete' }) do
            assert.has_error(function()
                handler[action]({ photo_id = 'missing', name = 'a', snapshot_id = 'missing' })
            end)
        end
        assert.same({}, state)
        assert.same({}, calls)
    end)

    it('rejects malformed names and replacement flags', function()
        for _, name in ipairs({ '', '  ', false, 4 }) do
            assert.has_error(function() handler.create({ photo_id = '1', name = name }) end)
        end
        assert.has_error(function() handler.create({ photo_id = '1', name = 'a', replace = 'yes' }) end)
        assert.same({}, state)
    end)
end)
