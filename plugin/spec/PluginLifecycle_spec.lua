-- Tests for the PluginInfoProvider reload/lifecycle logic.
-- These exercise the plain-Lua latch logic in isolation without
-- requiring a real Lightroom environment.

describe("Plugin lifecycle", function()
    local function freshState()
        return {
            running = false,
            serverGen = 0,
            requestSocket = nil,
            responseSocket = nil,
            sendConnected = false,
            receiveConnected = false,
            requestsProcessed = 0,
            lastEvent = nil,
            log = {},
            token = nil,
        }
    end

    -- Simulate what startServer() does to pluginState + return a cleanup fn.
    local function simulateStartServer(pluginState)
        if pluginState.running then
            return nil, "Already running"
        end
        pluginState.running = true
        pluginState.serverGen = (pluginState.serverGen or 0) + 1
        local myGen = pluginState.serverGen
        pluginState.token = "tok_" .. myGen
        pluginState.requestSocket = { id = "req_" .. myGen }
        pluginState.responseSocket = { id = "res_" .. myGen }
        pluginState.sendConnected = true
        pluginState.receiveConnected = true

        local cleanupHandler = function()
            if pluginState.serverGen ~= myGen then
                return -- stale; skip
            end
            pluginState.running = false
            pluginState.requestSocket = nil
            pluginState.responseSocket = nil
            pluginState.sendConnected = false
            pluginState.receiveConnected = false
            pluginState.token = nil
        end

        return cleanupHandler
    end

    -- Simulate what the module body does when loaded.
    local function simulateInfoProviderLoad(state)
        if state and state.running then
            return "preserved"
        end
        return "init"
    end

    it("startServer sets running and sockets", function()
        local ps = freshState()
        local cleanup = simulateStartServer(ps)
        assert.is_not_nil(cleanup)
        assert.is_true(ps.running)
        assert.is_not_nil(ps.requestSocket)
        assert.is_not_nil(ps.token)
        assert.equal(1, ps.serverGen)
    end)

    it("startServer refuses to start when already running", function()
        local ps = freshState()
        simulateStartServer(ps)
        local cleanup2, err = simulateStartServer(ps)
        assert.is_nil(cleanup2)
        assert.equal("Already running", err)
    end)

    it("InfoProvider load while running preserves server", function()
        local ps = freshState()
        simulateStartServer(ps)
        local result = simulateInfoProviderLoad(ps)
        assert.equal("preserved", result)
        assert.is_true(ps.running)
        assert.is_not_nil(ps.requestSocket)
    end)

    it("cleanup handler resets running so startServer can rebind", function()
        local ps = freshState()
        local cleanup = simulateStartServer(ps)
        assert.is_true(ps.running)

        -- Simulate "Reload Plug-in": Lightroom cancels context → cleanup fires
        cleanup()

        assert.is_false(ps.running)
        assert.is_nil(ps.requestSocket)
        assert.is_nil(ps.token)

        -- Now startServer should work again
        local cleanup2 = simulateStartServer(ps)
        assert.is_not_nil(cleanup2)
        assert.is_true(ps.running)
        assert.equal(2, ps.serverGen)
    end)

    it("stale cleanup handler does not corrupt new server (gen guard)", function()
        local ps = freshState()
        local oldCleanup = simulateStartServer(ps)
        assert.equal(1, ps.serverGen)

        -- User does Stop (manually set running=false)
        ps.running = false

        -- User does Start again quickly → new gen
        local newCleanup = simulateStartServer(ps)
        assert.equal(2, ps.serverGen)
        assert.is_true(ps.running)
        local newToken = ps.token
        local newReqSocket = ps.requestSocket

        -- Old context's cleanup fires late
        oldCleanup()

        -- New server must be untouched
        assert.is_true(ps.running)
        assert.equal(newToken, ps.token)
        assert.equal(newReqSocket, ps.requestSocket)
        assert.equal(2, ps.serverGen)
    end)

    it("full reload cycle: cleanup → InfoProvider load → auto-start", function()
        local ps = freshState()
        local cleanup = simulateStartServer(ps)

        -- Step 1: Reload cancels context → cleanup fires
        cleanup()
        assert.is_false(ps.running)

        -- Step 2: Lightroom re-runs PluginInit, which loads InfoProvider
        local result = simulateInfoProviderLoad(ps)
        assert.equal("init", result) -- running is false, so no "preserved"

        -- Step 3: PluginInit calls startServer() after 0.5s sleep
        local cleanup2 = simulateStartServer(ps)
        assert.is_not_nil(cleanup2)
        assert.is_true(ps.running)
        assert.is_not_nil(ps.token)
    end)
end)
