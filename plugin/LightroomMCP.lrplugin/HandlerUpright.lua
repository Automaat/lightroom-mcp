local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
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
-- A Guided request can be lost: 3 of 14 back-to-back writes with Lightroom in
-- front got no matrix within 6 s, and a fresh call then worked at once (live
-- on LrC 16.0.1, 61 MP raws). After the first wait, choose Guided again; last,
-- repeat what that fresh call did (write, then choose). About 20 s in all.
local COMPUTE_RETRY_SECONDS = 7
local COMPUTE_TOTAL_SECONDS = COMPUTE_TIMEOUT_SECONDS + 2 * COMPUTE_RETRY_SECONDS
local TRANSFORM_KEY = UprightGuides.TRANSFORM_KEY

local SERVER_LONG_RUNNING_TIMEOUT_SECONDS = 300
-- Worst case for one more photo: opening it (up to about 13 s when Lightroom
-- has to switch the source), the write and its read-back, all three compute
-- tiers, and a restore that recomputes the previous matrix.
local BATCH_PHOTO_RESERVE_SECONDS = 60
local BATCH_TIME_BUDGET_SECONDS = SERVER_LONG_RUNNING_TIMEOUT_SECONDS - BATCH_PHOTO_RESERVE_SECONDS
local MAX_BATCH_ITEMS = 50

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
        local function recomputedWithin(seconds)
            if not chooseGuided() then return false end
            return DevelopSession.waitFor(function()
                local ok, settings = LrTasks.pcall(readSettings, catalog, photo)
                return ok and settings[TRANSFORM_KEY] == previousTransform
            end, seconds)
        end
        if not (recomputedWithin(COMPUTE_TIMEOUT_SECONDS) or recomputedWithin(COMPUTE_RETRY_SECONDS)) then
            return false, "Lightroom did not recompute the previous Guided correction"
        end
    end
    return true
end

local function writeSettings(catalog, photo, settings, historyName)
    catalog:withWriteAccessDo(historyName, function()
        photo:applyDevelopSettings(settings, historyName)
    end)
end

-- Reads what a write needs to know about the photo before it changes anything.
local function prepare(catalog, photo, photoId, displayed)
    local orientation, before
    catalog:withReadAccessDo(function()
        orientation = photo:getRawMetadata("orientation")
        before = photo:getDevelopSettings()
    end)
    before = before or {}
    local stored = UprightGuides.toStored(ImageFrame.fromOrientation(orientation), displayed)
    local previousTransform = before[TRANSFORM_KEY]
    -- Guides on the lines of the current ones give the same matrix back, so an
    -- unchanged matrix proves nothing stale there; otherwise it must change.
    local sameMatrixExpected = previousTransform ~= nil and UprightGuides.sameLines(stored, before)
    return {
        photoId = photoId,
        stored = stored,
        saved = UprightGuides.snapshot(before),
        previousTransform = previousTransform,
        isComputed = function(settings)
            local transform = settings[TRANSFORM_KEY]
            return transform ~= nil and (sameMatrixExpected or transform ~= previousTransform)
        end,
    }
end

-- Write the guides, verify them and have Lightroom compute the matrix; on any
-- failure put the previous Upright settings back. Runs with the photo active
-- in Develop inside the caller's Develop session.
local function applyGuides(catalog, photo, prep)
    local stored, photoId = prep.stored, prep.photoId
    local guideSettings = UprightGuides.settingsFor(stored)
    local started = LrDate.currentTime()
    writeSettings(catalog, photo, guideSettings, HISTORY_NAME)

    local failure, tier
    local function guidesKept()
        local problems
        DevelopSession.waitFor(function()
            problems = UprightGuides.problems(stored, readSettings(catalog, photo))
            return #problems == 0
        end, SAVE_TIMEOUT_SECONDS)
        if #problems > 0 then
            failure = "Lightroom did not keep the guides (" .. table.concat(problems, "; ") .. ")"
        end
        return failure == nil
    end
    local function computeWithin(seconds)
        if not chooseGuided() then return false end
        return DevelopSession.waitFor(function()
            return prep.isComputed(readSettings(catalog, photo))
        end, seconds)
    end

    local checked, checkError = LrTasks.pcall(function()
        if not guidesKept() then return end
        if computeWithin(COMPUTE_TIMEOUT_SECONDS) then
            tier = "first"
        elseif computeWithin(COMPUTE_RETRY_SECONDS) then
            tier = "reselect"
        else
            writeSettings(catalog, photo, prep.saved, RESTORE_HISTORY_NAME)
            writeSettings(catalog, photo, guideSettings, HISTORY_NAME)
            if not guidesKept() then return end
            if computeWithin(COMPUTE_RETRY_SECONDS) then tier = "rewrite" end
        end
        local settings = readSettings(catalog, photo)
        local problems = UprightGuides.problems(stored, settings)
        if #problems > 0 then
            failure = "Lightroom changed the guides while computing the correction ("
                .. table.concat(problems, "; ") .. ")"
        elseif not prep.isComputed(settings) then
            failure = string.format("Lightroom did not compute the Guided correction within %d s, even after"
                .. " choosing Guided again and rewriting the guides. It computes only for the photo active in"
                .. " Develop and slows down while Lightroom is in the background: bring Lightroom to the front"
                .. " and call again. If it keeps failing in front, check that Develop offers Upright for this photo",
                COMPUTE_TOTAL_SECONDS)
        end
    end)
    if not checked then failure = "reading the photo back failed: " .. tostring(checkError) end

    if failure then
        local restored, why = restore(catalog, photo, prep.saved, prep.previousTransform)
        Log.warn(string.format("%s on photo %s: %s; restore %s", TOOL_NAME, photoId, failure,
            restored and "succeeded" or ("failed: " .. tostring(why))))
        error(failure .. "; " .. (restored and "the previous Upright settings were restored"
            or ("restoring the previous Upright settings failed: " .. tostring(why))), 0)
    end

    -- The tier shows in the log how often Lightroom needed a second request.
    Log.info(string.format("Set %d Upright guides on photo %s (matrix on %s attempt, %.1f s)",
        #stored, photoId, tier, LrDate.currentTime() - started))
    return #stored
end

local function requireItems(items)
    if type(items) ~= "table" or #items < 1 or #items > MAX_BATCH_ITEMS then
        error(string.format("items must hold 1 to %d entries", MAX_BATCH_ITEMS), 0)
    end
    local parsed = {}
    for i, item in ipairs(items) do
        if type(item) ~= "table" then error(string.format("items.%d must be an object", i - 1), 0) end
        local ok, photoId = pcall(requirePhotoId, item.photo_id)
        if not ok then error(string.format("items.%d.photo_id is required", i - 1), 0) end
        local valid, guides = pcall(UprightGuides.parseGuides, item.guides)
        if not valid then error(string.format("items.%d: %s", i - 1, tostring(guides)), 0) end
        parsed[i] = { photoId = photoId, guides = guides }
    end
    return parsed
end

-- One Develop session for many photos: every entry is validated before
-- Develop opens, each photo is written, verified and (on failure) restored
-- while it is the active one, and a failure moves on to the next photo.
-- Photos left when the time budget runs out come back in remaining_ids.
local function setGuidesBatch(args)
    local items = requireItems(args.items)
    local catalog = LrApplication.activeCatalog()
    local ids = {}
    for i, item in ipairs(items) do ids[i] = item.photoId end
    local resolved = PhotoLookup.resolveMany(catalog, ids)
    local startedAt = LrDate.currentTime()

    local results, remaining = {}, {}
    local counts = { applied = 0, failed = 0, skipped = 0 }
    DevelopSession.run(TOOL_NAME, catalog, true, function(state)
        local seen = {}
        for i, item in ipairs(items) do
            local entry = resolved[i]
            if #remaining > 0 or LrDate.currentTime() - startedAt >= BATCH_TIME_BUDGET_SECONDS then
                remaining[#remaining + 1] = item.photoId
            else
                local result
                if not entry.photo then
                    result = { status = "skipped", error = "photo not found" }
                elseif seen[entry.photo] then
                    result = { status = "skipped", error = "duplicate of an earlier entry" }
                else
                    seen[entry.photo] = true
                    local photoStarted = LrDate.currentTime()
                    local ok, outcome = LrTasks.pcall(function()
                        DevelopSession.openPhoto(catalog, entry.photo, state)
                        return applyGuides(catalog, entry.photo, prepare(catalog, entry.photo, item.photoId, item.guides))
                    end)
                    result = ok and { status = "applied", guide_count = outcome }
                        or { status = "failed", error = tostring(outcome) }
                    result.seconds = math.floor((LrDate.currentTime() - photoStarted) * 10 + 0.5) / 10
                end
                result.photo_id = item.photoId
                counts[result.status] = counts[result.status] + 1
                results[#results + 1] = result
            end
        end
    end)

    local complete = #remaining == 0
    Log.info(string.format("%s batch: %d applied, %d failed, %d skipped, %d not reached", TOOL_NAME,
        counts.applied, counts.failed, counts.skipped, #remaining))
    return {
        success = counts.failed == 0 and counts.skipped == 0 and complete,
        applied = counts.applied,
        failed = counts.failed,
        skipped = counts.skipped,
        results = results,
        complete = complete,
        remaining_ids = not complete and remaining or nil,
    }
end

-- Turn on Guided Upright with 2-4 guides given in the displayed frame, on one
-- photo (photo_id, guides) or on several (items). Every step, including the
-- restore on failure, runs in one Develop session, so no other Develop-driving
-- call can interleave and nothing is written when the session cannot start.
function UprightHandler.setGuides(args)
    args = args or {}
    if args.items ~= nil then
        if args.photo_id ~= nil or args.guides ~= nil then
            error("Give photo_id and guides, or items, not both", 0)
        end
        return setGuidesBatch(args)
    end
    local photoId = requirePhotoId(args.photo_id)
    local displayed = UprightGuides.parseGuides(args.guides)

    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, photoId)
    if not photo then error("Photo not found: " .. photoId, 0) end
    local prep = prepare(catalog, photo, photoId, displayed)

    return DevelopSession.withPhoto(TOOL_NAME, catalog, photo, function()
        local count = applyGuides(catalog, photo, prep)
        return { success = true, photo_id = photoId, guide_count = count }
    end)
end

return UprightHandler
