local state = _G.LightroomMCP_State
if state then
    state.shuttingDown = true
    state.running = false
    state.requestNeedsReconnect = false
    state.responseNeedsRebind = false
    state.responseNeedsReconnect = false
    state.needsFullRestart = false
    state.freshRestart = false
    state.sendConnected = false
    state.receiveConnected = false
    state.token = nil
end
