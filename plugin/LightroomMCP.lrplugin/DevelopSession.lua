local LrApplicationView = import 'LrApplicationView'
local LrDevelopController = import 'LrDevelopController'
local LrSelection = import 'LrSelection'
local LrTasks = import 'LrTasks'

local Log = require 'Log'

local DevelopSession = {}

local SELECT_TIMEOUT_SECONDS = 10
local RESELECT_SECONDS = 1
local POLL_SECONDS = 0.1
local PHOTO_SETTLE_SECONDS = 0.5

local MASK_API_FUNCTIONS = { "getAllMasks", "selectMask", "selectMaskTool" }
local MASK_API_MINIMUM_VERSION = "Lightroom Classic 11"

local runningTool = nil

function DevelopSession.waitFor(predicate, timeoutSeconds)
    local waited = 0
    while waited < timeoutSeconds do
        if predicate() then return true end
        LrTasks.sleep(POLL_SECONDS)
        waited = waited + POLL_SECONDS
    end
    return predicate()
end

local function retryUntil(done, action)
    local sinceAction = RESELECT_SECONDS
    return DevelopSession.waitFor(function()
        if done() then return true end
        if sinceAction >= RESELECT_SECONDS then
            action()
            sinceAction = 0
        end
        sinceAction = sinceAction + POLL_SECONDS
        return false
    end, SELECT_TIMEOUT_SECONDS)
end

local function selectAndWait(catalog, photo, selection)
    return retryUntil(
        function() return catalog:getTargetPhoto() == photo end,
        function() catalog:setSelectedPhotos(photo, selection) end)
end

local function selectNoneAndWait(catalog)
    local quietChecks = 0
    return retryUntil(function()
        quietChecks = catalog:getTargetPhoto() == nil and quietChecks + 1 or 0
        return quietChecks >= RESELECT_SECONDS / POLL_SECONDS + 1
    end, function() LrSelection.selectNone() end)
end

function DevelopSession.activate(catalog, photo, state)
    if selectAndWait(catalog, photo, { photo }) then return true end
    if state.switchedSource then return false end
    state.switchedSource = true
    local ok = LrTasks.pcall(function() catalog:setActiveSources({ catalog.kAllPhotos }) end)
    if not ok then return false end
    return selectAndWait(catalog, photo, { photo })
end

local function captureView(catalog)
    local active = catalog:getTargetPhoto()
    return {
        module = LrApplicationView.getCurrentModuleName(),
        sources = catalog:getActiveSources(),
        active = active,
        selection = active and catalog:getTargetPhotos() or nil,
    }
end

local function restoreView(catalog, view, state)
    if view.module ~= LrApplicationView.getCurrentModuleName() then
        LrTasks.pcall(function() LrApplicationView.switchToModule(view.module) end)
    end
    if state.switchedSource and view.sources then
        LrTasks.pcall(function() catalog:setActiveSources(view.sources) end)
    end
    if view.active then
        LrTasks.pcall(function() selectAndWait(catalog, view.active, view.selection) end)
    else
        LrTasks.pcall(function() selectNoneAndWait(catalog) end)
    end
end

local function developModuleShowing()
    return LrApplicationView.getCurrentModuleName() == "develop"
end

function DevelopSession.openDevelop(isReady)
    if not developModuleShowing() then
        LrApplicationView.switchToModule("develop")
    end
    if not DevelopSession.waitFor(isReady or developModuleShowing, SELECT_TIMEOUT_SECONDS) then
        error("Develop module did not open")
    end
end

function DevelopSession.run(toolName, catalog, restore, body)
    if runningTool then
        error(runningTool .. " is already running; wait for it to finish, then call again")
    end
    runningTool = toolName

    local state = {}
    local view
    local ok, result = LrTasks.pcall(function()
        if restore then view = captureView(catalog) end
        return body(state)
    end)
    if view then
        local restored, restoreError = LrTasks.pcall(restoreView, catalog, view, state)
        if not restored then
            Log.warn(string.format("%s could not restore the Develop view: %s", toolName, tostring(restoreError)))
        end
    end
    runningTool = nil
    if not ok then error(result, 0) end
    return result
end

function DevelopSession.openPhoto(catalog, photo, state)
    DevelopSession.openDevelop()
    if not DevelopSession.activate(catalog, photo, state) then
        error("Could not open photo " .. tostring(photo.localIdentifier) .. " in Develop")
    end
    LrTasks.sleep(PHOTO_SETTLE_SECONDS)
    if catalog:getTargetPhoto() ~= photo then
        error("Another photo became active in Develop while opening photo "
            .. tostring(photo.localIdentifier))
    end
end

function DevelopSession.withPhoto(toolName, catalog, photo, fn)
    return DevelopSession.run(toolName, catalog, true, function(state)
        DevelopSession.openPhoto(catalog, photo, state)
        return fn()
    end)
end

function DevelopSession.requireMaskApi(toolName)
    for _, name in ipairs(MASK_API_FUNCTIONS) do
        if type(LrDevelopController[name]) ~= "function" then
            error(toolName .. " needs " .. MASK_API_MINIMUM_VERSION .. " or later")
        end
    end
end

return DevelopSession
