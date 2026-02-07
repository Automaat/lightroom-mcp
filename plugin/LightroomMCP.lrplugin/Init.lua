local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'
local LrLogger = import 'LrLogger'

local logger = LrLogger('LightroomMCP')
logger:enable("logfile")

local HttpServer = require 'HttpServer'
local ServerState = require 'ServerState'

logger:info("=== Init.lua executing ===")
ServerState.addLog("Init.lua executing")

-- Start server when plugin loads
LrTasks.startAsyncTask(function()
    logger:info("Async task started")
    ServerState.addLog("Async task started")

    -- Need to be in a function context to use LrSocket
    LrFunctionContext.callWithContext("HttpServer", function(context)
        logger:info("Function context created")
        ServerState.addLog("Function context created")

        local success, err = pcall(function()
            logger:info("Calling HttpServer.start")
            ServerState.addLog("Calling HttpServer.start")

            HttpServer.start(context)

            logger:info("HttpServer.start returned")
            ServerState.addLog("HttpServer.start returned")
            ServerState.setRunning(true)
        end)

        if not success then
            local errorMsg = "Error starting server: " .. tostring(err)
            logger:error(errorMsg)
            ServerState.addLog("ERROR: " .. errorMsg)
            ServerState.setError(errorMsg)
            LrDialogs.message("Lightroom MCP Error", errorMsg, "critical")
        end
    end)
end)

logger:info("=== Init.lua completed ===")
ServerState.addLog("Init.lua completed")
