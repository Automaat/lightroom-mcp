-- Reliable file logging for the plugin.
--
-- `LrLogger:enable("logfile")` alone proved unreliable on Windows (issue #134):
-- its target directory `~/Documents/LrClassicLogs` is not created by us, and on
-- Windows `Documents` is frequently redirected (OneDrive), so the file lands
-- somewhere the user cannot find -- or nowhere. We therefore ALSO write our own
-- copy via io.open to an OS-resolved path we control, create the directory
-- ourselves, and expose the resolved absolute path so the Plug-in Manager can
-- show exactly where logs go. The LrLogger channel is kept as a secondary sink.
--
-- pcall around `import` keeps this module loadable under the busted specs, whose
-- mock `import` only stubs the handful of namespaces each spec needs; a missing
-- LrPathUtils/LrFileUtils there simply disables the file sink (no stray writes).
local function tryImport(name)
    local ok, mod = pcall(import, name)
    if ok then return mod end
    return nil
end

local LrLogger = tryImport('LrLogger')
local LrPathUtils = tryImport('LrPathUtils')
local LrFileUtils = tryImport('LrFileUtils')

local lrLogger = LrLogger and LrLogger('LightroomMCP') or nil
if lrLogger then lrLogger:enable("logfile") end

local Log = {}

local resolvedPath
local pathResolved = false

-- Resolve (once) the file we own. nil if the SDK path utils are unavailable
-- (test environment) or the OS path cannot be determined.
local function filePath()
    if pathResolved then return resolvedPath end
    pathResolved = true
    if not LrPathUtils then return nil end
    local ok, docs = pcall(function() return LrPathUtils.getStandardFilePath("documents") end)
    if not ok or not docs then return nil end
    local dir = LrPathUtils.child(docs, "LrClassicLogs")
    if LrFileUtils then
        pcall(function() LrFileUtils.createAllDirectories(dir) end)
    end
    resolvedPath = LrPathUtils.child(dir, "LightroomMCP.log")
    return resolvedPath
end

Log.filePath = filePath

-- Single-file rotation cap. Without it the append-only file grows unbounded
-- (e.g. if the server reconnect loop ever floods requests) on the same
-- OneDrive-synced Windows path the file sink exists to reach.
local MAX_LOG_BYTES = 5 * 1024 * 1024

-- Best-effort: when the log passes the cap, move it aside to <path>.1
-- (replacing any prior roll) and start fresh. Wrapped so a failed rotation
-- never disrupts logging; skipped in tests where LrFileUtils is absent.
local function rotateIfLarge(path, size)
    if not size or size <= MAX_LOG_BYTES or not LrFileUtils then return end
    pcall(function()
        local rolled = path .. ".1"
        if LrFileUtils.exists(rolled) then LrFileUtils.delete(rolled) end
        LrFileUtils.move(path, rolled)
    end)
end

local function write(level, msg)
    msg = tostring(msg)
    if lrLogger then
        if level == "warn" then
            lrLogger:warn(msg)
        elseif level == "error" then
            lrLogger:error(msg)
        else
            lrLogger:info(msg)
        end
    end
    local path = filePath()
    if not path then return end
    local fh = io.open(path, "a")
    if not fh then return end
    fh:write(os.date("%Y-%m-%d %H:%M:%S") .. " [" .. level .. "] " .. msg .. "\n")
    local size = fh:seek("end")
    fh:close()
    rotateIfLarge(path, size)
end

function Log.info(msg) write("info", msg) end
function Log.warn(msg) write("warn", msg) end
function Log.error(msg) write("error", msg) end

return Log
