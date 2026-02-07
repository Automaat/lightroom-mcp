local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'
local LrLogger = import 'LrLogger'

local logger = LrLogger('LightroomMCP')
logger:enable("logfile")

local HttpServer = require 'HttpServer'

-- Plugin status tracking
local pluginStatus = {
    initialized = false,
    serverRunning = false,
    error = nil,
    lastStartAttempt = nil,
    startupLog = {}
}

local function addLog(message)
    table.insert(pluginStatus.startupLog, os.date("%H:%M:%S") .. " - " .. message)
    logger:info(message)
end

-- Initialize plugin
local function initPlugin()
    addLog("Plugin initialization started")
    pluginStatus.lastStartAttempt = os.date("%Y-%m-%d %H:%M:%S")

    -- Start server in async task
    local success, err = LrTasks.pcall(function()
        addLog("Starting async task")

        LrTasks.startAsyncTask(function()
            addLog("Async task running")

            LrFunctionContext.callWithContext("HttpServer", function(context)
                addLog("Function context created: " .. tostring(context))

                HttpServer.start(context)
                addLog("HTTP server start() called")

                pluginStatus.serverRunning = true
                pluginStatus.initialized = true
                addLog("HTTP server started successfully")
            end)
        end)

        addLog("Async task launched")
    end)

    if not success then
        local errorMsg = "Failed to start HTTP server: " .. tostring(err)
        addLog("ERROR: " .. errorMsg)
        pluginStatus.error = errorMsg
        logger:error(errorMsg)
        LrDialogs.message("Lightroom MCP Error", errorMsg, "critical")
    end
end

-- Shutdown plugin
local function shutdownPlugin()
    addLog("Shutting down Lightroom MCP plugin...")
    HttpServer.stop()
    pluginStatus.serverRunning = false
end

-- Get diagnostic info
local function getDiagnostics()
    local diagnostics = {
        "=== Lightroom MCP Diagnostics ===",
        "",
        "Status:",
        "  Initialized: " .. tostring(pluginStatus.initialized),
        "  Server Running: " .. tostring(pluginStatus.serverRunning),
        "  Last Start Attempt: " .. (pluginStatus.lastStartAttempt or "Never"),
        "",
    }

    if pluginStatus.error then
        table.insert(diagnostics, "Error: " .. pluginStatus.error)
        table.insert(diagnostics, "")
    end

    table.insert(diagnostics, "Startup Log:")
    for _, log in ipairs(pluginStatus.startupLog) do
        table.insert(diagnostics, "  " .. log)
    end

    return table.concat(diagnostics, "\n")
end

initPlugin()

return {
    shutdown = shutdownPlugin,
    getDiagnostics = getDiagnostics,
    getStatus = function() return pluginStatus end
}
