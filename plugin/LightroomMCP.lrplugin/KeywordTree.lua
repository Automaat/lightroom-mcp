-- Helpers for addressing keywords by their place in the keyword hierarchy.
--
-- A keyword path is written parent-first with "|" between levels, e.g.
-- "Places|Europe|Paris". "|" is the separator Lightroom itself uses for
-- hierarchies in the Keywording panel, so it cannot occur inside a keyword
-- name and a string containing it is unambiguously a path.
local LrStringUtils = import 'LrStringUtils'

local KeywordTree = {}

KeywordTree.SEPARATOR = "|"

-- Lightroom treats keyword names case-insensitively (createKeyword with
-- returnExisting matches "paris" to "Paris"), so every name comparison here
-- does too. LrStringUtils.lower folds non-ASCII letters; string.lower does not.
function KeywordTree.fold(s)
    return LrStringUtils.lower(s)
end

function KeywordTree.trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
local trim = KeywordTree.trim

function KeywordTree.isPath(name)
    return type(name) == "string" and name:find(KeywordTree.SEPARATOR, 1, true) ~= nil
end

-- "A | B|C" -> { "A", "B", "C" }. Errors on an empty level ("A||B", "|A").
function KeywordTree.split(path)
    local parts = {}
    for segment in (path .. KeywordTree.SEPARATOR):gmatch("(.-)|") do
        local name = trim(segment)
        if name == "" then
            error("Invalid keyword path (empty level): " .. path)
        end
        parts[#parts + 1] = name
    end
    return parts
end

function KeywordTree.join(parts)
    return table.concat(parts, KeywordTree.SEPARATOR)
end

-- Full parent-first path of a keyword object.
function KeywordTree.pathOf(keyword)
    local names = {}
    local current = keyword
    while current do
        table.insert(names, 1, current:getName())
        current = current:getParent()
    end
    return KeywordTree.join(names)
end

-- Children of `parent`, or the top-level keywords when parent is nil.
function KeywordTree.children(catalog, parent)
    if parent then
        return parent:getChildren() or {}
    end
    return catalog:getKeywords() or {}
end

function KeywordTree.findChild(catalog, parent, name)
    local folded = KeywordTree.fold(name)
    for _, child in ipairs(KeywordTree.children(catalog, parent)) do
        if KeywordTree.fold(child:getName()) == folded then
            return child
        end
    end
    return nil
end

-- Children of `parent` (or the top level) keyed by folded name, the first
-- match winning as in findChild. One pass for many lookups: findChild reads
-- every sibling's name again for each one.
function KeywordTree.childIndex(catalog, parent)
    local index = {}
    for _, child in ipairs(KeywordTree.children(catalog, parent)) do
        local folded = KeywordTree.fold(child:getName())
        if index[folded] == nil then
            index[folded] = child
        end
    end
    return index
end

-- The top-level index, kept between calls: building it reads every top-level
-- keyword's name, which takes seconds on a catalog with thousands of them.
-- Rebuilt when the number of top-level keywords changes and after
-- forgetTopIndex. A rename or move in Lightroom leaves the count alone, so
-- findTopLevel checks each hit.
local topCache = nil

function KeywordTree.topIndex(catalog)
    local count = #KeywordTree.children(catalog, nil)
    if not topCache or topCache.count ~= count then
        topCache = { count = count, index = KeywordTree.childIndex(catalog, nil) }
    end
    return topCache.index
end

function KeywordTree.forgetTopIndex()
    topCache = nil
end

-- findChild(catalog, nil, name) through the cached index. A hit that has been
-- renamed or moved since the index was built is a miss; a miss does not
-- rebuild the index.
function KeywordTree.findTopLevel(catalog, name)
    local folded = KeywordTree.fold(name)
    local keyword = KeywordTree.topIndex(catalog)[folded]
    if keyword and not keyword:getParent() and KeywordTree.fold(keyword:getName()) == folded then
        return keyword
    end
    return nil
end

-- Walks `parts` from the top level. Returns the keyword, or nil plus the
-- number of leading levels that did resolve.
function KeywordTree.resolve(catalog, parts)
    local current = nil
    for i, name in ipairs(parts) do
        local child = KeywordTree.findChild(catalog, current, name)
        if not child then
            return nil, i - 1
        end
        current = child
    end
    return current, #parts
end

-- Depth-first, parent before children, siblings in name order so repeated
-- calls page through the tree in a stable order. `visit(keyword, path)`.
function KeywordTree.walk(catalog, root, visit)
    local function descend(parent, prefix)
        -- Names are read BEFORE sorting: LrKeyword getters can yield, which is
        -- fine inside an access gate (they are not catalog queries) but not
        -- from a table.sort comparator, a C call that raises "Yielding is
        -- not allowed within a C or metamethod call".
        local kids = {}
        for _, child in ipairs(KeywordTree.children(catalog, parent)) do
            local name = child:getName()
            kids[#kids + 1] = { keyword = child, name = name, lower = KeywordTree.fold(name) }
        end
        table.sort(kids, function(a, b)
            if a.lower ~= b.lower then return a.lower < b.lower end
            return a.name < b.name
        end)
        for _, kid in ipairs(kids) do
            local path = prefix .. kid.name
            visit(kid.keyword, path)
            descend(kid.keyword, path .. KeywordTree.SEPARATOR)
        end
    end

    if root then
        descend(root, KeywordTree.pathOf(root) .. KeywordTree.SEPARATOR)
    else
        descend(nil, "")
    end
end

-- Every keyword, at any depth, whose own name is `name`.
function KeywordTree.findByName(catalog, name)
    local folded = KeywordTree.fold(name)
    local matches = {}
    KeywordTree.walk(catalog, nil, function(keyword, path)
        if KeywordTree.fold(keyword:getName()) == folded then
            matches[#matches + 1] = { keyword = keyword, path = path }
        end
    end)
    return matches
end

return KeywordTree
