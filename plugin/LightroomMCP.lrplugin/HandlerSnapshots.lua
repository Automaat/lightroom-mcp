local LrApplication = import 'LrApplication'
local PhotoLookup = require 'PhotoLookup'
local DevelopSession = require 'DevelopSession'

local Handler = {}

local function nonempty(value, name)
    if type(value) ~= 'string' or not value:find('%S') then
        error(name .. ' must be a non-empty string')
    end
    return value
end

local function resolve(args)
    local id = args.photo_id
    if type(id) == 'number' then id = tostring(id) end
    nonempty(id, 'photo_id')
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, id)
    if not photo then error('Photo not found: ' .. id) end
    return catalog, photo
end

local function snapshots(photo)
    local result = {}
    for _, snapshot in ipairs(photo:getDevelopSnapshots() or {}) do
        result[#result + 1] = { id = tostring(snapshot.snapshotID), name = snapshot.name }
    end
    return result
end

local function find(photo, id)
    for _, snapshot in ipairs(photo:getDevelopSnapshots() or {}) do
        if tostring(snapshot.snapshotID) == id then return snapshot end
    end
    error('Snapshot not found on this photo: ' .. id)
end

function Handler.list(args)
    local _, photo = resolve(args)
    return { photo_id = args.photo_id, snapshots = snapshots(photo) }
end

function Handler.create(args)
    nonempty(args.name, 'name')
    if args.replace ~= nil and type(args.replace) ~= 'boolean' then
        error('replace must be a boolean')
    end
    local catalog, photo = resolve(args)
    local created
    catalog:withWriteAccessDo('Create Develop Snapshot', function()
        if not photo:createDevelopSnapshot(args.name, args.replace == true) then
            error('Snapshot name already exists: ' .. args.name)
        end
    end)
    -- Lightroom publishes the new snapshot only after the write gate returns.
    for _, snapshot in ipairs(snapshots(photo)) do
        if snapshot.name == args.name then created = snapshot break end
    end
    if not created then error('Created snapshot could not be read back') end
    return { success = true, photo_id = args.photo_id, snapshot = created }
end

function Handler.apply(args)
    nonempty(args.snapshot_id, 'snapshot_id')
    local catalog, photo = resolve(args)
    find(photo, args.snapshot_id)
    DevelopSession.withPhoto('apply_develop_snapshot', catalog, photo, function()
        catalog:withWriteAccessDo('Apply Develop Snapshot', function()
            local snapshot = find(photo, args.snapshot_id)
            photo:applyDevelopSnapshot(snapshot.snapshotID)
        end)
    end)
    return { success = true, photo_id = args.photo_id, snapshot_id = args.snapshot_id }
end

function Handler.delete(args)
    nonempty(args.snapshot_id, 'snapshot_id')
    local catalog, photo = resolve(args)
    find(photo, args.snapshot_id)
    DevelopSession.withPhoto('delete_develop_snapshot', catalog, photo, function()
        catalog:withWriteAccessDo('Delete Develop Snapshot', function()
            local snapshot = find(photo, args.snapshot_id)
            photo:deleteDevelopSnapshot(nonempty(snapshot.id_global, 'snapshot id_global'))
        end)
        local deleted = DevelopSession.waitFor(function()
            for _, snapshot in ipairs(snapshots(photo)) do
                if snapshot.id == args.snapshot_id then return false end
            end
            return true
        end, 5)
        if not deleted then error('Lightroom did not delete snapshot: ' .. args.snapshot_id) end
    end)
    return { success = true, photo_id = args.photo_id, snapshot_id = args.snapshot_id }
end

return Handler
