local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'

local PluginInfoProvider = require 'PluginInfoProvider'

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
    LrTasks.startAsyncTask(function()
        -- Brief yield so any prior-instance context cancel (from Reload
        -- Plug-in) can flush and release ports before we try to bind them.
        LrTasks.sleep(0.5)
        PluginInfoProvider.startServer()
    end)
end
