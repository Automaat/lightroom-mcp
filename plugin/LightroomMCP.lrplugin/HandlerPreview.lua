local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
local LrStringUtils = import 'LrStringUtils'
local LrTasks = import 'LrTasks'

local MaskState = require 'MaskState'
local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'

local PreviewHandler = {}

-- Lightroom answers with the smallest preview it has cached that is at least
-- this big, so the image is usually larger than asked: 512 gave 855px and 1024
-- gave 1710px on a 6048px raw. 512 is enough to see what a photo shows.
local DEFAULT_SIZE = 512
local MIN_SIZE = 64
local MAX_SIZE = 2048
-- Under the server's 30s default, so a stuck render is reported as an error
-- here rather than as a bare server-side timeout.
local TIMEOUT_SECONDS = 20
local POLL_SECONDS = 0.05
-- Claude rejects images over 5 MB of base64 (3.75 MB raw). size is only a
-- minimum, so a high-resolution raw can come back bigger than that.
local MAX_BYTES = 3.5 * 1024 * 1024
-- Claude rejects images over 2000px once a request holds more than 20 images.
local MAX_EDGE = 2000
-- requestJpegThumbnail answers with a cached preview. Right after a Develop
-- change it can fail with "error loading thumb" for over 10 minutes, offer
-- only a full-size preview or a smaller interim one (live on LrC 16.0.1).
-- render = "export" renders the current settings through an export session
-- instead (about 2 s on a 61 MP raw). Lightroom records every export in the
-- photo's History, so this runs only when asked, never as a silent fallback.
local EXPORT_RENDER_HINT = '; call again with render "export" for a fresh render through an export'
    .. " (about 2 s; Lightroom lists it in the photo's History)"

-- Exporting a photo with outdated AI masks opens Lightroom's "AI Updates
-- Recommended" dialog, which blocks until dismissed.
local function hasAiMasks(catalog, photo)
    local settings
    catalog:withReadAccessDo(function() settings = photo:getDevelopSettings() end)
    return MaskState.summarize(settings).state ~= "none"
end

-- Width and height from the first start-of-frame marker, or nil if the data
-- is not a JPEG this can read. Lightroom does not report the size it chose.
local function jpegDimensions(data)
    if data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then return nil end
    local pos = 3
    while pos + 8 <= #data do
        if data:byte(pos) ~= 0xFF then return nil end
        local marker = data:byte(pos + 1)
        -- SOF0-SOF15, except DHT (C4), JPG (C8) and DAC (CC).
        if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
            local height = data:byte(pos + 5) * 256 + data:byte(pos + 6)
            local width = data:byte(pos + 7) * 256 + data:byte(pos + 8)
            return width, height
        end
        local length = data:byte(pos + 2) * 256 + data:byte(pos + 3)
        pos = pos + 2 + length
    end
    return nil
end

-- Returns a JPEG of the photo as Lightroom renders it (develop settings
-- applied, so raw files work), base64-encoded for the JSON response. The
-- server turns `image` into an MCP image block.
local function renderPreview(args, batchDeadline, byteLimit, strictDimensions)
    if not args.photo_id then
        error("photo_id is required")
    end

    local size = args.size
    if size == nil then
        size = DEFAULT_SIZE
    elseif type(size) ~= "number" or size < MIN_SIZE or size > MAX_SIZE then
        error(string.format("size must be a number between %d and %d", MIN_SIZE, MAX_SIZE))
    end
    size = math.floor(size)
    if args.render ~= nil and args.render ~= "export" then
        error('render must be "export"')
    end

    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, args.photo_id)
    if not photo then
        error("Photo not found: " .. tostring(args.photo_id))
    end

    -- Wall-clock deadline across every attempt: sleeps can overshoot and the
    -- request call itself takes time, so counting sleeps undercounts.
    local deadline = batchDeadline or (LrDate.currentTime() + TIMEOUT_SECONDS)
    byteLimit = byteLimit or MAX_BYTES
    local function render(edge)
        -- requestJpegThumbnail is asynchronous and may call back before it
        -- returns. The request object must stay referenced until the callback
        -- fires, or Lightroom can cancel it.
        local done, data, failure = false, nil, nil
        local request = photo:requestJpegThumbnail(edge, edge, function(jpegData, errorMessage)
            if done then return end
            done, data, failure = true, jpegData, errorMessage
        end)

        -- Reading `request` each pass is what keeps it alive while we wait.
        while request and not done and LrDate.currentTime() < deadline do
            LrTasks.sleep(POLL_SECONDS)
        end

        if not done then
            error(string.format("Preview not ready after %ds", TIMEOUT_SECONDS))
        end
        if not data then
            error("Preview failed: " .. tostring(failure or "no image data"))
        end
        return data
    end

    local function tooBig(data)
        if #data > byteLimit then return true end
        local w, h = jpegDimensions(data)
        return w ~= nil and math.max(w, h) > MAX_EDGE
    end

    local edge = size
    local jpeg, renderedBy
    if args.render == "export" then
        local checked, aiMasks = LrTasks.pcall(hasAiMasks, catalog, photo)
        if not checked then error("Could not read the photo's masks: " .. tostring(aiMasks), 0) end
        if aiMasks then
            error('render "export" is refused for photos with AI masks: exporting one with outdated AI'
                .. " settings opens Lightroom's AI Updates dialog, which blocks until dismissed", 0)
        end
        jpeg = require('HandlerExport').renderJpeg(photo, math.min(size, MAX_EDGE))
        renderedBy = "export"
    else
        local rendered, data = LrTasks.pcall(render, edge)
        if not rendered then
            -- Only where an export is known to help; an offline original cannot be exported.
            local message = tostring(data)
            if message:find("error loading thumb", 1, true) then message = message .. EXPORT_RENDER_HINT end
            error(message, 0)
        end
        jpeg = data
        -- A smaller request makes Lightroom fall back to a smaller cached preview,
        -- though not at every step: one cached size can answer several requests.
        while tooBig(jpeg) and edge > MIN_SIZE do
            edge = math.max(MIN_SIZE, math.floor(edge / 2))
            jpeg = render(edge)
        end
    end
    if #jpeg > byteLimit then
        error(string.format("Preview is %d bytes, over the %d byte limit even at size %d",
            #jpeg, byteLimit, MIN_SIZE) .. (renderedBy and "" or EXPORT_RENDER_HINT), 0)
    end

    local width, height = jpegDimensions(jpeg)
    if strictDimensions and (not width or not height or math.max(width, height) > MAX_EDGE) then
        error("Preview must be a JPEG with a longest edge at most 2000 pixels")
    end
    Log.info(string.format("Rendered preview for photo %s (%sx%s, %d bytes)",
        tostring(args.photo_id), tostring(width), tostring(height), #jpeg))

    return {
        photo_id = photo.localIdentifier,
        rendered_by = renderedBy,
        requested_size = size,
        width = width,
        height = height,
        bytes = #jpeg,
        image = {
            mime_type = "image/jpeg",
            data = LrStringUtils.encodeBase64(jpeg),
        },
    }
end

function PreviewHandler.getPhotoPreview(args)
    return renderPreview(args)
end

function PreviewHandler.getPhotoPreviews(args)
    if type(args.photo_ids) ~= "table" or #args.photo_ids < 1 or #args.photo_ids > 20 then
        error("photo_ids must contain between 1 and 20 photo IDs")
    end
    local deadline = LrDate.currentTime() + TIMEOUT_SECONDS
    local previews, remaining = {}, {}
    local bytes, budget = 0, 8 * 1024 * 1024
    for index, id in ipairs(args.photo_ids) do
        if LrDate.currentTime() >= deadline or bytes >= budget then
            for rest = index, #args.photo_ids do remaining[#remaining + 1] = args.photo_ids[rest] end
            break
        end
        local ok, result = LrTasks.pcall(function()
            return renderPreview({ photo_id = id, size = args.size or 256 }, deadline, math.min(MAX_BYTES, budget - bytes), true)
        end)
        -- A timed-out in-flight request is retried along with the untouched tail.
        if not ok and LrDate.currentTime() >= deadline then
            for rest = index, #args.photo_ids do remaining[#remaining + 1] = args.photo_ids[rest] end
            break
        end
        if ok then
            bytes = bytes + result.bytes
            result.requested_id = id
            previews[#previews + 1] = result
        else
            previews[#previews + 1] = { requested_id = id, error = tostring(result) }
        end
    end
    return { previews = previews, complete = #remaining == 0, remaining_ids = remaining, bytes = bytes }
end

function PreviewHandler.getPhotoStats(args)
    if type(args.photo_ids) ~= "table" or #args.photo_ids ~= 1 then
        error("The server requests one statistics preview at a time")
    end
    return PreviewHandler.getPhotoPreview({ photo_id = args.photo_ids[1], size = DEFAULT_SIZE })
end

function PreviewHandler.findDuplicateGroups(args)
    if type(args.photo_ids) ~= "table" or #args.photo_ids ~= 1 then
        error("The server requests one duplicate-group preview at a time")
    end
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, args.photo_ids[1])
    if not photo then error("Photo not found: " .. tostring(args.photo_ids[1])) end
    local captureTime
    catalog:withReadAccessDo(function()
        captureTime = photo:getRawMetadata("dateTimeOriginal")
    end)
    if type(captureTime) ~= "number" then error("No raw capture time") end
    local result = PreviewHandler.getPhotoPreview({ photo_id = photo.localIdentifier, size = MIN_SIZE })
    result.capture_time = captureTime
    return result
end

return PreviewHandler
