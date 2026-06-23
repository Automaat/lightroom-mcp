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
            bind = function()
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
