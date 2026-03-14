-- AP/APConfig.lua
-- Loads ap_config.json from the mod directory
-- Includes a minimal JSON decoder (no external dependencies)

local APConfig = {}

local DEFAULTS = {
    server = "localhost:38281",
    slot = "",
    password = "",
    game = "Crab Champions",
    uuid = "",
    tags = { "AP" },
    items_handling = 7,
}

-- ---------------------------------------------------------------
-- Minimal JSON decoder
-- ---------------------------------------------------------------
local function skip_ws(s, i)
    return s:match("^%s*()", i)
end

local function decode_string(s, i)
    -- skip opening quote
    i = i + 1
    local parts = {}
    while i <= #s do
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(parts), i + 1
        elseif c == '\\' then
            i = i + 1
            local esc = s:sub(i, i)
            if esc == '"' or esc == '\\' or esc == '/' then
                parts[#parts + 1] = esc
            elseif esc == 'n' then parts[#parts + 1] = '\n'
            elseif esc == 't' then parts[#parts + 1] = '\t'
            elseif esc == 'r' then parts[#parts + 1] = '\r'
            else parts[#parts + 1] = esc
            end
        else
            parts[#parts + 1] = c
        end
        i = i + 1
    end
    error("unterminated string")
end

local decode_value -- forward declaration

local function decode_array(s, i)
    i = i + 1 -- skip [
    i = skip_ws(s, i)
    local arr = {}
    if s:sub(i, i) == ']' then return arr, i + 1 end
    while true do
        local val
        val, i = decode_value(s, i)
        arr[#arr + 1] = val
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == ']' then return arr, i + 1 end
        if c == ',' then i = skip_ws(s, i + 1) end
    end
end

local function decode_object(s, i)
    i = i + 1 -- skip {
    i = skip_ws(s, i)
    local obj = {}
    if s:sub(i, i) == '}' then return obj, i + 1 end
    while true do
        -- key
        if s:sub(i, i) ~= '"' then error("expected string key at " .. i) end
        local key
        key, i = decode_string(s, i)
        i = skip_ws(s, i)
        if s:sub(i, i) ~= ':' then error("expected ':' at " .. i) end
        i = skip_ws(s, i + 1)
        -- value
        local val
        val, i = decode_value(s, i)
        obj[key] = val
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == '}' then return obj, i + 1 end
        if c == ',' then i = skip_ws(s, i + 1) end
    end
end

decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '"' then return decode_string(s, i)
    elseif c == '{' then return decode_object(s, i)
    elseif c == '[' then return decode_array(s, i)
    elseif c == 't' then return true, i + 4   -- true
    elseif c == 'f' then return false, i + 5   -- false
    elseif c == 'n' then return nil, i + 4     -- null
    else
        -- number
        local num_str = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
        if num_str then
            return tonumber(num_str), i + #num_str
        end
        error("unexpected character '" .. c .. "' at position " .. i)
    end
end

local function json_decode(s)
    local val, _ = decode_value(s, 1)
    return val
end

-- ---------------------------------------------------------------
-- File I/O
-- ---------------------------------------------------------------
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- Load config from a JSON file path.
--- Falls back to defaults for any missing keys.
---@param path string Absolute or relative path to ap_config.json
---@return table config
function APConfig.load(path)
    local config = {}

    local raw = read_file(path)
    if raw and raw ~= "" then
        local ok, parsed = pcall(json_decode, raw)
        if ok and type(parsed) == "table" then
            config = parsed
        else
            print("[APConfig] WARNING: Failed to parse " .. tostring(path) .. ": " .. tostring(parsed))
        end
    else
        print("[APConfig] WARNING: Config not found at " .. tostring(path) .. ", using defaults")
    end

    -- Apply defaults for missing keys
    for k, v in pairs(DEFAULTS) do
        if config[k] == nil then
            config[k] = v
        end
    end

    return config
end

return APConfig
