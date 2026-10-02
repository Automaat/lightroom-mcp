local LrApplication = import 'LrApplication'

local KeywordTree = require 'KeywordTree'
local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'

local OrganizationHandler = {}
local MAX_KEYWORDS_PER_REQUEST = 1000

local function validateKeywordLimit(keywords, fieldName)
    if keywords and #keywords > MAX_KEYWORDS_PER_REQUEST then
        error(fieldName .. " must contain at most " .. MAX_KEYWORDS_PER_REQUEST .. " keywords")
    end
end

-- Splits the requested keywords into plain names and hierarchy paths.
-- A string containing "|" is a parent-first path ("Places|Europe|Paris");
-- anything else is a plain name, handled exactly as before paths existed.
local function parseKeywordList(keywords)
    local entries = {}
    local seen = {}
    for _, kw in ipairs(keywords or {}) do
        local entry, dedupeKey
        if KeywordTree.isPath(kw) then
            local parts = KeywordTree.split(kw)
            entry = { parts = parts, key = KeywordTree.join(parts) }
            -- Lightroom matches paths case-insensitively, so "A|B" and "a|b"
            -- address one keyword.
            dedupeKey = KeywordTree.fold(entry.key)
        else
            -- Trimmed like a path level, so the keyword created for it is found
            -- again by name.
            local name = KeywordTree.trim(kw)
            if name == "" then
                error("Invalid keyword (empty): '" .. kw .. "'")
            end
            entry = { name = name, key = name }
            -- Exact: a plain-name remove matches exact case, so "Paris" and
            -- "paris" are two removals. Case variants of an add are deduped
            -- where they are created.
            dedupeKey = "=" .. name
        end
        if not seen[dedupeKey] then
            seen[dedupeKey] = true
            table.insert(entries, entry)
        end
    end
    return entries
end

-- create_missing = false: every keyword to add must already exist. Returns a
-- list of problems (empty when all resolve) without touching the catalog.
local function findUnresolvable(catalog, addEntries)
    local problems = {}
    for _, entry in ipairs(addEntries) do
        if entry.parts then
            if not KeywordTree.resolve(catalog, entry.parts) then
                table.insert(problems, "not found: " .. entry.key)
            end
        else
            local matches = KeywordTree.findByName(catalog, entry.name)
            if #matches == 0 then
                table.insert(problems, "not found: " .. entry.name)
            elseif #matches > 1 then
                local paths = {}
                for _, match in ipairs(matches) do
                    table.insert(paths, match.path)
                end
                table.insert(problems, "ambiguous: " .. entry.name
                    .. " (" .. table.concat(paths, ", ") .. ")")
            end
        end
    end
    return problems
end

-- Creates every missing level of `pathsToEnsure` (lists of names). Lightroom
-- rejects a parent created earlier in the same write transaction ("bad
-- argument #2 to 'format'"), so each depth gets its own transaction, run after
-- the level above it is committed and visible to getChildren().
local function createMissingLevels(catalog, pathsToEnsure)
    local function prefixOf(parts, depth)
        local prefix = {}
        for i = 1, depth do
            prefix[i] = parts[i]
        end
        return prefix
    end

    local maxDepth = 0
    for _, parts in ipairs(pathsToEnsure) do
        maxDepth = math.max(maxDepth, #parts)
    end

    for depth = 1, maxDepth do
        local missing = {}
        catalog:withReadAccessDo(function()
            local seen = {}
            for _, parts in ipairs(pathsToEnsure) do
                if #parts >= depth then
                    local folded = KeywordTree.fold(KeywordTree.join(prefixOf(parts, depth)))
                    if not seen[folded] then
                        seen[folded] = true
                        local parent = nil
                        if depth > 1 then
                            local parentParts = prefixOf(parts, depth - 1)
                            parent = KeywordTree.resolve(catalog, parentParts)
                            if not parent then
                                error("Keyword level was not created: " .. KeywordTree.join(parentParts))
                            end
                        end
                        if not KeywordTree.findChild(catalog, parent, parts[depth]) then
                            table.insert(missing, { parent = parent, name = parts[depth] })
                        end
                    end
                end
            end
        end)

        if #missing > 0 then
            catalog:withWriteAccessDo("Create Keywords", function()
                for _, level in ipairs(missing) do
                    catalog:createKeyword(level.name, {}, true, level.parent, true)
                end
            end)
        end
    end
end

function OrganizationHandler.setKeywords(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end
    validateKeywordLimit(args.add_keywords, "add_keywords")
    validateKeywordLimit(args.remove_keywords, "remove_keywords")

    -- Neither list means there is nothing to do; reporting "Updated keywords
    -- for 1 photos" for that claimed work that never happened.
    local hasAdds = args.add_keywords ~= nil and args.add_keywords[1] ~= nil
    local hasRemoves = args.remove_keywords ~= nil and args.remove_keywords[1] ~= nil
    if not hasAdds and not hasRemoves then
        error("add_keywords or remove_keywords is required")
    end

    if args.create_missing ~= nil and type(args.create_missing) ~= "boolean" then
        error("create_missing must be a boolean")
    end
    -- Default true: a plain name that does not exist yet is created, as it
    -- always was.
    local createMissing = args.create_missing ~= false

    local catalog = LrApplication.activeCatalog()
    local updatedCount = 0

    local addEntries = parseKeywordList(args.add_keywords)

    local removeNames = {}
    local removePaths = {}
    local hasRemovePaths = false
    for _, entry in ipairs(parseKeywordList(args.remove_keywords)) do
        if entry.parts then
            removePaths[KeywordTree.fold(entry.key)] = true
            hasRemovePaths = true
        else
            removeNames[entry.name] = true
        end
    end

    -- Reject unknown or ambiguous keywords BEFORE resolving ids or opening the
    -- write gate, so a strict call that cannot be honoured changes nothing.
    if not createMissing and #addEntries > 0 then
        local problems = {}
        catalog:withReadAccessDo(function()
            problems = findUnresolvable(catalog, addEntries)
        end)
        if #problems > 0 then
            error("Keywords not resolved (create_missing is false): "
                .. table.concat(problems, "; "))
        end
    end

    local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)

    -- A plain name is created at the top level, as it always was.
    if createMissing and #addEntries > 0 then
        local pathsToEnsure = {}
        for _, entry in ipairs(addEntries) do
            table.insert(pathsToEnsure, entry.parts or { entry.name })
        end
        createMissingLevels(catalog, pathsToEnsure)
    end

    catalog:withWriteAccessDo("Set Keywords", function()
        local keywordObjs = {}
        local seenKeywords = {}
        for _, entry in ipairs(addEntries) do
            local keyword
            if entry.parts then
                keyword = KeywordTree.resolve(catalog, entry.parts)
            elseif createMissing then
                keyword = KeywordTree.findChild(catalog, nil, entry.name)
            else
                -- Looked up again rather than carried across gates: the check
                -- above only proved the name resolved then.
                local matches = KeywordTree.findByName(catalog, entry.name)
                if #matches == 1 then
                    keyword = matches[1].keyword
                end
            end
            if not keyword then
                error("Keyword not resolved: " .. entry.key)
            end
            -- "Summer" and "summer" resolve to one keyword.
            if not seenKeywords[keyword] then
                seenKeywords[keyword] = true
                table.insert(keywordObjs, keyword)
            end
        end

        for _, entry in ipairs(resolved) do
            local photo = entry.photo
            if photo then
                for _, kwObj in ipairs(keywordObjs) do
                    photo:addKeyword(kwObj)
                end

                if next(removeNames) or hasRemovePaths then
                    local existingKeywords = photo:getRawMetadata('keywords')
                    if existingKeywords then
                        for _, kw in ipairs(existingKeywords) do
                            -- A plain name removes every keyword so named; a
                            -- path removes only the keyword at that place.
                            local byPath = hasRemovePaths
                                and removePaths[KeywordTree.fold(KeywordTree.pathOf(kw))]
                            if removeNames[kw:getName()] or byPath then
                                photo:removeKeyword(kw)
                            end
                        end
                    end
                end

                updatedCount = updatedCount + 1
            end
        end
    end)

    Log.info(string.format("Updated keywords for %d photos", updatedCount))

    return {
        success = true,
        updated = updatedCount,
        message = string.format("Updated keywords for %d photos", updatedCount)
    }
end

function OrganizationHandler.setRating(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    if not args.rating then
        error("rating is required")
    end

    -- Comparing a string to a number raised a raw Lua type error that leaked
    -- the handler's file and line to the client.
    if type(args.rating) ~= "number" then
        error("rating must be a number between 0 and 5")
    end

    if args.rating < 0 or args.rating > 5 then
        error("rating must be between 0 and 5")
    end

    local catalog = LrApplication.activeCatalog()
    local updatedCount = 0
    local missingIds = {}
    local missingCount = 0

    -- LrSDK rejects literal 0 on the rating field; nil means "no rating".
    local ratingValue = args.rating
    if ratingValue == 0 then ratingValue = nil end

    local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)

    catalog:withWriteAccessDo("Set Rating", function()
        for _, entry in ipairs(resolved) do
            if entry.photo then
                entry.photo:setRawMetadata('rating', ratingValue)
                updatedCount = updatedCount + 1
            else
                missingCount = missingCount + 1
                missingIds[missingCount] = tostring(entry.id)
            end
        end
    end)

    Log.info(string.format("Set rating to %d for %d photos", args.rating, updatedCount))

    return {
        success = true,
        updated = updatedCount,
        rating = args.rating,
        missing = missingIds,
        message = string.format("Set rating to %d for %d photos (%d ids not found)",
            args.rating, updatedCount, missingCount)
    }
end

return OrganizationHandler
