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
-- Pure helper namespaces every spec gets unless it installs its own. lower is
-- ASCII-only here; Lightroom's folds Unicode.
local defaultImports = {
    LrStringUtils = { lower = string.lower },
}

function M.installImport(modules)
    _G.import = function(name)
        local m = modules[name]
        if m == nil then m = defaultImports[name] end
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
-- non-validating mock used to return a value for any key, so a typo'd/invalid key
-- (e.g. `copyrightStatus` for `copyrightState`) shipped green. Validate against
-- this allowlist so specs catch it. Add genuinely-new SDK keys here.
local VALID_METADATA_KEYS = {}
for _, key in ipairs({
    -- File / catalog
    "fileName", "fileSize", "fileFormat", "path", "dimensions",
    "rating", "colorNameForLabel", "pickStatus", "keywords",
    "uuid", "isVirtualCopy", "croppedDimensions", "dateTimeOriginalISO8601",
    "masterPhoto", "virtualCopies", "orientation",
    -- EXIF
    "dateTimeOriginal", "dateTimeDigitized", "cameraMake", "cameraModel",
    "cameraSerialNumber", "lens", "isoSpeedRating", "focalLength",
    "focalLength35mm", "aperture", "shutterSpeed", "exposureBias",
    "exposureProgram", "meteringMode", "flash", "artist", "software",
    "gps", "gpsAltitude",
    -- IPTC content / location / rights
    "title", "caption", "headline", "location", "city", "stateProvince",
    "country", "isoCountryCode", "creator", "copyright", "copyrightState",
    "rightsUsageTerms", "copyrightInfoUrl", "creatorUrl",
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
    if meta.uuid == nil and not meta.__dangling then
        meta.uuid = "uuid-" .. tostring(meta.localIdentifier or meta.id or "photo-id")
    end
    local photo = {
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
        applyDevelopPreset = function(_, preset, plugin)
            meta.__appliedPreset = preset
            meta.__appliedPresetPlugin = plugin
        end,
        applyDevelopSettings = function(_, settings, historyName, flattenAutoNow)
            meta.__appliedSettings = settings
            meta.__appliedHistoryName = historyName
            meta.__appliedFlattenAutoNow = flattenAutoNow
        end,
    }
    -- Opt in with aiUpdate = "ok" | "fail"; absent models LrC before 13.3.
    if meta.aiUpdate then
        photo.updateAISettings = function()
            meta.__aiUpdateCalls = (meta.__aiUpdateCalls or 0) + 1
            meta.__aiUpdateAfterSettings = meta.__appliedSettings
            meta.__aiUpdateAfterPreset = meta.__appliedPreset
            if meta.aiUpdate == "fail" then error("AI update failed") end
        end
    end
    return photo
end

-- Build a fake keyword. opts: parent (fake keyword), synonyms, includeOnExport,
-- photos (what getPhotos returns).
-- Registers itself with its parent so getChildren() sees it, as a keyword that
-- already exists in the catalog would be.
function M.fakeKeyword(name, opts)
    opts = opts or {}
    local children = {}
    local kw = {
        getName = function() return name end,
        getParent = function() return opts.parent end,
        getChildren = function() return children end,
        getSynonyms = function() return opts.synonyms or {} end,
        getPhotos = function() return opts.photos or {} end,
        -- Only keywordName is modelled. Like Lightroom, a rename that changes
        -- only the case is ignored. Applied at once: the fake has no
        -- transactions to defer it to.
        setAttributes = function(_, attributes)
            local newName = attributes.keywordName
            if newName and newName:lower() ~= name:lower() then
                name = newName
            end
            return true
        end,
        getAttributes = function()
            return {
                keywordName = name,
                synonyms = opts.synonyms or {},
                includeOnExport = opts.includeOnExport ~= false,
            }
        end,
        __addChild = function(_, child) table.insert(children, child) end,
    }
    if opts.parent and not opts.detached then
        opts.parent:__addChild(kw)
    end
    return kw
end

-- Counts getName() calls on each of `keywords` (fake keywords), keyed by the
-- name it had when wrapped. Reading names is what makes keyword lookup slow on
-- a large catalog, so specs count it.
function M.countNameReads(keywords)
    local reads = {}
    for _, kw in ipairs(keywords) do
        local getName = kw.getName
        local name = getName(kw)
        reads[name] = 0
        kw.getName = function(self)
            reads[name] = reads[name] + 1
            return getName(self)
        end
    end
    return reads
end

-- Build a fake collection.
-- opts (optional): smart = true for a smart collection.
function M.fakeFolder(path, photos, children)
    return {
        getPath = function() return path end,
        getName = function() return path:match("[^/]+$") end,
        getChildren = function() return children or {} end,
        getPhotos = function(_, includeChildren)
            local result = {}
            for _, photo in ipairs(photos or {}) do table.insert(result, photo) end
            if includeChildren then
                for _, child in ipairs(children or {}) do
                    for _, photo in ipairs(child:getPhotos(true)) do table.insert(result, photo) end
                end
            end
            return result
        end,
    }
end

function M.fakeCollection(name, photos, opts)
    photos = photos or {}
    opts = opts or {}
    local addedPhotos = {}
    local removedPhotos = {}
    local deleted = false
    return {
        getName = function() return name end,
        type = function() return "LrCollection" end,
        isSmartCollection = function() return opts.smart == true end,
        getPhotos = function() return photos end,
        addPhotos = function(_, ps)
            for _, p in ipairs(ps) do
                table.insert(addedPhotos, p)
                table.insert(photos, p)
            end
        end,
        removePhotos = function(_, ps)
            for _, p in ipairs(ps) do
                table.insert(removedPhotos, p)
                for i = #photos, 1, -1 do
                    if photos[i] == p then table.remove(photos, i) end
                end
            end
        end,
        delete = function() deleted = true end,
        getAddedPhotos = function() return addedPhotos end,
        getRemovedPhotos = function() return removedPhotos end,
        isDeleted = function() return deleted end,
    }
end

-- Build a fake collection set. opts: parent (fake set), collections, sets.
-- Registers itself with its parent so getChildCollectionSets() sees it, as a
-- set that already exists in the catalog would be, unless detached.
function M.fakeCollectionSet(name, opts)
    opts = opts or {}
    local collections = opts.collections or {}
    local sets = opts.sets or {}
    local set = {}
    -- The catalog installs __readGuard on sets it creates, to model the SDK
    -- refusing reads in the transaction that created them.
    local function read(value)
        if set.__readGuard then set.__readGuard() end
        return value
    end
    set.getName = function() return read(name) end
    set.type = function() return "LrCollectionSet" end
    set.getParent = function() return read(opts.parent) end
    set.getChildCollections = function() return read(collections) end
    set.getChildCollectionSets = function() return read(sets) end
    -- Unguarded, for the fake catalog's own bookkeeping.
    set.__name = function() return name end
    set.__childCollections = function() return collections end
    set.__childSets = function() return sets end
    if opts.parent and not opts.detached then
        table.insert(opts.parent.__childSets(), set)
    end
    return set
end

local function removeValue(list, value)
    for i = #list, 1, -1 do
        if list[i] == value then table.remove(list, i) end
    end
end

-- Build a fake catalog. opts:
--   photos: array of fake photos
--   collections: array of fake collections
--   collectionSets: array of fake collection sets
--   keywords: array of top-level fake keywords
function M.fakeCatalog(opts)
    opts = opts or {}
    local photos = opts.photos or {}
    local collections = opts.collections or {}
    local collectionSets = opts.collectionSets or {}
    local createdCollections = {}
    local createdCollectionSets = {}
    local createdKeywords = {}
    local topKeywords = opts.keywords or {}
    local pendingKeywords = {}
    local setsCreatedInWrite = {}
    local undoInWrite = {}
    local readAccessCount = 0
    local writeAccessCount = 0
    -- Tracks whether a catalog query (getTargetPhotos/findPhotos/getAllPhotos/
    -- findPhotoByPath) was invoked while a withReadAccessDo gate was open. The Windows deadlock
    -- (#134/#124) is exactly that nesting, so handlers must keep their query
    -- OUTSIDE the gate; specs assert getQueriedInsideReadAccess() == false.
    local insideReadAccess = false
    local queriedInsideReadAccess = false
    -- Same nesting, write side. withWriteAccessDo is an EXCLUSIVE gate, so a
    -- full-catalog scan held inside it serializes every other handler behind a
    -- scan that writes nothing. Handlers must resolve their photos BEFORE
    -- opening the gate; specs assert getQueriedInsideWriteAccess() == false.
    local insideWriteAccess = false
    local queriedInsideWriteAccess = false
    local selectionCall = nil
    -- How MANY catalog scans ran, not just where. A handler that can reject bad
    -- input before scanning should prove it never scanned.
    local queryCount = 0
    local function markQuery()
        queryCount = queryCount + 1
        if insideReadAccess then queriedInsideReadAccess = true end
        if insideWriteAccess then queriedInsideWriteAccess = true end
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
        elseif (crit == "camera" or crit == "lens" or crit == "isoSpeedRating" or crit == "focalLength"
            or crit == "pick" or crit == "labelColor" or crit == "fileFormat") and op == "==" then
            local keys = { camera = "cameraModel", pick = "pickStatus", labelColor = "colorNameForLabel" }
            local value = photo:getRawMetadata(keys[crit] or crit)
            if crit == "labelColor" then
                local colors = { red = 1, yellow = 2, green = 3, blue = 4, purple = 5, none = "none" }
                value = colors[value or "none"]
            end
            return value == criterion.value
        elseif crit == "hasAdjustments" and (op == "isTrue" or op == "isFalse") then
            return (photo:getRawMetadata('__hasAdjustments') == true) == (op == "isTrue")
        elseif crit == "folder" and op == "all" then
            local folder = (photo:getRawMetadata('path') or ""):match("^(.*)/[^/]+$") or ""
            folder = folder:lower()
            for word in criterion.value:lower():gmatch("%S+") do
                if not folder:find(word, 1, true) then return false end
            end
            return true
        elseif crit == "captureTime" then
            local t = photo:getRawMetadata('dateTimeOriginal')
            if not t then return false end
            if op == "in" then
                return t >= criterion.value and t <= criterion.value2
            elseif op == ">" then
                return t > criterion.value
            elseif op == "<" then
                return t < criterion.value
            end
        end
        error("fakeCatalog.findPhotos: unsupported criterion " .. tostring(crit) .. "/" .. tostring(op))
    end

    return {
        getAllPhotos = function() markQuery() return photos end,
        getPhotoByLocalId = function(_, id)
            markQuery()
            for _, photo in ipairs(photos) do
                if tostring(photo.localIdentifier) == tostring(id) then return photo end
            end
            return M.fakePhoto({ id = id, __dangling = true })
        end,
        getTargetPhotos = function() markQuery() return opts.targetPhotos or photos end,
        findPhotoByPath = function(_, path)
            markQuery()
            for _, photo in ipairs(photos) do
                if photo:getRawMetadata('path') == path then return photo end
            end
            return nil
        end,
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
        batchGetRawMetadata = function(_, list, keys)
            local out = {}
            for _, photo in ipairs(list) do
                local values = {}
                for _, key in ipairs(keys) do values[key] = photo:getRawMetadata(key) end
                out[photo] = values
            end
            return out
        end,
        batchGetFormattedMetadata = function(_, list, keys)
            local out = {}
            for _, photo in ipairs(list) do
                local values = {}
                for _, key in ipairs(keys) do values[key] = photo:getFormattedMetadata(key) end
                out[photo] = values
            end
            return out
        end,
        getFolders = function() return opts.folders or {} end,
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
        -- For queries that live off the catalog (a smart collection's
        -- getPhotos) and so cannot call markQuery themselves.
        isInsideReadAccess = function() return insideReadAccess end,
        setSelectedPhotos = function(_, activePhoto, selected)
            markQuery()
            selectionCall = { active = activePhoto, photos = selected }
        end,
        getSelectionCall = function() return selectionCall end,
        withWriteAccessDo = function(_, _, fn)
            writeAccessCount = writeAccessCount + 1
            insideWriteAccess = true
            pendingKeywords = {}
            setsCreatedInWrite = {}
            undoInWrite = {}
            local ok, err = pcall(fn)
            insideWriteAccess = false
            setsCreatedInWrite = {}
            -- Lightroom rolls back a failed transaction, including the
            -- collections and sets it created.
            local undo = undoInWrite
            undoInWrite = {}
            if not ok then
                for i = #undo, 1, -1 do undo[i]() end
            end
            -- Keywords created in the transaction become visible once it
            -- commits; a failed transaction leaves none behind.
            local pending = pendingKeywords
            pendingKeywords = {}
            if not ok then error(err, 0) end
            for _, kw in ipairs(pending) do
                createdKeywords[#createdKeywords + 1] = kw
                if kw:getParent() then
                    kw:getParent():__addChild(kw)
                else
                    table.insert(topKeywords, kw)
                end
            end
        end,
        getQueriedInsideWriteAccess = function() return queriedInsideWriteAccess end,
        findPhotoByLocalIdentifier = function(_, id)
            local target = tostring(id)
            for _, p in ipairs(photos) do
                if tostring(p.localIdentifier) == target then return p end
            end
            return nil
        end,
        createCollection = function(_, name, parent, canReturnPrior)
            if not insideWriteAccess then
                error("createCollection outside withWriteAccessDo")
            end
            local siblings = parent and parent.__childCollections() or collections
            local siblingSets = parent and parent.__childSets() or collectionSets
            -- Live Lightroom: an exact duplicate returns nil (or the prior
            -- collection), a case-only variant raises, and a sibling set of
            -- the same name returns nil.
            for _, c in ipairs(siblings) do
                if c:getName() == name then
                    if canReturnPrior then return c end
                    return nil
                end
                if c:getName():lower() == name:lower() then
                    error("name is not unique: " .. name)
                end
            end
            for _, set in ipairs(siblingSets) do
                if set.__name():lower() == name:lower() then return nil end
            end
            local c = M.fakeCollection(name, {})
            table.insert(createdCollections, c)
            table.insert(siblings, c)
            table.insert(undoInWrite, function()
                removeValue(createdCollections, c)
                removeValue(siblings, c)
            end)
            return c
        end,
        -- Models the SDK restriction the handler has to work around: a set
        -- created in a write transaction cannot be read (name, children) until
        -- that transaction ends; Lightroom raises the error below. It can still
        -- be passed as the parent of further sets in the same transaction.
        createCollectionSet = function(_, name, parent, canReturnPrior)
            if not insideWriteAccess then
                error("createCollectionSet outside withWriteAccessDo")
            end
            local siblings = parent and parent.__childSets() or collectionSets
            local siblingCollections = parent and parent.__childCollections() or collections
            -- Live Lightroom: a case-only variant of a sibling set raises, and
            -- a sibling collection of the same name returns nil.
            for _, set in ipairs(siblings) do
                local setName = set.__name()
                if setName == name then
                    if canReturnPrior then return set end
                    return nil
                end
                if setName:lower() == name:lower() then
                    error("name is not unique: " .. name)
                end
            end
            for _, c in ipairs(siblingCollections) do
                if c:getName():lower() == name:lower() then return nil end
            end
            local set = M.fakeCollectionSet(name, { parent = parent, detached = true })
            set.__readGuard = function()
                if setsCreatedInWrite[set] then
                    error("Can't get collection information after creating collection"
                        .. " inside the same withWriteAccessDo function")
                end
            end
            setsCreatedInWrite[set] = true
            table.insert(createdCollectionSets, set)
            table.insert(siblings, set)
            table.insert(undoInWrite, function()
                removeValue(createdCollectionSets, set)
                removeValue(siblings, set)
            end)
            return set
        end,
        getKeywords = function() return topKeywords end,
        -- Models the SDK behaviour the handlers have to work around: a keyword
        -- created in a write transaction is invisible to getKeywords() and
        -- getChildren() until it commits, cannot be used as a parent before
        -- then, and creating the same name twice in one transaction asserts.
        -- returnExisting matches committed keywords ignoring case.
        createKeyword = function(_, name, synonyms, includeOnExport, parent, returnExisting)
            if not insideWriteAccess then
                error("createKeyword outside withWriteAccessDo")
            end
            for _, kw in ipairs(pendingKeywords) do
                if kw == parent then
                    error("bad argument #2 to 'format' (number expected, got string)")
                end
                if kw:getParent() == parent and kw:getName():lower() == name:lower() then
                    error("createKeyword: " .. name .. " already created in this transaction")
                end
            end
            if returnExisting then
                local siblings = parent and parent:getChildren() or topKeywords
                for _, kw in ipairs(siblings) do
                    if kw:getName():lower() == name:lower() then return kw end
                end
            end
            local kw = M.fakeKeyword(name, {
                parent = parent,
                synonyms = synonyms,
                includeOnExport = includeOnExport,
                detached = true,
            })
            table.insert(pendingKeywords, kw)
            return kw
        end,
        addPhoto = function(_, path)
            local p = M.fakePhoto({ path = path, id = path })
            table.insert(photos, p)
            return p
        end,
        getCreatedCollections = function() return createdCollections end,
        getCreatedCollectionSets = function() return createdCollectionSets end,
        getCreatedKeywords = function() return createdKeywords end,
        getReadAccessCount = function() return readAccessCount end,
        getWriteAccessCount = function() return writeAccessCount end,
        getQueryCount = function() return queryCount end,
    }
end

return M
