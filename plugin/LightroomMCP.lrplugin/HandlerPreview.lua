local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
local LrStringUtils = import 'LrStringUtils'
local LrTasks = import 'LrTasks'

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
function PreviewHandler.getPhotoPreview(args)
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

    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, args.photo_id)
    if not photo then
        error("Photo not found: " .. tostring(args.photo_id))
    end

    -- Wall-clock deadline across every attempt: sleeps can overshoot and the
    -- request call itself takes time, so counting sleeps undercounts.
    local deadline = LrDate.currentTime() + TIMEOUT_SECONDS
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
        if #data > MAX_BYTES then return true end
        local w, h = jpegDimensions(data)
        return w ~= nil and math.max(w, h) > MAX_EDGE
    end

    -- A smaller request makes Lightroom fall back to a smaller cached preview.
    local edge = size
    local jpeg = render(edge)
    while tooBig(jpeg) and edge > MIN_SIZE do
        edge = math.max(MIN_SIZE, math.floor(edge / 2))
        jpeg = render(edge)
    end
    if #jpeg > MAX_BYTES then
        error(string.format("Preview is %d bytes, over the %d byte limit even at size %d",
            #jpeg, MAX_BYTES, MIN_SIZE))
    end

    local width, height = jpegDimensions(jpeg)
    Log.info(string.format("Rendered preview for photo %s (%sx%s, %d bytes)",
        tostring(args.photo_id), tostring(width), tostring(height), #jpeg))

    return {
        photo_id = photo.localIdentifier,
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

return PreviewHandler
