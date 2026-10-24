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

local function axisMovesOf(toStored)
    local originX, originY = toStored(0, 0)
    local acrossX, acrossY = toStored(1, 0)
    local downX, downY = toStored(0, 1)
    return {
        originX = originX,
        originY = originY,
        acrossX = acrossX - originX,
        acrossY = acrossY - originY,
        downX = downX - originX,
        downY = downY - originY,
    }
end

local function displayedFromStoredOf(moves)
    return function(x, y)
        local offsetX, offsetY = x - moves.originX, y - moves.originY
        return offsetX * moves.acrossX + offsetY * moves.acrossY, offsetX * moves.downX + offsetY * moves.downY
    end
end

function ImageFrame.fromOrientation(orientation)
    local toStored = type(orientation) == "string" and STORED_FROM_DISPLAYED[orientation] or nil
    if not toStored then
        error(string.format("The photo reports the orientation %s, which this tool cannot map to the stored"
            .. " mask frame, so nothing was written", tostring(orientation)), 0)
    end
    local moves = axisMovesOf(toStored)
    local swapsAxes = moves.acrossX == 0
    local reversesTurnDirection = moves.acrossX * moves.downY - moves.downX * moves.acrossY < 0
    return {
        orientation = orientation,
        isNormal = orientation == NORMAL_ORIENTATION,
        toStored = toStored,
        toDisplayed = displayedFromStoredOf(moves),
        swapsAxes = swapsAxes,
        reversesTurnDirection = reversesTurnDirection,
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
