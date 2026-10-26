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

local AI_MASK_SETTINGS = {
    Exposure2012 = 1.0,
    MaskGroupBasedCorrections = {
        { CorrectionMasks = { { What = "Mask/Image", MaskSubType = 1 } } },
    },
}

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
        LrApplicationView = opts.applicationView or {
            getCurrentModuleName = function() return "library" end,
            switchToModule = function() end,
        },
        LrDate = opts.date or { currentTime = function() return 0 end },
        LrDevelopController = opts.developController or {},
        LrSelection = opts.selection or { selectNone = function() end },
        LrTasks = opts.tasks or { sleep = function() end, pcall = pcall },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerDevelop = nil
    package.loaded.DevelopSession = nil
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
        assert.are.same({ name = "Visible", folder = "User Presets", scope = "lightroom", uuid = "visible-1" }, r.presets[1])
        assert.is_false(r.has_more)
    end)

    it("pages 250 presets across folders with a default limit of 100", function()
        local first, second = {}, {}
        for i = 1, 125 do
            first[i] = fakePreset("First " .. i)
            second[i] = fakePreset("Second " .. i)
        end
        local _, Handler = setup({ folders = { fakeFolder("A", first), fakeFolder("B", second) } })
        local a = Handler.listDevelopPresets({})
        local b = Handler.listDevelopPresets({ offset = 100 })
        local c = Handler.listDevelopPresets({ offset = 200 })
        assert.are.equal(250, a.count)
        assert.are.equal(100, #a.presets)
        assert.is_true(a.has_more)
        assert.are.equal("First 101", b.presets[1].name)
        assert.are.equal("Second 76", c.presets[1].name)
        assert.are.equal(50, #c.presets)
        assert.are.equal(250, c.count)
        assert.is_false(c.has_more)
        local past = Handler.listDevelopPresets({ offset = 300 })
        assert.are.equal(250, past.count)
        assert.are.same({}, past.presets)
        assert.is_false(past.has_more)
    end)

    it("filters names literally ignoring case and folders exactly before paging", function()
        local _, Handler = setup({ folders = {
            fakeFolder("User Presets", { fakePreset("Vibrant"), fakePreset("Moody"), fakePreset("Vivid Skies") }),
            fakeFolder("Adobe Color", { fakePreset("Vivid Color"), fakePreset("100%") }),
        }, pluginPresets = { fakePreset("Checkpoint") } })
        local names = Handler.listDevelopPresets({ query = "vI" })
        assert.are.equal(3, names.count)
        local filtered = Handler.listDevelopPresets({ query = "VI", folder = "User Presets", offset = 1, limit = 1 })
        assert.are.equal(2, filtered.count)
        assert.are.equal("Vivid Skies", filtered.presets[1].name)
        assert.is_false(filtered.has_more)
        assert.are.equal(2, Handler.listDevelopPresets({ folder = "Adobe Color" }).count)
        assert.are.equal(1, Handler.listDevelopPresets({ folder = "Plugin Develop Presets" }).count)
        assert.are.equal(1, Handler.listDevelopPresets({ query = "%" }).count)
        for _, args in ipairs({ { query = "absent" }, { folder = "Adobe" }, { folder = "adobe color" } }) do
            local none = Handler.listDevelopPresets(args)
            assert.are.equal(0, none.count)
            assert.are.same({}, none.presets)
            assert.is_false(none.has_more)
        end
    end)

    it("supports count-only and floors paging values", function()
        local _, Handler = setup({ folders = { fakeFolder("A", { fakePreset("One"), fakePreset("Two") }) } })
        local count = Handler.listDevelopPresets({ limit = 0 })
        assert.are.equal(2, count.count)
        assert.are.same({}, count.presets)
        assert.is_true(count.has_more)
        local page = Handler.listDevelopPresets({ limit = 1.9, offset = 1.9 })
        assert.are.equal(1, #page.presets)
        assert.are.equal("Two", page.presets[1].name)
        assert.is_false(page.has_more)
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
        assert.are.equal("warm-1", r.uuid)
        assert.are.equal("/user/John Warm.xmp", r.file)
        assert.are.equal(2, r.setting_count)
        assert.are.same({ 0, 0, 255, 255 }, r.settings.ToneCurvePV2012)
    end)

    it("rejects ambiguous names", function()
        local folders = {
            fakeFolder("A", { fakePreset("Same", { uuid = "same-a" }) }),
            fakeFolder("B", { fakePreset("Same", { uuid = "same-b" }) }),
        }
        local _, Handler = setup({ folders = folders })

        assert.has_error(function()
            Handler.getDevelopPreset({ preset_name = "Same" })
        end, "Preset selector is ambiguous; provide preset_uuid or preset_folder")
    end)

    it("accepts a name that resolves to one aliased preset", function()
        local shared = fakePreset("Portrait", {
            uuid = "portrait-1",
            settings = { Contrast2012 = 8 },
        })
        local folders = {
            fakeFolder("Favorites", { shared }),
            fakeFolder("John", { shared }),
        }
        local _, Handler = setup({ folders = folders })

        local r = Handler.getDevelopPreset({ preset_name = "Portrait" })

        assert.is_true(r.success)
        assert.are.equal("portrait-1", r.uuid)
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

describe("HandlerDevelop.compareDevelopPresets volatile ids", function()
    local function maskedPreset(name, uuid, correctionId, maskId, extra)
        return fakePreset(name, {
            uuid = uuid,
            settings = {
                Contrast2012 = extra or 10,
                MaskGroupBasedCorrections = {
                    {
                        CorrectionID = correctionId,
                        CorrectionActive = true,
                        CorrectionMasks = { { MaskID = maskId, MaskInverted = false } },
                    },
                },
            },
        })
    end

    it("ignores the per-read CorrectionID and MaskID Lightroom regenerates", function()
        local base = maskedPreset("Masked A", "a", "correction-1", "mask-1")
        local candidate = maskedPreset("Masked B", "b", "correction-2", "mask-2")
        local _, Handler = setup({ folders = { fakeFolder("F", { base, candidate }) } })

        local r = Handler.compareDevelopPresets({
            base = { preset_uuid = "a" },
            candidate = { preset_uuid = "b" },
        })

        assert.are.equal(0, r.changed_count)
        assert.are.same({}, r.changes)
    end)

    it("still reports a real difference inside a masked preset", function()
        local base = maskedPreset("Masked A", "a", "correction-1", "mask-1", 10)
        local candidate = maskedPreset("Masked B", "b", "correction-2", "mask-2", 40)
        local _, Handler = setup({ folders = { fakeFolder("F", { base, candidate }) } })

        local r = Handler.compareDevelopPresets({
            base = { preset_uuid = "a" },
            candidate = { preset_uuid = "b" },
        })

        assert.are.equal(1, r.changed_count)
        assert.are.equal("Contrast2012", r.changes[1].key)
        assert.are.equal(10, r.changes[1].before)
        assert.are.equal(40, r.changes[1].after)
    end)

    it("strips volatile ids from the reported diff values", function()
        local base = maskedPreset("Masked A", "a", "correction-1", "mask-1")
        local candidate = fakePreset("Plain", {
            uuid = "b",
            settings = { Contrast2012 = 10 },
        })
        local _, Handler = setup({ folders = { fakeFolder("F", { base, candidate }) } })

        local r = Handler.compareDevelopPresets({
            base = { preset_uuid = "a" },
            candidate = { preset_uuid = "b" },
        })

        assert.are.equal(1, r.changed_count)
        assert.are.equal("MaskGroupBasedCorrections", r.changes[1].key)
        assert.is_true(r.changes[1].before_present)
        assert.is_false(r.changes[1].after_present)
        assert.is_nil(r.changes[1].before[1].CorrectionID)
        assert.is_nil(r.changes[1].before[1].CorrectionMasks[1].MaskID)
        assert.is_true(r.changes[1].before[1].CorrectionActive)
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
            id = "7",
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
            photo_id = "7",
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

    it("resolves the source photo OUTSIDE the read-access gate", function()
        local photo = helper.fakePhoto({
            id = "7", path = "/raw/source.nef", developSettings = { Contrast2012 = 12 },
        })
        local catalog, Handler = setup({ photos = { photo } })

        Handler.createDevelopPreset({
            photo_id = "/raw/source.nef", preset_name = "Contrast v1", settings = { "Contrast2012" },
        })

        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)

    it("captures curves Lightroom stores off the 0-255 anchors", function()
        local photo = helper.fakePhoto({
            id = "7",
            path = "/raw/source.nef",
            developSettings = {
                ToneCurvePV2012 = { 17, 0, 127.5, 130.2, 255, 240 },
            },
        })
        local _, Handler, state = setup({ photos = { photo } })

        local r = Handler.createDevelopPreset({
            photo_id = "7",
            preset_name = "Clipped v1",
            settings = { "ToneCurvePV2012" },
        })

        assert.is_true(r.success)
        assert.are.same(
            { ToneCurvePV2012 = { 17, 0, 127.5, 130.2, 255, 240 } },
            state.pluginPresets[1]:getSetting()
        )
    end)

    it("refuses duplicate names and missing source settings", function()
        local existing = fakePreset("Existing")
        local photo = helper.fakePhoto({
            id = "7", path = "/raw/source.nef", developSettings = { Exposure2012 = 0.5 },
        })
        local _, Handler = setup({ photos = { photo }, pluginPresets = { existing } })

        assert.has_error(function()
            Handler.createDevelopPreset({
                photo_id = "7", preset_name = "Existing", settings = { "Exposure2012" },
            })
        end, "Plugin preset already exists; use a versioned preset_name")
        assert.has_error(function()
            Handler.createDevelopPreset({
                photo_id = "7", preset_name = "New", settings = { "Contrast2012" },
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
    it("resolves photos OUTSIDE the write-access gate", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local preset = fakePreset("Vibrant")
        local catalog, Handler = setup({ photos = { p1 }, folders = { fakeFolder("User", { preset }) } })

        Handler.applyDevelopPreset({ photo_ids = { "1" }, preset_name = "Vibrant" })

        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

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

    it("recomputes AI masks on each target after a preset with an AI mask", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", aiUpdate = "ok" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", aiUpdate = "ok" })
        local preset = fakePreset("Subject", { settings = AI_MASK_SETTINGS })
        local catalog, Handler = setup({ photos = { p1, p2 }, folders = { fakeFolder("User", { preset }) } })

        local r = Handler.applyDevelopPreset({ photo_ids = { "1", "2" }, preset_name = "Subject" })

        assert.are.equal(2, r.ai_updated)
        assert.are.same({}, r.ai_update_failed)
        assert.are.equal(1, p1.getRawMetadata(p1, "__aiUpdateCalls"))
        assert.are.equal(1, p2.getRawMetadata(p2, "__aiUpdateCalls"))
        assert.are.equal(2, catalog.getWriteAccessCount())
        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

    it("runs the AI update after the preset is applied", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", aiUpdate = "ok" })
        local preset = fakePreset("Subject", { settings = AI_MASK_SETTINGS })
        local _, Handler = setup({ photos = { p1 }, folders = { fakeFolder("User", { preset }) } })

        Handler.applyDevelopPreset({ photo_ids = { "1" }, preset_name = "Subject" })

        assert.are.equal(preset, p1.getRawMetadata(p1, "__aiUpdateAfterPreset"))
    end)

    it("lists photos whose AI mask recompute failed and keeps the rest", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", aiUpdate = "fail" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", aiUpdate = "ok" })
        local preset = fakePreset("Subject", { settings = AI_MASK_SETTINGS })
        local _, Handler = setup({ photos = { p1, p2 }, folders = { fakeFolder("User", { preset }) } })

        local r = Handler.applyDevelopPreset({ photo_ids = { "1", "2" }, preset_name = "Subject" })

        assert.is_true(r.success)
        assert.are.equal(2, r.applied)
        assert.are.equal(1, r.ai_updated)
        assert.are.same({ "1" }, r.ai_update_failed)
        assert.is_truthy(r.message:find("AI mask update failed for 1 photos", 1, true))
    end)

    it("does not touch AI settings for a preset without AI masks", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", aiUpdate = "ok" })
        local gradient = { MaskGroupBasedCorrections = { { CorrectionMasks = { { What = "Mask/Gradient" } } } } }
        local preset = fakePreset("Plain", { settings = gradient })
        local catalog, Handler = setup({ photos = { p1 }, folders = { fakeFolder("User", { preset }) } })

        local r = Handler.applyDevelopPreset({ photo_ids = { "1" }, preset_name = "Plain" })

        assert.are.equal(0, r.ai_updated)
        assert.are.same({}, r.ai_update_failed)
        assert.is_nil(p1.getRawMetadata(p1, "__aiUpdateCalls"))
        assert.are.equal(1, catalog.getWriteAccessCount())
    end)

    it("behaves as before when Lightroom has no updateAISettings", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local preset = fakePreset("Subject", { settings = AI_MASK_SETTINGS })
        local catalog, Handler = setup({ photos = { p1 }, folders = { fakeFolder("User", { preset }) } })

        local r = Handler.applyDevelopPreset({ photo_ids = { "1" }, preset_name = "Subject" })

        assert.is_true(r.success)
        assert.are.equal(1, r.applied)
        assert.are.equal(0, r.ai_updated)
        assert.are.same({}, r.ai_update_failed)
        assert.is_truthy(r.message:find("13.3", 1, true))
        assert.are.equal(1, catalog.getWriteAccessCount())
    end)

    it("skips the AI update when no photo resolved", function()
        local preset = fakePreset("Subject", { settings = AI_MASK_SETTINGS })
        local catalog, Handler = setup({ photos = {}, folders = { fakeFolder("User", { preset }) } })

        local r = Handler.applyDevelopPreset({ photo_ids = { "ghost" }, preset_name = "Subject" })

        assert.are.equal(0, r.applied)
        assert.are.equal(0, r.ai_updated)
        assert.are.equal(1, catalog.getWriteAccessCount())
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

describe("HandlerDevelop numeric photo ids", function()
    it("accepts the numeric ids the catalog hands out", function()
        local source = helper.fakePhoto({
            id = 10, path = "/s.jpg",
            developSettings = { Exposure2012 = 1.0 },
        })
        local target = helper.fakePhoto({ id = 11, path = "/t.jpg" })
        local _, Handler = setup({ photos = { source, target } })

        local set = Handler.setDevelopSettings({
            photo_id = 10,
            settings = { Exposure2012 = 0.25 },
        })
        assert.is_true(set.success)

        local copied = Handler.copyDevelopSettings({ source_id = 10, target_ids = { 11 } })
        assert.are.equal(1, copied.copied)
    end)

    it("reports target ids that matched no photo", function()
        local source = helper.fakePhoto({
            id = 10, path = "/s.jpg", developSettings = { Exposure2012 = 1.0 },
        })
        local target = helper.fakePhoto({ id = 11, path = "/t.jpg" })
        local _, Handler = setup({ photos = { source, target } })

        local r = Handler.copyDevelopSettings({ source_id = 10, target_ids = { 11, "ghost" } })

        assert.are.equal(1, r.copied)
        assert.are.same({ "ghost" }, r.missing)
        assert.is_not_nil(r.message:find("1 ids not found", 1, true))
    end)

    it("still rejects ids that are neither a number nor a non-empty string", function()
        local _, Handler = setup({})
        assert.has_error(function()
            Handler.setDevelopSettings({ photo_id = true, settings = { Exposure2012 = 0 } })
        end, "photo_id is required")
        assert.has_error(function()
            Handler.copyDevelopSettings({ source_id = "s", target_ids = { {} } })
        end, "target_ids[1] must be a photo id or file path")
    end)
end)

describe("HandlerDevelop.copyDevelopSettings", function()
    it("names the history step on every target", function()
        local source = helper.fakePhoto({ id = "10", developSettings = { Exposure2012 = 1 } })
        local first = helper.fakePhoto({ id = "11" })
        local second = helper.fakePhoto({ id = "12" })
        local _, Handler = setup({ photos = { source, first, second } })

        Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11", "12" } })

        for _, photo in ipairs({ first, second }) do
            assert.are.equal("Copy Develop Settings", photo:getRawMetadata("__appliedHistoryName"))
            assert.is_nil(photo:getRawMetadata("__appliedFlattenAutoNow"))
        end
        assert.is_nil(source:getRawMetadata("__appliedHistoryName"))
    end)

    it("resolves targets OUTSIDE the write-access gate", function()
        local source = helper.fakePhoto({
            id = "10", path = "/s.jpg",
            developSettings = { Exposure2012 = 1.0 },
        })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg" })
        local catalog, Handler = setup({ photos = { source, t1 } })

        Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

    it("resolves the source OUTSIDE the read-access gate", function()
        local source = helper.fakePhoto({
            id = "10", path = "/s.jpg",
            developSettings = { Exposure2012 = 1.0 },
        })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg" })
        local catalog, Handler = setup({ photos = { source, t1 } })

        Handler.copyDevelopSettings({ source_id = "/s.jpg", target_ids = { "11" } })

        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)

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

    it("recomputes AI masks on each target when the copy carries them", function()
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = AI_MASK_SETTINGS })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg", aiUpdate = "ok" })
        local t2 = helper.fakePhoto({ id = "12", path = "/t2.jpg", aiUpdate = "ok" })
        local catalog, Handler = setup({ photos = { source, t1, t2 } })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11", "12" } })

        assert.are.equal(2, r.copied)
        assert.are.equal(2, r.ai_updated)
        assert.are.same({}, r.ai_update_failed)
        assert.are.same(AI_MASK_SETTINGS, t1.getRawMetadata(t1, "__aiUpdateAfterSettings"))
        assert.are.equal(1, t2.getRawMetadata(t2, "__aiUpdateCalls"))
        assert.are.equal(2, catalog.getWriteAccessCount())
        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

    it("drops the source's computed AI mask data so each target recomputes its own", function()
        local sourceSettings = {
            Exposure2012 = 1.0,
            MaskGroupBasedCorrections = {
                {
                    CorrectionName = "Mask 1",
                    CorrectionMasks = {
                        {
                            What = "Mask/Image",
                            MaskSubType = 1,
                            Origin = "619,0",
                            MaskDigest = "mask-digest",
                            InputDigest = "input-digest",
                            LocalInputDigest = "local-digest",
                        },
                        { What = "Mask/Gradient", MaskDigest = "kept-on-geometry-masks" },
                    },
                },
            },
        }
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = sourceSettings })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg", aiUpdate = "ok" })
        local _, Handler = setup({ photos = { source, t1 } })

        Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

        local applied = t1.getRawMetadata(t1, "__appliedSettings")
        assert.are.equal(1.0, applied.Exposure2012)
        assert.are.same({
            { What = "Mask/Image", MaskSubType = 1, Origin = "619,0" },
            { What = "Mask/Gradient", MaskDigest = "kept-on-geometry-masks" },
        }, applied.MaskGroupBasedCorrections[1].CorrectionMasks)
        assert.are.equal("Mask 1", applied.MaskGroupBasedCorrections[1].CorrectionName)
        assert.are.equal("mask-digest", sourceSettings.MaskGroupBasedCorrections[1].CorrectionMasks[1].MaskDigest)
    end)

    it("lists targets whose AI mask recompute failed", function()
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = AI_MASK_SETTINGS })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg", aiUpdate = "ok" })
        local t2 = helper.fakePhoto({ id = "12", path = "/t2.jpg", aiUpdate = "fail" })
        local _, Handler = setup({ photos = { source, t1, t2 } })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11", "12" } })

        assert.is_true(r.success)
        assert.are.equal(2, r.copied)
        assert.are.equal(1, r.ai_updated)
        assert.are.same({ "12" }, r.ai_update_failed)
    end)

    it("does not touch AI settings when the copy has no AI masks", function()
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = { Exposure2012 = 1.0 } })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg", aiUpdate = "ok" })
        local catalog, Handler = setup({ photos = { source, t1 } })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

        assert.are.equal(0, r.ai_updated)
        assert.is_nil(t1.getRawMetadata(t1, "__aiUpdateCalls"))
        assert.are.equal(1, catalog.getWriteAccessCount())
    end)

    it("does not touch AI settings when the whitelist drops the masks", function()
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = AI_MASK_SETTINGS })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg", aiUpdate = "ok" })
        local _, Handler = setup({ photos = { source, t1 } })

        local r = Handler.copyDevelopSettings({
            source_id = "10", target_ids = { "11" }, settings = { "Exposure2012" },
        })

        assert.are.equal(0, r.ai_updated)
        assert.is_nil(t1.getRawMetadata(t1, "__aiUpdateCalls"))
    end)

    it("behaves as before when Lightroom has no updateAISettings", function()
        local source = helper.fakePhoto({ id = "10", path = "/s.jpg", developSettings = AI_MASK_SETTINGS })
        local t1 = helper.fakePhoto({ id = "11", path = "/t1.jpg" })
        local catalog, Handler = setup({ photos = { source, t1 } })

        local r = Handler.copyDevelopSettings({ source_id = "10", target_ids = { "11" } })

        assert.is_true(r.success)
        assert.are.equal(1, r.copied)
        assert.are.equal(0, r.ai_updated)
        assert.is_truthy(r.message:find("13.3", 1, true))
        assert.are.equal(1, catalog.getWriteAccessCount())
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
    it("names the history step", function()
        local photo = helper.fakePhoto({ id = "1" })
        local _, Handler = setup({ photos = { photo } })

        Handler.setDevelopSettings({ photo_id = "1", settings = { Exposure2012 = 0.5 } })

        assert.are.equal("Set Develop Settings", photo:getRawMetadata("__appliedHistoryName"))
        assert.is_nil(photo:getRawMetadata("__appliedFlattenAutoNow"))
    end)

    it("resolves the photo OUTSIDE the write-access gate", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local catalog, Handler = setup({ photos = { p } })

        Handler.setDevelopSettings({ photo_id = "1", settings = { Exposure2012 = 0.5 } })

        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

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

    it("applies RGB composite and per-channel point curves", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p } })
        local composite = { 0, 0, 64, 48, 192, 210, 255, 255 }
        local red = { 0, 4, 128, 132, 255, 250 }

        local r = Handler.setDevelopSettings({
            photo_id = "1",
            settings = {
                ToneCurveName2012 = "Custom",
                ToneCurvePV2012 = composite,
                ToneCurvePV2012Red = red,
            },
        })

        assert.is_true(r.success)
        local applied = p.getRawMetadata(p, "__appliedSettings")
        assert.are.same(composite, applied.ToneCurvePV2012)
        assert.are.same(red, applied.ToneCurvePV2012Red)
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

    it("rejects malformed point curves before catalog write", function()
        local invalidCurves = {
            { 0, 0, 128, 120, 255 },
            { 0, 0, 128, 120, 100, 150, 255, 255 },
            { 0, 0, 255, 300 },
            { 10, 0, 255, 255 },
            { 0, 0, 240, 255 },
            { 0, 0, 128.5, 120, 255, 255 },
        }

        for _, curve in ipairs(invalidCurves) do
            local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
            local catalog, Handler = setup({ photos = { p } })

            assert.has_error(function()
                Handler.setDevelopSettings({
                    photo_id = "1",
                    settings = { ToneCurvePV2012 = curve },
                })
            end)

            assert.are.equal(0, catalog.getWriteAccessCount())
            assert.is_nil(p.getRawMetadata(p, "__appliedSettings"))
        end
    end)
end)

-- Develop module fake for applyDenoise: one active photo, an Enhance panel per photo.
-- Photo spec: id, denoise (current amount, or nil for none), enabled (false = Denoise
-- unavailable), panel (override the panel state, e.g. a stale one).
local function denoiseSetup(opts)
    local photos, panels, outside, settingsOf = {}, {}, {}, {}
    local function saveDenoise(photo, amount)
        if opts.notSaved then return end
        settingsOf[photo].FilterList = { Filters = { { Name = "Enhance", CompressedSettings = "d" .. amount } } }
    end
    for _, spec in ipairs(opts.photos) do
        local settings = {}
        local p = helper.fakePhoto({ id = spec.id, path = "/" .. spec.id .. ".rw2", developSettings = settings })
        settingsOf[p] = settings
        if spec.denoise then
            settings.FilterList = { Filters = { { Name = "Enhance", CompressedSettings = "d" .. spec.denoise } } }
        end
        photos[#photos + 1] = p
        panels[p] = spec.panel or {
            denoiseEnabled = spec.enabled ~= false,
            denoiseState = spec.denoise ~= nil,
            denoiseAmount = spec.denoise or 50,
        }
        outside[p] = spec.outsideSource
    end
    local active = not opts.nothingSelected and photos[1] or nil
    local module = "library"
    local sources = { "folder" }
    local dropNextSelection = false
    local autoSelectPending = false
    local clock = { now = 0 }
    local calls = {
        selections = {}, enhance = {}, amounts = {}, switched = 0, modules = {}, sources = {}, selectNone = 0,
    }
    local Handler
    local pendingAuto, pendingAutoWhiteBalance
    local controller = {
        resetAllDevelopAdjustments = function()
            if opts.resetError then error(opts.resetError) end
            calls.resets = calls.resets or {}
            calls.resets[#calls.resets + 1] = active.localIdentifier
            if opts.onReset then opts.onReset(clock) end
        end,
        getEnhancePanelState = function()
            if module ~= "develop" or opts.panelUnavailable then return nil end
            if not active then return { denoiseEnabled = false } end
            -- Lightroom returns a fresh copy of the panel state on every call.
            local copy = {}
            for k, v in pairs(panels[active]) do copy[k] = v end
            return copy
        end,
        setEnhance = function(name, on, amount)
            if opts.enhanceError then error(opts.enhanceError) end
            calls.enhance[#calls.enhance + 1] = { id = active.localIdentifier, name = name, on = on, amount = amount }
            if opts.onEnhance then opts.onEnhance(Handler, clock) end
            if opts.enhanceIgnored then return end
            panels[active].denoiseState, panels[active].denoiseAmount = on, amount
            saveDenoise(active, amount)
        end,
        changeDenoiseAmount = function(amount)
            calls.amounts[#calls.amounts + 1] = { id = active.localIdentifier, amount = amount }
            panels[active].denoiseAmount = amount
            saveDenoise(active, amount)
        end,
    }
    controller.setAutoTone = function()
        if opts.autoError then error(opts.autoError) end
        if opts.onAuto then opts.onAuto(Handler, clock) end
        if opts.autoDelay then
            pendingAuto = { photo = active, at = clock.now + opts.autoDelay }
        elseif not opts.autoUnchanged then
            settingsOf[active].Exposure2012 = 1.25
        end
        calls.autoTone = (calls.autoTone or 0) + 1
    end
    controller.setAutoWhiteBalance = function()
        if opts.autoWhiteBalanceDelay then
            pendingAutoWhiteBalance = { photo = active, at = clock.now + opts.autoWhiteBalanceDelay }
        elseif not opts.autoUnchanged then
            settingsOf[active].Temperature = 5200
            settingsOf[active].Tint = 12
        end
        calls.autoWhiteBalance = (calls.autoWhiteBalance or 0) + 1
    end
    if opts.beforeLrC15 then controller.getEnhancePanelState = nil end
    local view = {
        getCurrentModuleName = function() return module end,
        switchToModule = function(name)
            module = name
            calls.switched = calls.switched + 1
            calls.modules[#calls.modules + 1] = name
        end,
    }
    local tasks = {
        pcall = pcall,
        sleep = function(seconds)
            clock.now = clock.now + seconds
            if pendingAuto and clock.now >= pendingAuto.at then
                settingsOf[pendingAuto.photo].Exposure2012 = 1.25
                pendingAuto = nil
            end
            if pendingAutoWhiteBalance and clock.now >= pendingAutoWhiteBalance.at then
                settingsOf[pendingAutoWhiteBalance.photo].Temperature = 5200
                settingsOf[pendingAutoWhiteBalance.photo].Tint = 12
                pendingAutoWhiteBalance = nil
            end
            if autoSelectPending then
                autoSelectPending = false
                active = photos[1]
            end
            if opts.onSleep then
                local photo = opts.onSleep(seconds, photos)
                if photo then active = photo end
            end
        end,
    }
    local selection = {
        selectNone = function()
            active = nil
            calls.selectNone = calls.selectNone + 1
        end,
    }
    local catalog
    catalog, Handler = setup({
        photos = photos,
        developController = controller,
        applicationView = view,
        tasks = tasks,
        date = { currentTime = function() return clock.now end },
        selection = selection,
    })
    local recordSelection = catalog.setSelectedPhotos
    catalog.setSelectedPhotos = function(self, photo, selected)
        recordSelection(self, photo, selected)
        if dropNextSelection then
            dropNextSelection = false
            return
        end
        if outside[photo] and sources[1] ~= catalog.kAllPhotos then return end
        active = photo
        calls.selections[#calls.selections + 1] = photo.localIdentifier
    end
    catalog.getTargetPhoto = function() return active end
    catalog.kAllPhotos = "all photographs"
    catalog.getActiveSources = function() return sources end
    catalog.setActiveSources = function(_, newSources)
        sources = newSources
        calls.sources[#calls.sources + 1] = newSources[1]
        dropNextSelection = opts.dropSelectionAfterSourceSwitch or false
        autoSelectPending = opts.autoSelectAfterSourceSwitch or false
    end
    return Handler, calls, photos, clock
end

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

describe("HandlerDevelop.resetDevelopAdjustments", function()
    it("resets unique photos and skips missing and duplicate ids", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" }, { id = "2" } } })
        local result = Handler.resetDevelopAdjustments({ photo_ids = { "1", "404", "1", "2" }, confirm = true })
        assert.is_true(result.success)
        assert.are.same({ "1", "2" }, calls.resets)
        assert.are.equal(2, result.reset)
        assert.are.equal(2, result.skipped)
        assert.are.equal("photo not found", result.results[2].reason)
        assert.are.equal("duplicate", result.results[3].reason)
        assert.are.equal("library", calls.modules[#calls.modules])
        assert.are.equal("1", calls.selections[#calls.selections])
    end)

    it("returns the unprocessed ids when the budget expires", function()
        local Handler, calls = denoiseSetup({
            photos = { { id = "1" }, { id = "2" }, { id = "3" } },
            onReset = function(clock) clock.now = 240 end,
        })
        local result = Handler.resetDevelopAdjustments({ photo_ids = { "1", "2", "3" }, confirm = true })
        assert.is_false(result.complete)
        assert.are.same({ "1" }, calls.resets)
        assert.are.same({ "2", "3" }, result.remaining_ids)
    end)

    it("reports reset failures and restores the view", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" } }, resetError = "reset refused" })
        local result = Handler.resetDevelopAdjustments({ photo_ids = { "1" }, confirm = true })
        assert.is_false(result.success)
        assert.are.equal(1, result.failed)
        assert.matches("reset refused", result.results[1].reason)
        assert.are.equal("library", calls.modules[#calls.modules])
    end)

    it("requires explicit confirmation before changing photos", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" } } })
        for _, args in ipairs({ { photo_ids = { "1" } }, { photo_ids = { "1" }, confirm = false } }) do
            assert.matches("confirm must be true", errorOf(function() Handler.resetDevelopAdjustments(args) end))
        end
        assert.is_nil(calls.resets)
        assert.are.equal(0, calls.switched)
    end)

    it("returns all ids when canceled before opening Develop", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" } } })
        local result = Handler.resetDevelopAdjustments({ photo_ids = { "1" }, confirm = true }, {
            isCanceled = function() return true end,
        })
        assert.are.same({ "1" }, result.remaining_ids)
        assert.is_nil(calls.resets)
        assert.are.equal(0, calls.switched)
    end)
end)

describe("HandlerDevelop.applyDenoise", function()
    it("cancel keeps completed denoise and restores the module and selection", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" }, { id = "2" }, { id = "3" } } })
        local context = { isCanceled = function() return #calls.enhance >= 1 end, report = function() end }

        local r = Handler.applyDenoise({ photo_ids = { "1", "2", "3" }, amount = 45 }, context)

        assert.are.equal(1, r.applied)
        assert.is_false(r.complete)
        assert.are.same({ "2", "3" }, r.remaining_ids)
        assert.are.same({ { id = "1", name = "denoise", on = true, amount = 45 } }, calls.enhance)
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("switches to Develop and applies Denoise one active photo at a time", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" }, { id = "2" } } })

        local r = Handler.applyDenoise({ photo_ids = { "1", "2" }, amount = 45 })

        assert.is_true(r.success)
        assert.is_true(r.complete)
        assert.are.equal(2, r.applied)
        assert.are.same({ "develop", "library" }, calls.modules)
        assert.are.same({
            { id = "1", name = "denoise", on = true, amount = 45 },
            { id = "2", name = "denoise", on = true, amount = 45 },
        }, calls.enhance)
        assert.is_nil(r.remaining_ids)
    end)

    it("rejects a second call while one is running and accepts calls afterwards", function()
        local nested
        local Handler, calls = denoiseSetup({
            photos = { { id = "1" }, { id = "2" } },
            onEnhance = function(handler)
                if nested == nil then
                    nested = errorOf(function() handler.applyDenoise({ photo_ids = { "2" }, amount = 70 }) end)
                end
            end,
        })

        local r = Handler.applyDenoise({ photo_ids = { "1" }, amount = 30 })

        assert.are.equal(1, r.applied)
        assert.truthy(nested:find("already running", 1, true))
        assert.are.same({ { id = "1", name = "denoise", on = true, amount = 30 } }, calls.enhance)
        assert.are.equal(1, Handler.applyDenoise({ photo_ids = { "2" }, amount = 70 }).applied)
    end)

    it("does not apply Denoise when another photo became active while the panel settled", function()
        local Handler, calls = denoiseSetup({
            photos = { { id = "1" }, { id = "2" } },
            onSleep = function(seconds, photos)
                if seconds == 0.5 then return photos[2] end
            end,
        })

        local r = Handler.applyDenoise({ photo_ids = { "1" }, amount = 30 })

        assert.is_false(r.success)
        assert.are.equal("failed", r.results[1].status)
        assert.truthy(r.results[1].reason:find("another photo became active", 1, true))
        assert.are.same({}, calls.enhance)
    end)

    it("reports an apply the panel never shows as failed", function()
        local Handler = denoiseSetup({ photos = { { id = "1" } }, enhanceIgnored = true })

        local r = Handler.applyDenoise({ photo_ids = { "1" }, amount = 30 })

        assert.is_false(r.success)
        assert.are.equal(1, r.failed)
        assert.truthy(r.results[1].reason:find("did not show the new amount", 1, true))
    end)

    it("reports a change Lightroom shows but never saves as failed and puts the panel back", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" }, { id = "2", denoise = 40 } }, notSaved = true })

        local r = Handler.applyDenoise({ photo_ids = { "1", "2" }, amount = 60 })

        assert.is_false(r.success)
        assert.are.equal(2, r.failed)
        assert.truthy(r.results[1].reason:find("did not save the change", 1, true))
        assert.truthy(r.results[2].reason:find("did not save the change", 1, true))
        assert.are.same({ { id = "2", amount = 60 }, { id = "2", amount = 40 } }, calls.amounts)
    end)

    it("stops at the time budget and returns the ids it did not reach", function()
        local Handler = denoiseSetup({
            photos = { { id = "1" }, { id = "2" }, { id = "3" }, { id = "4" } },
            onEnhance = function(_, clock) clock.now = clock.now + 100 end,
        })

        local r = Handler.applyDenoise({ photo_ids = { "1", "2", "3", "4", "404" }, amount = 30 })

        assert.are.equal(3, r.applied)
        assert.is_false(r.complete)
        assert.is_false(r.success)
        assert.are.same({ "4", "404" }, r.remaining_ids)
        assert.truthy(r.message:find("remaining_ids", 1, true))
    end)

    it("selects a photo outside the current source through All Photographs, then restores the view", function()
        local Handler, calls = denoiseSetup({
            photos = { { id = "1" }, { id = "2", outsideSource = true }, { id = "3", outsideSource = true } },
            dropSelectionAfterSourceSwitch = true,
        })

        local r = Handler.applyDenoise({ photo_ids = { "2", "3" }, amount = 30 })

        assert.are.equal(2, r.applied)
        assert.are.same({ "all photographs", "folder" }, calls.sources)
        assert.are.same({ "2", "3", "1" }, calls.selections)
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("clears the selection again when nothing was selected", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" } }, nothingSelected = true })

        assert.are.equal(1, Handler.applyDenoise({ photo_ids = { "1" }, amount = 30 }).applied)
        assert.are.equal(1, calls.selectNone)
    end)

    it("clears the selection again after Lightroom auto-selects a photo in the restored source", function()
        local Handler, calls = denoiseSetup({
            photos = { { id = "1" }, { id = "2", outsideSource = true } },
            nothingSelected = true,
            autoSelectAfterSourceSwitch = true,
        })

        assert.are.equal(1, Handler.applyDenoise({ photo_ids = { "2" }, amount = 30 }).applied)
        assert.are.same({ "all photographs", "folder" }, calls.sources)
        assert.are.equal(2, calls.selectNone)
    end)

    it("restores the view and releases the run when Develop fails to open", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" } }, panelUnavailable = true })

        local err = errorOf(function() Handler.applyDenoise({ photo_ids = { "1" }, amount = 30 }) end)

        assert.truthy(err:find("Develop module did not open", 1, true))
        assert.are.same({ "develop", "library" }, calls.modules)
        assert.is_nil(errorOf(function() Handler.applyDenoise({ photo_ids = { "1" }, amount = 30 }) end)
            :find("already running", 1, true))
    end)

    it("asks for Lightroom Classic 15 before touching Develop on older versions", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" } }, beforeLrC15 = true })

        local err = errorOf(function() Handler.applyDenoise({ photo_ids = { "1" }, amount = 30 }) end)

        assert.truthy(err:find("needs Lightroom Classic 15 or later", 1, true))
        assert.are.equal(0, calls.switched)
    end)

    it("puts the user's selection back unless restore_selection is false", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" }, { id = "2" } } })
        Handler.applyDenoise({ photo_ids = { "2" }, amount = 30 })
        assert.are.same({ "2", "1" }, calls.selections)

        local Handler2, calls2 = denoiseSetup({ photos = { { id = "1" }, { id = "2" } } })
        Handler2.applyDenoise({ photo_ids = { "2" }, amount = 30, restore_selection = false })
        assert.are.same({ "2" }, calls2.selections)
    end)

    it("leaves photos at the amount alone and changes a different amount", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1", denoise = 30 }, { id = "2", denoise = 50 } } })

        local r = Handler.applyDenoise({ photo_ids = { "1", "2" }, amount = 30 })

        assert.are.equal(1, r.unchanged)
        assert.are.equal(1, r.amount_changed)
        assert.are.equal(50, r.results[2].previous_amount)
        assert.are.same({ { id = "2", amount = 30 } }, calls.amounts)
        assert.are.same({}, calls.enhance)
    end)

    it("trusts the photo's own settings over a panel still showing the previous photo", function()
        local stale = { denoiseEnabled = true, denoiseState = true, denoiseAmount = 30 }
        local Handler, calls = denoiseSetup({ photos = { { id = "1", panel = stale } } })

        local r = Handler.applyDenoise({ photo_ids = { "1" }, amount = 30 })

        assert.are.equal(1, r.applied)
        assert.are.equal(1, #calls.enhance)
    end)

    it("skips missing photos and photos Denoise does not support", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1", enabled = false } } })

        local r = Handler.applyDenoise({ photo_ids = { "1", "404" }, amount = 40 })

        assert.are.equal(2, r.skipped)
        assert.are.equal("Denoise is not available for this photo", r.results[1].reason)
        assert.are.equal("photo not found", r.results[2].reason)
        assert.are.same({}, calls.enhance)
    end)

    it("reports a Develop error per photo and carries on", function()
        local Handler = denoiseSetup({ photos = { { id = "1" }, { id = "2" } }, enhanceError = "panel busy" })

        local r = Handler.applyDenoise({ photo_ids = { "1", "2" }, amount = 45 })

        assert.is_false(r.success)
        assert.are.equal(2, r.failed)
        assert.truthy(r.results[1].reason:find("panel busy", 1, true))
    end)

    it("validates amount, batch size and restore_selection before touching Develop", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" } } })
        for _, bad in ipairs({ 0, 101, 30.5, "30" }) do
            local err = errorOf(function() Handler.applyDenoise({ photo_ids = { "1" }, amount = bad }) end)
            assert.truthy(err:find("amount must be an integer from 1 to 100", 1, true))
        end
        local many = {}
        for i = 1, 101 do many[i] = tostring(i) end
        assert.truthy(errorOf(function() Handler.applyDenoise({ photo_ids = many, amount = 30 }) end)
            :find("at most 100", 1, true))
        assert.truthy(errorOf(function()
            Handler.applyDenoise({ photo_ids = { "1" }, amount = 30, restore_selection = "no" })
        end):find("restore_selection must be a boolean", 1, true))
        assert.are.equal(0, calls.switched)
    end)
end)


local function processVersionSetup(opts)
    opts = opts or {}
    local photos = {
        helper.fakePhoto({ id = "1", path = "/1.raw", developSettings = opts.settings1 }),
        helper.fakePhoto({ id = "2", path = "/2.raw", developSettings = opts.settings2 }),
    }
    local active, selected, module, sources = photos[1], { photos[1] }, "library", { "folder" }
    local versions, calls, now = { [photos[1]] = "Version 5", [photos[2]] = "Version 6" }, {}, 0
    local catalog, Handler = setup({
        photos = photos,
        applicationView = {
            getCurrentModuleName = function() return module end,
            switchToModule = function(name) module = name end,
        },
        developController = {
            getProcessVersion = function() return versions[active] end,
            setProcessVersion = function(version)
                calls[#calls + 1] = active.localIdentifier
                if opts.fail then error("version change failed") end
                if not opts.ignored then versions[active] = version end
                now = now + (opts.cost or 0)
            end,
        },
        date = { currentTime = function() return now end },
        tasks = { pcall = pcall, sleep = function(seconds) now = now + seconds end },
    })
    catalog.getTargetPhoto = function() return active end
    catalog.getTargetPhotos = function() return selected end
    catalog.getActiveSources = function() return sources end
    catalog.setActiveSources = function(_, value) sources = value end
    catalog.setSelectedPhotos = function(_, photo, selection) active, selected = photo, selection end
    return Handler, calls, function() return module, active.localIdentifier, sources[1] end
end

describe("HandlerDevelop.setProcessVersion", function()
    it("rejects invalid versions and missing confirmation before opening Develop", function()
        local Handler, calls, view = processVersionSetup()
        for _, version in ipairs({ "Version 7", "2012" }) do
            assert.has_error(function()
                Handler.setProcessVersion({ photo_ids = { "1" }, version = version, confirm = true })
            end)
        end
        assert.has_error(function() Handler.setProcessVersion({ photo_ids = { "1" }, version = "Version 6" }) end)
        assert.are.equal(0, #calls)
        assert.are.equal("library", view())
    end)

    it("reports previous and actual versions and leaves unchanged photos alone", function()
        local Handler, calls, view = processVersionSetup()
        local result = Handler.setProcessVersion({ photo_ids = { "1", "2", "/1.raw", "missing" }, version = "Version 6", confirm = true })
        assert.is_true(result.success)
        assert.are.same({ "1" }, calls)
        assert.are.equal(1, result.changed)
        assert.are.equal(1, result.unchanged)
        assert.are.equal(2, result.skipped)
        assert.are.equal("Version 5", result.results[1].previous_version)
        assert.are.equal("Version 6", result.results[1].new_version)
        assert.are.equal("duplicate", result.results[3].reason)
        assert.are.equal("photo not found", result.results[4].reason)
        local module, active, source = view()
        assert.are.equal("library", module)
        assert.are.equal("1", active)
        assert.are.equal("folder", source)
    end)

    it("refuses masked-photo downgrades before any setter call", function()
        local Handler, calls, view = processVersionSetup({ settings2 = { MaskGroupBasedCorrections = { { CorrectionMasks = {} } } } })
        local result = Handler.setProcessVersion({ photo_ids = { "2" }, version = "Version 5", confirm = true })
        assert.is_true(result.success)
        assert.are.equal(1, result.skipped)
        assert.are.equal("Version 6", result.results[1].previous_version)
        assert.are.equal("Version 6", result.results[1].new_version)
        assert.truthy(result.results[1].reason:find("downgrades are refused", 1, true))
        assert.are.equal(0, #calls)
        assert.are.equal("library", view())
    end)

    it("still upgrades masked photos and downgrades photos without masks", function()
        local Handler, calls = processVersionSetup({ settings1 = { MaskGroupBasedCorrections = { {} } } })
        assert.are.equal(1, Handler.setProcessVersion({ photo_ids = { "1" }, version = "Version 6", confirm = true }).changed)
        assert.are.equal(1, Handler.setProcessVersion({ photo_ids = { "2" }, version = "Version 4", confirm = true }).changed)
        assert.are.same({ "1", "2" }, calls)
    end)

    it("continues an unmasked batch after refusing a masked downgrade", function()
        local Handler, calls = processVersionSetup({ settings2 = { MaskGroupBasedCorrections = { {} } } })
        local result = Handler.setProcessVersion({ photo_ids = { "2", "1" }, version = "Version 4", confirm = true })
        assert.are.equal(1, result.skipped)
        assert.are.equal(1, result.changed)
        assert.are.same({ "1" }, calls)
    end)

    it("fails closed when mask settings cannot be read", function()
        local Handler, calls = processVersionSetup({ settings2 = { MaskGroupBasedCorrections = "unreadable" } })
        local result = Handler.setProcessVersion({ photo_ids = { "2" }, version = "Version 5", confirm = true })
        assert.is_false(result.success)
        assert.are.equal(1, result.failed)
        assert.are.equal("Version 6", result.results[1].previous_version)
        assert.are.equal("Version 6", result.results[1].new_version)
        assert.are.equal(0, #calls)
    end)

    it("retains completed changes and returns remaining ids at the time budget", function()
        local Handler = processVersionSetup({ cost = 240 })
        local result = Handler.setProcessVersion({ photo_ids = { "1", "2" }, version = "Version 6", confirm = true })
        assert.is_false(result.complete)
        assert.are.equal(1, result.changed)
        assert.are.same({ "2" }, result.remaining_ids)
    end)

    it("cancellation returns all unvisited ids", function()
        local Handler, calls = processVersionSetup()
        local result = Handler.setProcessVersion({ photo_ids = { "1", "2" }, version = "Version 6", confirm = true }, { isCanceled = function() return true end })
        assert.is_false(result.complete)
        assert.are.same({ "1", "2" }, result.remaining_ids)
        assert.are.equal(0, #calls)
    end)

    it("reports a refused change as failed and restores the view", function()
        local Handler, _, view = processVersionSetup({ ignored = true })
        local result = Handler.setProcessVersion({ photo_ids = { "1" }, version = "Version 6", confirm = true })
        assert.is_false(result.success)
        assert.are.equal(1, result.failed)
        assert.are.equal("Version 5", result.results[1].new_version)
        assert.are.equal("library", view())
    end)
end)

describe("HandlerDevelop.applyAutoAdjustments", function()
    it("applies requested operations and restores the module and selected photo", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" }, { id = "2" } } })
        local result = Handler.applyAutoAdjustments({ photo_ids = { "2", "1" }, tone = true, white_balance = true })
        assert.is_true(result.success)
        assert.are.equal(2, result.applied)
        assert.are.equal(2, calls.autoTone)
        assert.are.equal(2, calls.autoWhiteBalance)
        assert.are.same({ "develop", "library" }, calls.modules)
        assert.are.equal("1", calls.selections[#calls.selections])
    end)

    it("does not apply white balance when only tone is requested", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" } } })
        assert.are.equal(1, Handler.applyAutoAdjustments({ photo_ids = { "1" }, tone = true }).applied)
        assert.is_nil(calls.autoWhiteBalance)
    end)

    it("does not apply tone when only white balance is requested", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" } } })
        assert.are.equal(1, Handler.applyAutoAdjustments({ photo_ids = { "1" }, white_balance = true }).applied)
        assert.is_nil(calls.autoTone)
    end)

    it("waits for a delayed Auto result before selecting another photo", function()
        local Handler = denoiseSetup({ photos = { { id = "1" }, { id = "2" } }, autoDelay = 3 })
        local result = Handler.applyAutoAdjustments({ photo_ids = { "1", "2" }, tone = true })
        assert.are.equal(2, result.applied)
    end)

    for _, delay in ipairs({ "autoDelay", "autoWhiteBalanceDelay" }) do
        it("settles both operations before moving on with " .. delay, function()
            local opts = { photos = { { id = "1" }, { id = "2" } } }
            opts[delay] = 3
            local Handler, _, photos = denoiseSetup(opts)
            local result = Handler.applyAutoAdjustments({ photo_ids = { "1", "2" }, tone = true, white_balance = true })
            assert.are.equal(2, result.applied)
            for _, photo in ipairs(photos) do
                local settings = photo:getDevelopSettings()
                assert.are.equal(1.25, settings.Exposure2012)
                assert.are.equal(5200, settings.Temperature)
            end
        end)
    end

    it("reports unchanged, missing and duplicate photos with reasons", function()
        local Handler = denoiseSetup({ photos = { { id = "1" } }, autoUnchanged = true })
        local result = Handler.applyAutoAdjustments({ photo_ids = { "1", "404", "1" }, tone = true })
        assert.are.equal(1, result.unchanged)
        assert.are.equal(2, result.skipped)
        assert.are.equal("Auto returned the current settings", result.results[1].reason)
        assert.are.equal("photo not found", result.results[2].reason)
        assert.are.equal("duplicate", result.results[3].reason)
    end)

    it("returns the unreached ids when the time budget expires after the first photo", function()
        local Handler = denoiseSetup({
            photos = { { id = "1" }, { id = "2" }, { id = "3" } },
            onAuto = function(_, clock) clock.now = 241 end,
        })
        local result = Handler.applyAutoAdjustments({ photo_ids = { "1", "2", "3" }, tone = true })
        assert.is_false(result.complete)
        assert.is_false(result.success)
        assert.are.equal(1, result.applied)
        assert.are.same({ "2", "3" }, result.remaining_ids)
    end)

    it("rejects overlap through the shared Develop session lock", function()
        local nested
        local Handler = denoiseSetup({ photos = { { id = "1" } }, onAuto = function(handler)
            nested = errorOf(function()
                handler.applyAutoAdjustments({ photo_ids = { "1" }, tone = true })
            end)
        end })
        assert.are.equal(1, Handler.applyAutoAdjustments({ photo_ids = { "1" }, tone = true }).applied)
        assert.truthy(nested:find("is already running", 1, true))
    end)

    it("reports SDK failure and restores the view, releasing the lock", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" } }, autoError = "Auto failed" })
        local result = Handler.applyAutoAdjustments({ photo_ids = { "1" }, tone = true })
        assert.are.equal(1, result.failed)
        assert.truthy(result.results[1].reason:find("Auto failed", 1, true))
        assert.are.same({ "develop", "library" }, calls.modules)
        assert.are.equal(1, Handler.applyAutoAdjustments({ photo_ids = { "1" }, white_balance = true }).applied)
    end)

    it("rejects neither operation and malformed flags before opening Develop", function()
        local Handler, calls = denoiseSetup({ photos = { { id = "1" } } })
        for _, args in ipairs({
            { photo_ids = { "1" } },
            { photo_ids = { "1" }, tone = false, white_balance = false },
            { photo_ids = { "1" }, tone = "true" },
        }) do
            assert.truthy(errorOf(function() Handler.applyAutoAdjustments(args) end))
        end
        assert.are.equal(0, calls.switched)
    end)
end)


describe("HandlerDevelop batch dry runs", function()
    it("previews changed values, unchanged targets and missing ids without writes", function()
        local source = helper.fakePhoto({ id = "1001", developSettings = { Exposure2012 = 0.5, Contrast2012 = 10 } })
        local target = helper.fakePhoto({ id = "1002", developSettings = { Exposure2012 = 0, Contrast2012 = 10 } })
        local identical = helper.fakePhoto({ id = "1003", developSettings = { Exposure2012 = 0.5 } })
        local catalog, Handler = setup({ photos = { source, target, identical } })
        catalog.withWriteAccessDo = function() error("dry run wrote") end
        target.applyDevelopSettings = function() error("dry run applied") end
        local r = Handler.copyDevelopSettings({
            source_id = "1001", target_ids = { "1002", "1003", "missing" }, settings = { "Exposure2012" }, dry_run = true,
        })
        assert.are.same({ { key = "Exposure2012", before = 0, after = 0.5,
            before_present = true, after_present = true } }, r.details[1].changes)
        assert.are.same({}, r.details[2].changes)
        assert.are.same({ Exposure2012 = 1 }, r.setting_totals)
        assert.are.same({ "missing" }, r.missing)
        assert.are.equal(2, r.targets)
        assert.are.equal(1, r.changed_targets)
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)

    it("previews preset keys only and never applies or recomputes AI masks", function()
        local target = helper.fakePhoto({ id = "1002", developSettings = { Exposure2012 = 0, Contrast2012 = 10 } })
        local preset = fakePreset("Subject", { settings = AI_MASK_SETTINGS })
        local catalog, Handler = setup({ photos = { target }, folders = { fakeFolder("User", { preset }) } })
        catalog.withWriteAccessDo = function() error("dry run wrote") end
        target.applyDevelopPreset = function() error("dry run applied") end
        target.updateAISettings = function() error("dry run recomputed") end
        local r = Handler.applyDevelopPreset({ photo_ids = { "1002", "missing" }, preset_name = "Subject", dry_run = true })
        assert.are.equal(1, r.setting_totals.Exposure2012)
        assert.is_nil(r.setting_totals.Contrast2012)
        assert.is_true(r.masks_would_be_copied)
        assert.is_false(r.ai_recomputed)
        assert.are.same({ "missing" }, r.missing)
    end)

    it("omits equal preset scalars and curves", function()
        local settings = { Exposure2012 = 0.5, ToneCurvePV2012 = { 0, 0, 255, 255 } }
        local target = helper.fakePhoto({ id = "1002", developSettings = settings })
        local preset = fakePreset("Equal", { settings = settings })
        local _, Handler = setup({ photos = { target }, folders = { fakeFolder("User", { preset }) } })
        local r = Handler.applyDevelopPreset({ photo_ids = { "1002" }, preset_name = "Equal", dry_run = true })
        assert.are.same({}, r.details[1].changes)
        assert.are.same({}, r.setting_totals)
        assert.are.equal(0, r.changed_targets)
    end)

    it("limits preset diffs to readable declared keys and reports unknown effects", function()
        local preset = fakePreset("Heavy", { settings = {
            GrainAmount = 92, GrainFrequency = 40, GrainSize = 39, Glow = 0, Version = "18.7",
        } })
        local first = helper.fakePhoto({ id = "1002", developSettings = {
            GrainAmount = 0, GrainFrequency = 50, GrainSize = 25,
        } })
        local second = helper.fakePhoto({ id = "1003", developSettings = {
            GrainAmount = 92, GrainFrequency = 40, GrainSize = 39, Glow = 0,
        } })
        local catalog, Handler = setup({ photos = { first, second }, folders = { fakeFolder("Grain", { preset }) } })
        catalog.withWriteAccessDo = function() error("preset preview wrote") end
        first.applyDevelopPreset = function() error("preset preview applied") end
        first.updateAISettings = function() error("preset preview recomputed") end
        local r = Handler.applyDevelopPreset({ photo_ids = { "1002", "1003" }, preset_name = "Heavy", dry_run = true })
        assert.are.equal("readable_declared_preset_settings", r.preview_scope)
        assert.are.same({ Glow = 1, Version = 2 }, r.unknown_current_totals)
        assert.are.same({ GrainAmount = 1, GrainFrequency = 1, GrainSize = 1 }, r.setting_totals)
        assert.are.equal(3, #r.details[1].changes)
        assert.are.same({}, r.details[2].changes)
        assert.are.equal(1, r.changed_targets)
        assert.are.same({ "SDK-generated values, including GrainSeed", "Preset bookkeeping" }, r.unknown_effects)
        assert.is_nil(r.setting_totals.GrainSeed)
        assert.is_nil(r.setting_totals.Preset)
    end)

    it("keeps unknown preset values separate from unchanged values on all targets", function()
        local preset = fakePreset("Unknown", { settings = { Glow = 0 } })
        local target = helper.fakePhoto({ id = "1002" })
        local _, Handler = setup({ photos = { target }, folders = { fakeFolder("User", { preset }) } })
        local r = Handler.applyDevelopPreset({ photo_ids = { "1002" }, preset_name = "Unknown", dry_run = true })
        assert.are.same({}, r.details[1].changes)
        assert.are.same({ Glow = 1 }, r.unknown_current_totals)
        assert.are.equal(0, r.changed_targets)
    end)

    it("still previews copied settings whose current value is absent", function()
        local source = helper.fakePhoto({ id = "1001", developSettings = { Exposure2012 = 0.5 } })
        local target = helper.fakePhoto({ id = "1002" })
        local _, Handler = setup({ photos = { source, target } })
        local r = Handler.copyDevelopSettings({ source_id = "1001", target_ids = { "1002" }, dry_run = true })
        assert.are.equal(1, r.setting_totals.Exposure2012)
        assert.is_false(r.details[1].changes[1].before_present)
        assert.is_nil(r.preview_scope)
        assert.is_nil(r.unknown_current_totals)
        assert.is_nil(r.unknown_effects)
    end)

    it("does not recompute or write copied AI masks", function()
        local source = helper.fakePhoto({ id = "1001", developSettings = AI_MASK_SETTINGS })
        local target = helper.fakePhoto({ id = "1002" })
        local catalog, Handler = setup({ photos = { source, target } })
        catalog.withWriteAccessDo = function() error("dry run wrote") end
        target.updateAISettings = function() error("dry run recomputed") end
        local r = Handler.copyDevelopSettings({ source_id = "1001", target_ids = { "1002" }, dry_run = true })
        assert.is_true(r.masks_would_be_copied)
    end)

    it("retains validation errors in both modes", function()
        local source = helper.fakePhoto({ id = "1001" })
        local _, Handler = setup({ photos = { source } })
        for _, dryRun in ipairs({ false, true }) do
            assert.has_error(function()
                Handler.copyDevelopSettings({ source_id = "1001", target_ids = { "1001" }, settings = { "Unknown" }, dry_run = dryRun })
            end, "Unsupported develop setting key: Unknown")
            assert.has_error(function()
                Handler.copyDevelopSettings({ source_id = "1001", target_ids = {}, dry_run = dryRun })
            end, "target_ids is required")
            assert.has_error(function()
                Handler.applyDevelopPreset({ photo_ids = { "1001" }, preset_name = "Unknown", dry_run = dryRun })
            end, "Preset not found")
            assert.has_error(function()
                Handler.applyDevelopPreset({ photo_ids = {}, preset_name = "Unknown", dry_run = dryRun })
            end, "photo_ids is required")
        end
    end)

    it("bounds missing paths while retaining every missing input index", function()
        local source = helper.fakePhoto({ id = "1001", developSettings = { Exposure2012 = 0.5 } })
        local _, Handler = setup({ photos = { source } })
        local ids = {}
        for i = 1, 200 do ids[i] = "/missing/" .. string.rep("a", 200) .. tostring(i) .. ".jpg" end
        local r = Handler.copyDevelopSettings({ source_id = "1001", target_ids = ids, dry_run = true })
        assert.is_true(#require('JSON'):encode(r) <= 20000)
        assert.are.equal(200, r.missing_count)
        assert.are.equal(200, #r.missing_indices)
        assert.is_true(r.missing_truncated)
        assert.is_true(#r.missing < 200)
        for i, id in ipairs(r.missing) do assert.are.equal(ids[i], id) end
        for i, index in ipairs(r.missing_indices) do assert.are.equal(i, index) end
    end)

    it("bounds 200-target detail and totals every target", function()
        local settings = { Exposure2012 = 0.5, ToneCurvePV2012 = { 0, 0, 255, 255 } }
        local source = helper.fakePhoto({ id = "1001", developSettings = settings })
        local photos, ids = { source }, {}
        for i = 1, 200 do
            ids[i] = tostring(i)
            photos[#photos + 1] = helper.fakePhoto({ id = ids[i], developSettings = { Exposure2012 = 0 } })
        end
        local _, Handler = setup({ photos = photos })
        local r = Handler.copyDevelopSettings({ source_id = "1001", target_ids = ids, dry_run = true })
        assert.is_true(#require('JSON'):encode(r) <= 20000)
        assert.are.equal(5, #r.details)
        assert.is_true(r.detail_truncated)
        assert.are.equal(200, r.setting_totals.Exposure2012)
        assert.are.equal(200, r.setting_totals.ToneCurvePV2012)
        assert.are.same({ type = "table", entries = 4 }, r.details[1].changes[2].after)
    end)
end)
