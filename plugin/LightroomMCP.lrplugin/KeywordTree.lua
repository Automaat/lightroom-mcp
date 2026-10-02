-- Helpers for addressing keywords by their place in the keyword hierarchy.
--
-- A keyword path is written parent-first with "|" between levels, e.g.
-- "Places|Europe|Paris". "|" is the separator Lightroom itself uses for
-- hierarchies in the Keywording panel, so it cannot occur inside a keyword
-- name and a string containing it is unambiguously a path.
local KeywordTree = {}

KeywordTree.SEPARATOR = "|"

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

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
    for _, child in ipairs(KeywordTree.children(catalog, parent)) do
        if child:getName() == name then
            return child
        end
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
        -- Names are read BEFORE sorting: getName() yields inside Lightroom,
        -- and yielding from a table.sort comparator (a C call) raises
        -- "Yielding is not allowed within a C or metamethod call".
        local kids = {}
        for _, child in ipairs(KeywordTree.children(catalog, parent)) do
            local name = child:getName()
            kids[#kids + 1] = { keyword = child, name = name, lower = name:lower() }
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
    local matches = {}
    KeywordTree.walk(catalog, nil, function(keyword, path)
        if keyword:getName() == name then
            matches[#matches + 1] = { keyword = keyword, path = path }
        end
    end)
    return matches
end

return KeywordTree
