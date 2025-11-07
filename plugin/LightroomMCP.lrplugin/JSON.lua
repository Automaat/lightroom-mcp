-- Simple JSON encoder/decoder for Lightroom
local JSON = {}

function JSON:encode(obj)
    local function encode_value(v)
        local t = type(v)
        if t == "string" then
            return '"' .. v:gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
        elseif t == "number" or t == "boolean" then
            return tostring(v)
        elseif t == "table" then
            local is_array = #v > 0
            if is_array then
                local values = {}
                for i, item in ipairs(v) do
                    table.insert(values, encode_value(item))
                end
                return "[" .. table.concat(values, ",") .. "]"
            else
                local pairs = {}
                for k, val in pairs(v) do
                    table.insert(pairs, encode_value(tostring(k)) .. ":" .. encode_value(val))
                end
                return "{" .. table.concat(pairs, ",") .. "}"
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
            local start = pos
            while pos <= #str and str:sub(pos, pos) ~= '"' do
                if str:sub(pos, pos) == '\\' then
                    pos = pos + 2
                else
                    pos = pos + 1
                end
            end
            local value = str:sub(start, pos - 1)
            value = value:gsub('\\n', '\n'):gsub('\\r', '\r'):gsub('\\t', '\t'):gsub('\\"', '"')
            pos = pos + 1
            return value
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
            return tonumber(str:sub(start, pos - 1))
        else
            error("Unexpected character: " .. char)
        end
    end

    return decode_value()
end

return JSON
