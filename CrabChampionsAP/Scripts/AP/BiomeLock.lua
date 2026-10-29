-- AP/BiomeLock.lua
-- Biome Lock: a run only enters biomes the player owns the Access item for.
--
-- The game numbers its biomes 1 Tropical, 2 Arctic, 3 Desert, 4 Volcanic, and at the start of a run it builds the
-- biome order [1, 2, 3, 4] in native code, so the first biome is always the one numbered 1. Two things are done here:
--
--   * Starting biome. In the lobby the biome data assets (CrabBiomeDA) are renumbered so the starting biome answers to
--     1 (it swaps numbers with Tropical). The game then starts in it, with its lighting, maps and enemies, because it
--     looks those up by matching the number against CrabGS.Biome. The numbers stay swapped until the mod is turned
--     off, so a game loop (which rebuilds the order) restarts in the starting biome too.
--     CrabGS.Biome holds the swapped number, so the HUD biome name is wrong; the mod writes the real name.
--
--   * Next biome. The Biome portal at the end of a biome reads the next biome straight from CrabGS.BiomeOrder (the
--     entry after the current biome; the first entry if the current biome is not in the list; past the end of the
--     list if it is last). While in a run the order is checked often, and when the entry after the current biome is
--     not one the player owns, the order is rewritten with the current biome first and an owned biome second: the
--     next owned biome in the game's order, or the current biome again when it is the only one. A repeat is
--     replaced as soon as another biome is owned.
--
-- Numbers written to CrabGS.BiomeOrder and CrabGS.Biome are "labels": the number on a data asset. Labels equal the
-- real biome numbers except for the swap above.

local M = {}

local function log(msg) print("[CrabAP-BiomeLock] " .. tostring(msg)) end

-- Optional callback for debug tools: (kind, data).
M.on_event = nil
local function event(kind, data)
    if M.on_event then pcall(M.on_event, kind, data) end
end

M.NAMES = { "Tropical", "Arctic", "Desert", "Volcanic" }
local COUNT = #M.NAMES

local ACCESS_ITEMS = {
    ["Tropical Access"] = 1,
    ["Arctic Access"] = 2,
    ["Desert Access"] = 3,
    ["Volcanic Access"] = 4,
}

local TICK_MS = 500
local LOBBY_CHECK_EVERY = 4        -- ticks between label checks while in the lobby

local cfg = { enabled = false, start = 0 }
local owned = {}                   -- real biome number -> true
local label_cache = nil            -- real biome number -> label currently on its data asset
local lobby_ticks = 0
local steers = 0
local restore_pending = false  -- biome numbers to put back once the game is in the lobby

local function num(v)
    if type(v) == "number" then return v end
    local ok, n = pcall(function() return tonumber(v) end)
    return ok and n or nil
end

local function alive(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

-------------------------------------------------------------
-- Game access (replaceable by tests)
-------------------------------------------------------------

local game = {}
M.game = game

local function live_objects(class)
    local ok, all = pcall(FindAllOf, class)
    if not ok or type(all) ~= "table" then return {} end
    local out = {}
    for _, o in ipairs(all) do
        if alive(o) then
            local okn, name = pcall(function() return o:GetFullName() end)
            if okn and type(name) == "string" and not name:find("Default__", 1, true) then
                out[#out + 1] = o
            end
        end
    end
    return out
end

function game.gs()
    return live_objects("CrabGS")[1]
end

--- The biome data assets as { real = <biome number>, da = <object> }, matched by asset name.
function game.biome_assets()
    local out = {}
    for _, da in ipairs(live_objects("CrabBiomeDA")) do
        local ok, name = pcall(function() return da:GetFullName() end)
        local key = ok and type(name) == "string" and name:match("DA_Biome_(%a+)%.") or nil
        for real, n in ipairs(M.NAMES) do
            if key == n then out[#out + 1] = { real = real, da = da } end
        end
    end
    return out
end

--- Live game-state HUD widgets (they own the BiomeText block).
function game.hud_widgets()
    return live_objects("CrabGameStateUI")
end

function game.get_text(block)
    local ok, s = pcall(function() return block:GetText():ToString() end)
    return ok and s or nil
end

function game.set_text(block, text)
    return pcall(function() block:SetText(FText(text)) end)
end

local function read_array(arr)
    local out = {}
    if arr == nil then return out end
    local n = num(arr:GetArrayNum()) or 0
    for i = 1, n do out[i] = num(arr[i]) end
    return out
end

-------------------------------------------------------------
-- Labels
-------------------------------------------------------------

--- The label each real biome should carry: the starting biome swaps with Tropical so that it answers to 1.
function M.target_labels()
    local labels = {}
    for i = 1, COUNT do labels[i] = i end
    local s = cfg.start
    if s >= 1 and s <= COUNT then labels[s], labels[1] = 1, s end
    return labels
end

local function read_labels()
    local t = {}
    for _, a in ipairs(game.biome_assets()) do t[a.real] = num(a.da.Biome) end
    return t
end

local function set_labels(want)
    local assets = game.biome_assets()
    if #assets == 0 then return nil end
    local changed = 0
    for _, a in ipairs(assets) do
        local w = want[a.real]
        if w ~= nil and num(a.da.Biome) ~= w then
            local ok, err = pcall(function() a.da.Biome = w end)
            if ok then
                changed = changed + 1
            else
                log("Could not relabel " .. M.NAMES[a.real] .. ": " .. tostring(err))
            end
        end
    end
    label_cache = read_labels()
    return changed
end

--- Renumber the data assets for the starting biome. Returns how many changed, or nil if the assets are not loaded.
function M.apply_labels()
    local changed = set_labels(M.target_labels())
    if changed and changed > 0 then
        log("Starting biome " .. M.NAMES[cfg.start] .. ": renumbered " .. changed .. " biome assets")
        event("labels", { start = cfg.start, changed = changed })
    end
    return changed
end

--- Put the game's own numbers back.
function M.restore_labels()
    local want = {}
    for i = 1, COUNT do want[i] = i end
    return set_labels(want)
end

local function labels_match()
    local have, want = read_labels(), M.target_labels()
    local n = 0
    for real, label in pairs(have) do
        n = n + 1
        if want[real] ~= label then return false end
    end
    return n == COUNT
end

local function real_of_label(label)
    if not label_cache then label_cache = read_labels() end
    for real, l in pairs(label_cache) do
        if l == label then return real end
    end
    return nil
end

-------------------------------------------------------------
-- State
-------------------------------------------------------------

local function in_lobby()
    local gs = game.gs()
    if not gs then return true end
    return (num(gs.CurrentIsland) or 0) <= 0
end

--- Read the options from slot_data.options. `keep_items` (same seed and slot reconnecting) keeps the Access items
--- already received; the server re-sends them anyway.
function M.configure(opts, keep_items)
    opts = opts or {}
    cfg.enabled = opts.biome_lock == true
    cfg.start = num(opts.starting_biome) or 0
    if cfg.start < 1 or cfg.start > COUNT then cfg.enabled = false end
    if not keep_items then owned = {} end
    label_cache = nil
    lobby_ticks = 0
    if cfg.enabled then
        owned[cfg.start] = true
        restore_pending = false
        log("Biome lock on, starting biome " .. M.NAMES[cfg.start])
        -- Mid-run the numbers stay as they are; the lobby check applies them before the next run.
        if in_lobby() then pcall(M.apply_labels) end
    else
        log("Biome lock off")
        if in_lobby() then pcall(M.restore_labels) else restore_pending = true end
    end
end

--- Turn the lock off and put the game's biome numbers back (disconnect).
function M.deactivate()
    local was = cfg.enabled
    cfg.enabled = false
    owned = {}
    label_cache = nil
    if was then
        -- Mid-run the numbers stay: the run's biome order and lighting were built from them, and a reconnect
        -- picks the lock up again. They go back in the lobby.
        if in_lobby() then pcall(M.restore_labels) else restore_pending = true end
        log("Biome lock off (disconnected)")
    end
end

--- The biome the run is in, as the game's real biome number (1-4), or nil when there is no game state. Works with
--- the lock off too, when the numbers are the game's own.
function M.current_biome()
    local gs = game.gs()
    if not gs then return nil end
    local label = num(gs.Biome)
    if not label then return nil end
    return real_of_label(label) or label
end

function M.is_active() return cfg.enabled end
function M.is_owned(real) return owned[real] == true end
function M.starting_biome() return cfg.start end
function M.steer_count() return steers end

--- A snapshot of what the module holds, for debug tools: active, start, owned (list of biome numbers), steers and
--- the label on each biome's data asset (by biome number).
function M.state()
    local list = {}
    for real = 1, COUNT do
        if owned[real] then list[#list + 1] = real end
    end
    local labels = read_labels()
    return { active = cfg.enabled, start = cfg.start, owned = list, steers = steers,
             labels = { labels[1], labels[2], labels[3], labels[4] } }
end

--- A received item. Returns true when it is an Access item (so the caller skips normal handling).
function M.on_item(info)
    local real = info and ACCESS_ITEMS[info.name]
    if not real then return false end
    if not owned[real] then
        owned[real] = true
        log("Received " .. info.name)
        event("access", { biome = real })
    end
    return true
end

-------------------------------------------------------------
-- Steering the next biome
-------------------------------------------------------------

local function label_owned(label)
    local real = real_of_label(label)
    return real ~= nil and owned[real] == true
end

--- The label of the biome that should follow `current`: the next owned biome in the game's order, or `current`
--- again when no other biome is owned.
function M.pick_next(current)
    for step = 1, COUNT - 1 do
        local label = (current - 1 + step) % COUNT + 1
        if label_owned(label) then return label end
    end
    return current
end

-- Order of `len` entries with the current biome first and `nxt` second, then the remaining labels.
local function build_order(current, nxt, len)
    local out = { current, nxt }
    for label = 1, COUNT do
        if #out >= len then break end
        local present = false
        for _, v in ipairs(out) do
            if v == label then present = true break end
        end
        if not present then out[#out + 1] = label end
    end
    while #out > len do out[#out] = nil end
    return out
end

--- Make sure the biome after the current one is owned. Returns true when the order was rewritten.
function M.steer()
    local gs = game.gs()
    if not gs then return false end
    local current = num(gs.Biome)
    if not current then return false end
    local order = read_array(gs.BiomeOrder)
    if #order < 2 then return false end
    local idx
    for i, v in ipairs(order) do
        if v == current then idx = i break end
    end
    -- What the Biome portal will read; nil means past the end of the list.
    local following
    if idx then following = order[idx + 1] else following = order[1] end
    local pick = M.pick_next(current)
    -- An owned biome is fine, except that repeating the current one gives way once another biome is owned.
    if following and label_owned(following) and (following ~= current or pick == current) then return false end

    local want = build_order(current, pick, #order)
    for i, v in ipairs(want) do
        if order[i] ~= v then
            local ok, err = pcall(function() gs.BiomeOrder[i] = v end)
            if not ok then
                log("Could not write the biome order: " .. tostring(err))
                return false
            end
        end
    end
    steers = steers + 1
    local real = real_of_label(current)
    log("Biome order set to [" .. table.concat(want, ",") .. "] while in "
        .. (real and M.NAMES[real] or "?") .. ": next is " .. tostring(M.NAMES[real_of_label(want[2]) or 0]))
    event("steer", { current = current, order = want })
    return true
end

-------------------------------------------------------------
-- HUD
-------------------------------------------------------------

--- Write the real biome name into the HUD biome text (the game shows the name of the swapped number).
function M.update_hud()
    local gs = game.gs()
    if not gs then return 0 end
    local real = real_of_label(num(gs.Biome))
    local name = real and M.NAMES[real]
    if not name then return 0 end
    local changed = 0
    for _, w in ipairs(game.hud_widgets()) do
        local ok, block = pcall(function() return w.BiomeText end)
        if ok and alive(block) then
            local text = game.get_text(block)
            if text and text:lower() ~= name:lower() then
                if game.set_text(block, name) then changed = changed + 1 end
            end
        end
    end
    return changed
end

-------------------------------------------------------------
-- Tick
-------------------------------------------------------------

function M.tick()
    if not cfg.enabled then
        if restore_pending and in_lobby() then
            restore_pending = false
            pcall(M.restore_labels)
        end
        return
    end
    local gs = game.gs()
    if not gs then return end
    if (num(gs.CurrentIsland) or 0) <= 0 then
        -- Lobby: keep the numbers right for the next run.
        lobby_ticks = lobby_ticks + 1
        if lobby_ticks % LOBBY_CHECK_EVERY == 1 and not labels_match() then M.apply_labels() end
        return
    end
    lobby_ticks = 0
    M.steer()
    M.update_hud()
end

function M.install()
    if type(LoopAsync) ~= "function" then return end
    local GameThread = require("AP/GameThread")
    local function run_tick()
        local ok, err = pcall(M.tick)
        if not ok then log("tick error: " .. tostring(err)) end
    end
    -- Game objects are touched on the game thread.
    GameThread.loop(TICK_MS, function()
        run_tick()
        return false
    end)
    -- Island changes: check soon instead of waiting for the next tick.
    for _, hook in ipairs({ "ClientOnClearedIsland", "ClientOnEnteredPortal" }) do
        pcall(function()
            RegisterHook("/Script/CrabChampions.CrabPC:" .. hook, function()
                GameThread.after(300, run_tick)
            end)
        end)
    end
    log("Biome lock watcher running")
end

return M
