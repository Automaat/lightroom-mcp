local helper = require 'spec_helper'

-- tasks.pcallCount counts LrTasks.pcall calls: the plain pcall cannot yield,
-- so a write gate inside it fails in Lightroom.
local tasks = { pcallCount = 0 }

local function setup(keywords)
    local catalog = helper.fakeCatalog({ keywords = keywords or {} })
    tasks.pcallCount = 0
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
        LrTasks = {
            pcall = function(fn, ...)
                tasks.pcallCount = tasks.pcallCount + 1
                return pcall(fn, ...)
            end,
        },
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
            LrTasks = { pcall = pcall },
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

describe("HandlerKeywords.renameKeyword", function()
    it("renames a keyword found by its unique name and reports its photos", function()
        local person = helper.fakeKeyword("person", { photos = { {}, {}, {} } })
        local places = helper.fakeKeyword("Places")
        local _, Handler = setup({ person, places })

        local r = Handler.renameKeyword({ keyword = "person", new_name = "people" })

        assert.is_true(r.success)
        assert.are.equal("person", r.old_path)
        assert.are.equal("people", r.new_path)
        assert.are.equal(3, r.photo_count)
        assert.are.equal("people", person:getName())
    end)

    it("renames a nested keyword by path and keeps it under its parent", function()
        local places = helper.fakeKeyword("Places")
        local usa = helper.fakeKeyword("USA", { parent = places })
        local kc = helper.fakeKeyword("KC", { parent = usa })
        local _, Handler = setup({ places })

        local r = Handler.renameKeyword({ keyword = "Places|USA|KC", new_name = "  Kansas City " })

        assert.are.equal("Places|USA|KC", r.old_path)
        assert.are.equal("Places|USA|Kansas City", r.new_path)
        assert.are.equal("Kansas City", kc:getName())
        assert.are.equal(usa, kc:getParent())
    end)

    it("changes only the case through a temporary name, in two transactions", function()
        local callie = helper.fakeKeyword("callie")
        local catalog, Handler = setup({ callie })

        local r = Handler.renameKeyword({ keyword = "callie", new_name = "Callie" })

        assert.are.equal("Callie", r.new_path)
        assert.are.equal("Callie", callie:getName())
        assert.are.equal(2, catalog.getWriteAccessCount())
        assert.are.equal(1, tasks.pcallCount)
    end)

    it("names the temporary name it left behind if the second step fails", function()
        local callie = helper.fakeKeyword("callie")
        local catalog, Handler = setup({ callie })
        local realWrite = catalog.withWriteAccessDo
        local calls = 0
        catalog.withWriteAccessDo = function(self, name, fn)
            calls = calls + 1
            if calls == 2 then error("blocked by another write access call") end
            return realWrite(self, name, fn)
        end

        local ok, err = pcall(Handler.renameKeyword, { keyword = "callie", new_name = "Callie" })

        assert.is_false(ok)
        assert.is_not_nil(tostring(err):find(
            "Keyword 'callie' was left named 'Callie (renaming)' while changing its case", 1, true))
        assert.are.equal("Callie (renaming)", callie:getName())
    end)

    it("reports a sibling collision during the final case-only rename", function()
        local callie = helper.fakeKeyword("callie")
        local siblings = { callie }
        local catalog, Handler = setup(siblings)
        local realWrite = catalog.withWriteAccessDo
        local calls = 0
        catalog.withWriteAccessDo = function(self, name, fn)
            calls = calls + 1
            if calls == 2 then table.insert(siblings, helper.fakeKeyword("Callie")) end
            return realWrite(self, name, fn)
        end
        local realSetAttributes = callie.setAttributes
        callie.setAttributes = function(self, attributes)
            for _, sibling in ipairs(siblings) do
                if sibling ~= self and sibling:getName():lower() == attributes.keywordName:lower() then
                    return false
                end
            end
            return realSetAttributes(self, attributes)
        end

        local ok, err = pcall(Handler.renameKeyword, { keyword = "callie", new_name = "Callie" })

        assert.is_false(ok)
        assert.is_not_nil(tostring(err):find(
            "Keyword 'callie' was left named 'Callie (renaming)' while changing its case", 1, true))
        assert.are.equal("Callie (renaming)", callie:getName())
        assert.are.equal("Callie", siblings[2]:getName())
    end)

    it("reports a rename rejected by Lightroom before claiming success", function()
        local person = helper.fakeKeyword("person")
        local _, Handler = setup({ person })
        person.setAttributes = function() return false end

        assert.has_error(function()
            Handler.renameKeyword({ keyword = "person", new_name = "people" })
        end, "Lightroom refused to rename keyword 'person' to 'people'")
        assert.are.equal("person", person:getName())
    end)

    it("picks a temporary name that no sibling has", function()
        local callie = helper.fakeKeyword("callie")
        local taken = helper.fakeKeyword("Callie (renaming)")
        local catalog, Handler = setup({ callie, taken })

        Handler.renameKeyword({ keyword = "callie", new_name = "Callie" })

        assert.are.equal("Callie", callie:getName())
        assert.are.equal("Callie (renaming)", taken:getName())
        assert.are.equal(2, catalog.getWriteAccessCount())
    end)

    it("renames in one transaction when the name really changes", function()
        local person = helper.fakeKeyword("person")
        local catalog, Handler = setup({ person })

        Handler.renameKeyword({ keyword = "person", new_name = "people" })

        assert.are.equal(1, catalog.getWriteAccessCount())
    end)

    it("refuses a rename to the name it already has", function()
        local callie = helper.fakeKeyword("Callie")
        local _, Handler = setup({ callie })

        assert.has_error(function() Handler.renameKeyword({ keyword = "Callie", new_name = "Callie" }) end,
            "Keyword is already named 'Callie'")
    end)

    it("refuses to guess between keywords that share a name", function()
        local europe = helper.fakeKeyword("Europe")
        local places = helper.fakeKeyword("Places")
        local nested = helper.fakeKeyword("Europe", { parent = places })
        local _, Handler = setup({ europe, places })

        assert.has_error(function() Handler.renameKeyword({ keyword = "Europe", new_name = "EU" }) end,
            "Keyword is ambiguous, give its path: Europe (Europe, Places|Europe)")
        assert.are.equal("Europe", europe:getName())
        assert.are.equal("Europe", nested:getName())
    end)

    it("refuses a name a sibling already has, ignoring case", function()
        local places = helper.fakeKeyword("Places")
        local europe = helper.fakeKeyword("Europe", { parent = places })
        local paris = helper.fakeKeyword("Paris", { parent = europe })
        helper.fakeKeyword("Berlin", { parent = europe })
        local _, Handler = setup({ places })

        assert.has_error(function()
            Handler.renameKeyword({ keyword = "Places|Europe|Paris", new_name = "berlin" })
        end, "A keyword named 'Berlin' already exists at Places|Europe|Berlin; rename cannot merge keywords")
        assert.are.equal("Paris", paris:getName())
    end)

    it("allows a name used elsewhere in the hierarchy", function()
        local zebra = helper.fakeKeyword("zebra")
        local places = helper.fakeKeyword("Places")
        local paris = helper.fakeKeyword("Paris", { parent = places })
        local _, Handler = setup({ zebra, places })

        Handler.renameKeyword({ keyword = "Places|Paris", new_name = "zebra" })

        assert.are.equal("zebra", paris:getName())
        assert.are.equal("zebra", zebra:getName())
    end)

    it("reports a keyword or path that does not exist", function()
        local _, Handler = setup(tree())

        assert.has_error(function() Handler.renameKeyword({ keyword = "nope", new_name = "x" }) end,
            "Keyword not found: nope")
        assert.has_error(function() Handler.renameKeyword({ keyword = "Places|Nope", new_name = "x" }) end,
            "Keyword not found: Places|Nope")
    end)

    it("rejects missing arguments and a path as the new name", function()
        local _, Handler = setup(tree())

        assert.has_error(function() Handler.renameKeyword({ new_name = "x" }) end, "keyword is required")
        assert.has_error(function() Handler.renameKeyword({ keyword = "zebra", new_name = " " }) end,
            "new_name is required")
        assert.has_error(function() Handler.renameKeyword({ keyword = "zebra", new_name = "Animals|zebra" }) end,
            "new_name must be a single keyword name, not a path: Animals|zebra")
    end)
end)
