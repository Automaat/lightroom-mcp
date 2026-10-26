local LrApplication = import 'LrApplication'
local LrApplicationView = import 'LrApplicationView'
local LrSelection = import 'LrSelection'
local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local PhotoLookup = require 'PhotoLookup'

local Handler = {}

local function sameSelection(catalog, photos)
    if catalog:getTargetPhoto() ~= photos[1] then return false end
    local expected = {}
    for _, photo in ipairs(photos) do expected[photo] = true end
    local actual = catalog:getTargetPhotos() or {}
    if #actual ~= #photos then return false end
    for _, photo in ipairs(actual) do
        if not expected[photo] then return false end
        expected[photo] = nil
    end
    return next(expected) == nil
end

local function surviving(catalog, photos)
    local raw = catalog:batchGetRawMetadata(photos, { 'uuid' }) or {}
    local result = {}
    for _, photo in ipairs(photos) do
        if (raw[photo] or {}).uuid then result[#result + 1] = photo end
    end
    return result
end

local function restore(catalog, view)
    local ok, result = LrTasks.pcall(function()
        catalog:setActiveSources(view.sources)
        local photos = surviving(catalog, view.selection)
        if #photos > 0 then
            local active = photos[1]
            for _, photo in ipairs(photos) do
                if photo == view.active then active = photo end
            end
            local ordered = { active }
            for _, photo in ipairs(photos) do
                if photo ~= active then ordered[#ordered + 1] = photo end
            end
            catalog:setSelectedPhotos(active, ordered)
            if not DevelopSession.waitFor(function() return sameSelection(catalog, ordered) end, 10) then
                error("Lightroom did not restore the surviving selection")
            end
        else
            LrSelection.selectNone()
            if not DevelopSession.waitFor(function() return catalog:getTargetPhoto() == nil end, 10) then
                error("Lightroom did not restore the empty selection")
            end
        end
    end)
    LrApplicationView.switchToModule(view.module)
    if not ok then error(result, 0) end
end

function Handler.removePhotos(args)
    args = args or {}
    if args.confirm ~= true then error("confirm must be true to remove photos from the catalog") end
    local ids = args.photo_ids
    if type(ids) ~= "table" or #ids < 1 or #ids > 100 then
        error("photo_ids must contain between 1 and 100 IDs or paths")
    end
    local count = 0
    for key, id in pairs(ids) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key > #ids or key ~= math.floor(key)
            or not ((type(id) == "string" and id:find("%S"))
                or (type(id) == "number" and id == id and math.abs(id) < math.huge)) then
            error("photo_ids must be an array of IDs or paths")
        end
    end
    if count ~= #ids then error("photo_ids must be an array of IDs or paths") end
    if type(LrSelection.removeFromCatalog) ~= "function" then
        error("remove_photos_from_catalog needs Lightroom Classic 14.3 or later")
    end
    local catalog = LrApplication.activeCatalog()
    local photos, missing, seen, missingSeen = {}, {}, {}, {}
    for _, entry in ipairs(PhotoLookup.resolveMany(catalog, ids)) do
        if entry.photo then
            if not seen[entry.photo] then
                photos[#photos + 1] = entry.photo
                seen[entry.photo] = true
            end
        elseif not missingSeen[tostring(entry.id)] then
            missing[#missing + 1] = tostring(entry.id)
            missingSeen[tostring(entry.id)] = true
        end
    end
    if #photos == 0 then error("No photos matched photo_ids") end
    catalog:withReadAccessDo(function()
        local raw = catalog:batchGetRawMetadata(photos, { 'virtualCopies' }) or {}
        for _, photo in ipairs(photos) do
            for _, copy in ipairs((raw[photo] or {}).virtualCopies or {}) do
                if not seen[copy] then
                    error("Include every virtual copy when removing its master from the catalog")
                end
            end
        end
    end)
    return DevelopSession.run("remove_photos_from_catalog", catalog, false, function()
        local active = catalog:getTargetPhoto()
        local view = {
            module = LrApplicationView.getCurrentModuleName(),
            sources = catalog:getActiveSources(),
            active = active,
            selection = active and catalog:getTargetPhotos() or {},
        }
        local ok, result = LrTasks.pcall(function()
            LrApplicationView.switchToModule("library")
            LrApplicationView.gridView()
            catalog:setActiveSources({ catalog.kAllPhotos })
            catalog:setSelectedPhotos(photos[1], photos)
            if not DevelopSession.waitFor(function() return sameSelection(catalog, photos) end, 10) then
                error("Lightroom did not select exactly the requested photos; nothing was removed")
            end
            if LrApplicationView.getCurrentModuleName() ~= "library" or not sameSelection(catalog, photos) then
                error("The selection changed; nothing was removed")
            end
            LrSelection.removeFromCatalog()
            if not DevelopSession.waitFor(function() return #surviving(catalog, photos) == 0 end, 10) then
                error("Lightroom did not remove every requested photo; check the catalog before retrying")
            end
            return { success = true, removed = #photos, missing = missing }
        end)
        local restored, restoreError = LrTasks.pcall(restore, catalog, view)
        if not restored then
            error((ok and "Photos removed" or tostring(result))
                .. "; could not restore selection: " .. tostring(restoreError))
        end
        if not ok then error(result, 0) end
        return result
    end)
end

return Handler
