local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'
local LrLogger = import 'LrLogger'

local logger = LrLogger('LightroomMCP')
logger:enable("logfile")

local HttpServer = require 'HttpServer'
local ServerState = require 'ServerState'

logger:info("=== PluginInit.lua loaded ===")

-- This function is called by Lightroom when the plugin is initialized
LrTasks.startAsyncTask(function()
    logger:info("=== Plugin init async task started ===")
    ServerState.addLog("Plugin init async task started")

    LrFunctionContext.callWithContext("HttpServer", function(context)
        logger:info("Function context created")
        ServerState.addLog("Function context created")

        local success, err = pcall(function()
            logger:info("Starting HTTP server...")
            ServerState.addLog("Starting HTTP server...")

            HttpServer.start(context)

            logger:info("HTTP server started")
            ServerState.addLog("HTTP server started")
            ServerState.setRunning(true)
        end)

        if not success then
            local errorMsg = "Failed to start HTTP server: " .. tostring(err)
            logger:error(errorMsg)
            ServerState.addLog("ERROR: " .. errorMsg)
            ServerState.setError(errorMsg)
            LrDialogs.message("Lightroom MCP Error", errorMsg, "critical")
        end
    end)
end)
