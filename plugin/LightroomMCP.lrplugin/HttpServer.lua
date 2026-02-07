local LrSocket = import 'LrSocket'
local LrTasks = import 'LrTasks'
local LrLogger = import 'LrLogger'
local JSON = require 'JSON'

local logger = LrLogger('LightroomMCP')

local SearchHandler = require 'HandlerSearch'
local MetadataHandler = require 'HandlerMetadata'
local CollectionsHandler = require 'HandlerCollections'
local OrganizationHandler = require 'HandlerOrganization'
local ImportHandler = require 'HandlerImport'
local ExportHandler = require 'HandlerExport'

local HttpServer = {}
local serverSocket = nil
local isRunning = false
local externalLogger = nil

local PORT = 8765

-- Set external logger
function HttpServer.setLogger(logFunc)
    externalLogger = logFunc
end

local function log(msg)
    logger:info(msg)
    if externalLogger then
        externalLogger(msg)
    end
end

-- Route handlers
local routes = {
    ["/search_photos"] = SearchHandler.searchPhotos,
    ["/get_photo_metadata"] = MetadataHandler.getPhotoMetadata,
    ["/list_collections"] = CollectionsHandler.listCollections,
    ["/create_collection"] = CollectionsHandler.createCollection,
    ["/add_to_collection"] = CollectionsHandler.addToCollection,
    ["/set_keywords"] = OrganizationHandler.setKeywords,
    ["/set_rating"] = OrganizationHandler.setRating,
    ["/import_photos"] = ImportHandler.importPhotos,
    ["/export_photos"] = ExportHandler.exportPhotos,
}

-- Parse HTTP request
local function parseRequest(requestData)
    local lines = {}
    for line in requestData:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end

    if #lines == 0 then
        return nil
    end

    -- Parse request line
    local method, path = lines[1]:match("^(%S+)%s+(%S+)")

    -- Find the JSON body (after blank line)
    local body = nil
    local blankLineFound = false
    for i = 2, #lines do
        if lines[i] == "" then
            blankLineFound = true
        elseif blankLineFound and lines[i]:match("^%s*{") then
            body = lines[i]
            break
        end
    end

    return {
        method = method,
        path = path,
        body = body
    }
end

-- Send HTTP response
local function sendResponse(socket, status, data)
    local json = JSON:encode(data)
    local response = string.format(
        "HTTP/1.1 %d OK\r\n" ..
        "Content-Type: application/json\r\n" ..
        "Content-Length: %d\r\n" ..
        "Access-Control-Allow-Origin: *\r\n" ..
        "Connection: close\r\n" ..
        "\r\n" ..
        "%s",
        status,
        #json,
        json
    )

    socket:send(response)
end

-- Handle client connection
local function handleClient(socket)
    local requestData = ""
    repeat
        local data, err = socket:receive(1024)
        if data then
            requestData = requestData .. data
        end
    until not data or requestData:find("\r\n\r\n")

    if requestData == "" then
        socket:close()
        return
    end

    local request = parseRequest(requestData)

    if not request then
        sendResponse(socket, 400, { error = "Invalid request" })
        socket:close()
        return
    end

    logger:info(string.format("Request: %s %s", request.method, request.path))

    -- Route the request
    local handler = routes[request.path]

    if not handler then
        sendResponse(socket, 404, { error = "Not found" })
        socket:close()
        return
    end

    -- Parse JSON body
    local args = {}
    if request.body then
        local success, decoded = pcall(function()
            return JSON:decode(request.body)
        end)
        if success then
            args = decoded
        end
    end

    -- Call handler
    local success, result = pcall(handler, args)

    if success then
        sendResponse(socket, 200, result)
    else
        logger:error("Handler error: " .. tostring(result))
        sendResponse(socket, 500, { error = tostring(result) })
    end

    socket:close()
end

-- Start HTTP server
function HttpServer.start(functionContext)
    log("=== HttpServer.start() called ===")
    log("PORT: " .. tostring(PORT))
    log("isRunning: " .. tostring(isRunning))
    log("Function context: " .. tostring(functionContext))
    log("Plugin: " .. tostring(_PLUGIN))

    if isRunning then
        log("HTTP server already running")
        return
    end

    if not functionContext then
        local err = "No function context provided"
        log("ERROR: " .. err)
        error(err)
    end

    log("Calling LrSocket.bind...")

    log("Attempting bind with mode='receive', port=" .. tostring(PORT))

    serverSocket = LrSocket.bind {
        functionContext = functionContext,
        plugin = _PLUGIN,
        port = PORT,
        mode = 'receive',
        onConnecting = function(socket, port)
            log(string.format("=== onConnecting callback: port %d ===", port))
            log("Socket type: " .. type(socket))
            log("Socket: " .. tostring(socket))

            -- Try to inspect socket methods
            if type(socket) == "table" then
                for k, v in pairs(socket) do
                    log("  socket." .. tostring(k) .. " = " .. tostring(v))
                end
            end

            isRunning = true
        end,
        onConnected = function(socket, port)
            log(string.format("=== onConnected callback: port %d (CLIENT CONNECTED) ===", port))

            -- Spawn new task to handle this connection
            LrTasks.startAsyncTask(function()
                log("Handling client in async task")
                handleClient(socket)
            end)
        end,
        onError = function(socket, err)
            log("=== onError callback ===")
            log("Socket error: " .. tostring(err))
            if err ~= 'timeout' then
                log("Non-timeout error: " .. tostring(err))
            end
        end,
        onClosed = function(socket)
            log("=== onClosed callback ===")
            log("HTTP server stopped")
            isRunning = false
        end,
    }

    if not serverSocket then
        log("ERROR: LrSocket.bind returned nil!")
        error("Failed to create server socket")
    end

    log("LrSocket.bind returned: " .. tostring(serverSocket))
    log("=== HttpServer.start() completed ===")
end

-- Stop HTTP server
function HttpServer.stop()
    if serverSocket then
        serverSocket:close()
        serverSocket = nil
        isRunning = false
    end
end

return HttpServer
