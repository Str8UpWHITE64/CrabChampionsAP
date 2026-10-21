-- AP/Achievements.lua
-- Keeps Steam achievements from being awarded while the mod is active.
--
-- Safety net: the client no longer raises the account rank or level (ModifierUnlock.lua unlocks the difficulty
-- modifiers at button level), but while the mod is connected every achievement write the
-- game makes is turned into a zero-progress write, which Steam ignores. Outside a connection nothing is touched.

local M = {}

-- Optional callback, called with each log message (for debug tools).
M.on_event = nil
local ring = {}
local function log(msg)
    msg = tostring(msg)
    print("[CrabAP-Achievements] " .. msg)
    ring[#ring + 1] = msg
    if #ring > 40 then table.remove(ring, 1) end
    if M.on_event then pcall(M.on_event, "achievement_log", { msg = msg }) end
end

function M.recent_log() return ring end

-- Hooked achievement writers: path -> index of the progress parameter after Context.
-- WriteAchievementProgress(WorldContextObject, PlayerController, AchievementName, Progress, UserTag)
M.TARGETS = {
    ["/Script/OnlineSubsystemUtils.AchievementWriteCallbackProxy:WriteAchievementProgress"] = { name = 4, progress = 5 },
    ["/Script/Engine.AchievementWriteCallbackProxy:WriteAchievementProgress"] = { name = 4, progress = 5 },
}

local flag = false
M.also_active = nil     -- optional function() -> bool, e.g. "the AP client is connected"
local stats = { blocked = 0, passed = 0, failed = 0 }
local installed = {}    -- path -> true

function M.set_active(on)
    on = on and true or false
    if on ~= flag then log(on and "Achievement block ON" or "Achievement block OFF") end
    flag = on
end

function M.is_active()
    if flag then return true end
    if M.also_active then
        local ok, v = pcall(M.also_active)
        if ok and v then return true end
    end
    return false
end

function M.stats() return { blocked = stats.blocked, passed = stats.passed, failed = stats.failed } end

function M.installed()
    local out = {}
    for p in pairs(installed) do out[#out + 1] = p end
    table.sort(out)
    return out
end

local function read_text(p)
    local ok, v = pcall(function()
        local x = p:get()
        if type(x) == "string" then return x end
        return x:ToString()
    end)
    if ok then return tostring(v) end
    return "?"
end

local function read_num(p)
    local ok, v = pcall(function() return p:get() end)
    if ok and type(v) == "number" then return v end
    return nil
end

--- Pre-hook body. `params` are the hook's RemoteUnrealParams after Context.
function M.handle(path, params)
    local spec = M.TARGETS[path] or { name = 4, progress = 5 }
    local name = params[spec.name - 1] and read_text(params[spec.name - 1]) or "?"
    local pp = params[spec.progress - 1]
    local progress = pp and read_num(pp)
    if not M.is_active() then
        stats.passed = stats.passed + 1
        log(("Achievement write passed (block off): %s progress=%s"):format(name, tostring(progress)))
        return false
    end
    local done = false
    if pp then done = pcall(function() pp:set(0.0) end) end
    if done then
        stats.blocked = stats.blocked + 1
        log(("Achievement write BLOCKED: %s progress=%s -> 0"):format(name, tostring(progress)))
    else
        stats.failed = stats.failed + 1
        log(("Achievement write NOT blocked, could not change the call: %s progress=%s"):format(name, tostring(progress)))
    end
    return done
end

local function try_hook(path)
    if installed[path] then return true end
    local ok = pcall(function()
        RegisterHook(path, function(Context, ...)
            local params = { ... }
            local ok2, err = pcall(M.handle, path, params)
            if not ok2 then log("hook error: " .. tostring(err)) end
        end)
    end)
    if ok then
        installed[path] = true
        log("Hooked " .. path)
    end
    return ok
end

--- Hook every known writer. The game's Online Subsystem module may load after the mod, so retry for a while.
function M.install()
    local function attempt()
        for path in pairs(M.TARGETS) do try_hook(path) end
        return next(installed) ~= nil
    end
    if attempt() then return end
    if type(LoopAsync) ~= "function" then return end
    local tries = 0
    LoopAsync(2000, function()
        tries = tries + 1
        if attempt() then return true end
        if tries >= 60 then
            log("No achievement writer could be hooked; achievements are NOT blocked")
            return true
        end
        return false
    end)
end

return M
