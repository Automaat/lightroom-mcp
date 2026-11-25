-- Guided Upright guides as Lightroom stores them in develop settings.
--
-- A guide is UprightFourSegments_<i> = "x1,y1,x2,y2": the two ends of a line
-- normalized 0-1 in the unrotated (stored) frame of the photo, the same frame
-- as mask geometry, before any Transform or crop. UprightFourSegmentsCount
-- says how many are in use; PerspectiveUpright 5 is Guided mode, and
-- Lightroom computes the matching UprightTransform_5 matrix itself (live check
-- on LrC 16.0.1 against guides drawn by hand in Develop).
local UprightGuides = {}

UprightGuides.GUIDED_MODE = 5
UprightGuides.MIN_GUIDES = 2
UprightGuides.MAX_GUIDES = 4
UprightGuides.MIN_LENGTH = 0.02
UprightGuides.TOLERANCE = 1e-6
UprightGuides.LINE_TOLERANCE = 1e-6
UprightGuides.TRANSFORM_KEY = "UprightTransform_5"

local function segmentKey(index)
    return "UprightFourSegments_" .. tostring(index - 1)
end
UprightGuides.segmentKey = segmentKey

local function close(a, b, tolerance)
    -- false for NaN, unlike a > tolerance test
    return math.abs(a - b) <= tolerance
end

local function requireOnlyKeys(value, allowed, name)
    for key in pairs(value) do
        if not allowed[key] then
            error(string.format("%s has unknown property %s", name, tostring(key)), 0)
        end
    end
end

local POINT_KEYS = { x = true, y = true }
local GUIDE_KEYS = { start = true, ["end"] = true }

local function requirePoint(point, name)
    if type(point) ~= "table" then
        error(name .. " must be an object with x and y", 0)
    end
    requireOnlyKeys(point, POINT_KEYS, name)
    local x, y = point.x, point.y
    if type(x) ~= "number" or type(y) ~= "number" or x ~= x or y ~= y then
        error(name .. " needs numeric x and y", 0)
    end
    if x < 0 or x > 1 or y < 0 or y > 1 then
        error(name .. " must lie within 0 to 1", 0)
    end
    return x, y
end

-- Validates the tool argument and returns guides as { x1, y1, x2, y2 } in the
-- displayed frame.
function UprightGuides.parseGuides(guides)
    if type(guides) ~= "table" then
        error("guides must be an array of 2 to 4 guides", 0)
    end
    local count, seen = #guides, 0
    for key in pairs(guides) do
        if type(key) ~= "number" or key < 1 or key > count or key % 1 ~= 0 then
            error("guides must be an array of 2 to 4 guides", 0)
        end
        seen = seen + 1
    end
    -- # of an array with holes can count past them; ipairs below would not
    if seen ~= count then
        error("guides must be an array of 2 to 4 guides", 0)
    end
    if count < UprightGuides.MIN_GUIDES or count > UprightGuides.MAX_GUIDES then
        error(string.format("guides must hold %d to %d guides, got %d",
            UprightGuides.MIN_GUIDES, UprightGuides.MAX_GUIDES, count), 0)
    end
    local parsed = {}
    for i, guide in ipairs(guides) do
        local name = "guides." .. tostring(i - 1)
        if type(guide) ~= "table" then
            error(name .. " must be an object with start and end", 0)
        end
        requireOnlyKeys(guide, GUIDE_KEYS, name)
        local x1, y1 = requirePoint(guide.start, name .. ".start")
        local x2, y2 = requirePoint(guide["end"], name .. ".end")
        local dx, dy = x2 - x1, y2 - y1
        if math.sqrt(dx * dx + dy * dy) < UprightGuides.MIN_LENGTH then
            error(string.format("%s is shorter than %.2f of the frame; draw it along a longer stretch of the edge",
                name, UprightGuides.MIN_LENGTH), 0)
        end
        parsed[i] = { x1, y1, x2, y2 }
    end
    return parsed
end

function UprightGuides.toStored(frame, guides)
    local stored = {}
    for i, guide in ipairs(guides) do
        local x1, y1 = frame.toStored(guide[1], guide[2])
        local x2, y2 = frame.toStored(guide[3], guide[4])
        stored[i] = { x1, y1, x2, y2 }
    end
    return stored
end

function UprightGuides.format(segment)
    return string.format("%.9f,%.9f,%.9f,%.9f", segment[1], segment[2], segment[3], segment[4])
end

function UprightGuides.parse(text)
    if type(text) ~= "string" then return nil end
    local values = {}
    for part in text:gmatch("[^,]+") do
        local value = tonumber(part)
        if value == nil or value ~= value or value == math.huge or value == -math.huge then return nil end
        values[#values + 1] = value
    end
    if #values ~= 4 then return nil end
    return values
end

-- Develop settings that turn on Guided Upright with these stored guides.
function UprightGuides.settingsFor(stored)
    local settings = {
        PerspectiveUpright = UprightGuides.GUIDED_MODE,
        UprightFourSegmentsCount = #stored,
    }
    for i, segment in ipairs(stored) do
        settings[segmentKey(i)] = UprightGuides.format(segment)
    end
    return settings
end

-- The Upright keys a write can change, copied from saved settings so a failed
-- write can put them back.
function UprightGuides.snapshot(settings)
    settings = settings or {}
    local saved = {
        PerspectiveUpright = settings.PerspectiveUpright or 0,
        UprightFourSegmentsCount = settings.UprightFourSegmentsCount or 0,
    }
    for i = 1, UprightGuides.MAX_GUIDES do
        saved[segmentKey(i)] = settings[segmentKey(i)]
    end
    return saved
end

-- Differences between the guides written and the settings read back.
function UprightGuides.problems(stored, settings)
    settings = settings or {}
    local problems = {}
    if settings.PerspectiveUpright ~= UprightGuides.GUIDED_MODE then
        problems[#problems + 1] = string.format("Upright mode reads back as %s, not Guided",
            tostring(settings.PerspectiveUpright))
    end
    if settings.UprightFourSegmentsCount ~= #stored then
        problems[#problems + 1] = string.format("guide count reads back as %s, not %d",
            tostring(settings.UprightFourSegmentsCount), #stored)
    end
    for i, segment in ipairs(stored) do
        local actual = UprightGuides.parse(settings[segmentKey(i)])
        if actual == nil then
            problems[#problems + 1] = string.format("guide %d is missing", i)
        else
            for k = 1, 4 do
                if not close(actual[k], segment[k], UprightGuides.TOLERANCE) then
                    problems[#problems + 1] = string.format("guide %d reads back as %s", i,
                        tostring(settings[segmentKey(i)]))
                    break
                end
            end
        end
    end
    return problems
end

-- The guides in use in saved settings, parsed; nil when one does not parse.
function UprightGuides.guidesIn(settings)
    local count = settings and settings.UprightFourSegmentsCount
    if type(count) ~= "number" or count < 1 then return {} end
    local guides = {}
    for i = 1, math.min(count, UprightGuides.MAX_GUIDES) do
        local segment = UprightGuides.parse(settings[segmentKey(i)])
        if segment == nil then return nil end
        guides[i] = segment
    end
    return guides
end

local function onLineOf(segment, x, y)
    local dx, dy = segment[3] - segment[1], segment[4] - segment[2]
    local length = math.sqrt(dx * dx + dy * dy)
    if length == 0 then return false end
    return math.abs((x - segment[1]) * dy - (y - segment[2]) * dx) / length <= UprightGuides.LINE_TOLERANCE
end

-- True when every new guide lies on the line of a different current guide, in
-- any order or direction: Lightroom then computes the same Guided matrix.
function UprightGuides.sameLines(stored, settings)
    local current = UprightGuides.guidesIn(settings)
    if current == nil or #current ~= #stored then return false end
    local used = {}
    for _, segment in ipairs(stored) do
        local matched = false
        for j, line in ipairs(current) do
            if not used[j] and onLineOf(line, segment[1], segment[2]) and onLineOf(line, segment[3], segment[4]) then
                used[j], matched = true, true
                break
            end
        end
        if not matched then return false end
    end
    return true
end

-- Differences between a snapshot and the settings read back after restoring
-- it; guides compare as numbers, slots above the count are ignored.
function UprightGuides.restoreProblems(saved, settings)
    settings = settings or {}
    local problems = {}
    if (settings.PerspectiveUpright or 0) ~= saved.PerspectiveUpright then
        problems[#problems + 1] = string.format("Upright mode reads back as %s, not %s",
            tostring(settings.PerspectiveUpright), tostring(saved.PerspectiveUpright))
    end
    if (settings.UprightFourSegmentsCount or 0) ~= saved.UprightFourSegmentsCount then
        problems[#problems + 1] = string.format("guide count reads back as %s, not %s",
            tostring(settings.UprightFourSegmentsCount), tostring(saved.UprightFourSegmentsCount))
    end
    for i = 1, math.min(saved.UprightFourSegmentsCount, UprightGuides.MAX_GUIDES) do
        local want, got = saved[segmentKey(i)], settings[segmentKey(i)]
        local a, b = UprightGuides.parse(want), UprightGuides.parse(got)
        local same = want == got
        if a and b then
            same = true
            for k = 1, 4 do same = same and close(a[k], b[k], UprightGuides.TOLERANCE) end
        end
        if not same then
            problems[#problems + 1] = string.format("guide %d reads back as %s", i, tostring(got))
        end
    end
    return problems
end

return UprightGuides
