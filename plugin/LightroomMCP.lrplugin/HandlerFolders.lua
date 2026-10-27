local LrApplication = import 'LrApplication'
local PhotoSummary = require 'PhotoSummary'

local FoldersHandler = {}

local function pageBounds(args)
    return math.max(0, math.floor(tonumber(args.limit) or 100)),
        math.max(0, math.floor(tonumber(args.offset) or 0))
end

local function foldersInTreeOrder(catalog)
    local all = {}
    local paths = {}
    local function visit(folder)
        local path = folder:getPath()
        if paths[path] then
            error("Duplicate folder path in catalog: " .. path)
        end
        paths[path] = true
        table.insert(all, { folder = folder, path = path, name = folder:getName() })
        for _, child in ipairs(folder:getChildren() or {}) do
            visit(child)
        end
    end
    for _, folder in ipairs(catalog:getFolders() or {}) do
        visit(folder)
    end
    if #all == 0 and #(catalog:getAllPhotos() or {}) > 0 then
        error("Catalog has photos but returned no root folders")
    end
    return all
end

function FoldersHandler.listFolders(args)
    args = args or {}
    local limit, offset = pageBounds(args)
    local all = foldersInTreeOrder(LrApplication.activeCatalog())
    local folders = {}
    for i = offset + 1, math.min(offset + limit, #all) do
        local entry = all[i]
        table.insert(folders, {
            path = entry.path,
            name = entry.name,
            photo_count = #(entry.folder:getPhotos(false) or {}),
        })
    end
    return { count = #all, folders = folders, has_more = offset + #folders < #all }
end

function FoldersHandler.getFolderPhotos(args)
    args = args or {}
    if type(args.folder_path) ~= "string" or args.folder_path == "" then
        error("folder_path is required")
    end
    local catalog = LrApplication.activeCatalog()
    local target
    for _, entry in ipairs(foldersInTreeOrder(catalog)) do
        if entry.path == args.folder_path then target = entry.folder end
    end
    if not target then error("Folder not found: " .. args.folder_path) end
    local photos = target:getPhotos(args.include_subfolders == true) or {}
    local limit, offset = pageBounds(args)
    local results = PhotoSummary.page(catalog, photos, offset + 1, math.min(offset + limit, #photos), true)
    return { count = #photos, photos = results, has_more = offset + #results < #photos }
end

return FoldersHandler
