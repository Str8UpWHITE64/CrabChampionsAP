-- AP/ItemApply.lua
-- Applies received AP items to the player.
--
-- Weapons/Abilities/Melee: added to equip_lock allowed set (not force-equipped)
-- Perks/Relics/Mods: spawned at the player via ServerSpawnKeyTotemPickup
--   using the player character as the "totem", then auto-collected via
--   ServerInteract after a short delay. Greed items are spawned but NOT
--   auto-collected — the player must pick them up manually.
-- Filler: grants crystals directly
--
-- Per-run items (perks/mods/relics) are tracked in _run_items so they can
-- be re-spawned when the player starts a new run from the lobby.

local ItemData = require("AP/ItemData")
local GameThread = require("AP/GameThread")

local M = {}

local function log(msg) print("[CrabAP-ItemApply] " .. tostring(msg)) end

local function safe(fn, fallback)
    local ok, v = pcall(fn)
    if ok then return v end
    return fallback
end

local function get_full_name(obj)
    if not obj then return nil end
    return safe(function()
        if obj.GetFullName then return tostring(obj:GetFullName()) end
        return nil
    end, nil)
end

-- Track what we've already unlocked (full_name -> true)
M.unlocked = {}

-- Track received per-run items (perks/mods/relics) for re-application on new run
-- Each entry: { ap_item_id = number, name = string, da = userdata, full_name = string }
M._run_items = {}

-- Track total crystals received so we can re-grant them on lobby return
M._run_crystals = 0

-- Indices into _run_items that are in the inventory this run. With
-- starting_item_percentage below 100 a run only gets a share of them.
M._granted = {}

-- Lobby state: items are only spawned/granted while in the lobby.
-- Items received mid-run are tracked but not spawned until lobby return.
M.in_lobby = true

-- Set by a mid-run reset: which received items the run already had, so the
-- replay restores those instead of drawing again. { n = count, granted = set }
local resume = nil

-- Queue for items waiting to be spawned (processed sequentially, fallback only)
local spawn_queue = {}
local spawn_busy = false

-- Inventory ledger. The inventory is never wiped on a reconnect; instead this
-- run's items are tracked as levels per item and only the difference is applied.
--   want[full_name]  levels this run should hold (the draw plus mid-run arrivals)
--   have[full_name]  levels already delivered into the inventory
-- Waiting for a free slot is simply want > have, so there is no separate
-- overflow queue to lose or double-apply.
local want = {}
local want_order = {}     -- full_names in first-grant order, so older waits go first
local have = {}
local info_by_name = {}   -- full_name -> item info, every received item this session
local flushing = false    -- a batch is being applied; a second flush must not start
local flush_again = false
local flush_scheduled = false
local apply_generation = 0  -- bumped by a hard reset to abandon a batch in flight

local function want_clear()
    want = {}
    want_order = {}
end

-- True from a (re)connect until the first draw. The server re-sends every
-- received item on connect, so the draw waits until they stop arriving.
local draw_pending = false
local draw_generation = 0
local DRAW_SETTLE_MS = 1500

-- Fixed iteration order for the C++ array names.
local CPP_QUEUE_NAMES = { "Perks", "Relics", "WeaponMods", "MeleeMods", "AbilityMods" }

-- Crystals: M._run_crystals is what the server has sent, crystals_applied is
-- how much of that the player was already given. Only the difference is granted.
local crystals_applied = 0
local crystal_flush_scheduled = false

-------------------------------------------------------------
-- Reset: clear all state for a fresh connection
-------------------------------------------------------------

--- True when the game is in the lobby. A run is told apart by the lobby
--- pickups being gone while CrabGS reports an island; anything unclear counts
--- as the lobby, which is the safe default for a fresh launch.
local function detect_in_lobby()
    local ok, actors = pcall(FindAllOf, "BP_Pickup_Lobby_C")
    if ok and actors and #actors > 0 then return true end
    local island = safe(function()
        local gs = FindFirstOf("CrabGS")
        if gs and gs:IsValid() then return tonumber(gs.CurrentIsland) end
        return nil
    end, nil)
    return not (island and island > 0)
end

--- Reset item tracking for a (re)connect.
---
--- A soft reset (opts.soft) is for reconnecting to the same seed and slot. The
--- inventory and crystals are left alone: the server re-sends every item, the
--- ledger of what was already delivered survives, and only the difference is
--- applied. A hard reset (the default; first connect, or a different seed or
--- slot) also empties the inventory and crystals and forgets the ledger.
function M.reset(opts)
    local soft = opts and opts.soft == true
    log("Resetting item state for " .. (soft and "reconnect (inventory kept)..." or "fresh connection..."))

    -- Keep the real lobby/run state. Mid-run, remember what the run had so
    -- the replay restores it rather than rolling a new start draw.
    local in_lobby = detect_in_lobby()
    if not in_lobby then
        -- A second drop before the replay finished keeps the first snapshot.
        if not (resume and #M._run_items < resume.n) then
            resume = { n = #M._run_items, granted = M._granted }
        end
    else
        resume = nil
    end

    -- Clear per-connection tracking; the server re-sends everything.
    if not soft then M.unlocked = {} end
    M._run_items = {}
    M._run_crystals = 0
    M._granted = {}
    M.in_lobby = in_lobby
    draw_pending = in_lobby
    draw_generation = draw_generation + 1

    spawn_queue = {}
    spawn_busy = false
    crystal_flush_scheduled = false

    if not soft then
        apply_generation = apply_generation + 1
        want_clear()
        have = {}
        info_by_name = {}
        flushing = false
        flush_again = false
        flush_scheduled = false
        crystals_applied = 0
        if AP_ClearInventoryArray then
            for _, arr_name in ipairs({"Perks", "WeaponMods", "AbilityMods", "MeleeMods", "Relics"}) do
                pcall(AP_ClearInventoryArray, arr_name)
            end
            pcall(AP_RefreshInventoryUI)
            log("Cleared all inventory arrays")
        end
        pcall(function()
            local pss = FindAllOf("CrabPS")
            if pss and #pss > 0 then
                pss[1].Crystals = 0
            end
        end)
    elseif in_lobby then
        -- In the lobby the start draw is rolled again once the re-send settles,
        -- so the old target goes; what was delivered stays in the ledger.
        want_clear()
    end

    log("Item state reset complete")
end

-------------------------------------------------------------
-- Player / controller lookups
-------------------------------------------------------------

function M._get_pc()
    local all = FindAllOf("CrabPC")
    if not all then return nil end
    for _, p in ipairs(all) do
        if p and p:IsValid() then return p end
    end
    return nil
end

function M._get_player_c()
    local all = FindAllOf("CrabPlayerC")
    if not all then return nil end
    for _, p in ipairs(all) do
        if p and p:IsValid() then return p end
    end
    return nil
end

function M._get_ps()
    local all = FindAllOf("CrabPS")
    if not all then return nil end
    for _, p in ipairs(all) do
        if p and p:IsValid() then return p end
    end
    return nil
end

-------------------------------------------------------------
-- Snapshot: track existing CrabInteractPickup instances
-------------------------------------------------------------

local function snapshot_pickups()
    local set = {}
    local all = FindAllOf("CrabInteractPickup")
    if all then
        for _, p in ipairs(all) do
            if p and p:IsValid() then
                local fn = get_full_name(p)
                if fn then set[fn] = true end
            end
        end
    end
    return set
end

local function find_new_pickup(old_snapshot)
    local all = FindAllOf("CrabInteractPickup")
    if not all then return nil end
    for _, p in ipairs(all) do
        if p and p:IsValid() then
            local fn = get_full_name(p)
            if fn and not old_snapshot[fn] then
                return p
            end
        end
    end
    return nil
end

-------------------------------------------------------------
-- Spawn + auto-collect pipeline
-------------------------------------------------------------

--- Check if a DA full_name is a greed item (has /Greed/ in its asset path).
--- Greed items can't be dropped once picked up, so handling depends on greed_mode.
local function is_greed_item(full_name)
    if not full_name then return false end
    return full_name:find("/Greed/") ~= nil
end

--- Get the greed item mode from slot_data (via LocationData).
--- Returns 0=auto, 1=drop, 2=skip.
local GREED_AUTO = 0
local GREED_DROP = 1
local GREED_SKIP = 2

local function get_greed_mode()
    local ok, LocationData = pcall(require, "AP/LocationData")
    if ok and LocationData then
        return LocationData.greed_item_mode or GREED_AUTO
    end
    return GREED_AUTO
end

--- Spawn a pickup at the player and optionally auto-collect it.
--- Uses ServerSpawnKeyTotemPickup with the player character as the "totem",
--- then polls for the new CrabInteractPickup and calls ServerInteract.
--- If auto_collect is false, just spawns and leaves pickup in the world.
local function spawn_and_collect(pickup_da, item_name, auto_collect, callback)
    local pc = M._get_pc()
    local player = M._get_player_c()

    if not pc then
        log("No CrabPC — cannot spawn " .. item_name)
        if callback then callback(false) end
        return
    end
    if not player then
        log("No CrabPlayerC — cannot spawn " .. item_name)
        if callback then callback(false) end
        return
    end

    -- Snapshot existing pickups before spawning
    local before = snapshot_pickups()

    -- Spawn using player as "totem"
    local ok, err = pcall(function()
        pc:ServerSpawnKeyTotemPickup(player, pickup_da)
    end)
    if not ok then
        log("Spawn failed for " .. item_name .. ": " .. tostring(err))
        if callback then callback(false) end
        return
    end

    -- If not auto-collecting (greed items), just confirm spawn and return
    if not auto_collect then
        log("Spawned (no auto-collect): " .. item_name .. " — player must pick up manually")
        -- Small delay to let spawn complete, then callback
        GameThread.loop(300, function()
            if callback then callback(true) end
            return true
        end)
        return
    end

    -- Poll for the new pickup and auto-interact
    local attempts = 0
    local max_attempts = 20  -- 2 seconds at 100ms intervals

    GameThread.loop(100, function()
        attempts = attempts + 1

        local new_pickup = find_new_pickup(before)
        if new_pickup then
            local current_player = M._get_player_c()
            if current_player then
                local interact_ok = pcall(function()
                    current_player:ServerInteract(new_pickup)
                end)
                if interact_ok then
                    log("Spawned and collected: " .. item_name)
                else
                    log("ServerInteract failed for " .. item_name .. " — pickup is in world")
                end
            else
                log("Lost player reference — " .. item_name .. " pickup is in world")
            end
            if callback then callback(true) end
            return true  -- stop loop
        end

        if attempts >= max_attempts then
            log("Pickup not found after " .. max_attempts .. " attempts for " .. item_name .. " — may need manual collection")
            if callback then callback(false) end
            return true  -- stop loop
        end

        return false  -- keep polling
    end)
end

--- Process the spawn queue one item at a time.
--- Each spawn+collect is serialized with a cooldown between items
--- to avoid overwhelming the game engine and causing crashes.
local SPAWN_COOLDOWN_MS = 750  -- delay between consecutive spawns

local function process_spawn_queue()
    if spawn_busy then return end
    if #spawn_queue == 0 then return end

    spawn_busy = true
    local item = table.remove(spawn_queue, 1)

    spawn_and_collect(item.da, item.name, item.auto_collect, function(success)
        -- Wait before processing next item to avoid overwhelming the game
        if #spawn_queue > 0 then
            GameThread.loop(SPAWN_COOLDOWN_MS, function()
                spawn_busy = false
                process_spawn_queue()
                return true
            end)
        else
            spawn_busy = false
        end
    end)
end

--- Queue a pickup to be spawned.
--- Greed items are NOT auto-collected (player must pick up manually).
local function queue_spawn(pickup_da, item_name, full_name)
    local auto_collect = not is_greed_item(full_name)
    table.insert(spawn_queue, { da = pickup_da, name = item_name, auto_collect = auto_collect })
    process_spawn_queue()
end

-------------------------------------------------------------
-- C++ inventory mod integration
-------------------------------------------------------------

--- Category -> (ArrayName, DAFieldName) mapping for the C++ mod
local CPP_ARRAY_MAP = {
    -- [CAT.PERK]        = { "Perks",       "PerkDA" },
    -- [CAT.RELIC]       = { "Relics",      "RelicDA" },
    -- [CAT.WEAPON_MOD]  = { "WeaponMods",  "WeaponModDA" },
    -- [CAT.MELEE_MOD]   = { "MeleeMods",   "MeleeModDA" },
    -- [CAT.ABILITY_MOD] = { "AbilityMods", "AbilityModDA" },
}

-- Populated on first use (after ItemData.CATEGORY is available)
local function get_cpp_array_info(cat)
    local CAT = ItemData.CATEGORY
    if not CPP_ARRAY_MAP[CAT.PERK] then
        CPP_ARRAY_MAP[CAT.PERK]        = { "Perks",       "PerkDA" }
        CPP_ARRAY_MAP[CAT.RELIC]       = { "Relics",      "RelicDA" }
        CPP_ARRAY_MAP[CAT.WEAPON_MOD]  = { "WeaponMods",  "WeaponModDA" }
        CPP_ARRAY_MAP[CAT.MELEE_MOD]   = { "MeleeMods",   "MeleeModDA" }
        CPP_ARRAY_MAP[CAT.ABILITY_MOD] = { "AbilityMods", "AbilityModDA" }
    end
    return CPP_ARRAY_MAP[cat]
end

--- Check if the C++ inventory mod is available
local function has_cpp_mod()
    return AP_AddInventoryItem ~= nil
end

--- Sanitize inventory arrays: remove entries with null DA or Level=0.
--- Called after batch operations to clean up race condition artifacts.
local function sanitize_inventory()
    if not AP_SanitizeInventory then return 0 end
    local ok, removed = pcall(AP_SanitizeInventory)
    if ok and removed and removed > 0 then
        log("Inventory sanitized: removed " .. removed .. " broken entries")
    end
    return (ok and removed) or 0
end

--- Add an item via the C++ inventory mod. Returns true on success.
--- Does NOT refresh UI — caller should call AP_RefreshInventoryUI after batch.
--- Also sends the location check for the item (since we bypass ClientOnPickedUpPickup).
--- @param info table Item info with .da, .cat, .name, .full_name
--- @param count number Optional stack count (default 1). For stackable items,
---        adds this many levels in a single C++ call instead of one at a time.
local function cpp_add_item(info, count)
    count = count or 1
    local arr_info = get_cpp_array_info(info.cat)
    if not arr_info then return false end

    local da_addr = info.da:GetAddress()
    if not da_addr then
        log("Could not get DA address for " .. info.name)
        return false
    end

    local ok, result = pcall(AP_AddInventoryItem, da_addr, arr_info[1], arr_info[2], count)
    if ok and result then
        if count > 1 then
            log("Added via C++ mod: " .. info.name .. " x" .. count .. " -> " .. arr_info[1])
        else
            log("Added via C++ mod: " .. info.name .. " -> " .. arr_info[1])
        end

        return true
    else
        log("C++ mod failed for " .. info.name .. ": " .. tostring(result))
        return false
    end
end

-------------------------------------------------------------
-- Ledger and batch flush: apply the difference between want and have
-------------------------------------------------------------

local FLUSH_BATCH_SIZE = 20          -- items per chunk
local FLUSH_BATCH_DELAY_MS = 100     -- ms pause between chunks
local OVERFLOW_BATCH_SIZE = 10       -- items per chunk during a retry
local OVERFLOW_BATCH_DELAY_MS = 150  -- ms pause between retry chunks

--- Raise this run's target for an item by `count` levels.
local function want_add(info, count)
    local fn = info.full_name
    info_by_name[fn] = info
    if not want[fn] then
        want[fn] = 0
        want_order[#want_order + 1] = fn
    end
    want[fn] = want[fn] + count
end

--- Stacks still to apply: one per item name, oldest first, with the number of
--- levels missing. This is also what used to be the overflow queue: an item
--- with no free slot just stays missing until something frees one.
local function pending_work()
    local work = {}
    for _, fn in ipairs(want_order) do
        local diff = (want[fn] or 0) - (have[fn] or 0)
        local info = info_by_name[fn]
        if diff > 0 and info then
            work[#work + 1] = { info = info, count = diff }
        end
    end
    return work
end

--- Levels waiting on a free slot (or a flush that has not run yet).
function M.overflow_count()
    local total = 0
    for _, entry in ipairs(pending_work()) do total = total + entry.count end
    return total
end

--- Levels of every item currently in the inventory, by full name, or nil when
--- the inventory cannot be read.
local function observed_levels()
    local ok, InvSan = pcall(require, "AP/InventorySanitize")
    if not ok or not InvSan or not InvSan.build_inventory_snapshot then return nil end
    local ps = M._get_ps()
    if not ps then return nil end
    local snap = safe(function() return InvSan.build_inventory_snapshot(ps) end, nil)
    if not snap then return nil end
    local levels = {}
    for _, bucket in pairs(snap) do
        for full_name, entry in pairs(bucket) do
            levels[full_name] = tonumber(entry.level) or 1
        end
    end
    return levels
end

--- Compare the real inventory with this run's target. Received items that
--- are over the target are lowered with AP_RemoveInventoryItem; the ledger is
--- set to what is really there, so anything short is applied by the next
--- flush. Items the server never sent are not touched here.
local function sync_inventory()
    local observed = observed_levels()
    if not observed then
        have = {}   -- cannot read it: assume empty, as the old wipe did
        return
    end
    local new_have, removed = {}, 0
    for full_name, info in pairs(info_by_name) do
        local cur = observed[full_name] or 0
        local target = want[full_name] or 0
        local arr_info = get_cpp_array_info(info.cat)
        if cur > target and arr_info and AP_RemoveInventoryItem and info.da then
            local ok, res = pcall(AP_RemoveInventoryItem, info.da:GetAddress(), arr_info[1], arr_info[2], cur - target)
            if ok and res then
                log("Lowered " .. info.name .. " " .. cur .. " -> " .. target)
                cur = target
                removed = removed + 1
            end
        end
        new_have[full_name] = cur
    end
    have = new_have
    if removed > 0 then pcall(AP_RefreshInventoryUI) end
end

--- Apply a work list in rate-limited chunks to avoid overwhelming the engine.
--- Stacks whose inventory type has no free slots stay missing in the ledger
--- without a C++ call, unless the item is already in the inventory and only
--- needs a level bump. Calls on_done(applied, waiting) once the list is drained.
local function process_work_list(work, batch_size, delay_ms, gen, on_done)
    local present = {}
    for full_name in pairs(observed_levels() or {}) do present[full_name] = true end
    local known_full = {}
    local applied, waiting = 0, 0
    local idx = 1

    local function process_batch()
        if gen ~= apply_generation then return end  -- hard reset: abandon this batch
        local batch_end = math.min(idx + batch_size - 1, #work)
        local batch_applied = 0

        for i = idx, batch_end do
            local entry = work[i]
            local info, count = entry.info, entry.count
            local arr_info = get_cpp_array_info(info.cat)
            local queue_key = arr_info and arr_info[1] or "Perks"
            local stacks = info.cat ~= ItemData.CATEGORY.RELIC and present[info.full_name]

            if known_full[queue_key] and not stacks then
                waiting = waiting + count
            elseif cpp_add_item(info, count) then
                have[info.full_name] = (have[info.full_name] or 0) + count
                applied = applied + count
                batch_applied = batch_applied + 1
                present[info.full_name] = true
            else
                -- Mark this type as full so we stop hammering C++
                known_full[queue_key] = true
                waiting = waiting + count
            end
        end

        -- Refresh UI after each batch that applied something
        if batch_applied > 0 then
            pcall(AP_RefreshInventoryUI)
        end

        idx = batch_end + 1
        if idx <= #work then
            GameThread.loop(delay_ms, function()
                process_batch()
                return true  -- run once
            end)
        else
            -- All done — sanitize to clean up any race condition artifacts
            sanitize_inventory()
            on_done(applied, waiting)
        end
    end

    process_batch()
end

local schedule_flush

--- Apply everything missing, in batches. Only one flush runs at a time; a
--- request made meanwhile reruns once it finishes, so two flushes never both
--- add the same missing levels.
local function flush(batch_size, delay_ms)
    flush_scheduled = false
    if not has_cpp_mod() then return end
    if flushing then
        flush_again = true
        return
    end
    local work = pending_work()
    if #work == 0 then return end

    flushing = true
    local gen = apply_generation
    log("Flushing " .. #work .. " item stacks via C++ mod (batch size " .. (batch_size or FLUSH_BATCH_SIZE) .. ")...")
    process_work_list(work, batch_size or FLUSH_BATCH_SIZE, delay_ms or FLUSH_BATCH_DELAY_MS, gen,
        function(applied, waiting)
            flushing = false
            if waiting > 0 then
                log("Batch complete: " .. applied .. " applied, " .. waiting
                    .. " waiting for free slots (" .. M.overflow_count() .. " total waiting)")
            else
                log("Batch complete: " .. applied .. " applied")
            end
            if flush_again then
                flush_again = false
                schedule_flush()
            end
        end)
end

schedule_flush = function()
    if flush_scheduled then return end
    flush_scheduled = true
    GameThread.loop(200, function()
        flush()
        return true  -- run once
    end)
end

--- Retry everything missing, at a gentler cadence than a normal flush since
--- this runs mid-run. Items received since are part of the same difference.
function M.retry_overflow()
    if M.overflow_count() == 0 then return end
    if not has_cpp_mod() then return end
    flush(OVERFLOW_BATCH_SIZE, OVERFLOW_BATCH_DELAY_MS)
end

--- Raise the target for an item and schedule a flush so rapid-fire items batch.
local function queue_cpp_item(info)
    want_add(info, 1)
    schedule_flush()
end

-------------------------------------------------------------
-- Crystals: grant only what the player has not been given yet
-------------------------------------------------------------

local function flush_crystals()
    crystal_flush_scheduled = false
    local amount = M._run_crystals - crystals_applied
    if amount <= 0 then return end
    crystals_applied = M._run_crystals
    M._grant_crystals(amount)
    log("Granted " .. amount .. " crystals (batched)")
end

local function queue_crystals(amount)
    M._run_crystals = M._run_crystals + amount
    if not crystal_flush_scheduled then
        crystal_flush_scheduled = true
        GameThread.loop(200, function()
            flush_crystals()
            return true  -- run once
        end)
    end
end

-------------------------------------------------------------
-- Run draws: starting_item_percentage and biome_item_percentage
-------------------------------------------------------------

--- Starting and biome percentages for this slot. 100 / 0 when not connected
--- or on seeds from before 1.5, which gives the old everything-each-run.
local function draw_percentages()
    local ok, LocationData = pcall(require, "AP/LocationData")
    if not ok or not LocationData then return 100, 0 end
    return LocationData.starting_item_percentage or 100, LocationData.biome_item_percentage or 0
end

--- Put the tracked item at `idx` into the inventory for this run.
local function grant(idx)
    local item = M._run_items[idx]
    M._granted[idx] = true
    if has_cpp_mod() and item.da and item.cat then
        queue_cpp_item(item)
    elseif M.in_lobby and item.da then
        queue_spawn(item.da, item.name, item.full_name)
    end
end

--- Pick pct% of `pool` (rounded up) at random. Shuffles `pool` in place.
local function pick(pool, pct)
    for i = #pool, 2, -1 do
        local j = math.random(i)
        pool[i], pool[j] = pool[j], pool[i]
    end
    local out = {}
    for i = 1, math.min(math.ceil(#pool * pct / 100), #pool) do
        out[i] = pool[i]
    end
    return out
end

--- Items the draw picks from: everything received except greed drops, which
--- are spawned on the lobby floor for the player to take or leave.
local function draw_pool(skip_granted)
    local pool = {}
    for idx, item in ipairs(M._run_items) do
        if not item.greed_drop and not (skip_granted and M._granted[idx]) then
            pool[#pool + 1] = idx
        end
    end
    return pool
end

--- Draw this run's starting items. Called on lobby entry and once the
--- connect re-send has settled.
local function start_run_draw()
    draw_pending = false
    resume = nil
    M._granted = {}
    want_clear()
    local start_pct = draw_percentages()
    local pool = draw_pool(false)
    local chosen = pick(pool, start_pct)
    for _, idx in ipairs(chosen) do grant(idx) end
    -- Whatever the inventory already holds counts: only the difference is
    -- added, and received items left over from before are lowered.
    sync_inventory()
    if start_pct < 100 then
        log("Run start: " .. #chosen .. " of " .. #pool .. " received items (" .. start_pct .. "%)")
    end
end

--- Run the start draw once no item has arrived for DRAW_SETTLE_MS.
local function schedule_settled_draw()
    draw_generation = draw_generation + 1
    local generation = draw_generation
    GameThread.loop(DRAW_SETTLE_MS, function()
        if generation == draw_generation and draw_pending then
            start_run_draw()
        end
        return true  -- run once
    end)
end

--- Clearing a biome's last island grants biome_item_percentage of the
--- received items not in this run yet.
function M.on_biome_cleared()
    local start_pct, biome_pct = draw_percentages()
    if start_pct >= 100 or biome_pct <= 0 then return end
    local remaining = draw_pool(true)
    if #remaining == 0 then return end
    local chosen = pick(remaining, biome_pct)
    for _, idx in ipairs(chosen) do grant(idx) end
    log("Biome cleared: granted " .. #chosen .. " of " .. #remaining .. " remaining items ("
        .. biome_pct .. "%)")
end


--- Perk Boost: add one level to a random perk the player holds this run.
--- Skips greed perks and perks already at `level_cap`. Goes through the same
--- target the run draw uses, so a reconnect or the inventory sync keeps it.
--- Returns the perk's name and its new level, or nil when nothing qualifies.
function M.boost_random_perk(level_cap)
    local CAT = ItemData.CATEGORY
    local cands = {}
    for _, fn in ipairs(want_order) do
        local info = info_by_name[fn]
        if info and info.cat == CAT.PERK and info.da and not is_greed_item(fn)
            and (have[fn] or 0) >= 1 and (want[fn] or 0) < level_cap then
            cands[#cands + 1] = fn
        end
    end
    if #cands == 0 then return nil end
    local fn = cands[math.random(#cands)]
    want_add(info_by_name[fn], 1)
    schedule_flush()
    return info_by_name[fn].name, want[fn]
end

-------------------------------------------------------------
-- Public API
-------------------------------------------------------------

--- Apply an AP item: equip weapons immediately, add perks/mods/relics via C++ mod.
---@param ap_item_id number The AP item ID
function M.apply_item(ap_item_id)
    -- Ensure DA maps are built
    if not ItemData.is_resolved() then
        ItemData.resolve_game_objects()
    end

    local info = ItemData.from_ap_id(ap_item_id)
    if not info then
        log("Unknown AP item: " .. tostring(ap_item_id))
        return
    end

    local CAT = ItemData.CATEGORY

    -- Filler
    if info.cat == CAT.FILLER then
        local crystal_amounts = {
            ["Crystal Cache"]   = 50,
            ["Crystal Hoard"]   = 100,
            ["Crystal Jackpot"] = 500,
        }
        local amount = crystal_amounts[info.name]
        if amount then
            queue_crystals(amount)
        else
            log("Received Nothing (filler) — skipping")
        end
        return
    end

    -- Event
    if info.cat == CAT.EVENT then
        log("Received event: " .. info.name)
        return
    end

    -- An older seed's item that the game no longer has
    if info.cat == CAT.SKIP then
        log("Received " .. info.name .. ", which is no longer in the game — nothing to give")
        return
    end

    -- Slot items (progressive inventory slots)
    if info.cat == CAT.SLOT then
        local slot_map = {
            ["Progressive Perk Slot"] = "Perks",
            ["Progressive Weapon Mod Slot"] = "WeaponMods",
            ["Progressive Ability Mod Slot"] = "AbilityMods",
            ["Progressive Melee Mod Slot"] = "MeleeMods",
        }
        local slot_type = slot_map[info.name]
        if slot_type then
            local ok, SlotLock = pcall(require, "AP/SlotLock")
            if ok and SlotLock then
                SlotLock.add_slots(slot_type, 1)
                log("Received " .. info.name .. " — " .. slot_type .. " now " .. SlotLock.get_slots(slot_type))
            end
        end
        return
    end

    if not info.full_name or not info.da then
        log("No DA resolved for: " .. info.name .. " — cannot apply")
        return
    end

    local equip_lock = _G.AP and _G.AP.equip_lock or nil
    local inv_sanitize = _G.AP and _G.AP.inv_sanitize or nil

    -- Weapons/Abilities/Melee: add to allowed pool + unlock in game UI
    local unlock_da = _G.AP and _G.AP.unlock_equipment_da or nil
    if info.cat == CAT.WEAPON then
        if equip_lock then equip_lock.allow_item("weapon", info.full_name) end
        if unlock_da then unlock_da(info.full_name) end
        M.unlocked[info.full_name] = true
        log("Unlocked weapon: " .. info.name)
        return
    elseif info.cat == CAT.ABILITY then
        if equip_lock then equip_lock.allow_item("ability", info.full_name) end
        if unlock_da then unlock_da(info.full_name) end
        M.unlocked[info.full_name] = true
        log("Unlocked ability: " .. info.name)
        return
    elseif info.cat == CAT.MELEE then
        if equip_lock then equip_lock.allow_item("melee", info.full_name) end
        if unlock_da then unlock_da(info.full_name) end
        M.unlocked[info.full_name] = true
        log("Unlocked melee: " .. info.name)
        return
    end

    -- Perks/Relics/Mods: add to allowed sets + spawn and auto-collect
    if info.cat == CAT.PERK then
        if inv_sanitize then inv_sanitize.allowed_perk_full[info.full_name] = true end
    elseif info.cat == CAT.RELIC then
        if inv_sanitize then inv_sanitize.allowed_relic_full[info.full_name] = true end
    elseif info.cat == CAT.WEAPON_MOD then
        if inv_sanitize then inv_sanitize.allowed_weapon_mod_full[info.full_name] = true end
    elseif info.cat == CAT.MELEE_MOD then
        if inv_sanitize then inv_sanitize.allowed_melee_mod_full[info.full_name] = true end
    elseif info.cat == CAT.ABILITY_MOD then
        if inv_sanitize then inv_sanitize.allowed_ability_mod_full[info.full_name] = true end
    end

    M.unlocked[info.full_name] = true
    info_by_name[info.full_name] = info

    -- granted_item_checks: receiving the item completes its pickup check.
    -- Done on receipt so it doesn't depend on the run draw or free slots.
    local ld_ok, LocationData = pcall(require, "AP/LocationData")
    if ld_ok and LocationData and LocationData.granted_item_checks then
        pcall(function()
            require("AP/PickupWatch").send_pickup_check(info.full_name)
        end)
    end

    -- Handle greed items based on greed_item_mode from slot_data
    local is_greed = is_greed_item(info.full_name)
    if is_greed then
        local greed_mode = get_greed_mode()
        if greed_mode == GREED_SKIP then
            -- Should never happen: skip mode excludes greed items from the
            -- AP item/location pools entirely during world generation.
            -- Safety net in case of manual /send or other edge cases.
            log("Greed item ignored (mode=skip): " .. info.name)
            return  -- Do NOT add to _run_items
        elseif greed_mode == GREED_DROP then
            -- Track as greed_drop so reapply_run_items handles it correctly
            table.insert(M._run_items, {
                ap_item_id = ap_item_id,
                name = info.name,
                da = info.da,
                full_name = info.full_name,
                cat = info.cat,
                greed_drop = true,
            })
            if M.in_lobby then
                queue_spawn(info.da, info.name, info.full_name)
            else
                log("Queued greed item for lobby (mode=drop): " .. info.name)
            end
            return
        end
        -- GREED_AUTO: fall through to normal handling below
    end

    -- Track for re-application on new run
    table.insert(M._run_items, {
        ap_item_id = ap_item_id,
        name = info.name,
        da = info.da,
        full_name = info.full_name,
        cat = info.cat,
    })
    local idx = #M._run_items

    -- Items received mid-run always apply. In the lobby a partial start
    -- draw decides instead: the connect re-send waits for the draw, and
    -- later arrivals get the same odds the draw gave everything else, so
    -- waiting in the lobby doesn't get around it.
    local start_pct = draw_percentages()
    if resume and not M.in_lobby and idx <= resume.n then
        -- A replayed item the run already had is already in the target and
        -- the inventory; one it never had stays out. Later arrivals fall through.
        if resume.granted[idx] then M._granted[idx] = true end
        return
    end
    if start_pct >= 100 or not M.in_lobby then
        grant(idx)
        if not has_cpp_mod() and not M.in_lobby then
            log("Queued for lobby (no C++ mod): " .. info.name)
        end
    elseif draw_pending then
        schedule_settled_draw()
    elseif math.random() * 100 < start_pct then
        grant(idx)
    end
end

-------------------------------------------------------------
-- Re-apply per-run items (call on new run start)
-------------------------------------------------------------

--- Re-spawn all previously received perks/mods/relics and re-grant crystals
--- for a new run. Weapons/abilities/melee are persistent unlocks and don't
--- need re-application.
function M.reapply_run_items()
    -- Re-grant accumulated crystals
    if M._run_crystals > 0 then
        log("Re-granting " .. M._run_crystals .. " crystals for new run")
        crystals_applied = M._run_crystals
        M._grant_crystals(M._run_crystals)
    end

    if #M._run_items == 0 then
        if M._run_crystals == 0 then
            log("No run items or crystals to re-apply")
        end
        return
    end

    -- Greed drop mode: every greed item goes on the floor for manual pickup
    for _, item in ipairs(M._run_items) do
        if item.greed_drop and item.da then
            queue_spawn(item.da, item.name, item.full_name)
        end
    end

    log("Re-applying run items for new run (" .. #M._run_items .. " received)...")
    start_run_draw()
    if has_cpp_mod() then
        -- Flush immediately for re-apply (no need to wait)
        flush()
    end
end

-------------------------------------------------------------
-- Equip weapon/ability/melee
-------------------------------------------------------------

function M._equip_item(slot, info)
    local ps = M._get_ps()
    if not ps then
        log("No player state — cannot equip " .. info.name)
        return
    end

    local ok, err = pcall(function()
        local weapon  = ps.WeaponDA
        local ability = ps.AbilityDA
        local melee   = ps.MeleeDA

        if slot == "weapon" then
            weapon = info.da
        elseif slot == "ability" then
            ability = info.da
        elseif slot == "melee" then
            melee = info.da
        end

        ps:ServerEquipInventory(weapon, ability, melee)
    end)

    if ok then
        log("Equipped " .. slot .. ": " .. info.name)
    else
        log("ServerEquipInventory failed for " .. info.name .. ": " .. tostring(err))
    end
end

-------------------------------------------------------------
-- Grant crystals
-------------------------------------------------------------

function M._grant_crystals(amount)
    local ps = M._get_ps()
    if not ps then
        log("No player state — cannot grant crystals")
        return
    end
    local ok, err = pcall(function()
        local current = ps.Crystals or 0
        ps.Crystals = current + amount
    end)
    if ok then
        log("Granted " .. amount .. " crystals")
    else
        log("Failed to grant crystals: " .. tostring(err))
    end
end

-------------------------------------------------------------
-- Status
-------------------------------------------------------------

--- Get the number of items waiting in the spawn queue.
function M.pending_count()
    return #spawn_queue
end

--- Sanitize all inventory arrays, removing broken entries (null DA or Level=0).
--- Returns the number of entries removed.
function M.sanitize_inventory()
    return sanitize_inventory()
end

return M
