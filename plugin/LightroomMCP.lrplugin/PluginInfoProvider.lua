local LrView = import 'LrView'
local LrTasks = import 'LrTasks'
local LrHttp = import 'LrHttp'
local LrLogger = import 'LrLogger'
local LrDialogs = import 'LrDialogs'
local LrApplication = import 'LrApplication'
local LrFunctionContext = import 'LrFunctionContext'

local JSON = require 'JSON'

local logger = LrLogger('LightroomMCP')
logger:enable("logfile")

-- Plugin state
local pluginState = {
    initialized = false,
    serverRunning = false,
    polling = false,
    error = nil,
    lastPoll = nil,
    requestsProcessed = 0,
    startupLog = {}
}

local MCP_SERVER_URL = "http://localhost:8765"
local POLL_INTERVAL = 3 -- seconds

local function addLog(msg)
    table.insert(pluginState.startupLog, os.date("%H:%M:%S") .. " - " .. msg)
    logger:info(msg)
end

addLog("PluginInfoProvider loaded")

-- Execute Lightroom action based on request
local function executeAction(action, params, catalog)
    addLog("Executing action: " .. action)

    if action == "list_collections" then
        addLog("Getting child collections...")
        local collections = catalog:getChildCollections()
        addLog("Found " .. tostring(#collections) .. " collections")

        local result = {}
        for _, collection in ipairs(collections) do
            table.insert(result, {
                name = collection:getName(),
                type = "collection",
                photoCount = #collection:getPhotos()
            })
        end
        addLog("Returning result with " .. #result .. " collections")
        return { collections = result }

    elseif action == "search_photos" then
        local allPhotos = catalog:getAllPhotos()
        local results = {}

        for _, photo in ipairs(allPhotos) do
            local match = true

            -- Filter by filename
            if params.filename and not string.find(photo:getFormattedMetadata("fileName"), params.filename, 1, true) then
                match = false
            end

            -- Filter by rating
            if params.rating and photo:getRawMetadata("rating") ~= params.rating then
                match = false
            end

            if match then
                table.insert(results, {
                    id = photo:getRawMetadata("uuid"),
                    path = photo:getRawMetadata("path"),
                    filename = photo:getFormattedMetadata("fileName"),
                    rating = photo:getRawMetadata("rating"),
                    date = photo:getFormattedMetadata("captureDate")
                })

                -- Limit results
                if #results >= 100 then
                    break
                end
            end
        end

        return { photos = results, count = #results }

    else
        return { error = "Unknown action: " .. action }
    end
end

-- Poll MCP server for requests
local function pollServer()
    local response, headers = LrHttp.get(MCP_SERVER_URL .. "/poll-request", {
        { field = "Accept", value = "application/json" }
    })

    pluginState.lastPoll = os.date("%H:%M:%S")

    if not response or response == "" then
        addLog("Poll returned empty response")
        return
    end

    addLog("Poll response: " .. response)

    -- Parse JSON response
    local parseSuccess, data = pcall(function()
        return JSON:decode(response)
    end)

    if not parseSuccess then
        addLog("JSON parse error: " .. tostring(data))
        return
    end

    if data.action == "none" then
        -- No pending requests (normal)
        return
    end

    addLog("Received request: " .. data.action .. " (id: " .. data.id .. ")")

    -- Execute the action
    local result, error

    addLog("Executing action without catalog lock...")

    -- For now, return mock data to test the flow
    -- TODO: Implement proper catalog access
    if data.action == "list_collections" then
        result = {
            collections = {
                { name = "Test Collection 1", type = "collection", photoCount = 10 },
                { name = "Test Collection 2", type = "collection", photoCount = 25 }
            }
        }
        addLog("Returning mock data")
    else
        result = { message = "Action " .. data.action .. " not yet implemented" }
    end

    addLog("Execution complete")

    -- Send response back to MCP server
    addLog("About to encode JSON response...")
    local encodeSuccess, responseData = pcall(function()
        return JSON:encode({
            id = data.id,
            result = result,
            error = error
        })
    end)

    if not encodeSuccess then
        addLog("JSON encode failed: " .. tostring(responseData))
        return
    end

    addLog("JSON encoded successfully")
    addLog("Sending response to server...")
    addLog("URL: " .. MCP_SERVER_URL .. "/submit-response")
    addLog("Payload: " .. responseData)

    local submitResponse, submitHeaders = LrHttp.post(MCP_SERVER_URL .. "/submit-response", responseData, {
        { field = "Content-Type", value = "application/json" }
    })

    addLog("HTTP POST returned: " .. tostring(submitResponse))

    if submitResponse then
        addLog("Response submitted successfully")
        pluginState.requestsProcessed = pluginState.requestsProcessed + 1
    else
        addLog("Failed to submit response - empty response")
    end
end

-- Start polling loop
local function startPolling()
    if pluginState.polling then
        addLog("Already polling")
        return
    end

    addLog("Starting polling loop")
    pluginState.polling = true
    pluginState.serverRunning = true
    pluginState.initialized = true

    LrFunctionContext.postAsyncTaskWithContext("PollingLoop", function(context)
        while pluginState.polling do
            pollServer()
            LrTasks.sleep(POLL_INTERVAL)
        end

        addLog("Polling stopped")
    end)
end

local function stopPolling()
    if not pluginState.polling then
        addLog("Not currently polling")
        return
    end

    addLog("Stopping polling")
    pluginState.polling = false
    pluginState.serverRunning = false
end

local PluginInfoProvider = {}

function PluginInfoProvider.sectionsForTopOfDialog(f, propertyTable)
    local statusText = "=== Lightroom MCP Status ===\n\n"
    statusText = statusText .. "Polling: " .. tostring(pluginState.polling) .. "\n"
    statusText = statusText .. "Last Poll: " .. (pluginState.lastPoll or "Never") .. "\n"
    statusText = statusText .. "Requests Processed: " .. pluginState.requestsProcessed .. "\n"
    statusText = statusText .. "MCP Server: " .. MCP_SERVER_URL .. "\n"

    if pluginState.error then
        statusText = statusText .. "\nError: " .. pluginState.error .. "\n"
    end

    statusText = statusText .. "\nRecent Logs:\n"
    local startIdx = math.max(1, #pluginState.startupLog - 10)
    for i = startIdx, #pluginState.startupLog do
        statusText = statusText .. "  " .. pluginState.startupLog[i] .. "\n"
    end

    return {
        {
            title = "Lightroom MCP Server Status",
            f:static_text {
                title = statusText,
                fill_horizontal = 1,
                width_in_chars = 60,
                height_in_lines = 20,
            },
            f:row {
                f:push_button {
                    title = pluginState.polling and "Stop Polling" or "Start Polling",
                    action = function()
                        if pluginState.polling then
                            stopPolling()
                        else
                            startPolling()
                        end
                    end,
                },
                f:push_button {
                    title = "Test Connection",
                    action = function()
                        LrTasks.startAsyncTask(function()
                            local response, headers = LrHttp.get(MCP_SERVER_URL .. "/health")

                            if response then
                                LrDialogs.message("Connection Test", "Successfully connected to MCP server!\n\n" .. response, "info")
                            else
                                LrDialogs.message("Connection Test", "Failed to connect to MCP server at " .. MCP_SERVER_URL, "critical")
                            end
                        end)
                    end,
                },
                f:push_button {
                    title = "Refresh Status",
                    action = function()
                        addLog("Refresh button clicked")

                        -- Show full status
                        local allLogs = ""
                        for _, log in ipairs(pluginState.startupLog) do
                            allLogs = allLogs .. log .. "\n"
                        end

                        LrDialogs.message("Full Status",
                            "Polling: " .. tostring(pluginState.polling) .. "\n" ..
                            "Last Poll: " .. (pluginState.lastPoll or "Never") .. "\n" ..
                            "Requests Processed: " .. pluginState.requestsProcessed .. "\n\n" ..
                            "All logs:\n" .. allLogs,
                            "info")
                    end,
                },
            },
        },
    }
end

return PluginInfoProvider
