-- Shared state module for plugin status
local ServerState = {}

local state = {
    initialized = false,
    serverRunning = false,
    error = nil,
    lastStartAttempt = nil,
    startupLog = {}
}

function ServerState.addLog(message)
    table.insert(state.startupLog, os.date("%H:%M:%S") .. " - " .. message)
end

function ServerState.setRunning(running)
    state.serverRunning = running
    state.initialized = true
end

function ServerState.setError(error)
    state.error = error
end

function ServerState.getState()
    return state
end

-- Initialize
state.lastStartAttempt = os.date("%Y-%m-%d %H:%M:%S")
ServerState.addLog("Plugin loading...")

return ServerState
