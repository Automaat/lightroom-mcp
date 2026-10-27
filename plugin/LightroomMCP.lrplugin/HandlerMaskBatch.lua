local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
local LrTasks = import 'LrTasks'

local AIMaskData = require 'AIMaskData'
local DevelopSession = require 'DevelopSession'
local GuardedMaskWrite = require 'GuardedMaskWrite'
local Log = require 'Log'
local MaskCreate = require 'HandlerMaskCreate'
local PhotoLookup = require 'PhotoLookup'

local MaskBatchHandler = {}

local TOOL_NAME = "create_mask_batch"
local MAX_BATCH_PHOTO_IDS = 200
local SERVER_LONG_RUNNING_TIMEOUT_SECONDS = 300
local LAST_STEP_AND_RESTORE_SECONDS = 70
local TIME_BUDGET_SECONDS = SERVER_LONG_RUNNING_TIMEOUT_SECONDS - LAST_STEP_AND_RESTORE_SECONDS

local SAVED_ENTRY_TIMEOUT_SECONDS = 10
local SAVED_ENTRY_STABLE_READS = 3
local AI_COMPUTE_TIMEOUT_SECONDS = 15
local UPDATE_AI_SETTINGS_MINIMUM_VERSION = "Lightroom Classic 13.3"

local CORRECTION_ID_FIELDS = { "CorrectionID", "CorrectionSyncID" }
local COMPONENT_ID_FIELDS = { "MaskID", "MaskSyncID" }

local STATUS_CREATED = "created"
local STATUS_FAILED = "failed"
local STATUS_NOT_ATTEMPTED = "not_attempted"
local STATUS_PENDING = "pending"

local running = false

local function requirePhotoIdArray(value)
    if type(value) ~= "table" or #value == 0 then
        error("photo_ids is required and must be a non-empty array")
    end
    if #value > MAX_BATCH_PHOTO_IDS then
        error(string.format("photo_ids may hold at most %d ids", MAX_BATCH_PHOTO_IDS))
    end
    for _, id in ipairs(value) do
        local idType = type(id)
        if not ((idType == "string" and id ~= "") or idType == "number") then
            error("photo_ids must hold photo ids or file paths")
        end
    end
    return value
end

local function requireRecomputeApi(photo)
    if type(photo.updateAISettings) ~= "function" then
        error(TOOL_NAME .. " needs " .. UPDATE_AI_SETTINGS_MINIMUM_VERSION .. " or later")
    end
end

local function collectItems(catalog, photoIds)
    local items, missing, seen = {}, {}, {}
    for _, entry in ipairs(PhotoLookup.resolveMany(catalog, photoIds)) do
        if not entry.photo then
            missing[#missing + 1] = tostring(entry.id)
        elseif not seen[entry.photo] then
            seen[entry.photo] = true
            items[#items + 1] = {
                id = tostring(entry.photo.localIdentifier),
                photo = entry.photo,
                status = STATUS_PENDING,
            }
        end
    end
    return items, missing
end

local function fail(item, reason)
    item.status = STATUS_FAILED
    item.reason = reason
end

local function failUnsafePhotos(catalog, items)
    for _, item in ipairs(items) do
        local ok, err = LrTasks.pcall(GuardedMaskWrite.preflight, catalog, item.photo)
        if not ok then fail(item, tostring(err)) end
    end
end

local function pendingItems(items)
    local pending = {}
    for _, item in ipairs(items) do
        if item.status == STATUS_PENDING then pending[#pending + 1] = item end
    end
    return pending
end

local function createTemplateInDevelop(catalog, candidates, request, hasTimeLeft, report)
    local outcome = { alertPossible = false }
    DevelopSession.run(TOOL_NAME, catalog, true, function(state)
        for _, item in ipairs(candidates) do
            if not hasTimeLeft() then return end
            report(item)
            local ok, result = LrTasks.pcall(function()
                DevelopSession.openPhoto(catalog, item.photo, state)
                return MaskCreate.createInDevelop(
                    catalog, item.photo, item.id, request.typeName, request.spec, request.values)
            end)
            if ok then
                outcome.template = item
                outcome.maskId = result.ID
                outcome.mask = result
                return
            end
            fail(item, tostring(result))
            if MaskCreate.isNothingFoundFailure(tostring(result)) then
                outcome.alertPossible = true
                return
            end
        end
    end)
    return outcome
end

local function readSavedCorrection(catalog, photo, maskId)
    local previous, found
    local steadyReads = 0
    local ready = DevelopSession.waitFor(function()
        local _, correction = GuardedMaskWrite.findCorrection(GuardedMaskWrite.readEntries(catalog, photo), maskId)
        if correction and AIMaskData.correctionIsComputed(correction) and previous
            and #GuardedMaskWrite.compareEntries({ previous }, { correction }) == 0 then
            steadyReads = steadyReads + 1
        else
            steadyReads = 0
        end
        previous = correction
        found = correction
        return steadyReads >= SAVED_ENTRY_STABLE_READS
    end, SAVED_ENTRY_TIMEOUT_SECONDS)
    if ready then return found end
    return nil
end

local function recomputableCopyOf(correction)
    local copy = GuardedMaskWrite.deepClone(correction)
    for _, key in ipairs(CORRECTION_ID_FIELDS) do copy[key] = nil end
    for _, component in ipairs(copy.CorrectionMasks) do
        for _, key in ipairs(COMPONENT_ID_FIELDS) do component[key] = nil end
    end
    return AIMaskData.withoutComputedData({ MaskGroupBasedCorrections = { copy } }).MaskGroupBasedCorrections[1]
end

local function recomputeAISettings(catalog, photo)
    local ok, err
    catalog:withWriteAccessDo("Update AI Settings", function()
        ok, err = LrTasks.pcall(function() photo:updateAISettings() end)
    end)
    if not ok then error(tostring(err), 0) end
end

local function removeAddedMask(catalog, photo, previous)
    return LrTasks.pcall(GuardedMaskWrite.apply, catalog, photo, {
        description = "Remove failed AI mask",
        build = function() return GuardedMaskWrite.deepClone(previous) end,
    })
end

local function failureAfterCleanup(catalog, photo, previous, message)
    local removed = removeAddedMask(catalog, photo, previous)
    if removed then return message end
    return message .. "; the added mask could not be removed, check the photo's masks in Develop"
end

local function computedMaskOnTarget(catalog, photo, template, request)
    local written = GuardedMaskWrite.apply(catalog, photo, {
        description = "Add " .. request.typeName .. " mask",
        build = function(entries)
            entries[#entries + 1] = GuardedMaskWrite.deepClone(template)
            return entries
        end,
    })
    local previous = written.previous
    local addedIndex = #previous + 1

    local recomputed, recomputeError = LrTasks.pcall(recomputeAISettings, catalog, photo)
    if not recomputed then
        error(failureAfterCleanup(catalog, photo, previous, string.format(
            "Lightroom could not compute the %s mask: %s", request.typeName, tostring(recomputeError))), 0)
    end

    local computed
    local ready = DevelopSession.waitFor(function()
        computed = GuardedMaskWrite.readEntries(catalog, photo)[addedIndex]
        return AIMaskData.correctionIsComputed(computed)
    end, AI_COMPUTE_TIMEOUT_SECONDS)
    if not ready then
        error(failureAfterCleanup(catalog, photo, previous, string.format(
            "Lightroom found no %s to select", request.typeName)), 0)
    end
    return computed
end

local function addMasksToTargets(catalog, targets, template, request, hasTimeLeft, report)
    for _, item in ipairs(targets) do
        if hasTimeLeft() then
            report(item)
            local ok, result = LrTasks.pcall(computedMaskOnTarget, catalog, item.photo, template, request)
            if ok then
                item.status = STATUS_CREATED
                item.maskId = result.CorrectionID ~= nil and tostring(result.CorrectionID) or nil
            else
                fail(item, tostring(result))
            end
        end
    end
end

local function describe(item)
    local entry = { photo_id = item.id, status = item.status, created = item.status == STATUS_CREATED }
    if item.maskId then entry.mask_id = item.maskId end
    if item.reason then entry.reason = item.reason end
    return entry
end

local function summarize(items, outcome, request, startedAt, missing)
    local counts = { [STATUS_CREATED] = 0, [STATUS_FAILED] = 0, [STATUS_NOT_ATTEMPTED] = 0 }
    local results, remainingIds = {}, {}
    for _, item in ipairs(items) do
        if item.status == STATUS_PENDING then
            item.status = STATUS_NOT_ATTEMPTED
            item.reason = outcome.alertPossible
                and "stopped after Lightroom found nothing to select; click OK on its alert, then call again"
                or "not reached before the time budget ended; call again with remaining_ids"
        end
        if item.status == STATUS_NOT_ATTEMPTED then remainingIds[#remainingIds + 1] = item.id end
        counts[item.status] = counts[item.status] + 1
        results[#results + 1] = describe(item)
    end

    local message
    if outcome.alertPossible then
        message = "Lightroom probably shows a \"No " .. request.typeName
            .. " detected\" alert: click OK in Lightroom before the next Develop call"
    end
    local response = {
        success = counts[STATUS_FAILED] == 0 and counts[STATUS_NOT_ATTEMPTED] == 0,
        complete = counts[STATUS_NOT_ATTEMPTED] == 0,
        created = counts[STATUS_CREATED],
        failed = counts[STATUS_FAILED],
        not_attempted = counts[STATUS_NOT_ATTEMPTED],
        results = results,
        missing = missing,
        remaining_ids = #remainingIds > 0 and remainingIds or nil,
        seconds = math.floor((LrDate.currentTime() - startedAt) * 10 + 0.5) / 10,
        message = message,
    }
    return response, counts
end

local function runBatch(args, context)
    local photoIds = requirePhotoIdArray(args.photo_ids)
    local typeName, spec = MaskCreate.requireMaskType(args.type)
    local values = MaskCreate.validateAdjustments(args.adjustments)
    MaskCreate.requireCreateApi(TOOL_NAME)
    local request = { typeName = typeName, spec = spec, values = values }

    local catalog = LrApplication.activeCatalog()
    local startedAt = LrDate.currentTime()
    local function hasTimeLeft()
        return not (context and context:isCanceled()) and LrDate.currentTime() - startedAt < TIME_BUDGET_SECONDS
    end

    local items, missing = collectItems(catalog, photoIds)
    if #items > 0 then requireRecomputeApi(items[1].photo) end
    failUnsafePhotos(catalog, items)
    local lastReportedItem
    local function report(item)
        lastReportedItem = item
        if context then
            local done = 0
            for _, entry in ipairs(items) do if entry.status ~= STATUS_PENDING then done = done + 1 end end
            context:report(done, #items, item.photo:getFormattedMetadata("fileName") or item.id)
        end
    end

    local outcome = { alertPossible = false }
    local candidates = pendingItems(items)
    if #candidates > 0 then
        outcome = createTemplateInDevelop(catalog, candidates, request, hasTimeLeft, report)
    end

    if outcome.template then
        outcome.template.status = STATUS_CREATED
        outcome.template.maskId = outcome.maskId
        local correction = readSavedCorrection(catalog, outcome.template.photo, outcome.maskId)
        local targets = pendingItems(items)
        if correction then
            addMasksToTargets(catalog, targets, recomputableCopyOf(correction), request, hasTimeLeft, report)
        else
            for _, item in ipairs(targets) do
                fail(item, "Lightroom did not save the new mask on photo " .. outcome.template.id
                    .. ", so it could not be added here")
            end
        end
    end

    if context and lastReportedItem then report(lastReportedItem) end
    local response, counts = summarize(items, outcome, request, startedAt, missing)
    Log.info(string.format("create_mask_batch %s: %d created, %d failed, %d not attempted (%d ids not found)",
        typeName, counts[STATUS_CREATED], counts[STATUS_FAILED], counts[STATUS_NOT_ATTEMPTED], #missing))
    return response
end

function MaskBatchHandler.createMaskBatch(args, context)
    if running then
        error(TOOL_NAME .. " is already running; wait for it to finish, then call again")
    end
    running = true
    local ok, result = LrTasks.pcall(runBatch, args, context)
    running = false
    if not ok then error(result, 0) end
    return result
end

return MaskBatchHandler
