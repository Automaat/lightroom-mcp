local helper = require 'spec_helper'

-- Load PluginInit with mocked LR globals and a stubbed PluginInfoProvider.
-- Returns a table of observed effects.
local function loadInit(opts)
    opts = opts or {}
    local observed = {
        started = false,
        usedPostAsyncTaskWithContext = false,
        usedStartAsyncTask = false,
        loggedError = nil,
    }

    local prefs = { autoStartServer = opts.autoStartServer }

    package.loaded.PluginInfoProvider = {
        -- PluginInit calls this on load/reload to tear down a stale instance
        -- before auto-start (issues #121, #137); stub it so the require runs.
        resetForReload = function()
            observed.resetForReload = true
        end,
        startServer = function()
            if opts.startServerError then
                error(opts.startServerError)
            end
            observed.started = true
        end,
    }

    helper.installImport({
        LrPrefs = { prefsForPlugin = function() return prefs end },
        LrTasks = {
            -- A bare startAsyncTask is the fragile path PluginInit must NOT
            -- use for auto-start; flag it if called so the test can fail.
            startAsyncTask = function(fn)
                observed.usedStartAsyncTask = true
                fn()
            end,
            sleep = function() end,
            pcall = function(fn, ...) return pcall(fn, ...) end,
        },
        LrFunctionContext = {
            postAsyncTaskWithContext = function(_, fn)
                observed.usedPostAsyncTaskWithContext = true
                fn()
            end,
        },
        LrLogger = setmetatable({}, {
            __call = function()
                return {
                    info = function() end,
                    warn = function() end,
                    error = function(_, msg) observed.loggedError = msg end,
                    enable = function() end,
                }
            end,
        }),
    })

    package.loaded.PluginInit = nil
    require 'PluginInit'
    observed.prefs = prefs
    return observed
end

describe("PluginInit auto-start", function()
    it("starts the server via an independent function context", function()
        local o = loadInit({ autoStartServer = true })
        -- Durable context that survives the init script returning, not a
        -- bare startAsyncTask tied to the init context (issue #128).
        assert.is_true(o.usedPostAsyncTaskWithContext)
        assert.is_false(o.usedStartAsyncTask)
        assert.is_true(o.started)
        -- Reload teardown runs before auto-start (issues #121, #137).
        assert.is_true(o.resetForReload)
    end)

    it("does not start the server when auto-start is disabled", function()
        local o = loadInit({ autoStartServer = false })
        assert.is_false(o.usedPostAsyncTaskWithContext)
        assert.is_false(o.started)
    end)

    it("defaults auto-start to true when the pref is unset", function()
        local o = loadInit({ autoStartServer = nil })
        assert.is_true(o.prefs.autoStartServer)
        assert.is_true(o.started)
    end)

    it("logs the failure instead of dying silently when startServer throws", function()
        -- The auto-start task owns its own context with no cleanup handler, so
        -- an unhandled throw would tear it down with nothing logged -- the
        -- invisible-failure mode of issue #128. It must be surfaced.
        local o = loadInit({ autoStartServer = true, startServerError = "bind failed" })
        assert.is_false(o.started)
        assert.is_not_nil(o.loggedError)
        assert.is_truthy(o.loggedError:find("bind failed", 1, true))
    end)
end)
