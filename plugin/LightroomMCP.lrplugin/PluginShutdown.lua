local LrLogger = import 'LrLogger'
local HttpServer = require 'HttpServer'
local ServerState = require 'ServerState'

local logger = LrLogger('LightroomMCP')

logger:info("=== Plugin shutdown ===")
ServerState.addLog("Plugin shutting down")

HttpServer.stop()
ServerState.setRunning(false)
