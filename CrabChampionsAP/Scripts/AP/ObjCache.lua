-- AP/ObjCache.lua
-- Remembers the objects a timer looks up, so it doesn't scan the game's whole object list on every tick.
--
-- FindAllOf walks every object the game has, a few milliseconds each time, on the game thread. Timers that ask for
-- the same player, game state or HUD four times a second turned that into visible stutter. A getter made here
-- scans only when its answer is missing, no longer valid, or older than `ttl` seconds, so a replaced object
-- (new run, new level) is still picked up within a moment.

local M = {}

local getters = setmetatable({}, { __mode = "k" })   -- every getter made here, so clear_all() reaches them

local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

--- A getter for the live objects of `class` (a list, empty when there are none).
--- `accept(o)` (optional) filters them; `ttl` (seconds, default 2) is how long an answer is trusted.
function M.list(class, accept, ttl)
    ttl = ttl or 2
    local miss_ttl = math.min(ttl, 1)
    local cached, at = nil, -1e9
    local function scan()
        local out = {}
        local ok, all = pcall(FindAllOf, class)
        if ok and type(all) == "table" then
            for _, o in ipairs(all) do
                if valid(o) and (accept == nil or accept(o)) then out[#out + 1] = o end
            end
        end
        cached, at = out, os.clock()
        return out
    end
    local function get()
        if cached then
            local age = os.clock() - at
            if #cached == 0 then
                if age >= 0 and age < miss_ttl then return cached end
            elseif age >= 0 and age < ttl then
                local ok = true
                for i = 1, #cached do
                    if not valid(cached[i]) then ok = false break end
                end
                if ok then return cached end
            end
        end
        return scan()
    end
    getters[get] = function() cached = nil end
    return get
end

--- A getter for the first live object of `class` (nil when there is none).
function M.first(class, accept, ttl)
    local list = M.list(class, accept, ttl)
    local get = function() return list()[1] end
    getters[get] = function() M.clear(list) end
    return get
end

--- Forget what a getter made by list/first has remembered.
function M.clear(get)
    local f = getters[get]
    if f then f() end
end

--- Forget everything (level change).
function M.clear_all()
    for _, f in pairs(getters) do f() end
end

return M
