local PhotoSources = {}

-- The photos' own folders, a lighter source than All Photographs on a large
-- catalog. Returns nil when any folder cannot be resolved or is not on a
-- mounted drive, so callers fall back to All Photographs.
function PhotoSources.folders(catalog, photos)
    -- Imported per call: callers' specs install their own SDK mocks.
    local LrFileUtils, LrPathUtils, LrTasks = import 'LrFileUtils', import 'LrPathUtils', import 'LrTasks'
    local ok, raw = LrTasks.pcall(function() return catalog:batchGetRawMetadata(photos, { 'path' }) end)
    if not ok or type(raw) ~= "table" then return nil end
    local folders, seen = {}, {}
    for _, photo in ipairs(photos) do
        local path = (raw[photo] or {}).path
        if type(path) ~= "string" then return nil end
        local parent = LrPathUtils.parent(path)
        if not parent then return nil end
        if not seen[parent] then
            -- An unmounted folder as the active source opens Lightroom's
            -- "folder could not be found" alert, which blocks the plugin.
            local mounted, kind = LrTasks.pcall(LrFileUtils.exists, parent)
            if not mounted or kind ~= "directory" then return nil end
            local found, folder = LrTasks.pcall(function() return catalog:getFolderByPath(parent) end)
            if not found or not folder then return nil end
            seen[parent] = true
            folders[#folders + 1] = folder
        end
    end
    return folders
end

-- The folders, or All Photographs when any folder cannot be resolved.
function PhotoSources.foldersOrAll(catalog, photos)
    return PhotoSources.folders(catalog, photos) or { catalog.kAllPhotos }
end

return PhotoSources
