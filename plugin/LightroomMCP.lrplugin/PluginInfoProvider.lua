local LrTasks = import 'LrTasks'
local LrLogger = import 'LrLogger'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrSocket = import 'LrSocket'

local JSON = require 'JSON'
local HandlerSearch = require 'HandlerSearch'
local HandlerCollections = require 'HandlerCollections'
local HandlerMetadata = require 'HandlerMetadata'
local HandlerOrganization = require 'HandlerOrganization'
local HandlerImport = require 'HandlerImport'
local HandlerExport = require 'HandlerExport'

local logger = LrLogger('LightroomMCP')
logger:enable("logfile")

local REQUEST_PORT = 58763  -- plugin RECEIVES requests here (server in 'receive' mode)
local RESPONSE_PORT = 58764 -- plugin SENDS responses here (server in 'send' mode)

local pluginState = {
    running = false,
    requestSocket = nil,
    responseSocket = nil,
    sendConnected = false,
    receiveConnected = false,
    requestsProcessed = 0,
    lastEvent = nil,
    log = {},
}

local function addLog(msg)
    table.insert(pluginState.log, os.date("%H:%M:%S") .. " - " .. msg)
    if #pluginState.log > 100 then
        table.remove(pluginState.log, 1)
    end
    logger:info(msg)
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
}

local SEND_WAIT_SECONDS = 5

local function sendResponse(response)
    local waited = 0
    while not pluginState.sendConnected and waited < SEND_WAIT_SECONDS do
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

local function handleRequest(message)
    pluginState.lastEvent = os.date("%H:%M:%S")

    local parsedOk, request = pcall(function() return JSON:decode(message) end)
    if not parsedOk or type(request) ~= "table" then
        addLog("JSON decode failed: " .. tostring(message))
        return
    end

    local id = request.id
    local action = request.action
    local params = request.params or {}

    addLog("Request id=" .. tostring(id) .. " action=" .. tostring(action))

    local handler = DISPATCH[action]
    if not handler then
        sendResponse({ id = id, error = "Unknown action: " .. tostring(action) })
        return
    end

    local execOk, resultOrErr = LrTasks.pcall(function() return handler(params) end)
    if execOk then
        sendResponse({ id = id, result = resultOrErr })
    else
        addLog("Handler error: " .. tostring(resultOrErr))
        sendResponse({ id = id, error = tostring(resultOrErr) })
    end
end

local function startServer()
    if pluginState.running then
        addLog("Already running")
        return
    end

    pluginState.running = true
    addLog("Starting LrSocket servers")

    LrFunctionContext.postAsyncTaskWithContext("LightroomMCPServer", function(context)
        pluginState.requestSocket = LrSocket.bind {
            functionContext = context,
            plugin = _PLUGIN,
            port = REQUEST_PORT,
            mode = "receive",
            onConnected = function()
                pluginState.receiveConnected = true
                addLog("REQUEST socket connected")
            end,
            onMessage = function(_, message)
                LrTasks.startAsyncTask(function()
                    handleRequest(message)
                end)
            end,
            onClosed = function()
                pluginState.receiveConnected = false
                pluginState.requestNeedsReconnect = true
            end,
            onError = function(_, err)
                local errStr = tostring(err)
                if errStr == "timeout" then
                    -- listen socket timeout. Only reconnect if no active client.
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
        addLog("REQUEST bound on " .. REQUEST_PORT)

        pluginState.responseSocket = LrSocket.bind {
            functionContext = context,
            plugin = _PLUGIN,
            port = RESPONSE_PORT,
            mode = "send",
            onConnected = function()
                pluginState.sendConnected = true
                addLog("RESPONSE socket connected")
            end,
            onClosed = function()
                pluginState.sendConnected = false
                pluginState.responseNeedsReconnect = true
            end,
            onError = function(_, err)
                local errStr = tostring(err)
                if errStr == "timeout" then
                    if not pluginState.sendConnected then
                        pluginState.responseNeedsReconnect = true
                    end
                else
                    pluginState.sendConnected = false
                    pluginState.responseNeedsReconnect = true
                    addLog("RESPONSE socket error: " .. errStr)
                end
            end,
        }
        addLog("RESPONSE bound on " .. RESPONSE_PORT)

        while pluginState.running do
            if pluginState.requestNeedsReconnect and pluginState.requestSocket then
                pluginState.requestNeedsReconnect = false
                pluginState.requestSocket:reconnect()
            end
            if pluginState.responseNeedsReconnect and pluginState.responseSocket then
                pluginState.responseNeedsReconnect = false
                pluginState.responseSocket:reconnect()
            end
            LrTasks.sleep(0.2)
        end

        addLog("Server loop exiting")
        pluginState.requestSocket = nil
        pluginState.responseSocket = nil
        pluginState.sendConnected = false
        pluginState.receiveConnected = false
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

addLog("PluginInfoProvider loaded")

local PluginInfoProvider = {}

function PluginInfoProvider.sectionsForTopOfDialog(f, propertyTable)
    local statusText = "=== Lightroom MCP Status ===\n\n"
    statusText = statusText .. "Running: " .. tostring(pluginState.running) .. "\n"
    statusText = statusText .. "Request socket connected: " .. tostring(pluginState.receiveConnected) .. "\n"
    statusText = statusText .. "Response socket connected: " .. tostring(pluginState.sendConnected) .. "\n"
    statusText = statusText .. "Last event: " .. (pluginState.lastEvent or "Never") .. "\n"
    statusText = statusText .. "Requests processed: " .. pluginState.requestsProcessed .. "\n"
    statusText = statusText .. "Request port: " .. REQUEST_PORT .. " (mode=receive)\n"
    statusText = statusText .. "Response port: " .. RESPONSE_PORT .. " (mode=send)\n"
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
