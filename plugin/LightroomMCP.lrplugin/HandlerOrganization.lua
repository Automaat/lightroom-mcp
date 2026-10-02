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
        local entry
        if KeywordTree.isPath(kw) then
            local parts = KeywordTree.split(kw)
            entry = { parts = parts, key = KeywordTree.join(parts) }
        else
            entry = { name = kw, key = kw }
        end
        if not seen[entry.key] then
            seen[entry.key] = true
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
            removePaths[entry.key] = true
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

    catalog:withWriteAccessDo("Set Keywords", function()
        -- createKeyword is not idempotent within one write transaction, and a
        -- keyword created here is not visible to getChildren() until the
        -- transaction ends, so levels created for one path are remembered for
        -- the next ("A|B" then "A|C" must share one new "A").
        local createdByPath = {}

        local function resolveOrCreatePath(parts)
            local parent = nil
            local prefix = ""
            for _, name in ipairs(parts) do
                local path = prefix .. name
                local keyword = createdByPath[path]
                if not keyword then
                    keyword = KeywordTree.findChild(catalog, parent, name)
                end
                if not keyword then
                    if not createMissing then
                        error("Keyword not found: " .. KeywordTree.join(parts))
                    end
                    keyword = catalog:createKeyword(name, {}, true, parent, true)
                    createdByPath[path] = keyword
                end
                parent = keyword
                prefix = path .. KeywordTree.SEPARATOR
            end
            return parent
        end

        local keywordObjs = {}
        for _, entry in ipairs(addEntries) do
            if entry.parts then
                table.insert(keywordObjs, resolveOrCreatePath(entry.parts))
            elseif createMissing then
                table.insert(keywordObjs, catalog:createKeyword(entry.name, {}, true, nil, true))
            else
                -- Looked up again rather than carried across gates: the check
                -- above only proved the name resolved then.
                local matches = KeywordTree.findByName(catalog, entry.name)
                if #matches ~= 1 then
                    error("Keyword not resolved: " .. entry.name)
                end
                table.insert(keywordObjs, matches[1].keyword)
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
                            if removeNames[kw:getName()]
                                or (hasRemovePaths and removePaths[KeywordTree.pathOf(kw)]) then
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
