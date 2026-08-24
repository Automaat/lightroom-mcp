local function tearDownSharedState()
    local state = _G.LightroomMCP_State
    if not state then return end
    state.shuttingDown = true
    state.running = false
    if state.requestSocket then
        pcall(function() state.requestSocket:close() end)
    end
    if state.responseSocket then
        pcall(function() state.responseSocket:close() end)
    end
    state.requestSocket = nil
    state.responseSocket = nil
    state.sendConnected = false
    state.receiveConnected = false
    state.token = nil
end

local ok, PluginInfoProvider = pcall(require, 'PluginInfoProvider')
if ok and type(PluginInfoProvider) == "table" and type(PluginInfoProvider.shutdown) == "function" then
    PluginInfoProvider.shutdown()
else
    tearDownSharedState()
end
