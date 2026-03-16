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

-- Queue for items waiting to be spawned (processed sequentially)
local spawn_queue = {}
local spawn_busy = false

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
--- Greed items can't be dropped once picked up, so we spawn them without
--- auto-collecting, letting the player choose when to pick them up.
local function is_greed_item(full_name)
    if not full_name then return false end
    return full_name:find("/Greed/") ~= nil
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
-- Public API
-------------------------------------------------------------

--- Apply an AP item: equip weapons immediately, spawn+collect perks/mods/relics.
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
            M._run_crystals = M._run_crystals + amount
            M._grant_crystals(amount)
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

    if not info.full_name or not info.da then
        log("No DA resolved for: " .. info.name .. " — cannot apply")
        return
    end

    local equip_lock = _G.AP and _G.AP.equip_lock or nil
    local inv_sanitize = _G.AP and _G.AP.inv_sanitize or nil

    -- Weapons/Abilities/Melee: add to allowed pool only (don't force-equip mid-run)
    if info.cat == CAT.WEAPON then
        if equip_lock then equip_lock.allowed.weapon[info.full_name] = true end
        M.unlocked[info.full_name] = true
        log("Unlocked weapon: " .. info.name)
        return
    elseif info.cat == CAT.ABILITY then
        if equip_lock then equip_lock.allowed.ability[info.full_name] = true end
        M.unlocked[info.full_name] = true
        log("Unlocked ability: " .. info.name)
        return
    elseif info.cat == CAT.MELEE then
        if equip_lock then equip_lock.allowed.melee[info.full_name] = true end
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

    -- Track for re-application on new run
    table.insert(M._run_items, {
        ap_item_id = ap_item_id,
        name = info.name,
        da = info.da,
        full_name = info.full_name,
    })

    if M.in_lobby then
        queue_spawn(info.da, info.name, info.full_name)
    else
        log("Queued for lobby: " .. info.name)
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
    for _, item in ipairs(M._run_items) do
        if item.da then
            queue_spawn(item.da, item.name, item.full_name)
        else
            log("Skipping " .. item.name .. " — no DA reference")
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

return M
