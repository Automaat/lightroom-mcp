local helper = require 'spec_helper'

local function fakePreset(name)
    return { getName = function() return name end }
end

local function fakeFolder(name, presets)
    return {
        getName = function() return name end,
        getDevelopPresets = function() return presets end,
    }
end

local function setup(opts)
    opts = opts or {}
    local catalog = helper.fakeCatalog({ photos = opts.photos or {} })
    helper.installImport({
        LrApplication = {
            activeCatalog = function() return catalog end,
            developPresetFolders = function() return opts.folders or {} end,
        },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerDevelop = nil
    return catalog, require 'HandlerDevelop'
end

describe("HandlerDevelop.listDevelopPresets", function()
    it("returns flat list with name + folder", function()
        local folders = {
            fakeFolder("User Presets", { fakePreset("Vibrant"), fakePreset("Moody") }),
            fakeFolder("Adobe Color", { fakePreset("Standard") }),
        }
        local _, Handler = setup({ folders = folders })

        local r = Handler.listDevelopPresets({})

        assert.is_true(r.success)
        assert.are.equal(3, r.count)
        assert.are.equal(3, #r.presets)
        assert.are.equal("Vibrant", r.presets[1].name)
        assert.are.equal("User Presets", r.presets[1].folder)
        assert.are.equal("Standard", r.presets[3].name)
        assert.are.equal("Adobe Color", r.presets[3].folder)
    end)

    it("returns empty list when no folders", function()
        local _, Handler = setup({ folders = {} })
        local r = Handler.listDevelopPresets({})
        assert.are.equal(0, r.count)
        assert.are.same({}, r.presets)
    end)
end)

describe("HandlerDevelop.applyDevelopPreset", function()
    it("applies preset to resolved photos", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg" })
        local preset = fakePreset("Vibrant")
        local folders = { fakeFolder("User", { preset }) }
        local _, Handler = setup({ photos = { p1, p2 }, folders = folders })

        local r = Handler.applyDevelopPreset({ photo_ids = { "1", "2" }, preset_name = "Vibrant" })

        assert.is_true(r.success)
        assert.are.equal(2, r.applied)
        assert.are.equal("Vibrant", r.preset)
        assert.are.equal("User", r.folder)
        assert.are.equal(preset, p1.getRawMetadata(p1, "__appliedPreset"))
        assert.are.equal(preset, p2.getRawMetadata(p2, "__appliedPreset"))
    end)

    it("skips unresolved photos", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local folders = { fakeFolder("User", { fakePreset("Moody") }) }
        local _, Handler = setup({ photos = { p1 }, folders = folders })

        local r = Handler.applyDevelopPreset({ photo_ids = { "1", "missing" }, preset_name = "Moody" })

        assert.are.equal(1, r.applied)
    end)

    it("errors on unknown preset", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local folders = { fakeFolder("User", { fakePreset("Vibrant") }) }
        local _, Handler = setup({ photos = { p1 }, folders = folders })

        assert.has_error(function()
            Handler.applyDevelopPreset({ photo_ids = { "1" }, preset_name = "Nope" })
        end)
    end)

    it("requires photo_ids and preset_name", function()
        local _, Handler = setup({ folders = { fakeFolder("U", { fakePreset("X") }) } })
        assert.has_error(function() Handler.applyDevelopPreset({ preset_name = "X" }) end)
        assert.has_error(function() Handler.applyDevelopPreset({ photo_ids = { "1" } }) end)
        assert.has_error(function() Handler.applyDevelopPreset({ photo_ids = {}, preset_name = "X" }) end)
    end)
end)

describe("HandlerDevelop.copyDevelopSettings", function()
    it("copies all settings from source to targets", function()
        local source = helper.fakePhoto({
            id = "10", path = "/s.jpg",
            developSettings = { Exposure2012 = 1.0, Contrast2012 = 25, WhiteBalance = "Custom" },
        })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg" })
        local t2 = helper.fakePhoto({ id = "12", path = "/t2.jpg" })
        local _, Handler = setup({ photos = { source, t1, t2 } })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11", "12" } })

        assert.is_true(r.success)
        assert.are.equal(2, r.copied)
        assert.are.same(
            { Exposure2012 = 1.0, Contrast2012 = 25, WhiteBalance = "Custom" },
            t1.getRawMetadata(t1, "__appliedSettings")
        )
        assert.are.same(
            { Exposure2012 = 1.0, Contrast2012 = 25, WhiteBalance = "Custom" },
            t2.getRawMetadata(t2, "__appliedSettings")
        )
    end)

    it("filters by settings whitelist", function()
        local source = helper.fakePhoto({
            id = "20", path = "/s.jpg",
            developSettings = { Exposure2012 = 0.5, Contrast2012 = 10, Saturation = 20 },
        })
        local target = helper.fakePhoto({ id = "21", path = "/t.jpg" })
        local _, Handler = setup({ photos = { source, target } })

        Handler.copyDevelopSettings({
            source_id = "20",
            target_ids = { "21" },
            settings = { "Exposure2012", "Saturation" },
        })

        local applied = target.getRawMetadata(target, "__appliedSettings")
        assert.are.equal(0.5, applied.Exposure2012)
        assert.are.equal(20, applied.Saturation)
        assert.is_nil(applied.Contrast2012)
    end)

    it("errors when source missing", function()
        local _, Handler = setup({ photos = {} })
        assert.has_error(function()
            Handler.copyDevelopSettings({ source_id = "missing", target_ids = { "t" } })
        end)
    end)

    it("requires source_id and target_ids", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.copyDevelopSettings({ target_ids = { "t" } }) end)
        assert.has_error(function() Handler.copyDevelopSettings({ source_id = "s" }) end)
        assert.has_error(function() Handler.copyDevelopSettings({ source_id = "s", target_ids = {} }) end)
    end)
end)

describe("HandlerDevelop.setDevelopSettings", function()
    it("applies settings to the photo", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p } })

        local r = Handler.setDevelopSettings({
            photo_id = "1",
            settings = { Exposure2012 = 0.75, Contrast2012 = 15 },
        })

        assert.is_true(r.success)
        assert.are.same(
            { Exposure2012 = 0.75, Contrast2012 = 15 },
            p.getRawMetadata(p, "__appliedSettings")
        )
    end)

    it("errors when photo not found", function()
        local _, Handler = setup({ photos = {} })
        assert.has_error(function()
            Handler.setDevelopSettings({ photo_id = "missing", settings = { Exposure2012 = 1 } })
        end)
    end)

    it("requires photo_id and settings table", function()
        local _, Handler = setup({})
        assert.has_error(function() Handler.setDevelopSettings({ settings = {} }) end)
        assert.has_error(function() Handler.setDevelopSettings({ photo_id = "1" }) end)
        assert.has_error(function() Handler.setDevelopSettings({ photo_id = "1", settings = "not-a-table" }) end)
    end)
end)
