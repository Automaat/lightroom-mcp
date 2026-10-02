local helper = require 'spec_helper'

local function setup(keywords)
    local catalog = helper.fakeCatalog({ keywords = keywords or {} })
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerKeywords = nil
    return catalog, require 'HandlerKeywords'
end

-- zebra
-- Places > Europe > Paris, Europe > Berlin, Places > asia
local function tree()
    local zebra = helper.fakeKeyword("zebra", { synonyms = { "stripy horse" }, includeOnExport = false })
    local places = helper.fakeKeyword("Places")
    local europe = helper.fakeKeyword("Europe", { parent = places })
    helper.fakeKeyword("Paris", { parent = europe })
    helper.fakeKeyword("Berlin", { parent = europe })
    helper.fakeKeyword("asia", { parent = places })
    return { zebra, places }
end

local function paths(result)
    local out = {}
    for _, kw in ipairs(result.keywords) do
        table.insert(out, kw.path)
    end
    return out
end

describe("HandlerKeywords.listKeywords", function()
    it("lists the whole hierarchy as full paths, parents first, in name order", function()
        local _, Handler = setup(tree())

        local r = Handler.listKeywords({})

        assert.are.equal(6, r.count)
        assert.is_false(r.has_more)
        assert.are.same({
            "Places",
            "Places|asia",
            "Places|Europe",
            "Places|Europe|Berlin",
            "Places|Europe|Paris",
            "zebra",
        }, paths(r))
    end)

    it("returns name, synonyms and includeOnExport for each keyword", function()
        local _, Handler = setup(tree())

        local r = Handler.listKeywords({})

        local zebra = r.keywords[6]
        assert.are.equal("zebra", zebra.name)
        assert.are.same({ "stripy horse" }, zebra.synonyms)
        assert.is_false(zebra.includeOnExport)
        assert.is_true(r.keywords[1].includeOnExport)
        assert.are.same({}, r.keywords[1].synonyms)
    end)

    it("paginates with limit and offset", function()
        local _, Handler = setup(tree())

        local r = Handler.listKeywords({ limit = 2, offset = 1 })

        assert.are.equal(6, r.count)
        assert.is_true(r.has_more)
        assert.are.same({ "Places|asia", "Places|Europe" }, paths(r))
    end)

    it("lists only the descendants of parent", function()
        local _, Handler = setup(tree())

        local r = Handler.listKeywords({ parent = "Places|Europe" })

        assert.are.equal(2, r.count)
        assert.are.same({ "Places|Europe|Berlin", "Places|Europe|Paris" }, paths(r))
    end)

    it("filters by query on name or synonym, ignoring case", function()
        local _, Handler = setup(tree())

        local byName = Handler.listKeywords({ query = "EUR" })
        assert.are.equal(1, byName.count)
        assert.are.same({ "Places|Europe" }, paths(byName))

        local bySynonym = Handler.listKeywords({ query = "stripy" })
        assert.are.same({ "zebra" }, paths(bySynonym))

        local scoped = Handler.listKeywords({ query = "a", parent = "Places|Europe" })
        assert.are.same({ "Places|Europe|Paris" }, paths(scoped))
    end)

    it("treats query as plain text, not a Lua pattern", function()
        local _, Handler = setup({ helper.fakeKeyword("50% grey"), helper.fakeKeyword("grey") })

        local r = Handler.listKeywords({ query = "0%" })

        assert.are.same({ "50% grey" }, paths(r))
    end)

    it("returns bare path strings with paths_only", function()
        local _, Handler = setup(tree())

        local r = Handler.listKeywords({ paths_only = true, limit = 3 })

        assert.are.equal(6, r.count)
        assert.is_true(r.has_more)
        assert.are.same({ "Places", "Places|asia", "Places|Europe" }, r.keywords)
    end)

    it("rejects a bad query or paths_only", function()
        local _, Handler = setup(tree())

        assert.has_error(function() Handler.listKeywords({ query = " " }) end,
            "query must be a non-empty string")
        assert.has_error(function() Handler.listKeywords({ paths_only = "yes" }) end,
            "paths_only must be a boolean")
    end)

    it("resolves parent ignoring case", function()
        local _, Handler = setup(tree())

        local r = Handler.listKeywords({ parent = "places|EUROPE" })

        assert.are.same({ "Places|Europe|Berlin", "Places|Europe|Paris" }, paths(r))
    end)

    it("folds query case with LrStringUtils.lower, not string.lower", function()
        local catalog = helper.fakeCatalog({ keywords = { helper.fakeKeyword("Zürich"), helper.fakeKeyword("Bern") } })
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrLogger = helper.defaultLrLogger(),
            -- Stand-in for Lightroom's Unicode-aware lower.
            LrStringUtils = { lower = function(s) return (s:lower():gsub("Ü", "ü")) end },
        })
        package.loaded.HandlerKeywords = nil
        package.loaded.KeywordTree = nil
        local Handler = require 'HandlerKeywords'

        local r = Handler.listKeywords({ query = "ZÜRICH" })

        package.loaded.KeywordTree = nil
        assert.are.same({ "Zürich" }, paths(r))
    end)

    it("errors on an unknown parent", function()
        local _, Handler = setup(tree())

        assert.has_error(function() Handler.listKeywords({ parent = "Places|Africa" }) end,
            "Keyword not found: Places|Africa")
        assert.has_error(function() Handler.listKeywords({ parent = "  " }) end,
            "parent must be a keyword path")
    end)

    it("never calls into the SDK from inside table.sort", function()
        -- LrKeyword methods yield inside Lightroom, and a yield from a
        -- table.sort comparator raises "Yielding is not allowed within a C or
        -- metamethod call" there. Record any SDK call made while a sort is
        -- running. (Not modelled with coroutines: Lua 5.1 cannot yield across
        -- the pcall in the fake catalog's access gates.)
        local insideSort = false
        local calledInsideSort = {}
        local function watch(keyword)
            for _, method in ipairs({ "getName", "getParent", "getChildren", "getSynonyms", "getAttributes" }) do
                local original = keyword[method]
                keyword[method] = function(...)
                    if insideSort then
                        table.insert(calledInsideSort, method)
                    end
                    return original(...)
                end
            end
            for _, child in ipairs(keyword:getChildren()) do
                watch(child)
            end
        end
        local keywords = tree()
        for _, keyword in ipairs(keywords) do
            watch(keyword)
        end
        local _, Handler = setup(keywords)

        local realSort = table.sort
        table.sort = function(...)
            insideSort = true
            local ok, err = pcall(realSort, ...)
            insideSort = false
            if not ok then error(err, 0) end
        end
        local ok, result = pcall(Handler.listKeywords, {})
        table.sort = realSort

        assert.is_true(ok, tostring(result))
        assert.are.equal(6, result.count)
        assert.are.same({}, calledInsideSort)
    end)

    it("handles an empty catalog and missing args", function()
        local _, Handler = setup({})

        local r = Handler.listKeywords()

        assert.are.equal(0, r.count)
        assert.are.same({}, r.keywords)
        assert.is_false(r.has_more)
    end)
end)
