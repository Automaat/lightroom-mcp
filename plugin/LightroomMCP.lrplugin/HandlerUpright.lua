local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local DevelopSession = require 'DevelopSession'
local ImageFrame = require 'ImageFrame'
local Log = require 'Log'
local PhotoLookup = require 'PhotoLookup'
local UprightGuides = require 'UprightGuides'

local UprightHandler = {}

local TOOL_NAME = "set_upright_guides"
local HISTORY_NAME = "Upright Guides"
local RESTORE_HISTORY_NAME = "Upright Guides (restore)"
local SAVE_TIMEOUT_SECONDS = 2
local COMPUTE_TIMEOUT_SECONDS = 6
local TRANSFORM_KEY = UprightGuides.TRANSFORM_KEY

local function requirePhotoId(value)
    if type(value) == "number" then return tostring(value) end
    if type(value) ~= "string" or value == "" then
        error("photo_id is required", 0)
    end
    return value
end

local function readSettings(catalog, photo)
    local settings
    catalog:withReadAccessDo(function() settings = photo:getDevelopSettings() end)
    return settings or {}
end

-- Lightroom computes the Guided matrix (UprightTransform_5) only when Guided is
-- chosen through LrDevelopController with the photo active in Develop, not from
-- applyDevelopSettings (live check on LrC 16.0.1).
local function chooseGuided()
    local ok, err = LrTasks.pcall(LrDevelopController.setValue, "PerspectiveUpright", UprightGuides.GUIDED_MODE)
    if not ok then Log.warn(TOOL_NAME .. ": choosing Guided failed: " .. tostring(err)) end
    return ok
end

-- Puts back the Upright settings saved before the write and, for a photo that
-- was in Guided mode, has Lightroom recompute its matrix from the restored
-- guides. Runs with the photo active in Develop. Returns ok and why not.
local function restore(catalog, photo, saved, previousTransform)
    local wrote, writeError = LrTasks.pcall(function()
        catalog:withWriteAccessDo(RESTORE_HISTORY_NAME, function()
            photo:applyDevelopSettings(saved, RESTORE_HISTORY_NAME)
        end)
    end)
    if not wrote then return false, tostring(writeError) end

    local why
    local restored = DevelopSession.waitFor(function()
        local ok, settings = LrTasks.pcall(readSettings, catalog, photo)
        if not ok then
            why = "reading it back failed: " .. tostring(settings)
            return false
        end
        local problems = UprightGuides.restoreProblems(saved, settings)
        why = problems[1]
        return #problems == 0
    end, SAVE_TIMEOUT_SECONDS)
    if not restored then return false, why end

    if saved.PerspectiveUpright == UprightGuides.GUIDED_MODE and previousTransform ~= nil then
        if not chooseGuided() then return false, "choosing Guided again failed" end
        local recomputed = DevelopSession.waitFor(function()
            local ok, settings = LrTasks.pcall(readSettings, catalog, photo)
            return ok and settings[TRANSFORM_KEY] == previousTransform
        end, COMPUTE_TIMEOUT_SECONDS)
        if not recomputed then return false, "Lightroom did not recompute the previous Guided correction" end
    end
    return true
end

-- Turn on Guided Upright with 2-4 guides given in the displayed frame. Every
-- step, including the restore on failure, runs in one Develop session, so no
-- other Develop-driving call can interleave and nothing is written when the
-- session cannot start.
function UprightHandler.setGuides(args)
    args = args or {}
    local photoId = requirePhotoId(args.photo_id)
    local displayed = UprightGuides.parseGuides(args.guides)

    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, photoId)
    if not photo then error("Photo not found: " .. photoId, 0) end

    local orientation, before
    catalog:withReadAccessDo(function()
        orientation = photo:getRawMetadata("orientation")
        before = photo:getDevelopSettings()
    end)
    before = before or {}
    local stored = UprightGuides.toStored(ImageFrame.fromOrientation(orientation), displayed)
    local saved = UprightGuides.snapshot(before)
    local previousTransform = before[TRANSFORM_KEY]
    -- Guides on the lines of the current ones give the same matrix back, so an
    -- unchanged matrix proves nothing stale there; otherwise it must change.
    local sameMatrixExpected = previousTransform ~= nil and UprightGuides.sameLines(stored, before)
    local function isComputed(settings)
        local transform = settings[TRANSFORM_KEY]
        return transform ~= nil and (sameMatrixExpected or transform ~= previousTransform)
    end

    return DevelopSession.withPhoto(TOOL_NAME, catalog, photo, function()
        catalog:withWriteAccessDo(HISTORY_NAME, function()
            photo:applyDevelopSettings(UprightGuides.settingsFor(stored), HISTORY_NAME)
        end)

        local failure
        local checked, checkError = LrTasks.pcall(function()
            local problems
            DevelopSession.waitFor(function()
                problems = UprightGuides.problems(stored, readSettings(catalog, photo))
                return #problems == 0
            end, SAVE_TIMEOUT_SECONDS)
            if #problems > 0 then
                failure = "Lightroom did not keep the guides (" .. table.concat(problems, "; ") .. ")"
                return
            end
            if chooseGuided() then
                DevelopSession.waitFor(function()
                    return isComputed(readSettings(catalog, photo))
                end, COMPUTE_TIMEOUT_SECONDS)
            end
            local settings = readSettings(catalog, photo)
            problems = UprightGuides.problems(stored, settings)
            if #problems > 0 then
                failure = "Lightroom changed the guides while computing the correction ("
                    .. table.concat(problems, "; ") .. ")"
            elseif not isComputed(settings) then
                failure = "Lightroom did not compute the Guided correction"
                    .. " (Guided Upright needs Process Version 3 or later)"
            end
        end)
        if not checked then failure = "reading the photo back failed: " .. tostring(checkError) end

        if failure then
            local restored, why = restore(catalog, photo, saved, previousTransform)
            Log.warn(string.format("%s on photo %s: %s; restore %s", TOOL_NAME, photoId, failure,
                restored and "succeeded" or ("failed: " .. tostring(why))))
            error(failure .. "; " .. (restored and "the previous Upright settings were restored"
                or ("restoring the previous Upright settings failed: " .. tostring(why))), 0)
        end

        Log.info(string.format("Set %d Upright guides on photo %s", #stored, photoId))
        return { success = true, photo_id = photoId, guide_count = #stored }
    end)
end

return UprightHandler
