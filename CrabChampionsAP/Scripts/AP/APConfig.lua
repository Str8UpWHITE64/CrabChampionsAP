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

-- ---------------------------------------------------------------
-- Minimal JSON encoder
-- ---------------------------------------------------------------
local function json_encode_value(val, indent, level)
    local t = type(val)
    if t == "string" then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    elseif t == "number" then
        return tostring(val)
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "nil" then
        return "null"
    elseif t == "table" then
        level = level or 0
        local pad = indent and string.rep("  ", level + 1) or ""
        local pad_close = indent and string.rep("  ", level) or ""
        local sep = indent and ",\n" or ", "
        local nl = indent and "\n" or ""

        -- Detect array vs object
        if #val > 0 or next(val) == nil then
            -- Array (or empty table)
            local items = {}
            for _, v in ipairs(val) do
                items[#items + 1] = pad .. json_encode_value(v, indent, level + 1)
            end
            if #items == 0 then return "[]" end
            return "[" .. nl .. table.concat(items, sep) .. nl .. pad_close .. "]"
        else
            -- Object
            local items = {}
            -- Sort keys for stable output
            local keys = {}
            for k in pairs(val) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, k in ipairs(keys) do
                items[#items + 1] = pad .. '"' .. tostring(k) .. '": ' .. json_encode_value(val[k], indent, level + 1)
            end
            return "{" .. nl .. table.concat(items, sep) .. nl .. pad_close .. "}"
        end
    end
    return "null"
end

local function json_encode(val)
    return json_encode_value(val, true, 0)
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

--- Save connection details back to the config file.
--- Only writes the user-facing fields (server, slot, password).
---@param path string Path to ap_config.json
---@param server string Server address
---@param slot string Slot/player name
---@param password string Password (may be empty)
function APConfig.save(path, server, slot, password)
    -- Read existing config to preserve any extra fields
    local config = {}
    local raw = read_file(path)
    if raw and raw ~= "" then
        local ok, parsed = pcall(json_decode, raw)
        if ok and type(parsed) == "table" then
            config = parsed
        end
    end

    -- Update connection fields
    config.server = server or config.server or DEFAULTS.server
    config.slot = slot or config.slot or DEFAULTS.slot
    config.password = password or config.password or DEFAULTS.password

    -- Ensure defaults for other keys
    for k, v in pairs(DEFAULTS) do
        if config[k] == nil then
            config[k] = v
        end
    end

    -- Write back
    local json_str = json_encode(config)
    local f = io.open(path, "wb")
    if f then
        f:write(json_str .. "\n")
        f:close()
        print("[APConfig] Saved config to " .. tostring(path))
    else
        print("[APConfig] WARNING: Could not write to " .. tostring(path))
    end
end

return APConfig
