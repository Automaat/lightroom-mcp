local LrDialogs = import 'LrDialogs'

local state = _G.LightroomMCP_State or {}

local lines = {
    "Running: " .. tostring(state.running),
    "Request socket connected: " .. tostring(state.receiveConnected),
    "Response socket connected: " .. tostring(state.sendConnected),
    "Last event: " .. tostring(state.lastEvent or "Never"),
    "Requests processed: " .. tostring(state.requestsProcessed or 0),
    "",
    "Recent logs:",
}

if state.log then
    local startIdx = math.max(1, #state.log - 30)
    for i = startIdx, #state.log do
        table.insert(lines, "  " .. state.log[i])
    end
end

LrDialogs.message("Lightroom MCP Status", table.concat(lines, "\n"), "info")
