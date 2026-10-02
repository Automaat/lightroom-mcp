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

    it("errors on an unknown parent", function()
        local _, Handler = setup(tree())

        assert.has_error(function() Handler.listKeywords({ parent = "Places|Africa" }) end,
            "Keyword not found: Places|Africa")
        assert.has_error(function() Handler.listKeywords({ parent = "  " }) end,
            "parent must be a keyword path")
    end)

    it("never calls into the SDK from inside table.sort", function()
        -- LrKeyword methods yield inside Lightroom, and a yield from a
        -- table.sort comparator is an error there. Model that: getName()
        -- yields, and the handler runs in a coroutine as it does in the plugin.
        local function yielding(keyword)
            local getName = keyword.getName
            keyword.getName = function(...)
                coroutine.yield()
                return getName(...)
            end
            for _, child in ipairs(keyword:getChildren()) do
                yielding(child)
            end
        end
        local keywords = tree()
        for _, keyword in ipairs(keywords) do
            yielding(keyword)
        end
        local _, Handler = setup(keywords)

        local result
        local co = coroutine.create(function() result = Handler.listKeywords({}) end)
        local ok, err = true, nil
        while ok and coroutine.status(co) ~= "dead" do
            ok, err = coroutine.resume(co)
        end

        assert.is_true(ok, tostring(err))
        assert.are.equal(6, result.count)
    end)

    it("handles an empty catalog and missing args", function()
        local _, Handler = setup({})

        local r = Handler.listKeywords()

        assert.are.equal(0, r.count)
        assert.are.same({}, r.keywords)
        assert.is_false(r.has_more)
    end)
end)
