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

-- Lobby state: items are only spawned/granted while in the lobby.
-- Items received mid-run are tracked but not spawned until lobby return.
M.in_lobby = true

-- Queue for items waiting to be spawned (processed sequentially, fallback only)
local spawn_queue = {}
local spawn_busy = false

-- Queue for C++ mod items waiting to be applied in batch
local cpp_pending_queue = {}
local cpp_flush_scheduled = false

-- Per-type overflow queues for items that failed due to full inventory.
-- Keyed by array name so each inventory type retries independently.
local cpp_overflow_queues = {
    Perks = {},
    Relics = {},
    WeaponMods = {},
    MeleeMods = {},
    AbilityMods = {},
}

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
        LoopAsync(300, function()
            if callback then callback(true) end
            return true
        end)
        return
    end

    -- Poll for the new pickup and auto-interact
    local attempts = 0
    local max_attempts = 20  -- 2 seconds at 100ms intervals

    LoopAsync(100, function()
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
            LoopAsync(SPAWN_COOLDOWN_MS, function()
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

        -- Send location check (since we bypassed the pickup hook)
        pcall(function()
            local PickupWatch = require("AP/PickupWatch")
            PickupWatch.send_pickup_check(info.full_name)
        end)

        return true
    else
        log("C++ mod failed for " .. info.name .. ": " .. tostring(result))
        return false
    end
end

-------------------------------------------------------------
-- Batch flush: apply queued C++ items in rate-limited chunks
-------------------------------------------------------------

local FLUSH_BATCH_SIZE = 20       -- items per chunk
local FLUSH_BATCH_DELAY_MS = 100  -- ms pause between chunks

--- Flush all pending C++ items in small batches to avoid overwhelming
--- the engine. Each batch applies up to FLUSH_BATCH_SIZE items, then
--- pauses before the next batch. Items whose inventory type is already
--- full are sent straight to overflow without a C++ call.
--- Merge duplicate items in a list: same name items get combined into one
--- entry with a higher count. Preserves order of first occurrence.
--- Relics are never merged (they don't stack).
local function merge_duplicates(items)
    local CAT = ItemData.CATEGORY
    local merged = {}
    local seen = {}  -- name -> index in merged

    for _, info in ipairs(items) do
        -- Relics don't stack — always separate entries
        local is_relic = info.cat == CAT.RELIC
        if not is_relic and seen[info.name] then
            merged[seen[info.name]].count = merged[seen[info.name]].count + 1
        else
            local entry = { info = info, count = 1 }
            table.insert(merged, entry)
            if not is_relic then
                seen[info.name] = #merged
            end
        end
    end

    return merged
end

local function flush_cpp_queue()
    cpp_flush_scheduled = false
    if #cpp_pending_queue == 0 then return end

    local raw_items = cpp_pending_queue
    cpp_pending_queue = {}

    -- Merge duplicates: e.g. 5x Driller becomes one call with count=5
    local items = merge_duplicates(raw_items)
    log("Flushing " .. #raw_items .. " queued items (" .. #items .. " unique) via C++ mod (batch size " .. FLUSH_BATCH_SIZE .. ")...")

    -- Track which inventory types are known-full so we can skip C++ calls
    local known_full = {}

    local applied = 0
    local overflowed = 0
    local idx = 1

    local function process_batch()
        local batch_end = math.min(idx + FLUSH_BATCH_SIZE - 1, #items)
        local batch_applied = 0

        for i = idx, batch_end do
            local entry = items[i]
            local info = entry.info
            local count = entry.count
            local arr_info = get_cpp_array_info(info.cat)
            local queue_key = arr_info and arr_info[1] or "Perks"

            -- Skip C++ call if this inventory type is already full
            if known_full[queue_key] then
                if cpp_overflow_queues[queue_key] then
                    for j = 1, count do
                        table.insert(cpp_overflow_queues[queue_key], info)
                    end
                end
                overflowed = overflowed + count
            elseif cpp_add_item(info, count) then
                applied = applied + count
                batch_applied = batch_applied + 1
            else
                -- Mark this type as full so we stop hammering C++
                known_full[queue_key] = true
                if cpp_overflow_queues[queue_key] then
                    for j = 1, count do
                        table.insert(cpp_overflow_queues[queue_key], info)
                    end
                end
                overflowed = overflowed + count
            end
        end

        -- Refresh UI after each batch that applied something
        if batch_applied > 0 then
            pcall(AP_RefreshInventoryUI)
        end

        idx = batch_end + 1
        if idx <= #items then
            -- More items remaining — schedule next batch after delay
            LoopAsync(FLUSH_BATCH_DELAY_MS, function()
                process_batch()
                return true  -- run once
            end)
        else
            -- All done — sanitize to clean up any race condition artifacts
            sanitize_inventory()
            local total_overflow = M.overflow_count()
            if overflowed > 0 then
                log("Batch complete: " .. applied .. " applied, " .. overflowed .. " waiting for free slots (" .. total_overflow .. " total overflow)")
            else
                log("Batch complete: " .. applied .. " applied")
            end
        end
    end

    process_batch()
end

local OVERFLOW_BATCH_SIZE = 10       -- items per chunk during overflow retry
local OVERFLOW_BATCH_DELAY_MS = 150  -- ms pause between overflow chunks
local overflow_retry_running = false -- prevent overlapping retries

--- Retry overflow queue items across all inventory types.
--- Each type retries independently so a full perk inventory doesn't block weapon mods.
--- Processes in small batches to avoid overwhelming the engine.
--- Merge overflow queue entries by name within each queue type.
--- Returns a flat work list with merged counts and queue tags.
local function merge_overflow_queues()
    local CAT = ItemData.CATEGORY
    local work = {}

    for queue_name, queue in pairs(cpp_overflow_queues) do
        -- Merge duplicates within this queue
        local seen = {}  -- name -> index in merged
        local merged = {}
        for _, info in ipairs(queue) do
            local is_relic = info.cat == CAT.RELIC
            if not is_relic and seen[info.name] then
                merged[seen[info.name]].count = merged[seen[info.name]].count + 1
            else
                local entry = { queue_name = queue_name, info = info, count = 1 }
                table.insert(merged, entry)
                if not is_relic then
                    seen[info.name] = #merged
                end
            end
        end

        for _, entry in ipairs(merged) do
            table.insert(work, entry)
        end
        cpp_overflow_queues[queue_name] = {}
    end

    return work
end

function M.retry_overflow()
    if M.overflow_count() == 0 then return end
    if not has_cpp_mod() then return end
    if overflow_retry_running then return end  -- already in progress
    overflow_retry_running = true

    -- Merge duplicates within each overflow queue before retrying
    local work = merge_overflow_queues()

    local known_full = {}
    local total_applied = 0
    local idx = 1

    local function process_batch()
        local batch_end = math.min(idx + OVERFLOW_BATCH_SIZE - 1, #work)
        local batch_applied = 0

        for i = idx, batch_end do
            local entry = work[i]
            local qn = entry.queue_name
            local count = entry.count

            if known_full[qn] then
                -- Put back as individual items for future retry
                for j = 1, count do
                    table.insert(cpp_overflow_queues[qn], entry.info)
                end
            elseif cpp_add_item(entry.info, count) then
                batch_applied = batch_applied + 1
                total_applied = total_applied + count
            else
                known_full[qn] = true
                for j = 1, count do
                    table.insert(cpp_overflow_queues[qn], entry.info)
                end
            end
        end

        if batch_applied > 0 then
            pcall(AP_RefreshInventoryUI)
        end

        idx = batch_end + 1
        if idx <= #work then
            LoopAsync(OVERFLOW_BATCH_DELAY_MS, function()
                process_batch()
                return true  -- run once
            end)
        else
            overflow_retry_running = false
            sanitize_inventory()
            if total_applied > 0 then
                log("Overflow retry complete: " .. total_applied .. " applied, " .. M.overflow_count() .. " still waiting")
            end
        end
    end

    process_batch()
end

--- Get the total number of items waiting across all overflow queues.
function M.overflow_count()
    local total = 0
    for _, queue in pairs(cpp_overflow_queues) do
        total = total + #queue
    end
    return total
end

--- Queue an item for batch C++ application.
--- Schedules a flush after a short delay so rapid-fire items are batched.
local function queue_cpp_item(info)
    table.insert(cpp_pending_queue, info)
    if not cpp_flush_scheduled then
        cpp_flush_scheduled = true
        LoopAsync(200, function()
            flush_cpp_queue()
            return true  -- run once
        end)
    end
end

-------------------------------------------------------------
-- Crystal batching: accumulate crystal amounts and grant once
-------------------------------------------------------------
local crystal_pending = 0
local crystal_flush_scheduled = false

local function flush_crystals()
    crystal_flush_scheduled = false
    if crystal_pending <= 0 then return end
    local amount = crystal_pending
    crystal_pending = 0
    M._grant_crystals(amount)
    log("Granted " .. amount .. " crystals (batched)")
end

local function queue_crystals(amount)
    crystal_pending = crystal_pending + amount
    M._run_crystals = M._run_crystals + amount
    if not crystal_flush_scheduled then
        crystal_flush_scheduled = true
        LoopAsync(200, function()
            flush_crystals()
            return true  -- run once
        end)
    end
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

    -- Weapons/Abilities/Melee: add to allowed pool only (don't force-equip mid-run)
    if info.cat == CAT.WEAPON then
        if equip_lock then equip_lock.allow_item("weapon", info.full_name) end
        M.unlocked[info.full_name] = true
        log("Unlocked weapon: " .. info.name)
        return
    elseif info.cat == CAT.ABILITY then
        if equip_lock then equip_lock.allow_item("ability", info.full_name) end
        M.unlocked[info.full_name] = true
        log("Unlocked ability: " .. info.name)
        return
    elseif info.cat == CAT.MELEE then
        if equip_lock then equip_lock.allow_item("melee", info.full_name) end
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

    -- Try C++ mod first (instant, crash-free — works mid-run and in lobby)
    -- Fall back to spawn+collect (lobby only) if C++ mod not available
    if has_cpp_mod() then
        queue_cpp_item(info)
    else
        if M.in_lobby then
            queue_spawn(info.da, info.name, info.full_name)
        else
            log("Queued for lobby (no C++ mod): " .. info.name)
        end
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
        M._grant_crystals(M._run_crystals)
    end

    if #M._run_items == 0 then
        if M._run_crystals == 0 then
            log("No run items or crystals to re-apply")
        end
        return
    end

    log("Re-applying " .. #M._run_items .. " run items for new run...")
    if has_cpp_mod() then
        -- Batch all items through C++ mod, respecting greed mode
        for _, item in ipairs(M._run_items) do
            if item.greed_drop then
                -- Greed drop mode: spawn on floor for manual pickup
                if item.da then
                    queue_spawn(item.da, item.name, item.full_name)
                end
            elseif item.da and item.cat then
                table.insert(cpp_pending_queue, item)
            elseif item.da then
                queue_spawn(item.da, item.name, item.full_name)
            else
                log("Skipping " .. item.name .. " — no DA reference")
            end
        end
        -- Flush immediately for re-apply (no need to wait)
        flush_cpp_queue()
    else
        for _, item in ipairs(M._run_items) do
            if item.da then
                queue_spawn(item.da, item.name, item.full_name)
            else
                log("Skipping " .. item.name .. " — no DA reference")
            end
        end
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
