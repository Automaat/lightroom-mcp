local helper = require 'spec_helper'

-- Stub everything PluginInfoProvider / PluginInit pull in so requiring them
-- has no real side effects. The lifecycle logic under test lives in the
-- module body + resetForReload + PluginInit wiring; none of it binds a
-- socket at load time (binding happens only inside startServer).
local HANDLER_MODULES = {
    'JSON', 'HandlerSearch', 'HandlerCollections', 'HandlerMetadata',
    'HandlerOrganization', 'HandlerImport', 'HandlerExport',
    'HandlerSelection', 'HandlerDevelop',
}

-- opts (all optional) let a test drive the otherwise-async server task:
--   runTask        -- actually execute the postAsyncTaskWithContext body
--   cleanups       -- array; each registered cleanup handler is appended
--   socketOps      -- array; "close"/"reconnect" calls on bound sockets land here
--   stopLoopOnSleep -- flip running=false on the first LrTasks.sleep so the
--                      monitor loop exits after a single tick
--   capturedBinds  -- array; each LrSocket.bind opts table is appended, in
--                      bind order (request socket first, then response), so
--                      a test can invoke onConnected/onMessage/etc directly
--   onSleep        -- called with the shared state on each LrTasks.sleep, so a
--                      test can flip flags between monitor-loop ticks
local function installStubs(prefs, asyncTasks, opts)
    opts = opts or {}
    helper.installImport({
        LrTasks = {
            startAsyncTask = function(fn)
                if asyncTasks then
                    table.insert(asyncTasks, fn)
                else
                    fn()
                end
            end,
            sleep = function()
                if opts.stopLoopOnSleep and _G.LightroomMCP_State then
                    _G.LightroomMCP_State.running = false
                end
                if opts.onSleep then opts.onSleep(_G.LightroomMCP_State) end
            end,
            pcall = pcall,
        },
        LrLogger = helper.defaultLrLogger(),
        LrDialogs = { message = function() end },
        LrFunctionContext = {
            postAsyncTaskWithContext = function(_, fn)
                if not opts.runTask then return end
                local context = {
                    addCleanupHandler = function(_, handler)
                        if opts.cleanups then table.insert(opts.cleanups, handler) end
                    end,
                }
                fn(context)
            end,
        },
        LrSocket = {
            bind = function(bindOpts)
                if opts.capturedBinds then table.insert(opts.capturedBinds, bindOpts) end
                return {
                    close = function()
                        if opts.socketOps then table.insert(opts.socketOps, "close") end
                    end,
                    reconnect = function()
                        if opts.socketOps then table.insert(opts.socketOps, "reconnect") end
                    end,
                    send = function() end,
                }
            end,
        },
        LrPrefs = { prefsForPlugin = function() return prefs or {} end },
        LrView = { bind = function() end },
        LrUUID = { generateUUID = function() return "0000-0000" end },
        LrPathUtils = {
            child = function(a, b) return a .. "/" .. b end,
            getStandardFilePath = function() return "/home" end,
        },
        LrFileUtils = { createAllDirectories = function() end },
    })
    for _, name in ipairs(HANDLER_MODULES) do
        package.loaded[name] = {}
    end
end

-- Simulate Lightroom loading the InfoProvider file fresh (panel render) or
-- PluginInit requiring it: clear the module cache and re-run its body while
-- _G persists across the load (same Lua state).
local function loadInfoProvider()
    package.loaded.PluginInfoProvider = nil
    return require 'PluginInfoProvider'
end

local function loadPluginInit()
    package.loaded.PluginInfoProvider = nil
    package.loaded.PluginInit = nil
    require 'PluginInit'
end

describe("PluginInfoProvider lifecycle", function()
    before_each(function()
        _G.LightroomMCP_State = nil
        installStubs()
    end)

    it("creates fresh state on first load", function()
        loadInfoProvider()
        assert.is_not_nil(_G.LightroomMCP_State)
        assert.is_false(_G.LightroomMCP_State.running)
    end)

    it("preserves a running server across a Plug-in Manager render", function()
        loadInfoProvider()
        -- Simulate a live server, then a panel render that re-runs the body.
        _G.LightroomMCP_State.running = true
        local sock = { close = function() error("must not close on render") end }
        _G.LightroomMCP_State.requestSocket = sock
        local stateBefore = _G.LightroomMCP_State

        loadInfoProvider()

        assert.are.equal(stateBefore, _G.LightroomMCP_State)
        assert.is_true(_G.LightroomMCP_State.running)
        assert.are.equal(sock, _G.LightroomMCP_State.requestSocket)
    end)

    it("resetForReload stops a stale running instance", function()
        local mod = loadInfoProvider()
        local closed = { request = false, response = false }
        local s = _G.LightroomMCP_State
        s.running = true
        s.token = "tok"
        s.sendConnected = true
        s.receiveConnected = true
        s.requestSocket = { close = function() closed.request = true end }
        s.responseSocket = { close = function() closed.response = true end }

        mod.resetForReload()

        assert.is_false(s.running)
        assert.is_nil(s.requestSocket)
        assert.is_nil(s.responseSocket)
        assert.is_false(s.sendConnected)
        assert.is_false(s.receiveConnected)
        assert.is_nil(s.token)
        assert.is_true(closed.request)
        assert.is_true(closed.response)
    end)

    it("resetForReload is a no-op when nothing is running", function()
        local mod = loadInfoProvider()
        assert.has_no.errors(function() mod.resetForReload() end)
        assert.is_false(_G.LightroomMCP_State.running)
    end)
end)

-- Auto-start scheduling itself is covered by PluginInit_spec.lua; here we
-- only assert that PluginInit wires the reload teardown into the real module.
describe("PluginInit reload reset", function()
    before_each(function()
        _G.LightroomMCP_State = nil
    end)

    it("resets a surviving running instance on reload", function()
        installStubs({ autoStartServer = false })
        local closed = false
        _G.LightroomMCP_State = {
            running = true,
            requestSocket = { close = function() closed = true end },
            responseSocket = nil,
            sendConnected = true,
            receiveConnected = false,
            requestsProcessed = 7,
            lastEvent = "12:00:00",
            requestPort = 12345,
            responseNeedsRebind = true,
            log = {},
            token = "tok",
        }

        loadPluginInit()

        assert.is_false(_G.LightroomMCP_State.running)
        assert.is_nil(_G.LightroomMCP_State.requestSocket)
        assert.is_true(closed)
        -- Transient state returns to fresh-state defaults (Copilot #141).
        assert.are.equal(0, _G.LightroomMCP_State.requestsProcessed)
        assert.is_nil(_G.LightroomMCP_State.lastEvent)
        assert.is_nil(_G.LightroomMCP_State.requestPort)
        assert.is_false(_G.LightroomMCP_State.responseNeedsRebind)
    end)
end)

-- Drives the real startServer task body (binds, cleanup handler, monitor
-- loop) to cover the concurrency-sensitive teardown that the in-place
-- resetForReload refactor put at risk.
describe("PluginInfoProvider server task", function()
    local realOpen
    before_each(function()
        _G.LightroomMCP_State = nil
        -- startServer writes a token file; stub ONLY the write so it never
        -- touches disk. Delegate every other open to the real io.open --
        -- under CI's luarocks `require` loader, manifest reads call
        -- io.open(path):read(), and a fake handle there breaks module loading.
        realOpen = io.open
        io.open = function(path, mode, ...)
            if mode and mode:find("w", 1, true) then
                return { write = function() end, close = function() end }
            end
            return realOpen(path, mode, ...)
        end
    end)
    after_each(function()
        io.open = realOpen
    end)

    it("bumps instanceId on every start", function()
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {} })
        local mod = loadInfoProvider()

        mod.startServer()
        assert.are.equal(1, _G.LightroomMCP_State.instanceId)
        mod.startServer()
        assert.are.equal(2, _G.LightroomMCP_State.instanceId)
    end)

    it("ignores a superseded instance's cleanup handler", function()
        local cleanups = {}
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = cleanups })
        local mod = loadInfoProvider()

        mod.startServer() -- instance 1: binds, loop exits (stopLoopOnSleep)
        local staleCleanup = cleanups[1]

        mod.startServer() -- instance 2 supersedes
        local liveReq = _G.LightroomMCP_State.requestSocket
        local liveResp = _G.LightroomMCP_State.responseSocket
        local liveToken = _G.LightroomMCP_State.token

        -- Old context cleanup fires late (after the new instance rebound).
        staleCleanup()

        assert.are.equal(liveReq, _G.LightroomMCP_State.requestSocket)
        assert.are.equal(liveResp, _G.LightroomMCP_State.responseSocket)
        assert.are.equal(liveToken, _G.LightroomMCP_State.token)
    end)

    it("tears down its own sockets when not superseded", function()
        local cleanups = {}
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = cleanups })
        local mod = loadInfoProvider()

        mod.startServer()
        cleanups[1]()

        assert.is_nil(_G.LightroomMCP_State.requestSocket)
        assert.is_nil(_G.LightroomMCP_State.responseSocket)
        assert.is_nil(_G.LightroomMCP_State.token)
    end)

    it("does not churn freshly bound sockets when recovery flags are stale", function()
        local ops = {}
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {}, socketOps = ops })
        local mod = loadInfoProvider()

        -- Simulate flags left true by a client disconnect just before reload.
        _G.LightroomMCP_State.requestNeedsReconnect = true
        _G.LightroomMCP_State.responseNeedsRebind = true
        _G.LightroomMCP_State.responseNeedsReconnect = true

        mod.startServer()

        assert.are.equal(0, #ops)
        assert.is_false(_G.LightroomMCP_State.requestNeedsReconnect)
        assert.is_false(_G.LightroomMCP_State.responseNeedsRebind)
        assert.is_false(_G.LightroomMCP_State.responseNeedsReconnect)
    end)
end)


describe("stale-connection follow-up fixes (PR #151 re-review)", function()
    local realOpen
    before_each(function()
        _G.LightroomMCP_State = nil
        realOpen = io.open
        io.open = function(path, mode, ...)
            if mode and mode:find("w", 1, true) then
                return { write = function() end, close = function() end }
            end
            return realOpen(path, mode, ...)
        end
    end)
    after_each(function()
        io.open = realOpen
    end)

    it("clears a stale lastRequestTime on a fresh REQUEST connect so it doesn't leak into the new idle clock", function()
        local binds = {}
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {}, capturedBinds = binds })
        local mod = loadInfoProvider()

        mod.startServer()
        -- Simulate a prior session's activity timestamp surviving past a
        -- manual Stop/Start (or any reconnect) that happens long after it
        -- sat idle. Without clearing it here, the monitor loop's very next
        -- tick would see a huge idle value and restart immediately.
        _G.LightroomMCP_State.lastRequestTime = os.time() - 999
        binds[1].onConnected()

        assert.is_nil(_G.LightroomMCP_State.lastRequestTime)
        assert.is_not_nil(_G.LightroomMCP_State.lastConnectedTime)
    end)

    it("keeps a request counted in-flight until sendResponse actually completes, not just until the handler returns", function()
        package.loaded.JSON = nil -- exercise the real encoder/decoder, not the empty stub
        local binds = {}
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {}, capturedBinds = binds })
        local mod = loadInfoProvider()

        mod.startServer()
        local state = _G.LightroomMCP_State
        state.sendConnected = true
        state.responseSocket = {
            send = function()
                -- If inFlightRequests were decremented right after the
                -- handler returns (the pre-fix behavior), the monitor loop
                -- could see 0 in-flight and restart the server while this
                -- send is still happening — defeating the blast-radius fix.
                assert.are.equal(1, state.inFlightRequests)
            end,
        }

        binds[1].onMessage(nil, '{"id":1,"action":"ping","hello":"' .. state.token .. '"}')

        assert.are.equal(0, state.inFlightRequests)
    end)
end)

describe("heartbeat / stale-connection blast radius (PR #151 review)", function()
    before_each(function()
        _G.LightroomMCP_State = nil
        installStubs()
    end)

    it("ping handler is a pure liveness no-op returning pong=true", function()
        local mod = loadInfoProvider()
        assert.are.same({ pong = true }, mod.handlePing({}))
    end)

    it("derives the soft/hard thresholds from the heartbeat interval", function()
        local mod = loadInfoProvider()
        assert.are.equal(30, mod.HEARTBEAT_INTERVAL_SECONDS)
        assert.are.equal(90, mod.STALE_RECONNECT_SECONDS)
        assert.are.equal(120, mod.STALE_RESTART_HARD_CAP_SECONDS)
    end)

    describe("shouldRestartForStaleConnection", function()
        it("does not restart while idle is within the soft threshold", function()
            local mod = loadInfoProvider()
            local restart, suffix = mod.shouldRestartForStaleConnection(
                89, 0, mod.STALE_RECONNECT_SECONDS, mod.STALE_RESTART_HARD_CAP_SECONDS)
            assert.is_false(restart)
            assert.are.equal("", suffix)
        end)

        it("restarts once idle passes the soft threshold with nothing in flight", function()
            local mod = loadInfoProvider()
            local restart, suffix = mod.shouldRestartForStaleConnection(
                91, 0, mod.STALE_RECONNECT_SECONDS, mod.STALE_RESTART_HARD_CAP_SECONDS)
            assert.is_true(restart)
            assert.are.equal("", suffix)
        end)

        it("defers the restart past the soft threshold while a request is genuinely in flight (blast radius fix)", function()
            local mod = loadInfoProvider()
            local restart, suffix = mod.shouldRestartForStaleConnection(
                91, 1, mod.STALE_RECONNECT_SECONDS, mod.STALE_RESTART_HARD_CAP_SECONDS)
            assert.is_false(restart)
            assert.are.equal("", suffix)
        end)

        it("still restarts past the hard cap even if a request is in flight, to bound the wait", function()
            local mod = loadInfoProvider()
            local restart, suffix = mod.shouldRestartForStaleConnection(
                121, 1, mod.STALE_RECONNECT_SECONDS, mod.STALE_RESTART_HARD_CAP_SECONDS)
            assert.is_true(restart)
            assert.are.equal(" [hard cap, request still in flight]", suffix)
        end)

        it("treats exactly-at-threshold idle as not yet past it (strict greater-than)", function()
            local mod = loadInfoProvider()
            local restart = mod.shouldRestartForStaleConnection(
                90, 0, mod.STALE_RECONNECT_SECONDS, mod.STALE_RESTART_HARD_CAP_SECONDS)
            assert.is_false(restart)
        end)
    end)
end)

describe("cooperative shutdown at Lightroom quit (issue 195)", function()
    local realOpen
    local opens
    before_each(function()
        _G.LightroomMCP_State = nil
        opens = 0
        realOpen = io.open
        io.open = function(path, mode, ...)
            opens = opens + 1
            if mode and mode:find("w", 1, true) then
                return { write = function() end, close = function() end }
            end
            return realOpen(path, mode, ...)
        end
    end)
    after_each(function()
        io.open = realOpen
        package.preload.PluginInfoProvider = nil
    end)

    local function requestFor(state, action)
        return '{"id":1,"action":"' .. action .. '","hello":"' .. state.token .. '"}'
    end

    it("clears connection state without blocking on sockets or the log file", function()
        local ops = {}
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {}, socketOps = ops })
        local mod = loadInfoProvider()

        mod.startServer()
        local opensBefore = opens
        mod.shutdown()

        local state = _G.LightroomMCP_State
        assert.is_true(state.shuttingDown)
        assert.is_false(state.running)
        assert.is_false(state.sendConnected)
        assert.is_false(state.receiveConnected)
        assert.is_nil(state.token)
        assert.are.same({}, ops)
        assert.are.equal(opensBefore, opens)
    end)

    it("leaves the sockets for the server task to release", function()
        local ops, cleanups = {}, {}
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = cleanups, socketOps = ops })
        local mod = loadInfoProvider()

        mod.startServer()
        mod.shutdown()

        assert.is_not_nil(_G.LightroomMCP_State.requestSocket)
        assert.is_not_nil(_G.LightroomMCP_State.responseSocket)

        cleanups[1]()

        assert.are.same({ "close", "close" }, ops)
        assert.is_nil(_G.LightroomMCP_State.requestSocket)
        assert.is_nil(_G.LightroomMCP_State.responseSocket)
    end)

    it("is a cheap no-op when the server never started", function()
        local ops = {}
        installStubs(nil, nil, { socketOps = ops })
        local mod = loadInfoProvider()

        assert.has_no.errors(function() mod.shutdown() end)
        assert.are.same({}, ops)
        assert.is_true(_G.LightroomMCP_State.shuttingDown)
    end)

    it("leaves the monitor loop on the first tick after quit begins", function()
        local ticks = 0
        installStubs(nil, {}, {
            runTask = true,
            cleanups = {},
            onSleep = function(state)
                ticks = ticks + 1
                if ticks == 1 then
                    state.shuttingDown = true
                else
                    state.running = false
                end
            end,
        })
        local mod = loadInfoProvider()

        mod.startServer()

        assert.are.equal(1, ticks)
    end)

    it("does not bind a new response listener when quit lands inside the rebind yield", function()
        local binds = {}
        local ticks = 0
        installStubs(nil, {}, {
            runTask = true,
            cleanups = {},
            capturedBinds = binds,
            onSleep = function(state)
                ticks = ticks + 1
                if ticks == 1 then
                    state.responseNeedsRebind = true
                elseif ticks == 2 then
                    state.shuttingDown = true
                else
                    state.running = false
                end
            end,
        })
        local mod = loadInfoProvider()

        mod.startServer()

        assert.is_table(binds[2])
        assert.is_nil(binds[3])
    end)

    it("queues no dispatch task for a message that arrives during quit", function()
        local binds, asyncTasks = {}, {}
        installStubs(nil, asyncTasks, {
            runTask = true, stopLoopOnSleep = true, cleanups = {}, capturedBinds = binds,
        })
        package.loaded.JSON = nil
        local mod = loadInfoProvider()

        mod.startServer()
        local state = _G.LightroomMCP_State
        state.shuttingDown = true
        binds[1].onMessage(nil, requestFor(state, "ping"))

        assert.is_nil(asyncTasks[1])
    end)

    it("does not run a handler whose dispatch task was queued before quit", function()
        local binds, asyncTasks = {}, {}
        local handlerCalls = 0
        installStubs(nil, asyncTasks, {
            runTask = true, stopLoopOnSleep = true, cleanups = {}, capturedBinds = binds,
        })
        package.loaded.JSON = nil
        package.loaded.HandlerSearch = {
            searchPhotos = function()
                handlerCalls = handlerCalls + 1
                return { photos = {} }
            end,
        }
        local mod = loadInfoProvider()

        mod.startServer()
        local state = _G.LightroomMCP_State
        binds[1].onMessage(nil, requestFor(state, "search_photos"))
        state.shuttingDown = true
        asyncTasks[1]()

        assert.are.equal(0, handlerCalls)
    end)

    it("drops the response of a handler that finished after quit began", function()
        local binds, sent = {}, {}
        installStubs(nil, nil, {
            runTask = true, stopLoopOnSleep = true, cleanups = {}, capturedBinds = binds,
        })
        package.loaded.JSON = nil
        package.loaded.HandlerSearch = {
            searchPhotos = function()
                _G.LightroomMCP_State.shuttingDown = true
                return { photos = {} }
            end,
        }
        local mod = loadInfoProvider()

        mod.startServer()
        local state = _G.LightroomMCP_State
        state.sendConnected = true
        state.responseSocket = { send = function() table.insert(sent, true) end }

        binds[1].onMessage(nil, requestFor(state, "search_photos"))

        assert.are.same({}, sent)
    end)

    it("stops waiting for the send socket as soon as quit begins", function()
        local binds = {}
        local waitSleeps = 0
        local waiting = false
        installStubs(nil, nil, {
            runTask = true, stopLoopOnSleep = true, cleanups = {}, capturedBinds = binds,
            onSleep = function(state)
                if not waiting then return end
                waitSleeps = waitSleeps + 1
                if waitSleeps == 2 then state.shuttingDown = true end
            end,
        })
        package.loaded.JSON = nil
        local mod = loadInfoProvider()

        mod.startServer()
        local state = _G.LightroomMCP_State
        state.sendConnected = false
        waiting = true

        binds[1].onMessage(nil, requestFor(state, "ping"))

        assert.are.equal(2, waitSleeps)
    end)

    it("abandons a pending stale-connection restart", function()
        local asyncTasks = {}
        local ticks = 0
        installStubs(nil, asyncTasks, {
            runTask = true,
            cleanups = {},
            onSleep = function(state)
                ticks = ticks + 1
                if ticks == 1 then
                    state.needsFullRestart = true
                else
                    state.running = false
                end
            end,
        })
        local mod = loadInfoProvider()

        mod.startServer()
        local instanceBefore = _G.LightroomMCP_State.instanceId
        _G.LightroomMCP_State.shuttingDown = true
        local pendingRestart = asyncTasks[1]
        assert.is_function(pendingRestart)
        pendingRestart()

        assert.are.equal(instanceBefore, _G.LightroomMCP_State.instanceId)
    end)

    it("refuses an auto-start that wakes after quit began", function()
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {} })
        local mod = loadInfoProvider()

        mod.shutdown()
        mod.startServer()

        assert.is_false(_G.LightroomMCP_State.running)
        assert.is_nil(_G.LightroomMCP_State.token)
    end)

    it("lets the Plug-in Manager Start button supersede an earlier shutdown", function()
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {} })
        local mod = loadInfoProvider()

        mod.startServer()
        mod.shutdown()
        mod.startServerFromPanel()

        assert.is_false(_G.LightroomMCP_State.shuttingDown)
        assert.is_not_nil(_G.LightroomMCP_State.token)
    end)

    it("clears the shutdown flag on reload so the fresh instance can bind", function()
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {} })
        local mod = loadInfoProvider()

        mod.startServer()
        mod.shutdown()
        mod.resetForReload()
        mod.startServer()

        assert.is_false(_G.LightroomMCP_State.shuttingDown)
        assert.is_not_nil(_G.LightroomMCP_State.token)
    end)

    it("PluginShutdown.lua raises the flags the server task polls", function()
        local ops = {}
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {}, socketOps = ops })
        local mod = loadInfoProvider()
        mod.startServer()

        package.loaded.PluginShutdown = nil
        require 'PluginShutdown'

        local state = _G.LightroomMCP_State
        assert.is_true(state.shuttingDown)
        assert.is_false(state.running)
        assert.is_false(state.requestNeedsReconnect)
        assert.is_false(state.responseNeedsRebind)
        assert.is_false(state.responseNeedsReconnect)
        assert.is_false(state.needsFullRestart)
        assert.is_false(state.freshRestart)
        assert.is_false(state.sendConnected)
        assert.is_false(state.receiveConnected)
        assert.is_nil(state.token)
    end)

    it("PluginShutdown.lua closes no socket and writes no file", function()
        local ops = {}
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {}, socketOps = ops })
        local mod = loadInfoProvider()
        mod.startServer()

        local opensBefore = opens
        package.loaded.PluginShutdown = nil
        require 'PluginShutdown'

        assert.are.same({}, ops)
        assert.are.equal(opensBefore, opens)
        assert.is_not_nil(_G.LightroomMCP_State.requestSocket)
        assert.is_not_nil(_G.LightroomMCP_State.responseSocket)
    end)

    it("PluginShutdown.lua does not load PluginInfoProvider", function()
        installStubs(nil, nil, { runTask = true, stopLoopOnSleep = true, cleanups = {} })
        local mod = loadInfoProvider()
        mod.startServer()

        package.loaded.PluginInfoProvider = nil
        package.preload.PluginInfoProvider = function() error("must not load at quit") end
        package.loaded.PluginShutdown = nil
        assert.has_no.errors(function() require 'PluginShutdown' end)
        package.preload.PluginInfoProvider = nil

        assert.is_true(_G.LightroomMCP_State.shuttingDown)
        assert.is_nil(package.loaded.PluginInfoProvider)
    end)

    it("PluginShutdown.lua is inert when the plugin never built its state", function()
        _G.LightroomMCP_State = nil

        package.loaded.PluginShutdown = nil
        assert.has_no.errors(function() require 'PluginShutdown' end)

        assert.is_nil(_G.LightroomMCP_State)
    end)
end)
