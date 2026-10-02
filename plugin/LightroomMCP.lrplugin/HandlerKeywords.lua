local LrApplication = import 'LrApplication'

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

return KeywordsHandler
