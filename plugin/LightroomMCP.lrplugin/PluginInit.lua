local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'

local PluginInfoProvider = require 'PluginInfoProvider'
local Log = require 'Log'

-- LrInitPlugin runs on plugin load AND on "Reload Plug-in", but NOT when
-- Lightroom merely renders the Plug-in Manager panel. On reload a prior
-- instance's state may still live on _G with `running` stale-true; clear
-- it so the auto-start below can bind and so a later Plug-in Manager open
-- reports honest status. Doing this here (not in the InfoProvider module
-- body) is what keeps opening the manager from killing a live server
-- (issues #121, #137).
PluginInfoProvider.resetForReload()

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
            -- Route through Log (not raw LrLogger) so this lands in the
            -- OS-resolved file sink the user is told to check; the #128
            -- "server died with nothing in the log" failure mode lived here.
            Log.error("Auto-start failed: " .. tostring(err))
        end
    end)
end
