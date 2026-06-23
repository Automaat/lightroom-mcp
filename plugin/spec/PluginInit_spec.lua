local helper = require 'spec_helper'

-- Load PluginInit with mocked LR globals and a stubbed PluginInfoProvider.
-- Returns a table of observed effects.
local function loadInit(opts)
    opts = opts or {}
    local observed = {
        started = false,
        usedPostAsyncTaskWithContext = false,
        usedStartAsyncTask = false,
    }

    local prefs = { autoStartServer = opts.autoStartServer }

    package.loaded.PluginInfoProvider = {
        startServer = function() observed.started = true end,
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
        },
        LrFunctionContext = {
            postAsyncTaskWithContext = function(_, fn)
                observed.usedPostAsyncTaskWithContext = true
                fn()
            end,
        },
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
end)
