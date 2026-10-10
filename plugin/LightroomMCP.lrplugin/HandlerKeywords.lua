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

        KeywordTree.walk(catalog, root, function(keyword, path)
            local name = keyword:getName()
            -- Synonyms are only read when something needs them.
            local synonyms = nil
            if query then
                synonyms = keyword:getSynonyms() or {}
                if not matches(name, synonyms) then return end
            end

            total = total + 1
            if total > offset and #slice < limit then
                if pathsOnly then
                    table.insert(slice, path)
                else
                    local attributes = keyword:getAttributes() or {}
                    table.insert(slice, {
                        path = path,
                        name = name,
                        synonyms = synonyms or keyword:getSynonyms() or {},
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

    local parts = nil
    local oldName = nil
    if KeywordTree.isPath(args.keyword) then
        parts = KeywordTree.split(args.keyword)
    else
        oldName = KeywordTree.trim(args.keyword)
    end

    local catalog = LrApplication.activeCatalog()
    local keyword, oldPath, newPath, photoCount, tempName

    catalog:withWriteAccessDo("Rename Keyword", function()
        if parts then
            keyword = KeywordTree.resolve(catalog, parts)
            if not keyword then
                error("Keyword not found: " .. KeywordTree.join(parts))
            end
        else
            local matches = KeywordTree.findByName(catalog, oldName)
            if #matches == 0 then
                error("Keyword not found: " .. oldName)
            elseif #matches > 1 then
                local found = {}
                for _, match in ipairs(matches) do
                    table.insert(found, match.path)
                end
                error("Keyword is ambiguous, give its path: " .. oldName
                    .. " (" .. table.concat(found, ", ") .. ")")
            end
            keyword = matches[1].keyword
        end

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
        photoCount = #(keyword:getPhotos() or {})

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
        message = string.format("Renamed keyword '%s' to '%s' (%d photos)", oldPath, newPath, photoCount)
    }
end

return KeywordsHandler
