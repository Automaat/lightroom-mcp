local helper = require 'spec_helper'

local function fakePreset(name, opts)
    opts = opts or {}
    return {
        getName = function() return name end,
        getUuid = function() return opts.uuid or ("uuid-" .. name) end,
        getFile = function() return opts.file end,
        getSetting = function() return opts.settings or {} end,
    }
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
    local pluginPresets = opts.pluginPresets or {}
    local files = opts.files or {}
    local copies = {}
    local function leafName(path)
        return path:match("([^/\\]+)$") or path
    end
    local function extension(path)
        return leafName(path):match("%.([^%.]+)$") or ""
    end
    _G._PLUGIN = opts.plugin or { id = "com.lightroom.mcp" }
    helper.installImport({
        LrApplication = {
            activeCatalog = function() return catalog end,
            developPresetFolders = function() return opts.folders or {} end,
            getDevelopPresetsForPlugin = function() return pluginPresets end,
            addDevelopPresetForPlugin = function(_, name, settings)
                local preset = fakePreset(name, {
                    uuid = "plugin-" .. tostring(#pluginPresets + 1),
                    file = "/plugin/" .. name .. ".xmp",
                    settings = settings,
                })
                table.insert(pluginPresets, preset)
                files[preset:getFile()] = "file"
                return preset
            end,
        },
        LrFileUtils = {
            exists = function(path) return files[path] or false end,
            createAllDirectories = function(path) files[path] = "directory" return true end,
            copy = function(source, destination)
                if files[source] ~= "file" or files[destination] then return false, "copy refused" end
                files[destination] = "file"
                table.insert(copies, { source = source, destination = destination })
                return true
            end,
        },
        LrPathUtils = {
            leafName = leafName,
            extension = extension,
            child = function(parent, child) return parent .. "/" .. child end,
        },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerDevelop = nil
    return catalog, require 'HandlerDevelop', {
        pluginPresets = pluginPresets,
        files = files,
        copies = copies,
    }
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

    it("includes UUID, scope, and plugin-managed checkpoints", function()
        local visible = fakePreset("Visible", { uuid = "visible-1", file = "/user/Visible.xmp" })
        local checkpoint = fakePreset("Look-v2", { uuid = "plugin-1", file = "/plugin/Look-v2.xmp" })
        local _, Handler = setup({
            folders = { fakeFolder("User Presets", { visible }) },
            pluginPresets = { checkpoint },
        })

        local r = Handler.listDevelopPresets({})

        assert.are.equal(2, r.count)
        assert.are.equal("lightroom", r.presets[1].scope)
        assert.are.equal("visible-1", r.presets[1].uuid)
        assert.are.equal("plugin", r.presets[2].scope)
        assert.are.equal("Plugin Develop Presets", r.presets[2].folder)
    end)
end)

describe("HandlerDevelop.getDevelopPreset", function()
    it("returns exact preset settings", function()
        local preset = fakePreset("John Warm", {
            uuid = "warm-1",
            file = "/user/John Warm.xmp",
            settings = { Exposure2012 = 0.25, ToneCurvePV2012 = { 0, 0, 255, 255 } },
        })
        local _, Handler = setup({ folders = { fakeFolder("John", { preset }) } })

        local r = Handler.getDevelopPreset({ preset_uuid = "warm-1" })

        assert.is_true(r.success)
        assert.are.equal("John Warm", r.name)
        assert.are.equal(2, r.setting_count)
        assert.are.same({ 0, 0, 255, 255 }, r.settings.ToneCurvePV2012)
    end)

    it("rejects ambiguous names", function()
        local folders = {
            fakeFolder("A", { fakePreset("Same") }),
            fakeFolder("B", { fakePreset("Same") }),
        }
        local _, Handler = setup({ folders = folders })

        assert.has_error(function()
            Handler.getDevelopPreset({ preset_name = "Same" })
        end, "Preset selector is ambiguous; provide preset_uuid or preset_folder")
    end)

    it("accepts duplicate Lightroom aliases selected by UUID", function()
        local shared = fakePreset("John Warm", {
            uuid = "warm-1",
            file = "/user/John Warm.xmp",
            settings = { Contrast2012 = 12 },
        })
        local folders = {
            fakeFolder("Favorites", { shared }),
            fakeFolder("John", { shared }),
        }
        local _, Handler = setup({ folders = folders })

        local r = Handler.getDevelopPreset({ preset_uuid = "warm-1" })

        assert.is_true(r.success)
        assert.are.equal("warm-1", r.uuid)
        assert.are.equal(12, r.settings.Contrast2012)
    end)
end)

describe("HandlerDevelop.compareDevelopPresets", function()
    it("returns deterministic setting differences", function()
        local base = fakePreset("Approved", {
            uuid = "base",
            settings = { Contrast2012 = 10, Vibrance = 5, Saturation = -2 },
        })
        local candidate = fakePreset("Candidate", {
            uuid = "candidate",
            settings = { Contrast2012 = 15, Vibrance = 5, Dehaze = 3 },
        })
        local _, Handler = setup({ folders = { fakeFolder("John", { base, candidate }) } })

        local r = Handler.compareDevelopPresets({
            base = { preset_uuid = "base" },
            candidate = { preset_uuid = "candidate" },
        })

        assert.are.equal(3, r.changed_count)
        assert.are.equal("Contrast2012", r.changes[1].key)
        assert.are.equal(10, r.changes[1].before)
        assert.are.equal(15, r.changes[1].after)
        assert.are.equal("Dehaze", r.changes[2].key)
        assert.is_false(r.changes[2].before_present)
        assert.are.equal("Saturation", r.changes[3].key)
        assert.is_false(r.changes[3].after_present)
    end)
end)

describe("HandlerDevelop.createDevelopPreset", function()
    it("creates a versioned plugin checkpoint from explicit photo settings", function()
        local photo = helper.fakePhoto({
            id = "source",
            path = "/raw/source.nef",
            developSettings = {
                Exposure2012 = 0.5,
                Contrast2012 = 12,
                ToneCurvePV2012 = { 0, 0, 64, 58, 255, 255 },
                CropTop = 0.1,
            },
        })
        local _, Handler, state = setup({ photos = { photo } })

        local r = Handler.createDevelopPreset({
            photo_id = "source",
            preset_name = "John Warm v2",
            settings = { "Contrast2012", "ToneCurvePV2012" },
        })

        assert.is_true(r.success)
        assert.is_false(r.visible_in_develop)
        assert.are.equal("plugin", r.scope)
        assert.are.equal(1, #state.pluginPresets)
        assert.are.same({
            Contrast2012 = 12,
            ToneCurvePV2012 = { 0, 0, 64, 58, 255, 255 },
        }, state.pluginPresets[1]:getSetting())
    end)

    it("refuses duplicate names and missing source settings", function()
        local existing = fakePreset("Existing")
        local photo = helper.fakePhoto({
            id = "source", path = "/raw/source.nef", developSettings = { Exposure2012 = 0.5 },
        })
        local _, Handler = setup({ photos = { photo }, pluginPresets = { existing } })

        assert.has_error(function()
            Handler.createDevelopPreset({
                photo_id = "source", preset_name = "Existing", settings = { "Exposure2012" },
            })
        end, "Plugin preset already exists; use a versioned preset_name")
        assert.has_error(function()
            Handler.createDevelopPreset({
                photo_id = "source", preset_name = "New", settings = { "Contrast2012" },
            })
        end, "Source photo has no develop setting: Contrast2012")
    end)
end)

describe("HandlerDevelop.exportDevelopPreset", function()
    it("copies the backing file without overwriting", function()
        local preset = fakePreset("John Warm", {
            uuid = "warm-1",
            file = "/user/John Warm.xmp",
        })
        local _, Handler, state = setup({
            folders = { fakeFolder("John", { preset }) },
            files = { ["/user/John Warm.xmp"] = "file" },
        })

        local r = Handler.exportDevelopPreset({
            preset_uuid = "warm-1",
            destination_dir = "/exports",
            filename = "John-Warm-v2",
        })

        assert.is_true(r.success)
        assert.are.equal("/exports/John-Warm-v2.xmp", r.destination)
        assert.are.equal("/user/John Warm.xmp", state.copies[1].source)
        assert.are.equal("/exports/John-Warm-v2.xmp", state.copies[1].destination)
    end)

    it("refuses path traversal, extension changes, and existing files", function()
        local preset = fakePreset("John Warm", { uuid = "warm-1", file = "/user/Warm.xmp" })
        local base = {
            folders = { fakeFolder("John", { preset }) },
            files = { ["/user/Warm.xmp"] = "file", ["/exports"] = "directory" },
        }
        local _, Handler = setup(base)

        assert.has_error(function()
            Handler.exportDevelopPreset({
                preset_uuid = "warm-1", destination_dir = "/exports", filename = "../escape.xmp",
            })
        end, "filename must be a leaf filename without path separators")
        assert.has_error(function()
            Handler.exportDevelopPreset({
                preset_uuid = "warm-1", destination_dir = "/exports", filename = "Warm.lrtemplate",
            })
        end, "filename extension must match preset backing file: .xmp")

        base.files["/exports/Warm.xmp"] = "file"
        local _, ExistingHandler = setup(base)
        assert.has_error(function()
            ExistingHandler.exportDevelopPreset({
                preset_uuid = "warm-1", destination_dir = "/exports", filename = "Warm.xmp",
            })
        end, "destination preset already exists; choose a new filename")
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

    it("passes the plugin object when applying a plugin-managed checkpoint", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local preset = fakePreset("Checkpoint", { uuid = "plugin-1" })
        local _, Handler = setup({ photos = { p1 }, pluginPresets = { preset } })

        local r = Handler.applyDevelopPreset({
            photo_ids = { "1" }, preset_uuid = "plugin-1", preset_scope = "plugin",
        })

        assert.is_true(r.success)
        assert.are.equal(preset, p1.getRawMetadata(p1, "__appliedPreset"))
        assert.are.equal(_G._PLUGIN, p1.getRawMetadata(p1, "__appliedPresetPlugin"))
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
        local catalog, Handler = setup({ folders = { fakeFolder("U", { fakePreset("X") }) } })
        assert.has_error(function() Handler.applyDevelopPreset({ preset_name = "X" }) end)
        assert.has_error(function() Handler.applyDevelopPreset({ photo_ids = { "1" } }) end)
        assert.has_error(function() Handler.applyDevelopPreset({ photo_ids = {}, preset_name = "X" }) end)
        assert.has_error(function() Handler.applyDevelopPreset({ photo_ids = { "" }, preset_name = "X" }) end)
        assert.are.equal(0, catalog.getWriteAccessCount())
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

    it("copies HSL settings by whitelist", function()
        local source = helper.fakePhoto({
            id = "22", path = "/s.jpg",
            developSettings = {
                Exposure2012 = 0.5,
                HueAdjustmentOrange = -12,
                SaturationAdjustmentOrange = 18,
                LuminanceAdjustmentOrange = 7,
            },
        })
        local target = helper.fakePhoto({ id = "23", path = "/t.jpg" })
        local _, Handler = setup({ photos = { source, target } })

        Handler.copyDevelopSettings({
            source_id = "22",
            target_ids = { "23" },
            settings = { "HueAdjustmentOrange", "SaturationAdjustmentOrange", "LuminanceAdjustmentOrange" },
        })

        assert.are.same({
            HueAdjustmentOrange = -12,
            SaturationAdjustmentOrange = 18,
            LuminanceAdjustmentOrange = 7,
        }, target.getRawMetadata(target, "__appliedSettings"))
    end)

    it("errors when source missing", function()
        local _, Handler = setup({ photos = {} })
        assert.has_error(function()
            Handler.copyDevelopSettings({ source_id = "missing", target_ids = { "t" } })
        end)
    end)

    it("requires source_id and target_ids", function()
        local catalog, Handler = setup({})
        assert.has_error(function() Handler.copyDevelopSettings({ target_ids = { "t" } }) end)
        assert.has_error(function() Handler.copyDevelopSettings({ source_id = "s" }) end)
        assert.has_error(function() Handler.copyDevelopSettings({ source_id = "s", target_ids = {} }) end)
        assert.has_error(function() Handler.copyDevelopSettings({ source_id = "s", target_ids = { "" } }) end)
        assert.are.equal(0, catalog.getWriteAccessCount())
    end)

    it("rejects invalid settings whitelist before catalog access", function()
        local source = helper.fakePhoto({
            id = "20", path = "/s.jpg",
            developSettings = { Exposure2012 = 0.5 },
        })
        local target = helper.fakePhoto({ id = "21", path = "/t.jpg" })
        local catalog, Handler = setup({ photos = { source, target } })

        assert.has_error(function()
            Handler.copyDevelopSettings({
                source_id = "20",
                target_ids = { "21" },
                settings = { "UnsupportedSetting" },
            })
        end)

        assert.are.equal(0, catalog.getReadAccessCount())
        assert.are.equal(0, catalog.getWriteAccessCount())
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

    it("applies HSL settings to the photo", function()
        local p = helper.fakePhoto({ id = "2", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p } })

        local r = Handler.setDevelopSettings({
            photo_id = "2",
            settings = {
                HueAdjustmentRed = -5,
                SaturationAdjustmentOrange = -20,
                LuminanceAdjustmentYellow = 12,
            },
        })

        assert.is_true(r.success)
        assert.are.same({
            HueAdjustmentRed = -5,
            SaturationAdjustmentOrange = -20,
            LuminanceAdjustmentYellow = 12,
        }, p.getRawMetadata(p, "__appliedSettings"))
    end)

    it("errors when photo not found", function()
        local _, Handler = setup({ photos = {} })
        assert.has_error(function()
            Handler.setDevelopSettings({ photo_id = "missing", settings = { Exposure2012 = 1 } })
        end)
    end)

    it("requires photo_id and settings table", function()
        local catalog, Handler = setup({})
        assert.has_error(function() Handler.setDevelopSettings({ settings = {} }) end)
        assert.has_error(function() Handler.setDevelopSettings({ photo_id = "1" }) end)
        assert.has_error(function() Handler.setDevelopSettings({ photo_id = "1", settings = "not-a-table" }) end)
        assert.are.equal(0, catalog.getWriteAccessCount())
    end)

    it("rejects unsupported setting keys before catalog write", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local catalog, Handler = setup({ photos = { p } })

        assert.has_error(function()
            Handler.setDevelopSettings({
                photo_id = "1",
                settings = { UnsupportedSetting = 1 },
            })
        end)

        assert.are.equal(0, catalog.getWriteAccessCount())
        assert.is_nil(p.getRawMetadata(p, "__appliedSettings"))
    end)

    it("rejects unsupported setting values before catalog write", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local catalog, Handler = setup({ photos = { p } })

        assert.has_error(function()
            Handler.setDevelopSettings({
                photo_id = "1",
                settings = { Exposure2012 = { nested = true } },
            })
        end)

        assert.are.equal(0, catalog.getWriteAccessCount())
        assert.is_nil(p.getRawMetadata(p, "__appliedSettings"))
    end)
end)
