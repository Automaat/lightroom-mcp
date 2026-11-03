local LrApplication = import 'LrApplication'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

-- Lightroom Classic export presets (.lrtemplate files).
--
-- The SDK has no API to list or load export presets, so they are read from
-- disk. Each file is Lua source assigning `s = { title=..., type="Export",
-- value = { ... } }`, where `value` holds LrExportSession settings without
-- their `LR_` prefix (format -> LR_format).
local ExportPresets = {}

-- Only Hard Drive presets can run over the bridge. Other services (DxO,
-- Nik, publish services) hand the files to another application.
ExportPresets.FILE_SERVICE = 'com.adobe.ag.export.file'

-- Destination types that name a folder without asking. chooseLater opens a
-- folder dialog and tempFolder is a service-private scratch folder.
local FIXED_DESTINATION_TYPES = {
    specificFolder = true,
    sourceFolder = true,
    desktop = true,
    home = true,
    documents = true,
    pictures = true,
}

-- LOC "$$$/Key=Default text" -> "Default text"; third-party presets use it
-- for their titles.
local function loc(text)
    if type(text) ~= "string" then return text end
    return text:match("^%$%$%$[^=]*=(.*)$") or text
end

-- Preset files are parsed, never run: Lightroom's plug-in environment does
-- not load Lua source, and a file dropped into a preset folder must not be
-- able to execute code. The grammar is what Lightroom writes: `s = { ... }`
-- holding strings, numbers, booleans, nested tables and LOC "..." calls.
local MAX_DEPTH = 32
-- Marks a parse error, as opposed to a bug in the parser.
local PARSE_ERROR = "export preset parse error: "

local ESCAPES = { n = "\n", t = "\t", r = "\r", a = "\a", b = "\b", f = "\f", v = "\v",
    ["\\"] = "\\", ['"'] = '"', ["'"] = "'", ["\n"] = "\n" }

local function parsePreset(source)
    local pos = 1

    local function fail(message)
        local line = select(2, source:sub(1, pos):gsub("\n", "")) + 1
        error(PARSE_ERROR .. message .. " at line " .. line, 0)
    end

    local function skipSpace()
        while true do
            local _, stop = source:find("^%s+", pos)
            if stop then pos = stop + 1 end
            if source:sub(pos, pos + 1) ~= "--" then return end
            local level = source:match("^%-%-%[(=*)%[", pos)
            if level then
                local close = "]" .. level .. "]"
                local _, closeEnd = source:find(close, pos, true)
                if not closeEnd then fail("unfinished comment") end
                pos = closeEnd + 1
            else
                local lineEnd = source:find("\n", pos, true)
                pos = lineEnd and lineEnd + 1 or #source + 1
            end
        end
    end

    local function parseString()
        local level = source:match("^%[(=*)%[", pos)
        if level then
            local open = 2 + #level
            local close = "]" .. level .. "]"
            local closeStart, closeEnd = source:find(close, pos + open, true)
            if not closeStart then fail("unfinished long string") end
            local text = source:sub(pos + open, closeStart - 1):gsub("^\r?\n", "")
            pos = closeEnd + 1
            return text
        end
        local quote = source:sub(pos, pos)
        pos = pos + 1
        local parts = {}
        while true do
            local c = source:sub(pos, pos)
            if c == "" or c == "\n" then fail("unfinished string") end
            if c == quote then
                pos = pos + 1
                return table.concat(parts)
            end
            if c == "\\" then
                local nextChar = source:sub(pos + 1, pos + 1)
                local digits = source:match("^%d%d?%d?", pos + 1)
                if digits then
                    local code = tonumber(digits)
                    if code > 255 then fail("invalid escape") end
                    parts[#parts + 1] = string.char(code)
                    pos = pos + 1 + #digits
                elseif ESCAPES[nextChar] then
                    parts[#parts + 1] = ESCAPES[nextChar]
                    pos = pos + 2
                else
                    fail("invalid escape")
                end
            else
                parts[#parts + 1] = c
                pos = pos + 1
            end
        end
    end

    local parseValue

    local function parseTable(depth)
        if depth > MAX_DEPTH then fail("tables nested too deeply") end
        pos = pos + 1
        local result = {}
        local index = 1
        while true do
            skipSpace()
            if source:sub(pos, pos) == "}" then
                pos = pos + 1
                return result
            end
            local key
            local name = source:match("^[%a_][%w_]*", pos)
            if source:sub(pos, pos) == "[" and not source:match("^%[=*%[", pos) then
                pos = pos + 1
                skipSpace()
                key = parseValue(depth + 1)
                skipSpace()
                if source:sub(pos, pos) ~= "]" then fail("expected ']'") end
                pos = pos + 1
                skipSpace()
                if source:sub(pos, pos) ~= "=" then fail("expected '='") end
                pos = pos + 1
            elseif name and source:match("^[%a_][%w_]*%s*=[^=]", pos)
                and name ~= "true" and name ~= "false" and name ~= "nil" then
                key = name
                pos = pos + #name
                skipSpace()
                pos = pos + 1
            end
            skipSpace()
            local value = parseValue(depth + 1)
            if key == nil then
                key = index
                index = index + 1
            end
            result[key] = value
            skipSpace()
            local separator = source:sub(pos, pos)
            if separator == "," or separator == ";" then
                pos = pos + 1
            elseif separator ~= "}" then
                fail("expected ',' or '}'")
            end
        end
    end

    function parseValue(depth)
        local c = source:sub(pos, pos)
        if c == "{" then return parseTable(depth) end
        if c == '"' or c == "'" or source:match("^%[=*%[", pos) then return parseString() end
        local word = source:match("^[%a_][%w_]*", pos)
        if word == "true" or word == "false" or word == "nil" then
            pos = pos + #word
            if word == "nil" then return nil end
            return word == "true"
        end
        if word == "LOC" then
            pos = pos + 3
            skipSpace()
            local parenthesised = source:sub(pos, pos) == "("
            if parenthesised then
                pos = pos + 1
                skipSpace()
            end
            local first = source:sub(pos, pos)
            if first ~= '"' and first ~= "'" and not source:match("^%[=*%[", pos) then
                fail("expected a string after LOC")
            end
            local text = parseString()
            if parenthesised then
                skipSpace()
                if source:sub(pos, pos) ~= ")" then fail("expected ')'") end
                pos = pos + 1
            end
            return loc(text)
        end
        -- A bare name is a global, which is nil when Lightroom runs the file
        -- (the Nik presets write tiff_compressionMethod = compressionMethod_none).
        if word then
            pos = pos + #word
            return nil
        end
        local number = source:match("^-?0[xX]%x+", pos)
            or source:match("^-?%d*%.?%d+[eE][-+]?%d+", pos)
            or source:match("^-?%d+%.?%d*", pos)
            or source:match("^-?%.%d+", pos)
        if number and tonumber(number) then
            pos = pos + #number
            return tonumber(number)
        end
        fail("unexpected '" .. c .. "'")
    end

    skipSpace()
    if not source:match("^s%s*=", pos) then fail("expected 's = {'") end
    pos = source:find("=", pos, true) + 1
    skipSpace()
    if source:sub(pos, pos) ~= "{" then fail("expected 's = {'") end
    local preset = parseTable(1)
    skipSpace()
    if source:sub(pos, pos) == ";" then
        pos = pos + 1
        skipSpace()
    end
    if pos <= #source then fail("unexpected text after the preset") end
    return preset
end

local function readPresetSource(source)
    local ok, result = pcall(parsePreset, source)
    if ok then return result end
    if type(result) == "string" and result:sub(1, #PARSE_ERROR) == PARSE_ERROR then
        return nil, result:sub(#PARSE_ERROR + 1)
    end
    error(result, 0)
end

local function presetRoots()
    local roots = {}
    local ok, appData = pcall(LrPathUtils.getStandardFilePath, "appData")
    if ok and type(appData) == "string" and appData ~= "" then
        -- appData may already be Lightroom's own folder rather than the
        -- system application-data folder; accept either.
        local lightroomDir = appData
        if LrPathUtils.leafName(appData) ~= "Lightroom" then
            lightroomDir = LrPathUtils.child(LrPathUtils.child(appData, "Adobe"), "Lightroom")
        end
        table.insert(roots, { scope = "user", path = LrPathUtils.child(lightroomDir, "Export Presets") })
    end
    -- "Store presets with this catalog" keeps them beside the catalog file.
    local catalogOk, catalogPath = pcall(function() return LrApplication.activeCatalog():getPath() end)
    if catalogOk and type(catalogPath) == "string" and catalogPath ~= "" then
        local settingsDir = LrPathUtils.child(LrPathUtils.parent(catalogPath), "Lightroom Settings")
        table.insert(roots, { scope = "catalog", path = LrPathUtils.child(settingsDir, "Export Presets") })
    end
    return roots
end

local function readFile(path)
    local ok, text = pcall(LrFileUtils.readFile, path)
    if not ok then return nil, tostring(text) end
    if type(text) ~= "string" then return nil, "file could not be read" end
    return text
end

local function stem(path)
    return LrPathUtils.removeExtension(LrPathUtils.leafName(path))
end

local function sizeSummary(value)
    if not value.size_doConstrain then return nil end
    local resizeType = value.size_resizeType
    local summary = { type = resizeType }
    if resizeType == "megapixels" then
        summary.megapixels = value.size_megapixels
    elseif resizeType == "percentage" then
        summary.percentage = value.size_percentage
    else
        summary.max_width = value.size_maxWidth
        summary.max_height = value.size_maxHeight
    end
    summary.units = value.size_units
    summary.do_not_enlarge = value.size_doNotEnlarge
    return summary
end

-- The folder a specificFolder preset writes to, including its subfolder.
local function specificFolderPath(prefix, useSubfolder, suffix)
    if prefix and useSubfolder and suffix and suffix ~= "" then
        return LrPathUtils.child(prefix, suffix)
    end
    return prefix
end

local function loadEntry(root, folder, file)
    local entry = {
        name = stem(file),
        folder = folder,
        scope = root.scope,
        file = file,
        usable = false,
    }
    local source, readError = readFile(file)
    local preset
    if source then
        preset, readError = readPresetSource(source)
    end
    if not preset then
        entry.unusable_reason = "could not read preset: " .. tostring(readError)
        return entry
    end
    if type(preset.title) == "string" and preset.title ~= "" then
        entry.name = preset.title
    end
    entry.internal_name = type(preset.internalName) == "string" and preset.internalName or nil
    entry.id = type(preset.id) == "string" and preset.id or nil
    local value = preset.value
    if preset.type ~= "Export" or type(value) ~= "table" then
        entry.unusable_reason = "not an export preset"
        return entry
    end

    entry.service = value.exportServiceProvider
    entry.service_title = value.exportServiceProviderTitle
    entry.format = value.format
    entry.color_space = value.export_colorSpace
    if value.format == "JPEG" and type(value.jpeg_quality) == "number" then
        entry.quality = math.floor(value.jpeg_quality * 100 + 0.5)
    end
    entry.size = sizeSummary(value)
    if value.renamingTokensOn then
        entry.file_naming = value.tokens
    end
    entry.watermark = value.useWatermark == true
    entry.destination_type = value.export_destinationType
    if value.export_destinationType == "specificFolder" then
        entry.destination_folder = specificFolderPath(value.export_destinationPathPrefix,
            value.export_useSubfolder, value.export_destinationPathSuffix)
    end
    entry.has_fixed_destination = FIXED_DESTINATION_TYPES[value.export_destinationType] == true

    -- An unset provider is the built-in Hard Drive service.
    if entry.service ~= nil and entry.service ~= ExportPresets.FILE_SERVICE then
        entry.unusable_reason = "exports through " .. tostring(entry.service_title or entry.service)
            .. ", not Hard Drive"
        return entry
    end
    entry.usable = true
    entry.value = value
    return entry
end

-- Every .lrtemplate in <root>/<folder>/, user presets before catalog presets.
local function allEntries()
    local entries = {}
    for _, root in ipairs(presetRoots()) do
        if LrFileUtils.exists(root.path) == "directory" then
            for folderPath in LrFileUtils.directoryEntries(root.path) do
                if LrFileUtils.exists(folderPath) == "directory" then
                    local folder = LrPathUtils.leafName(folderPath)
                    local files = {}
                    for file in LrFileUtils.files(folderPath) do
                        local extension = LrPathUtils.extension(file)
                        if type(extension) == "string" and extension:lower() == "lrtemplate" then
                            table.insert(files, file)
                        end
                    end
                    table.sort(files)
                    for _, file in ipairs(files) do
                        table.insert(entries, loadEntry(root, folder, file))
                    end
                end
            end
        end
    end
    table.sort(entries, function(a, b)
        if a.scope ~= b.scope then return a.scope == "user" end
        if a.folder ~= b.folder then return a.folder < b.folder end
        return a.name < b.name
    end)
    return entries
end

local function summary(entry)
    local result = {}
    for key, v in pairs(entry) do
        if key ~= "value" then result[key] = v end
    end
    return result
end

function ExportPresets.list(folder)
    local result = {}
    for _, entry in ipairs(allEntries()) do
        if folder == nil or entry.folder == folder then
            table.insert(result, summary(entry))
        end
    end
    return result
end

local function matchesName(entry, name, fold)
    local candidates = { entry.name, entry.internal_name, stem(entry.file), entry.id }
    for _, candidate in pairs(candidates) do
        if candidate == name or (fold and candidate:lower() == name:lower()) then
            return true
        end
    end
    return false
end

local function findMatches(entries, name, folder, fold)
    local matches = {}
    for _, entry in ipairs(entries) do
        if (folder == nil or entry.folder == folder) and matchesName(entry, name, fold) then
            table.insert(matches, entry)
        end
    end
    return matches
end

-- Finds one export preset by name (title, internal name, file name or id),
-- optionally within one folder. An exact match wins over a case-insensitive
-- one. Returns the entry with `settings`: the LrExportSession settings
-- table, LR_-prefixed and safe to modify.
function ExportPresets.resolve(name, folder)
    if type(name) ~= "string" or name == "" then
        error("export_preset must be a non-empty string")
    end
    if folder ~= nil and (type(folder) ~= "string" or folder == "") then
        error("export_preset_folder must be a non-empty string")
    end
    local entries = allEntries()
    local matches = findMatches(entries, name, folder, false)
    if #matches == 0 then
        matches = findMatches(entries, name, folder, true)
    end
    if #matches == 0 then
        local where = folder and (" in folder '" .. folder .. "'") or ""
        error("Export preset not found: '" .. name .. "'" .. where .. " (use list_export_presets)")
    end
    if #matches > 1 then
        local locations = {}
        for _, match in ipairs(matches) do
            table.insert(locations, match.scope .. ":" .. match.folder)
        end
        error("Export preset '" .. name .. "' is ambiguous; pass export_preset_folder (found in "
            .. table.concat(locations, ", ") .. ")")
    end
    local entry = matches[1]
    if not entry.usable then
        error("Export preset '" .. entry.name .. "' cannot be used: " .. entry.unusable_reason)
    end
    local settings = {}
    for key, v in pairs(entry.value) do
        if type(key) == "string" then
            settings["LR_" .. key] = v
        end
    end
    local result = summary(entry)
    result.settings = settings
    return result
end

ExportPresets.FIXED_DESTINATION_TYPES = FIXED_DESTINATION_TYPES
ExportPresets.specificFolderPath = specificFolderPath
-- Exposed for the specs.
ExportPresets._parse = readPresetSource

return ExportPresets
