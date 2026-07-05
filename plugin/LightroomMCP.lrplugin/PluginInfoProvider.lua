local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrSocket = import 'LrSocket'
local LrPrefs = import 'LrPrefs'
local LrView = import 'LrView'
local LrUUID = import 'LrUUID'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

local JSON = require 'JSON'
local HandlerSearch = require 'HandlerSearch'
local HandlerCollections = require 'HandlerCollections'
local HandlerMetadata = require 'HandlerMetadata'
local HandlerOrganization = require 'HandlerOrganization'
local HandlerImport = require 'HandlerImport'
local HandlerExport = require 'HandlerExport'
local HandlerSelection = require 'HandlerSelection'
local HandlerDevelop = require 'HandlerDevelop'
local Log = require 'Log'

local DEFAULT_REQUEST_PORT = 58763
local DEFAULT_RESPONSE_PORT = 58764

-- LrSocket fires these on its accept-loop when no client is attached yet.
-- Both are benign listen-side states, not real failures.
local function isNoClientError(errStr)
    if errStr == "timeout" then return true end
    if errStr:find("failed to open", 1, true) then return true end
    return false
end

local function validPort(n)
    return type(n) == "number" and n == math.floor(n) and n >= 1 and n <= 65535
end

local function readPortPrefs()
    local prefs = LrPrefs.prefsForPlugin()
    local req = tonumber(prefs.requestPort)
    local res = tonumber(prefs.responsePort)
    if not validPort(req) then req = DEFAULT_REQUEST_PORT end
    if not validPort(res) then res = DEFAULT_RESPONSE_PORT end
    return req, res
end

-- State on _G so it survives across re-execution of this module body
-- within the same Lua state. This body runs BOTH when PluginInit requires
-- it AND every time Lightroom loads it as the InfoProvider to render the
-- Plug-in Manager panel. A render must NOT disturb a running server, so we
-- only ever CREATE state here (when absent) â€” never tear it down. Teardown
-- of a stale prior instance on Reload Plug-in is handled by resetForReload,
-- which PluginInit calls (PluginInit's LrInitPlugin runs on load/reload but
-- NOT on a plain panel render). Tearing down from this body â€” as earlier
-- versions did when running == true â€” killed the live server every time the
-- Plug-in Manager was opened (issues #121, #137).
if not _G.LightroomMCP_State then
    _G.LightroomMCP_State = {
        running = false,
        requestSocket = nil,
        responseSocket = nil,
        sendConnected = false,
        receiveConnected = false,
        requestsProcessed = 0,
        lastEvent = nil,
        log = {},
        token = nil,
        lastRequestTime = nil,
        lastConnectedTime = nil,
        needsFullRestart = false,
        freshRestart = false,
    }
end

local pluginState = _G.LightroomMCP_State

local function tokenDir()
    return LrPathUtils.child(LrPathUtils.getStandardFilePath("home"), ".config")
end

local function tokenFilePath()
    return LrPathUtils.child(LrPathUtils.child(tokenDir(), "lightroom-mcp"), "token")
end

local function addLog(msg)
    table.insert(pluginState.log, os.date("%H:%M:%S") .. " - " .. msg)
    if #pluginState.log > 100 then
        table.remove(pluginState.log, 1)
    end
    Log.info(msg)
end

local function generateToken()
    -- Two UUIDs (32 hex chars each after stripping dashes) â†’ 256 bits of entropy.
    local u1 = LrUUID.generateUUID():gsub("-", "")
    local u2 = LrUUID.generateUUID():gsub("-", "")
    return (u1 .. u2):lower()
end

local function writeTokenFile(token)
    local dir = LrPathUtils.child(tokenDir(), "lightroom-mcp")
    LrFileUtils.createAllDirectories(dir)
    local path = tokenFilePath()
    local fh, openErr = io.open(path, "w")
    if not fh then
        addLog("Token write failed: " .. tostring(openErr))
        return false
    end
    fh:write(token)
    fh:close()
    -- Lightroom's Lua sandbox has no os.execute, so chmod is impossible here.
    -- On macOS single-user installs ~/.config/ inherits home-dir privacy (700).
    -- On Linux/multi-user systems run: chmod 700 ~/.config/lightroom-mcp
    -- See README "Security" section. Token gates localhost only; threat is
    -- local-user access on the same machine.
    return true
end

local DISPATCH = {
    search_photos = HandlerSearch.searchPhotos,
    list_collections = HandlerCollections.listCollections,
    create_collection = HandlerCollections.createCollection,
    add_to_collection = HandlerCollections.addToCollection,
    get_photo_metadata = HandlerMetadata.getPhotoMetadata,
    set_keywords = HandlerOrganization.setKeywords,
    set_rating = HandlerOrganization.setRating,
    import_photos = HandlerImport.importPhotos,
    export_photos = HandlerExport.exportPhotos,
    get_selected_photos = HandlerSelection.getSelectedPhotos,
    list_develop_presets = HandlerDevelop.listDevelopPresets,
    apply_develop_preset = HandlerDevelop.applyDevelopPreset,
    copy_develop_settings = HandlerDevelop.copyDevelopSettings,
    set_develop_settings = HandlerDevelop.setDevelopSettings,
}

-- Generous wait so the very first response after handshake doesn't get
-- dropped while LrSocket is still settling sendConnected on the response
-- side. Must stay below the server's dispatcher timeout (30s) so a real
-- send-side outage still surfaces as a server-side timeout, not silent
-- success.
local SEND_WAIT_SECONDS = 25
-- After this many seconds of waiting for sendConnected, request a fresh
-- response-side rebind. Recovers from states where the response listener
-- ended up bound-but-clientless without responseNeedsRebind being set â€”
-- observed on Windows in issue #110, where the post-rebind onConnected
-- fires but sendConnected is later false by the time sendResponse runs
-- and no event sets the rebind flag again.
local SEND_REBIND_TRIGGER_SECONDS = 5
-- After this many idle seconds while receiveConnected is true, assume the
-- connection is stale (Windows onClosed unreliability, issue #134) and
-- force a requestSocket:reconnect() so the new MCP server can be accepted.
local STALE_RECONNECT_SECONDS = 300

local function sendResponse(response)
    local waited = 0
    local selfHealRequested = false
    while not pluginState.sendConnected and waited < SEND_WAIT_SECONDS do
        if not selfHealRequested and waited >= SEND_REBIND_TRIGGER_SECONDS then
            addLog("sendResponse stalled " .. SEND_REBIND_TRIGGER_SECONDS .. "s, requesting rebind id=" .. tostring(response.id))
            pluginState.responseNeedsRebind = true
            selfHealRequested = true
        end
        LrTasks.sleep(0.1)
        waited = waited + 0.1
    end
    if not pluginState.responseSocket or not pluginState.sendConnected then
        addLog("Drop response (send socket disconnected after " .. SEND_WAIT_SECONDS .. "s) id=" .. tostring(response.id))
        return
    end
    local ok, payload = pcall(function() return JSON:encode(response) end)
    if not ok then
        addLog("JSON encode failed: " .. tostring(payload))
        return
    end
    pluginState.responseSocket:send(payload .. "\n")
    pluginState.requestsProcessed = pluginState.requestsProcessed + 1
end

local function dispatchAction(request)
    local id = request.id
    local action = request.action
    local params = request.params or {}

    addLog("Request id=" .. tostring(id) .. " action=" .. tostring(action))

    local handler = DISPATCH[action]
    if not handler then
        sendResponse({ id = id, error = "Unknown action: " .. tostring(action) })
        return
    end

    -- xpcall, debug.traceback, and os.getenv aren't reliably exposed by
    -- Lightroom's Lua sandbox: using them in the dispatcher's error path
    -- turns a handler error into a silent nil-call that never reaches the
    -- client. Stick to LrTasks.pcall.
    local execOk, resultOrErr = LrTasks.pcall(function()
        return handler(params)
    end)
    if execOk then
        sendResponse({ id = id, result = resultOrErr })
    else
        addLog("Handler " .. action .. " error: " .. tostring(resultOrErr))
        sendResponse({ id = id, error = tostring(resultOrErr) })
    end
end

-- Runs SYNCHRONOUSLY in onMessage. Every request must carry the current
-- token in `hello`; we authenticate per-message so connection-state
-- races (reload, dual-instance, reconnect) can't desync auth from the
-- live token.
local function consumeMessage(message)
    pluginState.lastEvent = os.date("%H:%M:%S")
    pluginState.lastRequestTime = os.time()  -- track for stale connection detection

    local parsedOk, request = pcall(function() return JSON:decode(message) end)
    if not parsedOk or type(request) ~= "table" then
        addLog("JSON decode failed: " .. tostring(message))
        return nil
    end

    if not pluginState.token or request.hello ~= pluginState.token then
        -- Drop silently. We CANNOT call sendResponse here: onMessage runs
        -- in a non-yielding context and sendResponse uses LrTasks.sleep.
        -- Server will time out, which is correct behaviour for auth fail.
        addLog("Auth failed (token mismatch) id=" .. tostring(request.id))
        return nil
    end

    return request
end

local function startServer()
    if pluginState.running then
        addLog("Already running")
        return
    end
    -- Set running immediately after the guard so check-and-set is atomic.
    -- generateToken/writeTokenFile/readPortPrefs below can yield the
    -- cooperative LrTasks scheduler (token file I/O), and a second caller
    -- waking in that window would otherwise pass the guard too and bind a
    -- second pair of LrSocket listeners on the same ports.
    pluginState.running = true

    pluginState.token = generateToken()
    if writeTokenFile(pluginState.token) then
        addLog("Token written to " .. tokenFilePath())
    end

    local requestPort, responsePort = readPortPrefs()
    pluginState.requestPort = requestPort
    pluginState.responsePort = responsePort

    -- Tag this invocation. resetForReload reuses the same _G state table in
    -- place, so a prior instance's async context-cleanup handler (registered
    -- below) and this fresh start share one table. If that old cleanup fires
    -- AFTER we rebind here it would close the new sockets and wipe the new
    -- token, leaving a dead-but-running server (issues #121, #137). The
    -- handler captures this id and skips teardown once superseded (mirrors
    -- responseGen). Bumped in the synchronous prologue so the id is live
    -- before the old cleanup can interleave with the new binds.
    pluginState.instanceId = (pluginState.instanceId or 0) + 1
    local instanceId = pluginState.instanceId
    addLog("Starting LrSocket servers")

    LrFunctionContext.postAsyncTaskWithContext("LightroomMCPServer", function(context)
        context:addCleanupHandler(function()
            if pluginState.instanceId ~= instanceId then
                -- A newer startServer superseded this instance; its sockets
                -- and token now own the shared state table. Tearing them down
                -- here would kill the live server, so leave them be.
                addLog("Stale cleanup skipped (instance " .. instanceId .. " superseded)")
                return
            end
            addLog("Server task context cleanup")
            if pluginState.requestSocket then
                pcall(function() pluginState.requestSocket:close() end)
            end
            if pluginState.responseSocket then
                pcall(function() pluginState.responseSocket:close() end)
            end
            pluginState.requestSocket = nil
            pluginState.responseSocket = nil
            pluginState.sendConnected = false
            pluginState.receiveConnected = false
            pluginState.token = nil
        end)

        local function bindRequest()
            return LrSocket.bind {
                functionContext = context,
                plugin = _PLUGIN,
                port = requestPort,
                mode = "receive",
                onConnected = function()
                    pluginState.receiveConnected = true
                    pluginState.lastConnectedTime = os.time()
                    if pluginState.freshRestart then
                        -- Sockets were fully closed and rebound by the stale-detection
                        -- restart (issue #134 Windows workaround). The response listener
                        -- already accepted a fresh MCP client; no stale send-side
                        -- connection to flush. Skipping the rebind prevents the
                        -- request->response->request cycling that delays the first
                        -- post-restart response past the 30 s MCP timeout.
                        pluginState.freshRestart = false
                        addLog("REQUEST socket connected (post-restart)")
                    else
                        -- New request client on a live server = new MCP session. Force
                        -- a response-side rebind: LrSocket send-mode does not reliably
                        -- notice client disconnect on Windows, so sendConnected can stay
                        -- true pointing at a dead socket and :send() writes to the void.
                        pluginState.sendConnected = false
                        pluginState.responseNeedsRebind = true
                        addLog("REQUEST socket connected")
                    end
                end,
                onMessage = function(_, message)
                    local request = consumeMessage(message)
                    if request then
                        LrTasks.startAsyncTask(function()
                            dispatchAction(request)
                        end)
                    end
                end,
                onClosed = function()
                    pluginState.receiveConnected = false
                    pluginState.requestNeedsReconnect = true
                    addLog("REQUEST socket closed (client disconnected)")
                end,
                onError = function(_, err)
                    local errStr = tostring(err)
                    if isNoClientError(errStr) then
                        if not pluginState.receiveConnected then
                            pluginState.requestNeedsReconnect = true
                        end
                    else
                        pluginState.receiveConnected = false
                        pluginState.requestNeedsReconnect = true
                        addLog("REQUEST socket error: " .. errStr)
                    end
                end,
            }
        end

        -- Each rebind bumps a generation. Old-listener callbacks compare
        -- their captured gen to the live one and ignore themselves if
        -- stale. Without this, an onError/onClosed from the just-closed
        -- listener can flag rebind AGAIN immediately after we just
        -- finished rebinding, looping us out of the new client.
        pluginState.responseGen = 0
        -- Clear loop-control flags so a reused state table (in-place
        -- resetForReload, or a panel Stop->Start) doesn't enter the monitor
        -- loop with a stale reconnect/rebind pending and churn the sockets we
        -- just bound on the first tick.
        pluginState.requestNeedsReconnect = false
        pluginState.responseNeedsRebind = false
        pluginState.responseNeedsReconnect = false

        -- bindResponse takes myGen explicitly so callers can pre-bump the
        -- generation BEFORE calling :close() on the prior listener. On
        -- platforms where LrSocket invokes onClosed synchronously during
        -- close (suspected on Windows, per issue #110), a stale callback
        -- would otherwise see isLive()==true and re-set responseNeedsRebind
        -- after we just cleared it.
        local function bindResponse(myGen)
            local function isLive() return pluginState.responseGen == myGen end
            return LrSocket.bind {
                functionContext = context,
                plugin = _PLUGIN,
                port = responsePort,
                mode = "send",
                onConnected = function()
                    if not isLive() then return end
                    pluginState.sendConnected = true
                    addLog("RESPONSE socket connected")
                end,
                onClosed = function()
                    if not isLive() then return end
                    pluginState.sendConnected = false
                    pluginState.responseNeedsRebind = true
                    addLog("RESPONSE socket closed (gen=" .. myGen .. ")")
                end,
                onError = function(_, err)
                    if not isLive() then return end
                    local errStr = tostring(err)
                    if isNoClientError(errStr) then
                        if not pluginState.sendConnected then
                            pluginState.responseNeedsReconnect = true
                        end
                    else
                        pluginState.sendConnected = false
                        pluginState.responseNeedsRebind = true
                        addLog("RESPONSE socket error: " .. errStr)
                    end
                end,
            }
        end

        -- Bump first, then bind, so the initial listener owns gen=1 (any
        -- pre-existing stale callbacks from a Reload Plug-in cycle were
        -- bound against gen=0 and stay ignored).
        pluginState.responseGen = pluginState.responseGen + 1
        pluginState.requestSocket = bindRequest()
        addLog("REQUEST bound on " .. requestPort)
        pluginState.responseSocket = bindResponse(pluginState.responseGen)
        addLog("RESPONSE bound on " .. responsePort .. " gen=" .. pluginState.responseGen)

        while pluginState.running do
            if pluginState.requestNeedsReconnect and pluginState.requestSocket then
                pluginState.requestNeedsReconnect = false
                pluginState.requestSocket:reconnect()
            end
            -- Response socket has two recovery paths:
            -- - rebind: full close+rebind for true client disconnect
            -- - reconnect: cheap reconnect for listen-side timeouts
            if pluginState.responseNeedsRebind then
                -- Pre-bump gen BEFORE close so any synchronous onClosed
                -- callback fired during close() sees isLive()==false and
                -- ignores itself. Without this, the OLD listener's close
                -- callback re-sets responseNeedsRebind after we clear it
                -- below, looping the rebind on the next tick. Issue #110
                -- suspected Windows trigger.
                pluginState.responseGen = pluginState.responseGen + 1
                local newGen = pluginState.responseGen
                if pluginState.responseSocket then
                    pcall(function() pluginState.responseSocket:close() end)
                end
                pluginState.sendConnected = false
                -- Brief yield so any kernel cleanup of the just-closed
                -- listener completes before we try to bind the same port
                -- again. The actual server-side reconnect takes ~1s, so
                -- 100ms here doesn't meaningfully delay recovery.
                LrTasks.sleep(0.1)
                pluginState.responseSocket = bindResponse(newGen)
                pluginState.responseNeedsRebind = false
                pluginState.responseNeedsReconnect = false
                addLog("RESPONSE rebound on " .. responsePort .. " gen=" .. newGen)
            elseif pluginState.responseNeedsReconnect and pluginState.responseSocket then
                pluginState.responseNeedsReconnect = false
                pluginState.responseSocket:reconnect()
            end
            -- Full restart requested by stale detection
            if pluginState.needsFullRestart then
                pluginState.needsFullRestart = false
                LrTasks.startAsyncTask(function()
                    addLog("Restarting server (stale connection recovery)")
                    -- stopServer() is declared after startServer() in this file
                    -- and is not an upvalue here; inline its effect directly.
                    pluginState.running = false
                    LrTasks.sleep(0.5)
                    startServer()
                end)
            end
            -- Stale connection detection: Windows LrSocket does not reliably
            -- fire onClosed when the remote MCP server process exits (issue #134).
            -- If receiveConnected is true but no message has arrived for
            -- STALE_RECONNECT_SECONDS, force a reconnect so the already-connected
            -- MCP server can be properly accepted by a fresh listener.
            if pluginState.receiveConnected then
                local ref = pluginState.lastRequestTime or pluginState.lastConnectedTime
                if ref then
                    local idle = os.time() - ref
                    if idle > STALE_RECONNECT_SECONDS then
                        addLog("Stale connection: " .. idle .. "s idle, scheduling restart")
                        pluginState.lastRequestTime = nil
                        pluginState.lastConnectedTime = nil
                        pluginState.needsFullRestart = true
                        pluginState.freshRestart = true
                    end
                end
            end
            LrTasks.sleep(0.2)
        end

        addLog("Server loop exiting")
        -- Socket cleanup runs in context:addCleanupHandler above.
    end)
end

local function stopServer()
    if not pluginState.running then
        addLog("Not running")
        return
    end
    addLog("Stopping LrSocket servers")
    pluginState.running = false
end

-- Called by PluginInit on plugin load/reload (never on a Plug-in Manager
-- render). Reload re-runs PluginInit while a prior instance's state may
-- still live on _G in the same Lua state, with `running` stale-true and
-- its task context already cancelled by Lightroom. Clear the flag so the
-- subsequent startServer() isn't blocked by its "Already running" guard,
-- and signal any surviving monitor loop to exit. Reset IN PLACE (not a new
-- table) so this module's pluginState and the old loop's closure keep
-- pointing at the same table â€” flipping running here is what stops it.
local function resetForReload()
    if not pluginState.running then return end
    addLog("Reload detected - resetting previous server instance")
    pluginState.running = false
    if pluginState.requestSocket then
        pcall(function() pluginState.requestSocket:close() end)
    end
    if pluginState.responseSocket then
        pcall(function() pluginState.responseSocket:close() end)
    end
    pluginState.requestSocket = nil
    pluginState.responseSocket = nil
    pluginState.sendConnected = false
    pluginState.receiveConnected = false
    pluginState.token = nil
    -- Return the rest of the transient runtime state to fresh-state defaults
    -- so the Plug-in Manager reports honest status after a reload (no
    -- carried-over lastEvent / counters / ports) and the next startServer
    -- can't inherit a stale reconnect/rebind request. instanceId is
    -- deliberately NOT reset -- it must keep advancing so a superseded
    -- instance's cleanup handler stays a no-op (see startServer).
    pluginState.requestNeedsReconnect = false
    pluginState.responseNeedsRebind = false
    pluginState.responseNeedsReconnect = false
    pluginState.lastEvent = nil
    pluginState.requestsProcessed = 0
    pluginState.requestPort = nil
    pluginState.responsePort = nil
    pluginState.lastRequestTime = nil
    pluginState.lastConnectedTime = nil
    pluginState.needsFullRestart = false
    pluginState.freshRestart = false
end

addLog("PluginInfoProvider loaded")

local PluginInfoProvider = {
    startServer = startServer,
    stopServer = stopServer,
    resetForReload = resetForReload,
}

function PluginInfoProvider.sectionsForTopOfDialog(f, propertyTable)
    local prefs = LrPrefs.prefsForPlugin()
    if prefs.autoStartServer == nil then
        prefs.autoStartServer = true
    end
    propertyTable.autoStartServer = prefs.autoStartServer
    propertyTable:addObserver('autoStartServer', function(_, _, value)
        prefs.autoStartServer = value
    end)

    local cfgRequestPort, cfgResponsePort = readPortPrefs()
    propertyTable.requestPort = cfgRequestPort
    propertyTable.responsePort = cfgResponsePort
    propertyTable:addObserver('requestPort', function(_, _, value)
        local n = tonumber(value)
        if validPort(n) then prefs.requestPort = n end
    end)
    propertyTable:addObserver('responsePort', function(_, _, value)
        local n = tonumber(value)
        if validPort(n) then prefs.responsePort = n end
    end)

    local activeRequest = pluginState.requestPort or cfgRequestPort
    local activeResponse = pluginState.responsePort or cfgResponsePort

    local statusText = "=== Lightroom MCP Status ===\n\n"
    statusText = statusText .. "Running: " .. tostring(pluginState.running) .. "\n"
    statusText = statusText .. "Request socket connected: " .. tostring(pluginState.receiveConnected) .. "\n"
    statusText = statusText .. "Response socket connected: " .. tostring(pluginState.sendConnected) .. "\n"
    statusText = statusText .. "Last event: " .. (pluginState.lastEvent or "Never") .. "\n"
    statusText = statusText .. "Requests processed: " .. pluginState.requestsProcessed .. "\n"
    statusText = statusText .. "Request port: " .. activeRequest .. " (mode=receive)\n"
    statusText = statusText .. "Response port: " .. activeResponse .. " (mode=send)\n"
    statusText = statusText .. "Log file: " .. (Log.filePath() or "(unavailable)") .. "\n"
    statusText = statusText .. "\nRecent logs:\n"
    local startIdx = math.max(1, #pluginState.log - 15)
    for i = startIdx, #pluginState.log do
        statusText = statusText .. "  " .. pluginState.log[i] .. "\n"
    end

    return {
        {
            title = "Lightroom MCP Server Status",
            f:static_text {
                title = statusText,
                fill_horizontal = 1,
                width_in_chars = 70,
                height_in_lines = 25,
            },
            f:checkbox {
                title = "Auto-start server on Lightroom launch",
                value = LrView.bind('autoStartServer'),
            },
            f:row {
                f:static_text { title = "Request port:", width = 110 },
                f:edit_field {
                    value = LrView.bind('requestPort'),
                    width_in_chars = 7,
                    precision = 0,
                    min = 1,
                    max = 65535,
                },
                f:static_text { title = "(default 58763)" },
            },
            f:row {
                f:static_text { title = "Response port:", width = 110 },
                f:edit_field {
                    value = LrView.bind('responsePort'),
                    width_in_chars = 7,
                    precision = 0,
                    min = 1,
                    max = 65535,
                },
                f:static_text { title = "(default 58764)" },
            },
            f:static_text {
                title = "Port changes apply on next Start. Server env vars must match: LIGHTROOM_MCP_REQUEST_PORT / LIGHTROOM_MCP_RESPONSE_PORT.",
                fill_horizontal = 1,
                width_in_chars = 70,
                height_in_lines = 2,
            },
            f:row {
                f:push_button {
                    title = pluginState.running and "Stop Server" or "Start Server",
                    action = function()
                        if pluginState.running then
                            stopServer()
                        else
                            startServer()
                        end
                    end,
                },
                f:push_button {
                    title = "Show Status",
                    action = function()
                        local lines = {
                            "Running: " .. tostring(pluginState.running),
                            "Request socket connected: " .. tostring(pluginState.receiveConnected),
                            "Response socket connected: " .. tostring(pluginState.sendConnected),
                            "Last event: " .. (pluginState.lastEvent or "Never"),
                            "Requests processed: " .. pluginState.requestsProcessed,
                            "Log file: " .. (Log.filePath() or "(unavailable)"),
                            "",
                            "Recent logs:",
                        }
                        local logStart = math.max(1, #pluginState.log - 30)
                        for i = logStart, #pluginState.log do
                            table.insert(lines, "  " .. pluginState.log[i])
                        end
                        LrDialogs.message("Lightroom MCP Status", table.concat(lines, "\n"), "info")
                    end,
                },
            },
        },
    }
end

return PluginInfoProvider


