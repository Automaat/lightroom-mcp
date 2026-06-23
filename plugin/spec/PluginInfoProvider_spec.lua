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

local function installStubs(prefs, asyncTasks)
    helper.installImport({
        LrTasks = {
            startAsyncTask = function(fn)
                if asyncTasks then
                    table.insert(asyncTasks, fn)
                else
                    fn()
                end
            end,
            sleep = function() end,
            pcall = pcall,
        },
        LrLogger = helper.defaultLrLogger(),
        LrDialogs = { message = function() end },
        LrFunctionContext = { postAsyncTaskWithContext = function() end },
        LrSocket = { bind = function() return {} end },
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

describe("PluginInit", function()
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
            requestsProcessed = 0,
            log = {},
            token = "tok",
        }

        loadPluginInit()

        assert.is_false(_G.LightroomMCP_State.running)
        assert.is_nil(_G.LightroomMCP_State.requestSocket)
        assert.is_true(closed)
    end)

    it("schedules auto-start when enabled", function()
        local tasks = {}
        installStubs({ autoStartServer = true }, tasks)

        loadPluginInit()

        assert.are.equal(1, #tasks)
    end)

    it("does not schedule auto-start when disabled", function()
        local tasks = {}
        installStubs({ autoStartServer = false }, tasks)

        loadPluginInit()

        assert.are.equal(0, #tasks)
    end)
end)
