local RadialEllipse = {}

local function formOf(semiAlong, semiAcross, degrees, centerX, centerY)
    local radians = math.rad(degrees)
    local cosine, sine = math.cos(radians), math.sin(radians)
    local alongWeight, acrossWeight = 1 / (semiAlong * semiAlong), 1 / (semiAcross * semiAcross)
    return {
        centerX = centerX,
        centerY = centerY,
        xx = cosine * cosine * alongWeight + sine * sine * acrossWeight,
        yy = sine * sine * alongWeight + cosine * cosine * acrossWeight,
        xy = cosine * sine * (alongWeight - acrossWeight),
    }
end

function RadialEllipse.ofGeometry(geometry, aspect)
    return formOf(geometry.width / 2 * aspect, geometry.height / 2, geometry.rotation,
        geometry.center.x, geometry.center.y)
end

function RadialEllipse.ofComponent(component, aspect)
    local boxHalfWidth = (component.Right - component.Left) / 2 * aspect
    local boxHalfHeight = (component.Bottom - component.Top) / 2
    local radians = math.rad(component.Angle)
    local cosine, sine = math.cos(radians), math.sin(radians)
    return formOf(boxHalfWidth * cosine + boxHalfHeight * sine, boxHalfHeight * cosine - boxHalfWidth * sine,
        component.Angle, (component.Left + component.Right) / 2, (component.Top + component.Bottom) / 2)
end

function RadialEllipse.differenceBetween(left, right)
    local worst = 0
    for _, field in ipairs({ "centerX", "centerY", "xx", "yy", "xy" }) do
        local scale = field:sub(1, 6) == "center" and 1 or math.max(math.abs(left[field]), math.abs(right[field]), 1)
        worst = math.max(worst, math.abs(left[field] - right[field]) / scale)
    end
    return worst
end

return RadialEllipse
