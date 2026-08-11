local json = require "lib.external.json"

-- Deterministic JSON, for the board save format.
--
-- lib/external/json.lua stays as vendored upstream code and is used here for
-- *decoding* only. Its encoder can't back a file format meant to live in git:
--
--   * it walks tables with pairs(), so key order changes between runs and a re-save
--     of an untouched board produces a diff that corresponds to no edit;
--   * it writes numbers with "%.14g", so a coordinate that picked up float noise
--     during a drag lands in the file as 100.00000000000001;
--   * it writes everything on one line, so any change diffs as the whole board.
--
-- So encoding is ours: keys sorted, numbers rounded, one value per line. The output
-- is still plain JSON -- json.decode reads it back, and so will anything else.
local Serialize = {}

-- Decimals kept on a number. World coordinates come out of pointer math as floats;
-- past this they're noise, and noise is what makes a board re-save differently than
-- it was read.
local PRECISION = 4
local SCALE = 10 ^ PRECISION

-- Past this magnitude value * SCALE stops being exactly representable, so rounding
-- would corrupt rather than tidy. Nothing on a board should ever get here.
local ROUND_LIMIT = 2 ^ 53 / SCALE

local INDENT = "  "

Serialize.PRECISION = PRECISION

-- An empty Lua table is ambiguous -- {} could be a JSON array or a JSON object -- and
-- the difference is visible to anything else that reads the file. Tables that must
-- write as an array even when empty are marked; everything else is an array only if
-- it has a positive integer length.
local arrayMarker = { __serialize = "array" }

function Serialize.array(t)
    return setmetatable(t or {}, arrayMarker)
end

local function isArray(t)
    return getmetatable(t) == arrayMarker or #t > 0
end

local function encodeNumber(value)
    if value ~= value or value == math.huge or value == -math.huge then
        error("cannot serialize the number " .. tostring(value))
    end

    local rounded = value
    if math.abs(value) < ROUND_LIMIT then
        -- Half-up on the scaled value: the same input always lands on the same
        -- output, however it was arrived at.
        rounded = math.floor(value * SCALE + 0.5) / SCALE
    end

    -- Collapses -0, which would otherwise write as "-0" and diff against a plain 0.
    if rounded == 0 then
        rounded = 0
    end

    if rounded % 1 == 0 then
        return ("%.0f"):format(rounded)
    end

    -- Trailing zeros stripped, so 100.5 doesn't write as 100.5000.
    local text = ("%." .. PRECISION .. "f"):format(rounded)
    text = text:gsub("0+$", ""):gsub("%.$", "")
    return text
end

local encodeValue

local function encodeArray(value, indent, seen)
    local inner = indent .. INDENT
    local parts = {}
    for index = 1, #value do
        parts[index] = inner .. encodeValue(value[index], inner, seen)
    end
    if #parts == 0 then
        return "[]"
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
end

local function encodeObject(value, indent, seen)
    local keys = {}
    for key in pairs(value) do
        if type(key) ~= "string" then
            error("object keys must be strings, got a " .. type(key))
        end
        keys[#keys + 1] = key
    end
    -- The whole point: same table, same bytes, every time.
    table.sort(keys)

    local inner = indent .. INDENT
    local parts = {}
    for index, key in ipairs(keys) do
        parts[index] = inner .. json.encode(key) .. ": " .. encodeValue(value[key], inner, seen)
    end
    if #parts == 0 then
        return "{}"
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

encodeValue = function(value, indent, seen)
    local valueType = type(value)

    if value == nil then
        return "null"
    elseif valueType == "boolean" then
        return tostring(value)
    elseif valueType == "number" then
        return encodeNumber(value)
    elseif valueType == "string" then
        -- Escaping is the one part of upstream's encoder worth reusing verbatim.
        return json.encode(value)
    elseif valueType ~= "table" then
        error("cannot serialize a " .. valueType)
    end

    if seen[value] then
        error("cannot serialize a circular reference")
    end
    seen[value] = true

    local text
    if isArray(value) then
        text = encodeArray(value, indent, seen)
    else
        text = encodeObject(value, indent, seen)
    end

    seen[value] = nil
    return text
end

-- Raises on anything JSON can't represent (a function in a props table, NaN, a
-- circular reference). Callers writing a file should pcall it: a board that can't be
-- encoded is a bug worth reporting, not worth crashing over.
function Serialize.encode(value)
    return encodeValue(value, "", {})
end

-- Returns the decoded value, or nil plus a message. Malformed input is expected --
-- it's a file off disk that anything could have written -- so it comes back as an
-- error rather than an exception.
function Serialize.decode(text)
    if type(text) ~= "string" then
        return nil, "expected a string, got " .. type(text)
    end

    local ok, result = pcall(json.decode, text)
    if not ok then
        return nil, tostring(result)
    end
    return result
end

return Serialize
