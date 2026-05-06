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
        PluginInfoProvider.startServer()
    end)
end
