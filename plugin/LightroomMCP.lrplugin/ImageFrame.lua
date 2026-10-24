local Log = require 'Log'

local ImageFrame = {}

local NORMAL_ORIENTATION = "AB"

local STORED_FROM_DISPLAYED = {
    AB = function(u, v) return u, v end,
    BA = function(u, v) return 1 - u, v end,
    CD = function(u, v) return 1 - u, 1 - v end,
    DC = function(u, v) return u, 1 - v end,
    CB = function(u, v) return v, u end,
    BC = function(u, v) return v, 1 - u end,
    AD = function(u, v) return 1 - v, 1 - u end,
    DA = function(u, v) return 1 - v, u end,
}

function ImageFrame.fromOrientation(orientation)
    local toStored = type(orientation) == "string" and STORED_FROM_DISPLAYED[orientation] or nil
    if not toStored then
        error(string.format("The photo reports the orientation %s, which this tool cannot map to the stored"
            .. " mask frame, so nothing was written", tostring(orientation)), 0)
    end
    return {
        orientation = orientation,
        isNormal = orientation == NORMAL_ORIENTATION,
        toStored = toStored,
    }
end

function ImageFrame.forPhoto(catalog, photo)
    local orientation
    catalog:withReadAccessDo(function()
        orientation = photo:getRawMetadata("orientation")
    end)
    Log.info("Photo " .. tostring(photo.localIdentifier) .. " reports orientation " .. tostring(orientation))
    return ImageFrame.fromOrientation(orientation)
end

return ImageFrame
