local helper = require 'spec_helper'

-- A fresh module per spec: the top-level index outlives a call.
local function setup(keywords)
    local catalog = helper.fakeCatalog({ keywords = keywords })
    helper.installImport({})
    package.loaded.KeywordTree = nil
    return catalog, require 'KeywordTree'
end

describe("KeywordTree.childIndex", function()
    it("keys children by folded name, the first of a case pair winning", function()
        local places = helper.fakeKeyword("Places")
        local paris = helper.fakeKeyword("Paris", { parent = places })
        helper.fakeKeyword("paris", { parent = places })
        local rome = helper.fakeKeyword("Rome", { parent = places })
        local catalog, KeywordTree = setup({ places })

        local index = KeywordTree.childIndex(catalog, places)

        assert.are.equal(paris, index.paris)
        assert.are.equal(rome, index.rome)
        assert.is_nil(index.Paris)
    end)
end)

describe("KeywordTree.topIndex", function()
    it("reads each top-level name once and reuses the index", function()
        local top = { helper.fakeKeyword("a"), helper.fakeKeyword("b") }
        local reads = helper.countNameReads(top)
        local catalog, KeywordTree = setup(top)

        local first = KeywordTree.topIndex(catalog)
        local second = KeywordTree.topIndex(catalog)

        assert.are.equal(first, second)
        assert.are.same({ a = 1, b = 1 }, reads)
    end)

    it("rebuilds when the number of top-level keywords changes", function()
        local top = { helper.fakeKeyword("a"), helper.fakeKeyword("b") }
        local reads = helper.countNameReads(top)
        local catalog, KeywordTree = setup(top)

        KeywordTree.topIndex(catalog)
        local c = helper.fakeKeyword("c")
        table.insert(catalog:getKeywords(), c)
        local index = KeywordTree.topIndex(catalog)

        assert.are.equal(c, index.c)
        assert.are.same({ a = 2, b = 2 }, reads)
    end)

    it("rebuilds when a top-level keyword is replaced by another of the same count", function()
        local top = { helper.fakeKeyword("a"), helper.fakeKeyword("b") }
        local reads = helper.countNameReads(top)
        local catalog, KeywordTree = setup(top)

        KeywordTree.topIndex(catalog)
        local c = helper.fakeKeyword("c")
        catalog:getKeywords()[1] = c
        local index = KeywordTree.topIndex(catalog)

        assert.are.equal(c, index.c)
        assert.is_nil(index.a)
        assert.are.equal(2, reads.b)
    end)

    it("rebuilds after forgetTopIndex", function()
        local top = { helper.fakeKeyword("a"), helper.fakeKeyword("b") }
        local reads = helper.countNameReads(top)
        local catalog, KeywordTree = setup(top)

        KeywordTree.topIndex(catalog)
        KeywordTree.forgetTopIndex()
        KeywordTree.topIndex(catalog)

        assert.are.same({ a = 2, b = 2 }, reads)
    end)
end)

describe("KeywordTree.findTopLevel", function()
    it("finds a top-level keyword ignoring case", function()
        local summer = helper.fakeKeyword("summer")
        local catalog, KeywordTree = setup({ summer })

        assert.are.equal(summer, KeywordTree.findTopLevel(catalog, "SUMMER"))
    end)

    it("misses an unknown name without rebuilding the index", function()
        local top = { helper.fakeKeyword("a") }
        local reads = helper.countNameReads(top)
        local catalog, KeywordTree = setup(top)

        assert.is_nil(KeywordTree.findTopLevel(catalog, "nope"))
        assert.is_nil(KeywordTree.findTopLevel(catalog, "nope"))
        assert.are.equal(1, reads.a)
    end)

    it("finds a keyword deleted and created again under the same name", function()
        local summer = helper.fakeKeyword("summer")
        local catalog, KeywordTree = setup({ summer, helper.fakeKeyword("winter") })

        KeywordTree.findTopLevel(catalog, "summer")
        local recreated = helper.fakeKeyword("summer")
        catalog:getKeywords()[1] = recreated
        summer.getName = function() error("keyword deleted") end
        summer.getParent = function() error("keyword deleted") end

        assert.are.equal(recreated, KeywordTree.findTopLevel(catalog, "summer"))
    end)

    it("misses a keyword renamed since the index was built", function()
        local summer = helper.fakeKeyword("summer")
        local catalog, KeywordTree = setup({ summer })

        KeywordTree.findTopLevel(catalog, "summer")
        summer:setAttributes({ keywordName = "winter" })

        assert.is_nil(KeywordTree.findTopLevel(catalog, "summer"))
    end)

    it("misses a keyword moved under a parent since the index was built", function()
        local summer = helper.fakeKeyword("summer")
        local seasons = helper.fakeKeyword("Seasons")
        local catalog, KeywordTree = setup({ summer, seasons })

        KeywordTree.findTopLevel(catalog, "summer")
        -- Moved under Seasons while another keyword was created at the top
        -- level, so the count is unchanged.
        local top = catalog:getKeywords()
        table.remove(top, 1)
        summer.getParent = function() return seasons end
        seasons:__addChild(summer)
        table.insert(top, helper.fakeKeyword("autumn"))

        assert.is_nil(KeywordTree.findTopLevel(catalog, "summer"))
    end)
end)
