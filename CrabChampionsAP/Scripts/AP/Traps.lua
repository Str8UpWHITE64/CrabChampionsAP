-- AP/Traps.lua
-- Received traps and Perk Boosts.
--
-- Traps are temporary and never touch equipment: every effect is a multiplier or a one-off cut that is undone on
-- its own (timer, end of the island, or back in the lobby). Nothing is saved into the player's game save.
--
-- The server re-sends every received item on each connect. A small ledger file remembers the highest item index
-- already handled for this seed and slot, so a reconnect or a game restart never fires a trap or a boost twice.
-- Traps that arrived but have not hit yet (lobby, grace period) are saved in the same file.

local LocationData = require("AP/LocationData")

local M = {}

-- Optional callback, called with each trap message (for debug tools; the game's own log is lost on a kill).
M.on_event = nil
local ring = {}
local function log(msg)
    msg = tostring(msg)
    print("[CrabAP-Traps] " .. msg)
    ring[#ring + 1] = msg
    if #ring > 40 then table.remove(ring, 1) end
    if M.on_event then pcall(M.on_event, "trap_log", { msg = msg }) end
end

--- The last trap messages, oldest first.
function M.recent_log() return ring end

local function safe(fn, fallback)
    local ok, v = pcall(fn)
    if ok and v ~= nil then return v end
    return fallback
end

-------------------------------------------------------------
-- Settings and test seams
-------------------------------------------------------------

M.STATE_PATH = "Mods/CrabChampionsAP/Scripts/trap_state.txt"
M.TICK_MS = 250
M.MIN_GAP_S = 3               -- seconds between two trap hits

-- Replaceable by tests. Real values come from the game.
M.now = function() return os.time() end
M.game = nil                  -- set below

local ledger = { identity = nil, last = -1, boosts = 0, traps = {} }
local run = { island = nil, island_since = nil, last_hit = 0 }
local active = {}             -- kind -> { name, ops, expires, island }
local state_dirty_warned = false

-------------------------------------------------------------
-- Ledger file
-------------------------------------------------------------

local function save_ledger()
    local ok, err = pcall(function()
        local f = io.open(M.STATE_PATH, "w")
        if not f then error("cannot write " .. M.STATE_PATH) end
        f:write("identity=" .. tostring(ledger.identity) .. "\n")
        f:write("last=" .. tostring(ledger.last) .. "\n")
        f:write("boosts=" .. tostring(ledger.boosts) .. "\n")
        f:write("traps=" .. table.concat(ledger.traps, ",") .. "\n")
        f:close()
    end)
    if not ok and not state_dirty_warned then
        state_dirty_warned = true
        log("Could not save the trap ledger: " .. tostring(err))
    end
end

local function load_ledger(identity)
    ledger = { identity = identity, last = -1, boosts = 0, traps = {} }
    local ok, text = pcall(function()
        local f = io.open(M.STATE_PATH, "r")
        if not f then return nil end
        local t = f:read("*a")
        f:close()
        return t
    end)
    if not ok or not text then return end
    local saved = {}
    for k, v in text:gmatch("([%w_]+)=([^\n]*)") do saved[k] = v end
    if saved.identity ~= identity then return end   -- another seed or slot: start clean
    ledger.last = tonumber(saved.last) or -1
    ledger.boosts = tonumber(saved.boosts) or 0
    for name in tostring(saved.traps or ""):gmatch("[^,]+") do
        ledger.traps[#ledger.traps + 1] = name
    end
end

--- Handled-index watermark for the current seed and slot.
function M.watermark() return ledger.last end
function M.pending_traps() return #ledger.traps end
function M.pending_boosts() return ledger.boosts end

-------------------------------------------------------------
-- Game access (replaceable)
-------------------------------------------------------------

local function first(class)
    local ok, all = pcall(FindAllOf, class)
    if not ok or type(all) ~= "table" then return nil end
    for _, o in ipairs(all) do
        if safe(function() return o:IsValid() end, false) then return o end
    end
    return nil
end

local game = {}
M.game = game

function game.ps() return first("CrabPS") end
function game.player() return first("CrabPlayerC") end
function game.gs() return first("CrabGS") end
local function item_apply()
    local ok, m = pcall(require, "AP/ItemApply")
    return ok and m or nil
end

function game.in_lobby()
    local ia = item_apply()
    return not ia or ia.in_lobby ~= false
end

function game.island()
    local gs = game.gs()
    return gs and tonumber(safe(function() return gs.CurrentIsland end, nil)) or nil
end

--- The local crab has been eliminated (the run is over, even before the game-over screen is dismissed).
function game.eliminated()
    local p = game.player()
    return p ~= nil and safe(function() return p.bIsEliminated end, false) == true
end

function game.paused()
    local gs = game.gs()
    return gs and safe(function() return gs.bIsTimePaused end, false) == true or false
end

--- Resolve a target name to a live object.
function game.target(name)
    if name == "ps" then return game.ps() end
    local p = game.player()
    if not p then return nil end
    if name == "player" then return p end
    if name == "cmc" then return safe(function() return p.CharacterMovement end, nil) end
    return nil
end

function game.addr(obj)
    return safe(function() return obj:GetAddress() end, nil)
end

function game.get(obj, prop)
    if prop == "ActorScale" then
        local v = safe(function() return obj:GetActorScale3D() end, nil)
        return v and tonumber(safe(function() return v.X end, nil)) or nil
    end
    return tonumber(safe(function() return obj[prop] end, nil))
end

function game.set(obj, prop, value)
    if prop == "ActorScale" then
        return pcall(function() obj:SetActorScale3D({ X = value, Y = value, Z = value }) end)
    end
    return pcall(function() obj[prop] = value end)
end

function game.crystals() local ps = game.ps(); return ps and game.get(ps, "Crystals") or nil end

function game.set_crystals(n)
    local ps = game.ps()
    if not ps then return false end
    return game.set(ps, "Crystals", n)
end

--- Current and max health of the local crab, or nil when unreadable.
function game.health()
    local p = game.player()
    if not p then return nil end
    local info = safe(function() return p.HC.HealthInfo end, nil)
    if not info then return nil end
    return tonumber(safe(function() return info.CurrentHealth end, nil)),
           tonumber(safe(function() return info.CurrentMaxHealth end, nil))
end

function game.set_health(value)
    local p = game.player()
    if not p then return false end
    local info = safe(function() return p.HC.HealthInfo end, nil)
    if not info then return false end
    local ok = game.set(info, "CurrentHealth", value)
    local ps = game.ps()
    local psinfo = ps and safe(function() return ps.HealthInfo end, nil)
    if psinfo then game.set(psinfo, "CurrentHealth", value) end
    return ok
end

-------------------------------------------------------------
-- Timed effects
-------------------------------------------------------------
-- An effect is a list of ops { target, prop, factor }. The game rewrites some of these values by itself (walk speed
-- when the crab starts aiming or sprinting, damage when a perk is picked up), so every tick each running effect
-- looks at the live value: if it is not the one last written, the game has changed it, so the new value times the
-- factor is written. Undoing restores the value the game last set, unless the game already reset it.
-- An op whose object has been replaced since (a new run) is skipped on undo: the new object starts from defaults.
--
-- "ActorScale" is not a property: it reads and writes the crab's actor scale (CrabPS.ScaleMultiplier changes nothing
-- visible, SetActorScale3D does). A size perk may only change CrabPS.ScaleMultiplier and leave the actor scale to
-- the game, so an op can name a second value to watch (ops 4th and 5th fields): when that value changes by itself,
-- the op's base changes by the same ratio.

local KIND_OF = {
    ["Slowdown Trap"]       = "speed",
    ["Weak Shots Trap"]     = "damage",
    ["Grow Trap"]           = "size",
    ["Shrink Trap"]         = "size",
    ["Heavy Gravity Trap"]  = "gravity",
    ["Floaty Gravity Trap"] = "gravity",
}

M.GROW_FACTOR = 1.6
M.SHRINK_FACTOR = 0.5
M.HEAVY_FACTOR = 2.0
M.FLOATY_FACTOR = 0.4

local function ops_for(name)
    local pct_slow = (LocationData.slowdown_percent or 35) / 100
    local weak = (LocationData.weak_shots_percent or 50) / 100
    if name == "Slowdown Trap" then
        return { { "cmc", "MaxWalkSpeed", 1 - pct_slow } }
    elseif name == "Weak Shots Trap" then
        return { { "ps", "DamageMultiplier", weak } }
    elseif name == "Grow Trap" then
        return { { "player", "ActorScale", M.GROW_FACTOR, "ps", "ScaleMultiplier" } }
    elseif name == "Shrink Trap" then
        return { { "player", "ActorScale", M.SHRINK_FACTOR, "ps", "ScaleMultiplier" } }
    elseif name == "Heavy Gravity Trap" then
        return { { "cmc", "GravityScale", M.HEAVY_FACTOR } }
    elseif name == "Floaty Gravity Trap" then
        return { { "cmc", "GravityScale", M.FLOATY_FACTOR } }
    end
    return nil
end

local function close(a, b)
    return math.abs(a - b) <= 1e-4 * math.max(1, math.abs(a), math.abs(b))
end

local function read_op(op)
    local obj = game.target(op.target)
    if not obj then return nil, nil end
    return obj, game.get(obj, op.prop)
end

local function apply_ops(ops)
    local applied = {}
    for _, o in ipairs(ops) do
        local op = { target = o[1], prop = o[2], factor = o[3], wtarget = o[4], wprop = o[5] }
        local obj, cur = read_op(op)
        if cur then
            local written = cur * op.factor
            if game.set(obj, op.prop, written) then
                op.addr, op.base, op.written = game.addr(obj), cur, written
                if op.wtarget then
                    local wo = game.target(op.wtarget)
                    op.wseen = wo and game.get(wo, op.wprop) or nil
                end
                applied[#applied + 1] = op
            end
        end
    end
    return applied
end

--- Re-assert running ops whose value the game changed.
local function enforce_ops(applied)
    for _, op in ipairs(applied) do
        local obj, cur = read_op(op)
        if obj and cur and game.addr(obj) == op.addr then
            local wcur
            if op.wtarget then
                local wo = game.target(op.wtarget)
                wcur = wo and game.get(wo, op.wprop) or nil
            end
            if not close(cur, op.written) then
                -- the game wrote the value itself
                op.base = cur
                op.written = cur * op.factor
                game.set(obj, op.prop, op.written)
            elseif wcur and op.wseen and op.wseen ~= 0 and not close(wcur, op.wseen) then
                -- the game changed only the watched value: move the base by the same ratio
                op.base = op.base * wcur / op.wseen
                op.written = op.base * op.factor
                game.set(obj, op.prop, op.written)
            end
            if wcur then op.wseen = wcur end
        end
    end
end

local function undo_ops(applied)
    for _, op in ipairs(applied) do
        local obj, cur = read_op(op)
        if obj and cur and game.addr(obj) == op.addr and close(cur, op.written) then
            game.set(obj, op.prop, op.base)
        end
    end
end

local function end_effect(kind, why)
    local e = active[kind]
    if not e then return end
    enforce_ops(e.applied)
    undo_ops(e.applied)
    active[kind] = nil
    log("Trap over (" .. why .. "): " .. e.name)
end

local function end_all(why)
    for kind in pairs(active) do end_effect(kind, why) end
end

--- Names of the traps whose effect is running.
function M.active_names()
    local out = {}
    for _, e in pairs(active) do out[#out + 1] = e.name end
    table.sort(out)
    return out
end

local function start_timed(name)
    local kind = KIND_OF[name]
    local now = M.now()
    local ex = active[kind]
    if ex and ex.name == name then
        -- the same trap again: extend it
        ex.expires = (kind == "speed") and math.huge or (now + (LocationData.trap_duration or 30))
        ex.island = game.island()
        log("Trap extended: " .. name)
        return
    end
    if ex then end_effect(kind, "replaced") end
    local ops = ops_for(name)
    if not ops then return end
    local applied = apply_ops(ops)
    if #applied == 0 then log("Trap had nothing to act on: " .. name) end
    active[kind] = {
        name = name, applied = applied,
        -- Slowdown lasts for the island it hits on; the rest run on a timer.
        expires = (kind == "speed") and math.huge or (now + (LocationData.trap_duration or 30)),
        island = (kind == "speed") and game.island() or nil,
    }
    log("Trap hit: " .. name .. " (" .. #applied .. " change(s))")
end

-------------------------------------------------------------
-- One-off traps
-------------------------------------------------------------

local function hit_crystal_tax()
    local c = game.crystals()
    if not c or c <= 0 then log("Crystal Tax: no crystals to take"); return end
    local take = math.floor(c * (LocationData.crystal_tax_percent or 25) / 100)
    if take > 0 then game.set_crystals(c - take) end
    log("Crystal Tax: took " .. take .. " of " .. c)
end

local function hit_bruise()
    local cur = game.health()
    if not cur then log("Bruise Trap: health unreadable"); return end
    local cut = math.floor(cur * (LocationData.bruise_percent or 30) / 100)
    local newv = math.max(1, cur - cut)
    local ok = true
    if newv < cur then ok = game.set_health(newv) end
    log("Bruise Trap: health " .. cur .. " -> " .. newv .. (ok and "" or " (write failed)"))
end

local function hit(name)
    if name == "Crystal Tax" then hit_crystal_tax()
    elseif name == "Bruise Trap" then hit_bruise()
    elseif KIND_OF[name] then start_timed(name)
    else log("Unknown trap: " .. tostring(name)) end
end

-------------------------------------------------------------
-- Receiving
-------------------------------------------------------------

M.TRAP_NAMES = {
    ["Crystal Tax"] = true, ["Slowdown Trap"] = true, ["Weak Shots Trap"] = true, ["Bruise Trap"] = true,
    ["Grow Trap"] = true, ["Shrink Trap"] = true, ["Heavy Gravity Trap"] = true, ["Floaty Gravity Trap"] = true,
}

--- True for the items this module owns (traps and Perk Boost).
function M.owns(info)
    return info ~= nil and (M.TRAP_NAMES[info.name] == true or info.name == "Perk Boost")
end

--- Called for every received item, in index order. `identity` is seed/slot.
--- Returns true when the item belonged here (so the caller skips normal handling).
function M.on_item(info, index, identity)
    if not M.owns(info) then return false end
    if ledger.identity ~= identity then load_ledger(identity) end
    local idx = tonumber(index) or -1
    if idx <= ledger.last then return true end     -- a replay of something already handled
    ledger.last = idx
    if info.name == "Perk Boost" then
        ledger.boosts = ledger.boosts + 1
        log("Perk Boost received (" .. ledger.boosts .. " waiting)")
    else
        ledger.traps[#ledger.traps + 1] = info.name
        log("Trap received: " .. info.name .. " (" .. #ledger.traps .. " waiting)")
    end
    save_ledger()
    return true
end

-------------------------------------------------------------
-- The tick: expire effects, deliver waiting traps and boosts
-------------------------------------------------------------

local function try_boost()
    if ledger.boosts <= 0 then return end
    local ItemApply = M.item_apply and M.item_apply() or item_apply()
    if not (ItemApply and ItemApply.boost_random_perk) then return end
    local name, level = ItemApply.boost_random_perk(LocationData.perk_boost_levels or 1)
    if not name then return end    -- nothing eligible yet; the boost keeps waiting
    ledger.boosts = ledger.boosts - 1
    save_ledger()
    log("Perk Boost: " .. name .. " is now level " .. tostring(level))
end

function M.tick()
    local now = M.now()
    local lobby = game.in_lobby()

    if lobby then
        if next(active) then end_all("back in the lobby") end
        run.island, run.island_since = nil, nil
        return
    end

    if game.eliminated() then
        if next(active) then end_all("run over") end
        return
    end

    local island = game.island()
    if island ~= run.island then
        run.island = island
        run.island_since = now
        -- Slowdown ends when the island it hit on is over.
        local e = active.speed
        if e and e.island and island ~= e.island then end_effect("speed", "island over") end
    end
    for kind, e in pairs(active) do
        if now >= e.expires then end_effect(kind, "time up") else enforce_ops(e.applied) end
    end

    if game.paused() then return end
    try_boost()

    if #ledger.traps == 0 then return end
    if now - (run.island_since or now) < (LocationData.trap_grace_seconds or 0) then return end
    if now - run.last_hit < M.MIN_GAP_S then return end
    local name = table.remove(ledger.traps, 1)
    run.last_hit = now
    save_ledger()
    hit(name)
end

--- Called when the player is eliminated: effects end with the run.
function M.on_run_over()
    end_all("run over")
end

function M.install()
    if type(LoopAsync) ~= "function" then return end
    local GameThread = require("AP/GameThread")
    -- Game objects are touched on the game thread.
    GameThread.loop(M.TICK_MS, function()
        local ok, err = pcall(M.tick)
        if not ok then log("tick error: " .. tostring(err)) end
        return false
    end)
    log("Trap watcher running")
end

--- Forget everything this module remembers: running effects, the ledger (file and memory), waiting traps and
--- boosts. Normal play never needs this. It's for testing against a server that restarts with the same seed, so
--- new items don't look like replays of earlier ones (the ledger file outlives a run, as it should).
function M.reset()
    end_all("reset")
    ledger = { identity = nil, last = -1, boosts = 0, traps = {} }
    run = { island = nil, island_since = nil, last_hit = 0 }
    save_ledger()
end

-- Test helpers
function M._reset_for_test(identity)
    ledger = { identity = identity, last = -1, boosts = 0, traps = {} }
    run = { island = nil, island_since = nil, last_hit = 0 }
    active = {}
end

return M
