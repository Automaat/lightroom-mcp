local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'

local PluginInfoProvider = require 'PluginInfoProvider'

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
