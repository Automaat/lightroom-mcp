local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'

local Log = require 'Log'

local GuardedMaskWrite = {}

local TESTED_LIGHTROOM_VERSIONS = { ["15.6"] = true }
local TESTED_PROCESS_VERSIONS = { ["15.4"] = true }

local READ_BACK_TIMEOUT_SECONDS = 3
local READ_BACK_POLL_SECONDS = 0.1
local TOLERANCE = 1e-5
local MAX_CLONE_DEPTH = 40
local MAX_REPORTED_PROBLEMS = 6

local OPAQUE_WHAT = "Mask/Image"
local PAINT_WHAT = "Mask/Paint"
local LOCAL_ADJUSTMENT_PREFIX = "Local"

local DERIVED_FIELDS = {
    MaskID = true,
    MaskSyncID = true,
    MaskValue = true,
    CorrectionID = true,
    CorrectionSyncID = true,
    CorrectionReferenceX = true,
    CorrectionReferenceY = true,
    LocalCurveRefineSaturation = true,
    LuminanceDepthSampleInfo = true,
    Flipped = true,
}

local ENTRY_REQUIRED_FIELDS = { What = "string", CorrectionMasks = "table" }
local ENTRY_OPTIONAL_FIELDS = {
    CorrectionName = "string",
    CorrectionActive = "boolean",
    CorrectionAmount = "number",
    MainCurve = "table",
    RedCurve = "table",
    GreenCurve = "table",
    BlueCurve = "table",
}

local COMPONENT_OPTIONAL_FIELDS = {
    MaskActive = "boolean",
    MaskInverted = "boolean",
    MaskBlendMode = "number",
    MaskName = "string",
}

local COMPONENT_SCHEMAS = {
    ["Mask/Gradient"] = {
        required = { What = "string", ZeroX = "number", ZeroY = "number", FullX = "number", FullY = "number" },
        optional = {},
    },
    ["Mask/CircularGradient"] = {
        required = {
            What = "string", Top = "number", Left = "number", Bottom = "number", Right = "number",
            Angle = "number", Feather = "number", Midpoint = "number", Roundness = "number", Version = "number",
        },
        optional = {},
    },
    ["Mask/Aggregate"] = {
        required = { What = "string", Masks = "table" },
        optional = {},
    },
    ["Mask/Paint"] = {
        required = {
            What = "string", Dabs = "table", Radius = "number", Flow = "number", CenterWeight = "number",
        },
        optional = {},
    },
    ["Mask/RangeMask"] = {
        required = { What = "string", CorrectionRangeMask = "table" },
        optional = {},
    },
}

local RANGE_OPTIONAL_FIELDS = { Version = "number", SampleType = "number", Invert = "boolean" }
local RANGE_TYPE_FIELDS = {
    [1] = { ColorAmount = "number", PointModels = "table" },
    [2] = { LumRange = "string" },
    [-1] = { DepthRange = "string" },
}
local RANGE_TYPE_COLOR = 1

local function sortedKeys(set)
    local keys = {}
    for key in pairs(set) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function deepClone(value, depth)
    if type(value) ~= "table" then
        if type(value) == "function" or type(value) == "userdata" then return tostring(value) end
        return value
    end
    if depth > MAX_CLONE_DEPTH then error("mask data is nested too deeply to copy", 0) end
    local copy = {}
    for key, item in pairs(value) do
        copy[key] = deepClone(item, depth + 1)
    end
    return copy
end

function GuardedMaskWrite.deepClone(value)
    return deepClone(value, 0)
end

local function hasType(value, expected)
    if expected == "number" then
        return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
    end
    return type(value) == expected
end

local function addProblem(problems, text)
    problems[#problems + 1] = text
end

local function checkFields(item, required, optional, isAllowedExtra, where, problems)
    for name, expected in pairs(required) do
        local value = item[name]
        if value == nil then
            addProblem(problems, where .. ": missing " .. name)
        elseif not hasType(value, expected) then
            addProblem(problems, where .. ": " .. name .. " must be a " .. expected)
        end
    end
    for name, value in pairs(item) do
        if required[name] == nil then
            local expected = optional[name]
            if expected ~= nil then
                if not hasType(value, expected) then
                    addProblem(problems, where .. ": " .. name .. " must be a " .. expected)
                end
            elseif not DERIVED_FIELDS[name] and not isAllowedExtra(name) then
                addProblem(problems, where .. ": unexpected field " .. tostring(name))
            end
        end
    end
end

local function never() return false end

local function isLocalAdjustment(name)
    return type(name) == "string" and name:sub(1, #LOCAL_ADJUSTMENT_PREFIX) == LOCAL_ADJUSTMENT_PREFIX
end

local function validateRange(range, where, problems)
    if type(range) ~= "table" then
        addProblem(problems, where .. ": CorrectionRangeMask must be a table")
        return
    end
    local typeFields = RANGE_TYPE_FIELDS[range.Type]
    if typeFields == nil then
        addProblem(problems, where .. ": unsupported range Type " .. tostring(range.Type)
            .. " (only luminance 2, color 1 and depth -1 are supported)")
        return
    end
    local required = { Type = "number" }
    for name, expected in pairs(typeFields) do required[name] = expected end
    checkFields(range, required, RANGE_OPTIONAL_FIELDS, never, where, problems)
    if range.Type == RANGE_TYPE_COLOR and type(range.PointModels) == "table" then
        if #range.PointModels ~= 1 then
            addProblem(problems, where .. ": a color range needs exactly one PointModels entry")
        elseif type(range.PointModels[1]) ~= "string" then
            addProblem(problems, where .. ": PointModels entry must be a string")
        end
    end
end

local function validateComponent(component, where, problems)
    if type(component) ~= "table" then
        addProblem(problems, where .. ": not a table")
        return
    end
    if component.What == OPAQUE_WHAT then return end
    local schema = COMPONENT_SCHEMAS[component.What]
    if schema == nil then
        addProblem(problems, where .. ": unknown mask type " .. tostring(component.What))
        return
    end
    local optional = {}
    for name, expected in pairs(COMPONENT_OPTIONAL_FIELDS) do optional[name] = expected end
    for name, expected in pairs(schema.optional) do optional[name] = expected end
    checkFields(component, schema.required, optional, never, where, problems)
    if component.What == "Mask/Aggregate" and type(component.Masks) == "table" then
        for index, child in ipairs(component.Masks) do
            validateComponent(child, where .. ".Masks[" .. index .. "]", problems)
        end
    elseif component.What == "Mask/RangeMask" then
        validateRange(component.CorrectionRangeMask, where, problems)
    end
end

local function validateEntry(entry, where, problems)
    if type(entry) ~= "table" or entry.What ~= "Correction" then
        addProblem(problems, where .. ": not a Correction")
        return
    end
    checkFields(entry, ENTRY_REQUIRED_FIELDS, ENTRY_OPTIONAL_FIELDS, isLocalAdjustment, where, problems)
    if type(entry.CorrectionMasks) ~= "table" then return end
    if #entry.CorrectionMasks == 0 then
        addProblem(problems, where .. ": no mask components")
        return
    end
    for index, component in ipairs(entry.CorrectionMasks) do
        validateComponent(component, where .. ".CorrectionMasks[" .. index .. "]", problems)
    end
end

function GuardedMaskWrite.validateEntries(entries, label)
    local problems = {}
    for index, entry in ipairs(entries) do
        validateEntry(entry, label .. " " .. index, problems)
    end
    table.sort(problems)
    return problems
end

local function describeProblems(problems)
    local shown = {}
    for index = 1, math.min(#problems, MAX_REPORTED_PROBLEMS) do
        shown[index] = problems[index]
    end
    local text = table.concat(shown, "; ")
    if #problems > MAX_REPORTED_PROBLEMS then
        text = text .. string.format("; and %d more", #problems - MAX_REPORTED_PROBLEMS)
    end
    return text
end

local function closeEnough(left, right)
    return math.abs(left - right) <= TOLERANCE * math.max(1, math.abs(left))
end

local function numbersIn(text)
    local numbers = {}
    for token in text:gmatch("%S+") do numbers[#numbers + 1] = tonumber(token) end
    return numbers
end

local function isNumberList(text)
    return text:match("^[%d%.%-%s]+$") ~= nil
end

local function sameNumberList(expected, actual)
    if not (isNumberList(expected) and isNumberList(actual)) then return false end
    local left, right = numbersIn(expected), numbersIn(actual)
    if #left == 0 or #left ~= #right then return false end
    for index = 1, #left do
        if left[index] == nil or right[index] == nil or not closeEnough(left[index], right[index]) then
            return false
        end
    end
    return true
end

local STATE_TOKENS = { f = true, h = true }
local POSITION_TOKEN = "d"

local function dabParts(dab)
    local tag, rest = tostring(dab):match("^(%a+)%s*(.*)$")
    return tag, numbersIn(rest or "")
end

local function splitStateTokens(dabs)
    local positions, tokens = {}, { f = {}, h = {} }
    for _, dab in ipairs(dabs) do
        local tag, numbers = dabParts(dab)
        if STATE_TOKENS[tag] then
            tokens[tag][#tokens[tag] + 1] = numbers[1]
        else
            positions[#positions + 1] = dab
        end
    end
    return positions, tokens
end

local function sameStateTokens(expected, actual)
    if #expected == 0 or #actual == 0 then return true end
    if #expected ~= #actual then return false end
    for index, value in ipairs(expected) do
        if value == nil or actual[index] == nil or not closeEnough(value, actual[index]) then return false end
    end
    return true
end

local function compareDabs(expected, actual, where, problems)
    local expectedPositions, expectedTokens = splitStateTokens(expected)
    local actualPositions, actualTokens = splitStateTokens(actual)
    if #expectedPositions ~= #actualPositions then
        addProblem(problems, where .. ": dab count changed from " .. #expectedPositions .. " to " .. #actualPositions)
        return
    end
    for tag in pairs(STATE_TOKENS) do
        if not sameStateTokens(expectedTokens[tag], actualTokens[tag]) then
            addProblem(problems, where .. ": " .. tag .. " token changed")
        end
    end
    for index, dab in ipairs(expectedPositions) do
        local expectedTag, expectedNumbers = dabParts(dab)
        local actualTag, actualNumbers = dabParts(actualPositions[index])
        local compared = expectedTag == POSITION_TOKEN and 2 or 1
        local same = expectedTag == actualTag and #actualNumbers >= compared
        for position = 1, compared do
            same = same and expectedNumbers[position] ~= nil and actualNumbers[position] ~= nil
                and closeEnough(expectedNumbers[position], actualNumbers[position])
        end
        if not same then addProblem(problems, where .. ": dab " .. index .. " changed") end
    end
end

local function pathOf(parent, name)
    if type(name) == "number" then return parent .. "[" .. name .. "]" end
    return parent .. "." .. tostring(name)
end

local function isLocalAdjustmentOmittedAtDefault(name, expected, actual)
    return actual == nil and isLocalAdjustment(name) and type(expected) == "number" and closeEnough(expected, 0)
end

local function compareValue(name, expected, actual, parent, problems, inPaint)
    if DERIVED_FIELDS[name] and not (inPaint and name == "MaskValue") then return end
    local where = pathOf(parent, name)
    if type(expected) == "table" then
        if type(actual) ~= "table" then
            addProblem(problems, where .. ": lost after the write")
            return
        end
        if expected.What == OPAQUE_WHAT then
            if actual.What ~= OPAQUE_WHAT then addProblem(problems, where .. ": mask type changed") end
            return
        end
        if name == "Dabs" then
            compareDabs(expected, actual, where, problems)
            return
        end
        if #expected ~= #actual then
            addProblem(problems, where .. ": count changed from " .. #expected .. " to " .. #actual)
            return
        end
        for key, value in pairs(expected) do
            compareValue(key, value, actual[key], where, problems, expected.What == PAINT_WHAT)
        end
        return
    end
    local same
    if type(expected) == "number" then
        same = (type(actual) == "number" and closeEnough(expected, actual))
            or isLocalAdjustmentOmittedAtDefault(name, expected, actual)
    elseif type(expected) == "string" then
        same = actual == expected or (type(actual) == "string" and sameNumberList(expected, actual))
    elseif expected == false then
        same = actual == false or actual == nil
    else
        same = actual == expected
    end
    if not same then
        addProblem(problems, where .. ": wrote " .. tostring(expected) .. ", read back " .. tostring(actual))
    end
end

function GuardedMaskWrite.compareEntries(expected, actual)
    local problems = {}
    if #expected ~= #actual then
        addProblem(problems, string.format("mask count changed: wrote %d, read back %d", #expected, #actual))
        return problems
    end
    for index, entry in ipairs(expected) do
        compareValue(index, entry, actual[index], "masks", problems)
    end
    table.sort(problems)
    return problems
end

local function versionLabel()
    local version = LrApplication.versionTable()
    return tostring(version.major) .. "." .. tostring(version.minor)
end

local function requireTestedVersions(processVersion)
    local lightroom = versionLabel()
    if not TESTED_LIGHTROOM_VERSIONS[lightroom] then
        error(string.format(
            "Lightroom Classic %s is not a version this tool has been tested on for writing mask geometry"
                .. " (tested: %s). Nothing was changed.",
            lightroom, table.concat(sortedKeys(TESTED_LIGHTROOM_VERSIONS), ", ")), 0)
    end
    if processVersion == nil or not TESTED_PROCESS_VERSIONS[tostring(processVersion)] then
        error(string.format(
            "The photo's process version (%s) is not one this tool has been tested on for writing mask"
                .. " geometry (tested: %s). Nothing was changed.",
            tostring(processVersion), table.concat(sortedKeys(TESTED_PROCESS_VERSIONS), ", ")), 0)
    end
end

local function readEntries(catalog, photo)
    local settings
    catalog:withReadAccessDo(function() settings = photo:getDevelopSettings() end)
    settings = settings or {}
    local entries = settings.MaskGroupBasedCorrections
    if entries ~= nil and type(entries) ~= "table" then
        error("Lightroom returned mask data that is not a list", 0)
    end
    return deepClone(entries or {}, 0), settings.ProcessVersion
end

function GuardedMaskWrite.readEntries(catalog, photo)
    return (readEntries(catalog, photo))
end

function GuardedMaskWrite.preflight(catalog, photo)
    local entries, processVersion = readEntries(catalog, photo)
    requireTestedVersions(processVersion)
    local problems = GuardedMaskWrite.validateEntries(entries, "existing mask")
    if #problems > 0 then
        error(string.format(
            "The masks already on this photo do not match the format this tool was tested with on"
                .. " Lightroom Classic %s, so nothing was written: %s",
            versionLabel(), describeProblems(problems)), 0)
    end
    return entries
end

local function writeEntries(catalog, photo, description, entries)
    catalog:withWriteAccessDo(description, function()
        photo:applyDevelopSettings({ MaskGroupBasedCorrections = entries })
    end)
end

local function readBackUntilMatching(catalog, photo, expected)
    local waited = 0
    while true do
        local actual = readEntries(catalog, photo)
        local mismatches = GuardedMaskWrite.compareEntries(expected, actual)
        if #mismatches == 0 or waited >= READ_BACK_TIMEOUT_SECONDS then
            return actual, mismatches
        end
        LrTasks.sleep(READ_BACK_POLL_SECONDS)
        waited = waited + READ_BACK_POLL_SECONDS
    end
end

local function restorePrevious(catalog, photo, previous)
    local wrote = LrTasks.pcall(writeEntries, catalog, photo, "Restore masks", previous)
    if not wrote then return false end
    local read, _, mismatches = LrTasks.pcall(readBackUntilMatching, catalog, photo, previous)
    return read and #mismatches == 0
end

local function failAfterRollback(catalog, photo, previous, problems)
    local restored = restorePrevious(catalog, photo, previous)
    local summary = describeProblems(problems)
    Log.warn(string.format("Guarded mask write failed (restored=%s): %s", tostring(restored), summary))
    if restored then
        error("Lightroom did not keep the mask data that was written, so the photo's previous masks were"
            .. " restored: " .. summary, 0)
    end
    error("Lightroom did not keep the mask data that was written, and the previous masks could not be"
        .. " confirmed restored; check the photo's masks in Develop: " .. summary, 0)
end

function GuardedMaskWrite.apply(catalog, photo, spec)
    local previous = GuardedMaskWrite.preflight(catalog, photo)
    local proposed = spec.build(deepClone(previous, 0))
    if type(proposed) ~= "table" then error("mask change produced no mask list", 0) end

    local problems = GuardedMaskWrite.validateEntries(proposed, "new mask")
    if #problems > 0 then
        error("The requested mask change does not match the format this tool was tested with, so nothing was"
            .. " written: " .. describeProblems(problems), 0)
    end

    local wrote, writeError = LrTasks.pcall(writeEntries, catalog, photo, spec.description, deepClone(proposed, 0))
    if not wrote then
        failAfterRollback(catalog, photo, previous, { "Lightroom rejected the write: " .. tostring(writeError) })
    end

    local read, actual, mismatches = LrTasks.pcall(readBackUntilMatching, catalog, photo, proposed)
    if not read then
        mismatches = { "the masks could not be read back: " .. tostring(actual) }
    end
    if #mismatches == 0 and spec.crossCheck then
        local checked, crossProblem = LrTasks.pcall(spec.crossCheck, actual)
        if not checked then
            mismatches = { "check against Lightroom's mask list failed: " .. tostring(crossProblem) }
        elseif crossProblem then
            mismatches = { crossProblem }
        end
    end
    if #mismatches > 0 then
        failAfterRollback(catalog, photo, previous, mismatches)
    end
    return { previous = previous, entries = actual }
end

function GuardedMaskWrite.newCorrection(name, components)
    return {
        What = "Correction",
        CorrectionName = name,
        CorrectionActive = true,
        CorrectionAmount = 1,
        CorrectionMasks = components,
    }
end

function GuardedMaskWrite.findCorrection(entries, maskId)
    for index, entry in ipairs(entries) do
        if entry.CorrectionID ~= nil and tostring(entry.CorrectionID) == tostring(maskId) then
            return index, entry
        end
    end
    return nil
end

function GuardedMaskWrite.findComponent(entries, toolId)
    for entryIndex, entry in ipairs(entries) do
        for componentIndex, component in ipairs(entry.CorrectionMasks or {}) do
            if component.MaskID ~= nil and tostring(component.MaskID) == tostring(toolId) then
                return entryIndex, componentIndex, component
            end
        end
    end
    return nil
end

GuardedMaskWrite.TESTED_LIGHTROOM_VERSIONS = TESTED_LIGHTROOM_VERSIONS
GuardedMaskWrite.TESTED_PROCESS_VERSIONS = TESTED_PROCESS_VERSIONS

return GuardedMaskWrite
