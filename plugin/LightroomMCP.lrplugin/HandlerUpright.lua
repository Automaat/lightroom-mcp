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
local SAVE_TIMEOUT_SECONDS = 2
local COMPUTE_TIMEOUT_SECONDS = 6

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

local function restore(catalog, photo, saved)
    local ok, err = LrTasks.pcall(function()
        catalog:withWriteAccessDo(HISTORY_NAME .. " (restore)", function()
            photo:applyDevelopSettings(saved, HISTORY_NAME .. " (restore)")
        end)
    end)
    if not ok then return false, tostring(err) end
    -- A settings write cannot delete a key, so a guide slot that was empty
    -- keeps the new text; the mode and count decide what Lightroom uses.
    local back = UprightGuides.snapshot(readSettings(catalog, photo))
    for key, value in pairs(saved) do
        if value ~= nil and back[key] ~= value then return false, key .. " did not restore" end
    end
    return true
end

local function failAndRestore(catalog, photo, saved, problems)
    local restored, why = restore(catalog, photo, saved)
    error(string.format("Lightroom did not keep the guides (%s); %s", table.concat(problems, "; "),
        restored and "the previous Upright settings were restored"
            or ("restoring the previous Upright settings failed: " .. tostring(why))), 0)
end

-- Turn on Guided Upright with 2-4 guides given in the displayed frame.
--
-- applyDevelopSettings stores the guides but Lightroom does not compute the
-- Guided matrix (UprightTransform_5) from them, not even when the photo is
-- opened in Develop. Choosing Guided through LrDevelopController with the
-- photo active in Develop does, within about 2 s (live check on LrC 16.0.1).
function UprightHandler.setGuides(args)
    args = args or {}
    local photoId = requirePhotoId(args.photo_id)
    local displayed = UprightGuides.parseGuides(args.guides)

    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, photoId)
    if not photo then error("Photo not found: " .. photoId, 0) end

    local frame = ImageFrame.forPhoto(catalog, photo)
    local stored = UprightGuides.toStored(frame, displayed)
    local before = readSettings(catalog, photo)
    local saved = UprightGuides.snapshot(before)
    local previousTransform = before[UprightGuides.TRANSFORM_KEY]
    -- Writing the guides already in place leaves a computed matrix unchanged.
    local alreadySet = #UprightGuides.problems(stored, before) == 0
    local function isComputed(settings)
        local transform = settings[UprightGuides.TRANSFORM_KEY]
        return transform ~= nil and (alreadySet or transform ~= previousTransform)
    end

    catalog:withWriteAccessDo(HISTORY_NAME, function()
        photo:applyDevelopSettings(UprightGuides.settingsFor(stored), HISTORY_NAME)
    end)

    local settings, problems
    DevelopSession.waitFor(function()
        settings = readSettings(catalog, photo)
        problems = UprightGuides.problems(stored, settings)
        return #problems == 0
    end, SAVE_TIMEOUT_SECONDS)
    if #problems > 0 then failAndRestore(catalog, photo, saved, problems) end

    if not isComputed(settings) then
        DevelopSession.withPhoto(TOOL_NAME, catalog, photo, function()
            local ok, err = LrTasks.pcall(LrDevelopController.setValue, "PerspectiveUpright",
                UprightGuides.GUIDED_MODE)
            if not ok then Log.warn("set_upright_guides: choosing Guided failed: " .. tostring(err)) end
            DevelopSession.waitFor(function()
                settings = readSettings(catalog, photo)
                return isComputed(settings)
            end, COMPUTE_TIMEOUT_SECONDS)
        end)
        settings = readSettings(catalog, photo)
        problems = UprightGuides.problems(stored, settings)
        if #problems > 0 then failAndRestore(catalog, photo, saved, problems) end
    end

    local computed = isComputed(settings)
    Log.info(string.format("Set %d Upright guides on photo %s (transform %s)", #stored, photoId,
        computed and "computed" or "not computed"))
    return {
        success = true,
        photo_id = photoId,
        guide_count = #stored,
        transform_computed = computed,
    }
end

return UprightHandler
