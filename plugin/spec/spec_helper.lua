-- Common test helpers + LR SDK mock factory.
-- Usage from a spec file:
--   local helper = require 'spec.spec_helper'
--   local catalog, photos = helper.mockCatalog({...})
--   helper.installImport({ LrApplication = { activeCatalog = function() return catalog end } })
--   local Handler = require 'HandlerSearch'

local M = {}

-- Make plugin sources requireable.
local lfs_ok = pcall(function() return require 'lfs' end)
local sep = package.config:sub(1, 1)
local pluginRoot = "plugin" .. sep .. "LightroomMCP.lrplugin" .. sep .. "?.lua"
if not package.path:find(pluginRoot, 1, true) then
    package.path = package.path .. ";" .. pluginRoot
end

-- Install a mock `import` global. Subsequent `import 'X'` calls return the mock for X.
function M.installImport(modules)
    _G.import = function(name)
        local m = modules[name]
        if m == nil then
            error("No mock installed for import('" .. tostring(name) .. "')", 2)
        end
        return m
    end
end

-- Default LrLogger stub used by every handler.
function M.defaultLrLogger()
    return setmetatable({}, {
        __call = function()
            return {
                info = function() end,
                warn = function() end,
                error = function() end,
                enable = function() end,
            }
        end,
    })
end

-- Valid Lightroom SDK metadata keys. The real getRawMetadata/getFormattedMetadata
-- THROW on an unsupported key, taking down the enclosing withReadAccessDo. The
-- unvalidating mock used to return a value for any key, so a typo'd/invalid key
-- (e.g. `copyrightStatus` for `copyrightState`) shipped green. Validate against
-- this allowlist so specs catch it. Add genuinely-new SDK keys here.
local VALID_METADATA_KEYS = {}
for _, key in ipairs({
    -- File / catalog
    "fileName", "fileSize", "fileFormat", "path", "dimensions",
    "rating", "colorNameForLabel", "pickStatus", "keywords",
    -- EXIF
    "dateTimeOriginal", "dateTimeDigitized", "cameraMake", "cameraModel",
    "cameraSerialNumber", "lens", "isoSpeedRating", "focalLength",
    "focalLength35mm", "aperture", "shutterSpeed", "exposureBias",
    "exposureProgram", "meteringMode", "flash", "artist", "software",
    "gps", "gpsAltitude",
    -- IPTC content / location / rights
    "title", "caption", "headline", "location", "city", "stateProvince",
    "country", "isoCountryCode", "creator", "copyright", "copyrightState",
    "rightsUsageTerms",
}) do
    VALID_METADATA_KEYS[key] = true
end
M.VALID_METADATA_KEYS = VALID_METADATA_KEYS

local function readMetadata(meta, key)
    -- `__`-prefixed keys are test-internal sentinels (e.g. __appliedSettings)
    -- that specs read back to assert what a handler wrote; never SDK keys.
    if key:sub(1, 2) ~= "__" and not VALID_METADATA_KEYS[key] then
        error("unsupported metadata key '" .. tostring(key)
            .. "' (add it to spec_helper VALID_METADATA_KEYS if it is a real SDK key)", 2)
    end
    return meta[key]
end

-- Build a fake photo with the given metadata table.
-- meta keys correspond to keys passed to getRawMetadata / getFormattedMetadata / localIdentifier.
function M.fakePhoto(meta)
    return {
        localIdentifier = meta.localIdentifier or meta.id or "photo-id",
        getRawMetadata = function(_, key) return readMetadata(meta, key) end,
        getFormattedMetadata = function(_, key) return readMetadata(meta, key) end,
        getDevelopSettings = function() return meta.developSettings or {} end,
        addKeyword = function(_, kw)
            meta.__addedKeywords = meta.__addedKeywords or {}
            table.insert(meta.__addedKeywords, kw)
        end,
        removeKeyword = function(_, kw)
            meta.__removedKeywords = meta.__removedKeywords or {}
            table.insert(meta.__removedKeywords, kw)
        end,
        setRawMetadata = function(_, key, value) meta[key] = value end,
        applyDevelopPreset = function(_, preset)
            meta.__appliedPreset = preset
        end,
        applyDevelopSettings = function(_, settings)
            meta.__appliedSettings = settings
        end,
    }
end

-- Build a fake collection.
function M.fakeCollection(name, photos)
    photos = photos or {}
    local addedPhotos = {}
    return {
        getName = function() return name end,
        type = function() return "LrCollection" end,
        getPhotos = function() return photos end,
        addPhotos = function(_, ps)
            for _, p in ipairs(ps) do
                table.insert(addedPhotos, p)
                table.insert(photos, p)
            end
        end,
        getAddedPhotos = function() return addedPhotos end,
    }
end

-- Build a fake catalog. opts:
--   photos: array of fake photos
--   collections: array of fake collections
--   collectionSets: array of fake collection sets
function M.fakeCatalog(opts)
    opts = opts or {}
    local photos = opts.photos or {}
    local collections = opts.collections or {}
    local collectionSets = opts.collectionSets or {}
    local createdCollections = {}
    local createdKeywords = {}
    local readAccessCount = 0
    local writeAccessCount = 0
    -- Tracks whether a catalog query (getTargetPhotos/findPhotos/getAllPhotos)
    -- was invoked while a withReadAccessDo gate was open. The Windows deadlock
    -- (#134/#124) is exactly that nesting, so handlers must keep their query
    -- OUTSIDE the gate; specs assert getQueriedInsideReadAccess() == false.
    local insideReadAccess = false
    local queriedInsideReadAccess = false
    local function markQuery()
        if insideReadAccess then queriedInsideReadAccess = true end
    end

    local function photoMatches(photo, criterion)
        local crit = criterion.criteria
        local op = criterion.operation
        if crit == "filename" and op == "any" then
            local name = photo:getFormattedMetadata('fileName')
            if not name then return false end
            return name:lower():find(criterion.value:lower(), 1, true) ~= nil
        elseif crit == "rating" and op == "==" then
            return photo:getRawMetadata('rating') == criterion.value
        elseif crit == "rating" and op == ">=" then
            local r = photo:getRawMetadata('rating')
            return r ~= nil and r >= criterion.value
        elseif crit == "keywords" and op == "all" then
            local kws = photo:getRawMetadata('keywords') or {}
            local target = criterion.value:lower()
            for _, kw in ipairs(kws) do
                if kw:getName():lower() == target then return true end
            end
            return false
        elseif crit == "captureTime" then
            local t = photo:getRawMetadata('dateTimeOriginal')
            if not t then return false end
            if op == "inRange" then
                return t >= criterion.value and t <= criterion.value2
            elseif op == ">=" then
                return t >= criterion.value
            elseif op == "<=" then
                return t <= criterion.value
            end
        end
        error("fakeCatalog.findPhotos: unsupported criterion " .. tostring(crit) .. "/" .. tostring(op))
    end

    return {
        getAllPhotos = function() markQuery() return photos end,
        getTargetPhotos = function() markQuery() return opts.targetPhotos or photos end,
        findPhotos = function(_, opts)
            markQuery()
            local desc = opts and opts.searchDesc or {}
            local out = {}
            for _, photo in ipairs(photos) do
                local ok = true
                for _, criterion in ipairs(desc) do
                    if not photoMatches(photo, criterion) then
                        ok = false
                        break
                    end
                end
                if ok then table.insert(out, photo) end
            end
            return out
        end,
        getChildCollections = function() return collections end,
        getChildCollectionSets = function() return collectionSets end,
        withReadAccessDo = function(_, fn)
            readAccessCount = readAccessCount + 1
            insideReadAccess = true
            local ok, err = pcall(fn)
            insideReadAccess = false
            if not ok then error(err, 0) end
        end,
        getQueriedInsideReadAccess = function() return queriedInsideReadAccess end,
        withWriteAccessDo = function(_, _, fn)
            writeAccessCount = writeAccessCount + 1
            fn()
        end,
        findPhotoByLocalIdentifier = function(_, id)
            local target = tostring(id)
            for _, p in ipairs(photos) do
                if tostring(p.localIdentifier) == target then return p end
            end
            return nil
        end,
        createCollection = function(_, name)
            local c = M.fakeCollection(name, {})
            table.insert(createdCollections, c)
            table.insert(collections, c)
            return c
        end,
        createKeyword = function(_, name)
            local kw = { getName = function() return name end }
            table.insert(createdKeywords, kw)
            return kw
        end,
        addPhoto = function(_, path)
            local p = M.fakePhoto({ path = path, id = path })
            table.insert(photos, p)
            return p
        end,
        getCreatedCollections = function() return createdCollections end,
        getCreatedKeywords = function() return createdKeywords end,
        getReadAccessCount = function() return readAccessCount end,
        getWriteAccessCount = function() return writeAccessCount end,
    }
end

return M
