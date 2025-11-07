local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'
local LrLogger = import 'LrLogger'

local logger = LrLogger('LightroomMCP')
logger:enable("logfile")

local HttpServer = require 'HttpServer'

-- Initialize plugin
local function initPlugin()
    LrTasks.startAsyncTask(function()
        LrFunctionContext.callWithContext("HttpServer", function(context)
            logger:info("Starting Lightroom MCP plugin...")

            local success, err = pcall(function()
                HttpServer.start()
            end)

            if not success then
                logger:error("Failed to start HTTP server: " .. tostring(err))
                LrDialogs.message("Lightroom MCP Error", "Failed to start HTTP server: " .. tostring(err), "critical")
            end
        end)
    end)
end

-- Shutdown plugin
local function shutdownPlugin()
    logger:info("Shutting down Lightroom MCP plugin...")
    HttpServer.stop()
end

initPlugin()

return {
    shutdown = shutdownPlugin
}
