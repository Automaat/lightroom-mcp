local LrApplication = import 'LrApplication'
local LrSelection = import 'LrSelection'
local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local PhotoLookup = require 'PhotoLookup'

local Handler = {}
local MAX_PHOTOS = 25

local function samePhotos(actual, expected)
    if #actual ~= #expected then return false end
    local wanted = {}
    for _, photo in ipairs(expected) do wanted[photo] = true end
    for _, photo in ipairs(actual) do
        if not wanted[photo] then return false end
    end
    return true
end

local function select(catalog, active, photos)
    local sinceAction = 1
    local quietChecks = 0
    return DevelopSession.waitFor(function()
        if sinceAction >= 1 then
            if active then
                catalog:setSelectedPhotos(active, photos)
            else
                LrSelection.selectNone()
            end
            sinceAction = 0
        end
        sinceAction = sinceAction + 0.1
        if not active then
            quietChecks = catalog:getTargetPhoto() == nil and quietChecks + 1 or 0
            return quietChecks >= 11
        end
        return catalog:getTargetPhoto() == active
            and samePhotos(catalog:getTargetPhotos() or {}, photos)
    end, 10)
end

-- "N (copy ids a, b)" so a caller that sees an error can tell which copies
-- already exist and does not create them again.
local function describeCopies(copies)
    if #copies == 0 then return '0' end
    local ids = {}
    for i, copy in ipairs(copies) do ids[i] = copy.copy_id end
    return #copies .. ' (copy ids ' .. table.concat(ids, ', ') .. ')'
end

local function resolve(catalog, ids)
    local photos, missing, seen = {}, {}, {}
    for _, entry in ipairs(PhotoLookup.resolveMany(catalog, ids)) do
        if not entry.photo then
            missing[#missing + 1] = tostring(entry.id)
        elseif not seen[entry.photo] then
            seen[entry.photo] = true
            photos[#photos + 1] = entry.photo
        end
    end
    if #photos == 0 then error('No photos matched photo_ids') end
    return photos, missing
end

function Handler.create(args)
    args = args or {}
    if type(args.photo_ids) ~= 'table' or #args.photo_ids == 0 or #args.photo_ids > MAX_PHOTOS then
        error('photo_ids must contain 1 to 25 photo IDs or paths')
    end
    for _, id in ipairs(args.photo_ids) do
        if (type(id) ~= 'string' or not id:find('%S')) and type(id) ~= 'number' then
            error('photo_ids must contain photo IDs or paths')
        end
    end
    if args.copy_name ~= nil and (type(args.copy_name) ~= 'string' or not args.copy_name:find('%S')) then
        error('copy_name must be a non-empty string')
    end

    local catalog = LrApplication.activeCatalog()
    local photos, missing = resolve(catalog, args.photo_ids)
    return DevelopSession.run('create_virtual_copies', catalog, false, function()
        local active = catalog:getTargetPhoto()
        local selection = active and catalog:getTargetPhotos() or {}
        local sources = catalog:getActiveSources()
        local switchedSource = false
        local copies = {}
        local ok, failure = LrTasks.pcall(function()
            for _, photo in ipairs(photos) do
                if not select(catalog, photo, { photo }) then
                    switchedSource = true
                    catalog:setActiveSources({ catalog.kAllPhotos })
                    if not select(catalog, photo, { photo }) then
                        error('Could not select photo ' .. tostring(photo.localIdentifier), 0)
                    end
                end
                local created = catalog:createVirtualCopies(args.copy_name) or {}
                -- Record every copy before judging any: each exists in the
                -- catalog either way, and the error must name it.
                local first = #copies + 1
                for _, copy in ipairs(created) do
                    if copy:getRawMetadata('isVirtualCopy') then
                        local master = copy:getRawMetadata('masterPhoto')
                        copies[#copies + 1] = {
                            photo_id = tostring(photo.localIdentifier),
                            master_id = master and tostring(master.localIdentifier) or nil,
                            copy_id = tostring(copy.localIdentifier),
                        }
                    end
                end
                if #created ~= 1 then error('Lightroom did not return exactly one virtual copy', 0) end
                local copy = copies[first]
                if not copy then error('Lightroom did not return a virtual copy', 0) end
                if not copy.master_id then error('Virtual copy ' .. copy.copy_id .. ' has no master photo', 0) end
                -- A virtual copy of a virtual copy belongs to the original master.
                local expected = tostring((photo:getRawMetadata('masterPhoto') or photo).localIdentifier)
                if copy.master_id ~= expected then
                    error(string.format('Virtual copy %s belongs to photo %s, not the requested photo %s',
                        copy.copy_id, copy.master_id, expected), 0)
                end
            end
        end)
        local restored, restoreFailure = LrTasks.pcall(function()
            if switchedSource then
                catalog:setActiveSources(sources)
                if not DevelopSession.waitFor(function()
                    return samePhotos(catalog:getActiveSources() or {}, sources)
                end, 10) then error('Could not restore the previous view source', 0) end
            end
            if not select(catalog, active, selection) then
                error('Could not restore the previous photo selection', 0)
            end
        end)
        if not (ok and restored) then
            -- The creation failure goes first: only a leading source position
            -- is stripped from the message the client sees.
            local reasons = {}
            if not ok then reasons[#reasons + 1] = tostring(failure) end
            if not restored then reasons[#reasons + 1] = tostring(restoreFailure) end
            error(table.concat(reasons, '; ') .. '; virtual copies already created: '
                .. describeCopies(copies), 0)
        end
        return { created = #copies, copies = copies, missing = missing }
    end)
end

return Handler
