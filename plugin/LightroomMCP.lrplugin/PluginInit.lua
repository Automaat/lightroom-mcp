local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrLogger = import 'LrLogger'

local PluginInfoProvider = require 'PluginInfoProvider'

local logger = LrLogger('LightroomMCP')

local prefs = LrPrefs.prefsForPlugin()
local autoStart = prefs.autoStartServer
if autoStart == nil then
    autoStart = true
    prefs.autoStartServer = true
end

if autoStart then
    -- Must use postAsyncTaskWithContext, NOT LrTasks.startAsyncTask. A bare
    -- startAsyncTask here runs in THIS init script's function context; when
    -- LrInitPlugin returns, that context is torn down and the task is
    -- cancelled mid-sleep before startServer() ever runs. On macOS that left
    -- the server stopped after launch despite auto-start being on (issue
    -- #128). A fresh context survives the init script returning.
    LrFunctionContext.postAsyncTaskWithContext("LightroomMCPAutoStart", function()
        -- Brief yield so any prior-instance context cancel (from Reload
        -- Plug-in) can flush and release ports before we try to bind them.
        LrTasks.sleep(0.5)
        -- Guard startServer. This task owns an independent context with no
        -- cleanup handler, so an unhandled throw (token write, socket bind)
        -- would tear the context down and leave auto-start dead with nothing
        -- in the log -- the same invisible "server stopped after launch"
        -- failure #128 was about. Surface it instead.
        local ok, err = LrTasks.pcall(PluginInfoProvider.startServer)
        if not ok then
            logger:error("Auto-start failed: " .. tostring(err))
        end
    end)
end
