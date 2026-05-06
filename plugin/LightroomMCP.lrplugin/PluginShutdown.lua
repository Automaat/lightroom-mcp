-- Called when Lightroom is shutting down. Tear down sockets cleanly so
-- ports are released before Lr exits.
local state = _G.LightroomMCP_State
if state then
    state.running = false
    if state.requestSocket then
        pcall(function() state.requestSocket:close() end)
    end
    if state.responseSocket then
        pcall(function() state.responseSocket:close() end)
    end
end
