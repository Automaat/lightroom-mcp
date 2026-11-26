local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'

local KeywordTree = require 'KeywordTree'
local Log = require 'Log'

local KeywordsHandler = {}

-- Lists the catalog's keyword hierarchy as a flat, paginated list of full
-- paths, so a client can pick existing keywords (set_keywords accepts the same
-- "Parent|Child" paths) instead of guessing names and creating duplicates.
-- A hierarchy can hold thousands of keywords, so `query` narrows the list to
-- keywords whose name or a synonym contains the text, and `paths_only` returns
-- bare path strings instead of one object per keyword.
function KeywordsHandler.listKeywords(args)
    args = args or {}
    local catalog = LrApplication.activeCatalog()

    local limit = math.floor(tonumber(args.limit) or 100)
    if limit < 0 then limit = 0 end
    local offset = math.floor(tonumber(args.offset) or 0)
    if offset < 0 then offset = 0 end

    local parentParts = nil
    if args.parent ~= nil then
        if type(args.parent) ~= "string" or args.parent:match("^%s*$") then
            error("parent must be a keyword path")
        end
        parentParts = KeywordTree.split(args.parent)
    end

    local query = nil
    if args.query ~= nil then
        if type(args.query) ~= "string" or args.query:match("^%s*$") then
            error("query must be a non-empty string")
        end
        query = KeywordTree.fold(args.query)
    end

    if args.paths_only ~= nil and type(args.paths_only) ~= "boolean" then
        error("paths_only must be a boolean")
    end
    local pathsOnly = args.paths_only == true

    local function matches(name, synonyms)
        if not query then return true end
        if KeywordTree.fold(name):find(query, 1, true) then return true end
        for _, synonym in ipairs(synonyms) do
            if KeywordTree.fold(synonym):find(query, 1, true) then return true end
        end
        return false
    end

    local total = 0
    local slice = {}

    catalog:withReadAccessDo(function()
        local root = nil
        if parentParts then
            root = KeywordTree.resolve(catalog, parentParts)
            if not root then
                error("Keyword not found: " .. KeywordTree.join(parentParts))
            end
        end

        KeywordTree.walk(catalog, root, function(keyword, path, attributes)
            local name = attributes.keywordName or keyword:getName()
            local synonyms = attributes.synonyms or {}
            if query and not matches(name, synonyms) then return end

            total = total + 1
            if total > offset and #slice < limit then
                if pathsOnly then
                    table.insert(slice, path)
                else
                    table.insert(slice, {
                        path = path,
                        name = name,
                        synonyms = synonyms,
                        includeOnExport = attributes.includeOnExport,
                    })
                end
            end
        end)
    end)

    Log.info(string.format("Found %d keywords, returning %d (offset=%d, limit=%d)",
        total, #slice, offset, limit))

    return {
        count = total,
        keywords = slice,
        has_more = (offset + #slice) < total,
    }
end

-- Returns a function(catalog) that resolves `ref` to exactly one keyword: a
-- "Parent|Child" path addresses it directly, a plain name must match exactly
-- one keyword. Call it inside a gate; it errors when nothing or several match.
local function keywordFinder(ref)
    local parts = nil
    local name = nil
    if KeywordTree.isPath(ref) then
        parts = KeywordTree.split(ref)
    else
        name = KeywordTree.trim(ref)
    end
    return function(catalog)
        if parts then
            local resolved = KeywordTree.resolve(catalog, parts)
            if not resolved then
                error("Keyword not found: " .. KeywordTree.join(parts))
            end
            return resolved
        end
        local matches = KeywordTree.findByName(catalog, name)
        if #matches == 0 then
            error("Keyword not found: " .. name)
        elseif #matches > 1 then
            local found = {}
            for _, match in ipairs(matches) do
                table.insert(found, match.path)
            end
            error("Keyword is ambiguous, give its path: " .. name
                .. " (" .. table.concat(found, ", ") .. ")")
        end
        return matches[1].keyword
    end
end

-- Renames one keyword in place: every photo tagged with it shows the new name,
-- and its parent, children and synonyms are unchanged. A plain name must match
-- exactly one keyword; a "Parent|Child" path addresses it directly.
function KeywordsHandler.renameKeyword(args)
    if type(args.keyword) ~= "string" or args.keyword:match("^%s*$") then
        error("keyword is required")
    end
    if type(args.new_name) ~= "string" or args.new_name:match("^%s*$") then
        error("new_name is required")
    end

    -- Trimmed like a level of a path, so the keyword is found again by name.
    local newName = KeywordTree.trim(args.new_name)
    if KeywordTree.isPath(newName) then
        error("new_name must be a single keyword name, not a path: " .. newName)
    end

    local findKeyword = keywordFinder(args.keyword)
    local catalog = LrApplication.activeCatalog()
    local keyword, oldPath, newPath, photoCount, tempName

    catalog:withReadAccessDo(function() keyword = findKeyword(catalog) end)
    photoCount = #(keyword:getPhotos() or {})

    catalog:withWriteAccessDo("Rename Keyword", function()
        keyword = findKeyword(catalog)

        local currentName = keyword:getName()
        if currentName == newName then
            error("Keyword is already named '" .. newName .. "'")
        end

        -- Lightroom matches names ignoring case, so a sibling "callie" would
        -- clash with "Callie"; the keyword itself does not.
        local parent = keyword:getParent()
        local clash = KeywordTree.findChild(catalog, parent, newName)
        if clash and clash ~= keyword then
            error("A keyword named '" .. clash:getName() .. "' already exists at "
                .. KeywordTree.pathOf(clash) .. "; rename cannot merge keywords")
        end

        oldPath = KeywordTree.pathOf(keyword)
        -- Built rather than read back: until this transaction commits,
        -- getName() still returns the old name.
        newPath = parent and (KeywordTree.pathOf(parent) .. KeywordTree.SEPARATOR .. newName) or newName
        -- Lightroom silently ignores a rename that changes only the case, so
        -- that goes through a temporary name, committed first.
        if KeywordTree.fold(currentName) == KeywordTree.fold(newName) then
            tempName = newName .. " (renaming)"
            local n = 1
            while KeywordTree.findChild(catalog, parent, tempName) do
                n = n + 1
                tempName = string.format("%s (renaming %d)", newName, n)
            end
            if not keyword:setAttributes({ keywordName = tempName }) then
                error("Lightroom refused to rename keyword '" .. oldPath .. "' to '" .. tempName .. "'")
            end
        else
            if not keyword:setAttributes({ keywordName = newName }) then
                error("Lightroom refused to rename keyword '" .. oldPath .. "' to '" .. newName .. "'")
            end
        end
    end)

    if tempName then
        -- LrTasks.pcall, not pcall: a write gate yields, and Lua 5.1's pcall
        -- cannot yield, so withWriteAccessDo fails inside it with "must be
        -- called from within an LrTask".
        local ok, err = LrTasks.pcall(function()
            catalog:withWriteAccessDo("Rename Keyword", function()
                if not keyword:setAttributes({ keywordName = newName }) then
                    error("Lightroom refused the final rename to '" .. newName .. "'")
                end
            end)
        end)
        if not ok then
            error(string.format("Keyword '%s' was left named '%s' while changing its case: %s",
                oldPath, tempName, tostring(err)))
        end
    end

    Log.info(string.format("Renamed keyword %s to %s (%d photos)", oldPath, newPath, photoCount))

    return {
        success = true,
        old_path = oldPath,
        new_path = newPath,
        photo_count = photoCount,
    }
end

local MAX_SYNONYMS = 100

-- Validates one synonym list argument: an array of strings, each trimmed,
-- non-empty and free of commas (Lightroom's Keyword List edits synonyms as one
-- comma-separated field, so a comma inside a synonym would split it there).
-- Case variants collapse to the first, as Lightroom matches keywords ignoring
-- case. Returns nil when the argument is absent.
local function synonymList(value, field)
    if value == nil then return nil end
    if type(value) ~= "table" then error(field .. " must be an array of strings") end
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    if count ~= #value then error(field .. " must be an array of strings") end
    if #value > MAX_SYNONYMS then
        error(field .. " must contain at most " .. MAX_SYNONYMS .. " synonyms")
    end
    local list, seen = {}, {}
    for _, synonym in ipairs(value) do
        if type(synonym) ~= "string" then error(field .. " must be an array of strings") end
        local trimmed = KeywordTree.trim(synonym)
        if trimmed == "" then error(field .. " contains an empty synonym") end
        if trimmed:find(",", 1, true) then
            error("Synonym '" .. trimmed .. "' contains a comma; give each synonym as its own item")
        end
        local key = KeywordTree.fold(trimmed)
        if not seen[key] then
            seen[key] = true
            list[#list + 1] = trimmed
        end
    end
    return list
end

local function foldedSet(list)
    local set = {}
    for _, item in ipairs(list) do set[KeywordTree.fold(item)] = true end
    return set
end

-- Same strings, in any order: Lightroom may store synonyms in its own order.
local function sameSynonyms(left, right)
    if #left ~= #right then return false end
    local counts = {}
    for _, item in ipairs(left) do counts[item] = (counts[item] or 0) + 1 end
    for _, item in ipairs(right) do
        if not counts[item] or counts[item] == 0 then return false end
        counts[item] = counts[item] - 1
    end
    return true
end

local function copyList(list)
    local result = {}
    for i, item in ipairs(list or {}) do result[i] = item end
    return result
end

-- Replaces a keyword's synonyms (`synonyms`), or edits them (`add_synonyms`,
-- `remove_synonyms`, matched ignoring case). Its name, parent, children and
-- photos are unchanged. The stored list is read back after the write commits.
function KeywordsHandler.setKeywordSynonyms(args)
    args = args or {}
    if type(args.keyword) ~= "string" or args.keyword:match("^%s*$") then
        error("keyword is required")
    end
    local replace = synonymList(args.synonyms, "synonyms")
    local add = synonymList(args.add_synonyms, "add_synonyms")
    local remove = synonymList(args.remove_synonyms, "remove_synonyms")
    if replace and (add or remove) then
        error("Use synonyms, or add_synonyms/remove_synonyms, not both")
    end
    if not replace and not add and not remove then
        error("synonyms, add_synonyms or remove_synonyms is required")
    end
    if add and remove then
        local removing = foldedSet(remove)
        for _, synonym in ipairs(add) do
            if removing[KeywordTree.fold(synonym)] then
                error("Synonym '" .. synonym .. "' is in both add_synonyms and remove_synonyms")
            end
        end
    end

    local function target(current)
        if replace then return replace end
        local removing = foldedSet(remove or {})
        local result, present = {}, {}
        for _, synonym in ipairs(current) do
            local key = KeywordTree.fold(synonym)
            if not removing[key] then
                result[#result + 1] = synonym
                present[key] = true
            end
        end
        for _, synonym in ipairs(add or {}) do
            local key = KeywordTree.fold(synonym)
            if not present[key] then
                result[#result + 1] = synonym
                present[key] = true
            end
        end
        return result
    end

    local findKeyword = keywordFinder(args.keyword)
    local catalog = LrApplication.activeCatalog()
    local keyword, path, previous, wanted

    -- An unchanged list writes nothing, so it adds no undo step.
    catalog:withReadAccessDo(function()
        keyword = findKeyword(catalog)
        path = KeywordTree.pathOf(keyword)
        previous = copyList(keyword:getSynonyms())
    end)
    wanted = target(previous)
    if sameSynonyms(wanted, previous) then
        return { success = true, path = path, changed = false,
            synonyms = previous, previous_synonyms = previous }
    end

    catalog:withWriteAccessDo("Set Keyword Synonyms", function()
        keyword = findKeyword(catalog)
        path = KeywordTree.pathOf(keyword)
        -- Recomputed from the list as it is now, in case it changed since.
        previous = copyList(keyword:getSynonyms())
        wanted = target(previous)
        if not keyword:setAttributes({ synonyms = wanted }) then
            error("Lightroom refused to set the synonyms of keyword '" .. path .. "'")
        end
    end)

    local stored
    catalog:withReadAccessDo(function()
        stored = copyList(keyword:getSynonyms())
    end)
    if not sameSynonyms(stored, wanted) then
        error(string.format("Keyword '%s' stored synonyms [%s] instead of [%s]",
            path, table.concat(stored, ", "), table.concat(wanted, ", ")))
    end

    Log.info(string.format("Set synonyms of keyword %s: %d -> %d", path, #previous, #stored))

    return {
        success = true,
        path = path,
        changed = true,
        synonyms = stored,
        previous_synonyms = previous,
    }
end

return KeywordsHandler
