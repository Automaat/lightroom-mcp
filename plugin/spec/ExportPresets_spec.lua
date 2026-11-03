local helper = require 'spec_helper'

-- Trimmed from a real Hard Drive preset (destination anonymised).
local BLUESKY = [[
s = {
	id = "98B51E14-B94C-45A7-894A-341998926014",
	internalName = "BlueSky",
	title = "BlueSky",
	type = "Export",
	value = {
		collisionHandling = "ask",
		exportServiceProvider = "com.adobe.ag.export.file",
		exportServiceProviderTitle = "Hard Drive",
		export_colorSpace = "sRGB",
		export_destinationPathPrefix = "/Users/someone/Desktop",
		export_destinationType = "desktop",
		export_postProcessing = "doNothing",
		export_useSubfolder = false,
		format = "JPEG",
		jpeg_quality = 0.80121527777778,
		markedPresets = {
		},
		outputSharpeningOn = true,
		removeLocationMetadata = true,
		renamingTokensOn = true,
		size_doConstrain = true,
		size_megapixels = 1,
		size_resizeType = "megapixels",
		tokens = "Bsky - {{com.adobe.title}} {{image_originalName}}",
		useWatermark = false,
	},
	version = 0,
}
]]

local CHOOSE_LATER = [[
s = {
	id = "C0FFEE00-0000-0000-0000-000000000001",
	title = "For Editing",
	type = "Export",
	value = {
		export_destinationType = "chooseLater",
		export_postProcessing = "openInOtherApp",
		format = "TIFF",
		size_doConstrain = false,
	},
	version = 0,
}
]]

local SPECIFIC_FOLDER = [[
s = {
	title = "To Prints",
	type = "Export",
	value = {
		exportServiceProvider = "com.adobe.ag.export.file",
		export_destinationPathPrefix = "/prints",
		export_destinationType = "specificFolder",
		export_useSubfolder = true,
		export_destinationPathSuffix = "Batch",
		format = "JPEG",
		jpeg_quality = 1.0,
	},
	version = 0,
}
]]

-- A third-party service preset with a LOC title.
local DXO = [[
s = {
	internalName = "DxO PureRAW 6",
	title = LOC "$$$/DxOPureRaw/ExportPreset/ProcessWith=Process instantly with DxO PureRAW 6",
	type = "Export",
	value = {
		exportServiceProvider = "com.dxo-labs.PureRAWv6.lightroom",
		exportServiceProviderTitle = "DxO PureRAW 6",
		["com.dxo-labs.PureRAWv6.lightroom_exportAppType"] = "exportInstantly",
		export_destinationType = "tempFolder",
		format = "ORIGINAL",
	},
	version = 0,
}
]]

local ROOT = "/appdata/Adobe/Lightroom/Export Presets"
local CATALOG_ROOT = "/cat/Lightroom Settings/Export Presets"

local function defaultFiles()
    return {
        [ROOT .. "/User Presets/BlueSky.lrtemplate"] = BLUESKY,
        [ROOT .. "/User Presets/For Editing.lrtemplate"] = CHOOSE_LATER,
        [ROOT .. "/User Presets/To Prints.lrtemplate"] = SPECIFIC_FOLDER,
        [ROOT .. "/User Presets/notes.txt"] = "not a preset",
        [ROOT .. "/DxO PureRAW 6/DxOPureRAWv6_proc_inst.lrtemplate"] = DXO,
        [ROOT .. "/Broken/Broken.lrtemplate"] = "s = {",
    }
end

local function parent(path) return (path:match("^(.*)/[^/]*$")) end
local function leaf(path) return (path:match("([^/]*)$")) end

-- An in-memory file tree served through LrFileUtils / LrPathUtils.
local function fakeFs(files)
    local dirs = {}
    for path in pairs(files) do
        local dir = parent(path)
        while dir and dir ~= "" do
            dirs[dir] = true
            dir = parent(dir)
        end
    end
    local function children(dir, wantDirs)
        local list = {}
        local seen = {}
        local source = wantDirs and dirs or files
        for path in pairs(source) do
            if parent(path) == dir and not seen[path] then
                seen[path] = true
                table.insert(list, path)
            end
        end
        table.sort(list)
        local i = 0
        return function()
            i = i + 1
            return list[i]
        end
    end
    local LrFileUtils = {
        exists = function(path)
            if files[path] then return "file" end
            if dirs[path] then return "directory" end
            return false
        end,
        readFile = function(path) return files[path] end,
        directoryEntries = function(dir) return children(dir, true) end,
        files = function(dir) return children(dir, false) end,
        createAllDirectories = function(path) dirs[path] = true end,
    }
    local LrPathUtils = {
        getStandardFilePath = function(name)
            assert(name == "appData")
            return "/appdata"
        end,
        child = function(dir, name) return dir .. "/" .. name end,
        parent = parent,
        leafName = leaf,
        extension = function(path) return path:match("%.([^./]*)$") or "" end,
        removeExtension = function(path) return (path:gsub("%.[^./]*$", "")) end,
    }
    return LrFileUtils, LrPathUtils
end

local function setup(opts)
    opts = opts or {}
    local files = opts.files or defaultFiles()
    local LrFileUtils, LrPathUtils = fakeFs(files)
    local catalog = helper.fakeCatalog({ photos = opts.photos or {} })
    catalog.getPath = function() return "/cat/Main.lrcat" end
    local exportSessionCalls = {}
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
        LrFileUtils = LrFileUtils,
        LrPathUtils = LrPathUtils,
        LrExportSession = function(args)
            table.insert(exportSessionCalls, args)
            return { doExportOnCurrentTask = function() end }
        end,
    })
    package.loaded.ExportPresets = nil
    package.loaded.HandlerExport = nil
    return require 'ExportPresets', require 'HandlerExport', exportSessionCalls
end

local function byName(presets, name)
    for _, preset in ipairs(presets) do
        if preset.name == name then return preset end
    end
    return nil
end

describe("ExportPresets.list", function()
    it("lists every .lrtemplate with a summary of its settings", function()
        local _, Handler = setup()
        local r = Handler.listExportPresets({})

        assert.are.equal(5, r.count)
        local bluesky = byName(r.presets, "BlueSky")
        assert.are.equal("User Presets", bluesky.folder)
        assert.are.equal("user", bluesky.scope)
        assert.are.equal(ROOT .. "/User Presets/BlueSky.lrtemplate", bluesky.file)
        assert.are.equal("98B51E14-B94C-45A7-894A-341998926014", bluesky.id)
        assert.is_true(bluesky.usable)
        assert.are.equal("JPEG", bluesky.format)
        assert.are.equal(80, bluesky.quality)
        assert.are.same({ type = "megapixels", megapixels = 1 }, bluesky.size)
        assert.are.equal("Bsky - {{com.adobe.title}} {{image_originalName}}", bluesky.file_naming)
        assert.are.equal("desktop", bluesky.destination_type)
        assert.is_true(bluesky.has_fixed_destination)
        assert.is_nil(bluesky.value)
        assert.is_nil(bluesky.settings)
    end)

    it("treats a preset without a service as Hard Drive", function()
        local _, Handler = setup()
        local editing = byName(Handler.listExportPresets({}).presets, "For Editing")
        assert.is_true(editing.usable)
        assert.is_false(editing.has_fixed_destination)
    end)

    it("marks other export services unusable and resolves LOC titles", function()
        local _, Handler = setup()
        local dxo = byName(Handler.listExportPresets({}).presets, "Process instantly with DxO PureRAW 6")
        assert.is_false(dxo.usable)
        assert.are.equal("exports through DxO PureRAW 6, not Hard Drive", dxo.unusable_reason)
        assert.are.equal("DxO PureRAW 6", dxo.internal_name)
    end)

    it("lists an unreadable preset under its file name with the reason", function()
        local _, Handler = setup()
        local broken = byName(Handler.listExportPresets({}).presets, "Broken")
        assert.is_false(broken.usable)
        assert.truthy(broken.unusable_reason:find("could not read preset", 1, true))
    end)

    it("reports a specific folder with its subfolder", function()
        local _, Handler = setup()
        local prints = byName(Handler.listExportPresets({}).presets, "To Prints")
        assert.are.equal("/prints/Batch", prints.destination_folder)
    end)

    it("leaves out a subfolder that is off or empty", function()
        local Presets = setup()
        assert.are.equal("/prints", Presets.specificFolderPath("/prints", false, "Batch"))
        assert.are.equal("/prints", Presets.specificFolderPath("/prints", true, ""))
        assert.are.equal("/prints", Presets.specificFolderPath("/prints", true, nil))
    end)

    it("filters by folder", function()
        local _, Handler = setup()
        local r = Handler.listExportPresets({ folder = "User Presets" })
        assert.are.equal(3, r.count)
        assert.are.equal(0, Handler.listExportPresets({ folder = "Nope" }).count)
    end)

    it("rejects an empty or whitespace-only folder", function()
        local _, Handler = setup()
        for _, folder in ipairs({ "", "   ", "\t\n" }) do
            assert.has_error(function()
                Handler.listExportPresets({ folder = folder })
            end, "folder must be a non-empty string")
        end
    end)

    it("includes presets stored with the catalog, after user presets", function()
        local files = defaultFiles()
        files[CATALOG_ROOT .. "/User Presets/Catalog Only.lrtemplate"] = SPECIFIC_FOLDER:gsub("To Prints", "Catalog Only")
        local _, Handler = setup({ files = files })
        local presets = Handler.listExportPresets({}).presets
        assert.are.equal("catalog", presets[#presets].scope)
        assert.are.equal("Catalog Only", presets[#presets].name)
    end)

    it("does not let a preset file reach globals", function()
        local files = { [ROOT .. "/User Presets/Evil.lrtemplate"] = "os.exit(1) s = {}" }
        local _, Handler = setup({ files = files })
        local evil = Handler.listExportPresets({}).presets[1]
        assert.is_false(evil.usable)
        assert.truthy(evil.unusable_reason:find("could not read preset", 1, true))
    end)

    it("returns nothing when no preset folder exists", function()
        local _, Handler = setup({ files = {} })
        assert.are.equal(0, Handler.listExportPresets({}).count)
    end)
end)

describe("ExportPresets.resolve", function()
    it("matches title, file name, id, then case-insensitively", function()
        local Presets = setup()
        assert.are.equal("BlueSky", Presets.resolve("BlueSky").name)
        assert.are.equal("BlueSky", Presets.resolve("98B51E14-B94C-45A7-894A-341998926014").name)
        assert.are.equal("Process instantly with DxO PureRAW 6",
            select(2, pcall(Presets.resolve, "DxOPureRAWv6_proc_inst")):match("'(.-)'"))
        assert.are.equal("BlueSky", Presets.resolve("bluesky").name)
    end)

    it("returns LR_-prefixed settings", function()
        local Presets = setup()
        local preset = Presets.resolve("BlueSky")
        assert.are.equal("JPEG", preset.settings.LR_format)
        assert.are.equal("megapixels", preset.settings.LR_size_resizeType)
        assert.are.equal("ask", preset.settings.LR_collisionHandling)
        assert.is_nil(preset.settings.format)
    end)

    it("explains an unknown name", function()
        local Presets = setup()
        assert.has_error(function() Presets.resolve("Nope") end,
            "Export preset not found: 'Nope' (use list_export_presets)")
        assert.has_error(function() Presets.resolve("BlueSky", "Other") end,
            "Export preset not found: 'BlueSky' in folder 'Other' (use list_export_presets)")
    end)

    it("refuses an ambiguous name unless a folder is given", function()
        local files = defaultFiles()
        files[ROOT .. "/Other/BlueSky.lrtemplate"] = BLUESKY
        local Presets = setup({ files = files })
        assert.has_error(function() Presets.resolve("BlueSky") end,
            "Export preset 'BlueSky' is ambiguous; pass export_preset_folder "
            .. "(found in user:Other, user:User Presets)")
        assert.are.equal("Other", Presets.resolve("BlueSky", "Other").folder)
    end)

    it("refuses a preset for another export service", function()
        local Presets = setup()
        assert.has_error(function() Presets.resolve("DxO PureRAW 6") end,
            "Export preset 'Process instantly with DxO PureRAW 6' cannot be used: "
            .. "exports through DxO PureRAW 6, not Hard Drive")
    end)
end)

describe("HandlerExport.exportPhotos with export_preset", function()
    local function photo() return helper.fakePhoto({ id = "1", path = "/a.jpg" }) end

    it("exports with the preset's settings into the given destination", function()
        local _, Handler, calls = setup({ photos = { photo() } })

        local r = Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", export_preset = "BlueSky" })

        local s = calls[1].exportSettings
        assert.are.equal("JPEG", s.LR_format)
        assert.are.equal(0.80121527777778, s.LR_jpeg_quality)
        assert.are.equal("megapixels", s.LR_size_resizeType)
        assert.are.equal(1, s.LR_size_megapixels)
        assert.is_true(s.LR_outputSharpeningOn)
        assert.is_true(s.LR_removeLocationMetadata)
        assert.are.equal("Bsky - {{com.adobe.title}} {{image_originalName}}", s.LR_tokens)
        assert.are.equal("specificFolder", s.LR_export_destinationType)
        assert.are.equal("/out", s.LR_export_destinationPathPrefix)
        assert.is_false(s.LR_export_useSubfolder)
        assert.are.equal("/out", r.destination)
        assert.are.same({
            name = "BlueSky",
            folder = "User Presets",
            scope = "user",
            file = ROOT .. "/User Presets/BlueSky.lrtemplate",
        }, r.preset)
    end)

    it("never lets the preset prompt or open another application", function()
        local _, Handler, calls = setup({ photos = { photo() } })

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", export_preset = "BlueSky" })
        assert.are.equal("rename", calls[1].exportSettings.LR_collisionHandling)

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", export_preset = "For Editing",
            on_existing = "skip" })
        assert.are.equal("skip", calls[2].exportSettings.LR_collisionHandling)
        assert.are.equal("doNothing", calls[2].exportSettings.LR_export_postProcessing)
    end)

    it("overrides only the settings passed explicitly", function()
        local _, Handler, calls = setup({ photos = { photo() } })

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", export_preset = "BlueSky",
            format = "png", quality = 50, width = 2000 })

        local s = calls[1].exportSettings
        assert.are.equal("PNG", s.LR_format)
        assert.are.equal(0.5, s.LR_jpeg_quality)
        assert.are.equal("longEdge", s.LR_size_resizeType)
        assert.are.equal(2000, s.LR_size_maxWidth)
        assert.are.equal("sRGB", s.LR_export_colorSpace)
        assert.is_true(s.LR_outputSharpeningOn)
    end)

    it("rejects an invalid quality override", function()
        local _, Handler, calls = setup({ photos = { photo() } })

        assert.has_error(function()
            Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", export_preset = "BlueSky", quality = "high" })
        end, "quality must be a number between 0 and 100")
        assert.are.equal(0, #calls)
    end)

    it("does not apply the tool's defaults over the preset", function()
        local _, Handler, calls = setup({ photos = { photo() } })

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", export_preset = "For Editing" })

        local s = calls[1].exportSettings
        assert.are.equal("TIFF", s.LR_format)
        assert.is_nil(s.LR_jpeg_quality)
        assert.is_nil(s.LR_tiff_compressionMethod)
        assert.is_nil(s.LR_export_colorSpace)
    end)

    it("creates a preset's missing folder when no destination is given", function()
        local _, Handler, calls = setup({ photos = { photo() } })
        local LrFileUtils = import 'LrFileUtils'
        assert.is_false(LrFileUtils.exists("/prints/Batch"))

        Handler.exportPhotos({ photo_ids = { "1" }, export_preset = "To Prints" })

        assert.are.equal("directory", LrFileUtils.exists("/prints/Batch"))
        assert.are.equal(1, #calls)
    end)

    it("refuses a preset folder path that is a file", function()
        local files = defaultFiles()
        files["/prints/Batch"] = "not a folder"
        local _, Handler, calls = setup({ files = files, photos = { photo() } })

        assert.has_error(function()
            Handler.exportPhotos({ photo_ids = { "1" }, export_preset = "To Prints" })
        end, "destination is not a directory: /prints/Batch")
        assert.are.equal(0, #calls)
    end)

    it("creates no folder for a preset without a specific folder", function()
        local _, Handler = setup({ photos = { photo() } })

        Handler.exportPhotos({ photo_ids = { "1" }, export_preset = "BlueSky" })

        assert.is_false((import 'LrFileUtils').exists("/Users/someone/Desktop"))
    end)

    it("uses the preset's fixed destination when none is given", function()
        local _, Handler, calls = setup({ photos = { photo() } })

        local r = Handler.exportPhotos({ photo_ids = { "1" }, export_preset = "To Prints" })

        local s = calls[1].exportSettings
        assert.are.equal("specificFolder", s.LR_export_destinationType)
        assert.are.equal("/prints", s.LR_export_destinationPathPrefix)
        assert.is_true(s.LR_export_useSubfolder)
        assert.are.equal("Batch", s.LR_export_destinationPathSuffix)
        assert.are.equal("/prints/Batch", r.destination)

        r = Handler.exportPhotos({ photo_ids = { "1" }, export_preset = "BlueSky" })
        assert.are.equal("desktop", calls[2].exportSettings.LR_export_destinationType)
        assert.are.equal("desktop", r.destination)
    end)

    it("requires a destination for a choose-later preset", function()
        local _, Handler, calls = setup({ photos = { photo() } })
        assert.has_error(function()
            Handler.exportPhotos({ photo_ids = { "1" }, export_preset = "For Editing" })
        end, "Export preset 'For Editing' has no fixed destination (chooseLater); pass destination")
        assert.are.equal(0, #calls)
    end)

    it("still requires a destination without a preset", function()
        local _, Handler = setup({ photos = { photo() } })
        assert.has_error(function() Handler.exportPhotos({ photo_ids = { "1" } }) end,
            "destination is required")
    end)

    it("rejects a folder without a preset name", function()
        local _, Handler = setup({ photos = { photo() } })
        assert.has_error(function()
            Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", export_preset_folder = "User Presets" })
        end, "export_preset_folder requires export_preset")
    end)

    it("refuses an unusable preset before exporting anything", function()
        local _, Handler, calls = setup({ photos = { photo() } })
        assert.has_error(function()
            Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", export_preset = "DxO PureRAW 6" })
        end)
        assert.are.equal(0, #calls)
    end)

    it("does not leak one export's overrides into the next", function()
        local _, Handler, calls = setup({ photos = { photo() } })
        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", export_preset = "BlueSky", quality = 10 })
        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", export_preset = "BlueSky" })
        assert.are.equal(0.80121527777778, calls[2].exportSettings.LR_jpeg_quality)
    end)
end)

describe("ExportPresets preset parser", function()
    local function parse(source)
        local Presets = setup()
        return Presets._parse(source)
    end

    it("reads the literal forms Lightroom writes", function()
        local preset = parse([==[
-- a comment
s = {
	["quoted key"] = 'single \'quoted\'',
	escaped = "tab\tnewline\n\65\\",
	long = [[
line]],
	negative = -2,
	float = 0.80121527777778,
	exponent = 1e3,
	hex = 0x10,
	yes = true, no = false, gone = nil;
	bare = compressionMethod_none,
	title = LOC("$$$/Some/Key=Shown title"),
	--[[ block
	comment ]]
	list = { "a", "b", { nested = 1 }, },
}
]==])
        assert.are.same({
            ["quoted key"] = "single 'quoted'",
            escaped = "tab\tnewline\nA\\",
            long = "line",
            negative = -2,
            float = 0.80121527777778,
            exponent = 1000,
            hex = 16,
            yes = true,
            no = false,
            title = "Shown title",
            list = { "a", "b", { nested = 1 } },
        }, preset)
    end)

    it("reports where a file stops being a preset", function()
        local _, err = parse("s = {\n  a = 1\n  b = 2\n}")
        assert.are.equal("expected ',' or '}' at line 3", err)
        _, err = parse("s = { a = os.exit(1) }")
        assert.truthy(err:find("expected ',' or '}'", 1, true))
        _, err = parse("s = {} os.exit(1)")
        assert.are.equal("unexpected text after the preset at line 1", err)
        _, err = parse("return { }")
        assert.are.equal("expected 's = {' at line 1", err)
        _, err = parse('s = { a = "unfinished }')
        assert.are.equal("unfinished string at line 1", err)
    end)

    it("refuses tables nested deeper than any preset", function()
        local _, err = parse("s = " .. string.rep("{", 40) .. string.rep("}", 40))
        assert.truthy(err:find("nested too deeply", 1, true))
    end)
end)
