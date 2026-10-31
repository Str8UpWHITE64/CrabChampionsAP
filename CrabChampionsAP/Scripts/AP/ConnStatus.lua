-- AP/ConnStatus.lua
-- Plain-word connection messages and the connect timeout for the connection window.
-- No game calls in here, so tools/test_connstatus.py can run it on its own.

local ConnStatus = {}

--- Seconds to wait for the slot to connect before giving up.
ConnStatus.CONNECT_TIMEOUT = 10

-- Server refusal codes (Archipelago "ConnectionRefused" errors) in plain words.
local REFUSALS = {
    InvalidSlot = "Slot name not found on this server. Check the spelling (it is case sensitive).",
    InvalidGame = "That slot is for a different game.",
    InvalidPassword = "Wrong password for this server.",
    IncompatibleVersion = "The server does not accept this mod's version.",
    InvalidItemsHandling = "The server did not accept the mod's item settings.",
}

--- The sentence to show for a disconnect or refusal reason.
--- Accepts "Refused: InvalidSlot", "InvalidSlot, InvalidPassword", a plain message, or nil.
function ConnStatus.friendly(reason)
    if reason == nil or reason == "" then return "" end
    reason = tostring(reason):gsub("^Refused:%s*", "")
    for code in reason:gmatch("[%w_]+") do
        if REFUSALS[code] then return REFUSALS[code] end
    end
    if reason:find("^%u[%w_]*$") then
        return "The server refused the connection (" .. reason .. ")."
    end
    return reason   -- already a sentence (ID layout mismatch, timeout text...)
end

--- A short form for the small status label.
function ConnStatus.short(reason)
    local f = ConnStatus.friendly(reason)
    if f == "" then return "" end
    if f:find("^Slot name not found") then return "slot not found" end
    if f:find("^Wrong password") then return "wrong password" end
    if f:find("^That slot is for") then return "wrong game" end
    if f:find("^Could not reach") then return "server unreachable" end
    if f:find("seed needs ID layout") then return "mod version mismatch" end
    if #f > 40 then return f:sub(1, 37) .. "..." end
    return f
end

--- The message when the server never answered.
function ConnStatus.timeout_message(server, limit)
    return "Could not reach the server at " .. tostring(server or "?")
        .. " within " .. tostring(limit or ConnStatus.CONNECT_TIMEOUT)
        .. " seconds. Check the address and that the server is running."
end

--- True once `since` (a clock reading) is older than the limit.
function ConnStatus.timed_out(since, now, limit)
    if since == nil or now == nil then return false end
    return (now - since) >= (limit or ConnStatus.CONNECT_TIMEOUT)
end

--- The connected-details text for the panel. `d` has server, slot, seed, items, checked (any may be nil).
function ConnStatus.info_text(d)
    if not d then return "" end
    local lines = {
        "Slot: " .. tostring(d.slot or "?") .. "    Seed: " .. tostring(d.seed or "?"),
        "Server: " .. tostring(d.server or "?"),
        "Items received: " .. tostring(d.items or 0) .. "    Locations checked: " .. tostring(d.checked or 0),
    }
    return table.concat(lines, "\n")
end

--- One short line for the title strip: "server - N items - N checks".
function ConnStatus.strip_text(d)
    if not d then return "" end
    return tostring(d.server or "?") .. "  \xC2\xB7  " .. tostring(d.items or 0) .. " items  \xC2\xB7  "
        .. tostring(d.checked or 0) .. " checks"
end

--- The warning for a UE4SS-settings.ini whose HookLoadMap isn't 0, or nil when it is.
--- UE4SS hooks LoadMap when the line is missing, so a missing line warns too.
function ConnStatus.settings_warning(ini_text)
    if type(ini_text) ~= "string" then return nil end
    local value = nil
    for line in (ini_text .. "\n"):gmatch("([^\n]*)\n") do
        local v = line:match("^%s*HookLoadMap%s*=%s*([^%s;]*)")
        if v then value = v end
    end
    if value == "0" then return nil end
    return "UE4SS-settings.ini has HookLoadMap "
        .. (value and ("= " .. value) or "missing")
        .. ", which can crash the game while it loads. Replace it with the"
        .. " UE4SS-settings.ini from the mod's release."
end

--- Read the settings file (path relative to the game exe) and return its warning, or nil.
--- Says nothing when the file can't be read.
function ConnStatus.read_settings_warning(path)
    local ok, text = pcall(function()
        local f = io.open(path or "UE4SS-settings.ini", "r")
        if not f then return nil end
        local t = f:read("*a")
        f:close()
        return t
    end)
    if not ok or type(text) ~= "string" then return nil end
    return ConnStatus.settings_warning(text)
end

return ConnStatus
