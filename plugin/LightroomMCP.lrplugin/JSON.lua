-- Simple JSON encoder/decoder for Lightroom
local JSON = {}

local SHORT_ESCAPES = {
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
}

-- Control characters are illegal raw inside a JSON string, so anything without
-- a short escape has to go out as \u00XX. Emitting them raw produced responses
-- the MCP server could not parse.
local function escapeString(s)
    local escaped = s:gsub('[\\"]', '\\%0'):gsub('%c', function(c)
        return SHORT_ESCAPES[c] or string.format('\\u%04x', c:byte())
    end)
    return escaped
end

-- Lightroom runs Lua 5.1: no utf8 library, so encode the code point by hand.
local function codepointToUtf8(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + (math.floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40))
    end
    return string.char(
        0xF0 + math.floor(cp / 0x40000),
        0x80 + (math.floor(cp / 0x1000) % 0x40),
        0x80 + (math.floor(cp / 0x40) % 0x40),
        0x80 + (cp % 0x40))
end

-- Reads one \uXXXX escape at `pos` (which points at the backslash), pairing a
-- high surrogate with the low surrogate that follows. A lone surrogate becomes
-- U+FFFD rather than an error: JSON.stringify emits those for unpaired code
-- units, and erroring would drop the whole request.
local function decodeUnicodeEscape(str, pos)
    local hex = str:sub(pos + 2, pos + 5)
    if not hex:match('^%x%x%x%x$') then
        error('Invalid unicode escape: \\u' .. hex)
    end
    local cp = tonumber(hex, 16)
    local nextPos = pos + 6

    if cp >= 0xD800 and cp <= 0xDBFF then
        if str:sub(nextPos, nextPos + 1) == '\\u' then
            local lowHex = str:sub(nextPos + 2, nextPos + 5)
            local low = lowHex:match('^%x%x%x%x$') and tonumber(lowHex, 16)
            if low and low >= 0xDC00 and low <= 0xDFFF then
                cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
                nextPos = nextPos + 6
            else
                cp = 0xFFFD
            end
        else
            cp = 0xFFFD
        end
    elseif cp >= 0xDC00 and cp <= 0xDFFF then
        cp = 0xFFFD
    end

    return codepointToUtf8(cp), nextPos
end

function JSON:encode(obj)
    local function encode_value(v)
        local t = type(v)
        if t == "string" then
            return '"' .. escapeString(v) .. '"'
        elseif t == "number" or t == "boolean" then
            return tostring(v)
        elseif t == "table" then
            -- An empty Lua table is ambiguous. Encoding it as {} broke every
            -- client iterating an empty result list (changes.map is not a
            -- function); an empty object rendered as [] is harmless by
            -- comparison, so empty means array here.
            local is_array = next(v) == nil or #v > 0
            if is_array then
                local values = {}
                for i, item in ipairs(v) do
                    table.insert(values, encode_value(item))
                end
                return "[" .. table.concat(values, ",") .. "]"
            else
                local key_value_pairs = {}
                for k, val in pairs(v) do
                    table.insert(key_value_pairs, encode_value(tostring(k)) .. ":" .. encode_value(val))
                end
                return "{" .. table.concat(key_value_pairs, ",") .. "}"
            end
        elseif t == "nil" then
            return "null"
        else
            return '"' .. tostring(v) .. '"'
        end
    end
    return encode_value(obj)
end

function JSON:decode(str)
    local pos = 1

    local function skip_whitespace()
        while pos <= #str and str:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
    end

    local function decode_value()
        skip_whitespace()
        local char = str:sub(pos, pos)

        if char == '"' then
            -- String
            pos = pos + 1
            local chars = {}
            while pos <= #str do
                local current = str:sub(pos, pos)
                if current == '"' then
                    pos = pos + 1
                    return table.concat(chars)
                elseif current == '\\' then
                    local escaped = str:sub(pos + 1, pos + 1)
                    if escaped == 'u' then
                        local text, nextPos = decodeUnicodeEscape(str, pos)
                        table.insert(chars, text)
                        pos = nextPos
                    else
                        if escaped == '"' or escaped == '\\' or escaped == '/' then
                            table.insert(chars, escaped)
                        elseif escaped == 'n' then
                            table.insert(chars, '\n')
                        elseif escaped == 'r' then
                            table.insert(chars, '\r')
                        elseif escaped == 't' then
                            table.insert(chars, '\t')
                        elseif escaped == 'b' then
                            table.insert(chars, string.char(8))
                        elseif escaped == 'f' then
                            table.insert(chars, string.char(12))
                        else
                            error("Invalid escape sequence: \\" .. tostring(escaped))
                        end
                        pos = pos + 2
                    end
                else
                    table.insert(chars, current)
                    pos = pos + 1
                end
            end
            error("Unterminated string")
        elseif char == '{' then
            -- Object
            pos = pos + 1
            local obj = {}
            skip_whitespace()
            if str:sub(pos, pos) == '}' then
                pos = pos + 1
                return obj
            end
            while true do
                skip_whitespace()
                local key = decode_value()
                skip_whitespace()
                if str:sub(pos, pos) ~= ':' then
                    error("Expected ':'")
                end
                pos = pos + 1
                local value = decode_value()
                obj[key] = value
                skip_whitespace()
                char = str:sub(pos, pos)
                if char == '}' then
                    pos = pos + 1
                    break
                elseif char == ',' then
                    pos = pos + 1
                else
                    error("Expected ',' or '}'")
                end
            end
            return obj
        elseif char == '[' then
            -- Array
            pos = pos + 1
            local arr = {}
            skip_whitespace()
            if str:sub(pos, pos) == ']' then
                pos = pos + 1
                return arr
            end
            while true do
                local value = decode_value()
                table.insert(arr, value)
                skip_whitespace()
                char = str:sub(pos, pos)
                if char == ']' then
                    pos = pos + 1
                    break
                elseif char == ',' then
                    pos = pos + 1
                else
                    error("Expected ',' or ']'")
                end
            end
            return arr
        elseif char == 't' and str:sub(pos, pos + 3) == 'true' then
            pos = pos + 4
            return true
        elseif char == 'f' and str:sub(pos, pos + 4) == 'false' then
            pos = pos + 5
            return false
        elseif char == 'n' and str:sub(pos, pos + 3) == 'null' then
            pos = pos + 4
            return nil
        elseif char:match("[%-0-9]") then
            -- Number
            local start = pos
            if char == '-' then
                pos = pos + 1
            end
            while pos <= #str and str:sub(pos, pos):match("[0-9]") do
                pos = pos + 1
            end
            if pos <= #str and str:sub(pos, pos) == '.' then
                pos = pos + 1
                while pos <= #str and str:sub(pos, pos):match("[0-9]") do
                    pos = pos + 1
                end
            end
            -- Exponent form is core JSON and JSON.stringify emits it for
            -- magnitudes past 1e21. Without this the scanner stopped at the
            -- 'e', and the whole request failed to decode.
            local exponent = str:sub(pos, pos)
            if exponent == 'e' or exponent == 'E' then
                pos = pos + 1
                local sign = str:sub(pos, pos)
                if sign == '+' or sign == '-' then
                    pos = pos + 1
                end
                while str:sub(pos, pos):match("[0-9]") do
                    pos = pos + 1
                end
            end
            -- tonumber returns nil for a malformed number such as "1e", "1e+"
            -- or a lone "-". Returning that nil would drop the field silently
            -- and read as null; a malformed number is a parse error.
            local numberText = str:sub(start, pos - 1)
            local value = tonumber(numberText)
            if value == nil then
                error("Invalid number: " .. numberText)
            end
            return value
        else
            error("Unexpected character: " .. char)
        end
    end

    return decode_value()
end

return JSON
