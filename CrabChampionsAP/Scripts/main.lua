-- Crab Champions Archipelago Mod (UE4SS Lua)
-- Connects directly to the AP server via lua-apclientpp.
-- No external Python bridge required.
--
-- THREADING MODEL:
-- All DLL interaction (client creation + polling) runs in a LoopAsync
-- callback on a single consistent thread, as required by lua-apclientpp.
-- RegisterHook callbacks run on the game thread and only queue data
-- (location checks, chat) for the LoopAsync thread to send.

local APClient = require("AP/APClient")
local ItemApply = require("AP/ItemApply")
local ItemData = require("AP/ItemData")
local LocationData = require("AP/LocationData")
local PickupWatch = require("AP/PickupWatch")

------------------------------------------------------------
-- Logging (Console.log used when available, fallback to plain print)
------------------------------------------------------------
local Console = nil  -- set after Console module loads

local function log(msg)
    print("[CrabAP] " .. tostring(msg))
end

local function clog(category, msg)
    if Console then
        Console.log(category, msg)
    else
        log(tostring(msg))
    end
end

------------------------------------------------------------
-- AP Callbacks (fired from LoopAsync thread during poll)
------------------------------------------------------------

local function on_item(it)
    local item_id = tonumber(it.item) or 0
    local info = ItemData.from_ap_id(item_id)
    local name = info and info.name or ("Item#" .. item_id)

    clog("ITEM", string.format("Received: %s (idx=%d from=Player%s flags=%d)",
        name,
        tonumber(it.index) or -1,
        tostring(it.player),
        tonumber(it.flags) or 0
    ))

    -- Apply immediately — we're on the LoopAsync thread, no need to defer
    ItemApply.apply_item(item_id)
end

local function on_message(msg)
    clog("MSG", tostring(msg))
    -- TODO: Display in-game HUD message
end

local function on_slot_connected(slot_data)
    clog("STATUS", "Slot data received")
    -- Resolve game objects now that we're connected and in-game
    ItemData.resolve_game_objects()
    -- Configure location data and pickup watcher with slot options
    LocationData.configure(slot_data)

    -- Log goal summary so the player knows what equipment they need
    local opts = slot_data and slot_data.options or slot_data or {}
    local sep = "=================================="
    clog("INFO", sep)
    clog("INFO", "  Victory Requirements")
    clog("INFO", sep)
    clog("INFO", "  Rank:        " .. tostring(opts.required_rank_name or "?"))
    clog("INFO", "  Run Length:  " .. tostring(opts.run_length or "?") .. " islands")

    -- Pool weapons
    local pw = opts.pool_weapons or {}
    local wfc = opts.weapons_for_completion or #pw
    clog("INFO", "  Weapons:     " .. wfc .. " of " .. #pw .. " pool weapons needed")
    for _, name in ipairs(pw) do
        clog("INFO", "    - " .. name)
    end

    -- Pool melee
    local pm = opts.pool_melee or {}
    local mfc = opts.melee_for_completion or 0
    if mfc > 0 then
        clog("INFO", "  Melee:       " .. mfc .. " of " .. #pm .. " pool melee needed")
        for _, name in ipairs(pm) do
            clog("INFO", "    - " .. name)
        end
    end

    -- Pool abilities
    local pa = opts.pool_abilities or {}
    local afc = opts.ability_for_completion or 0
    if afc > 0 then
        clog("INFO", "  Abilities:   " .. afc .. " of " .. #pa .. " pool abilities needed")
        for _, name in ipairs(pa) do
            clog("INFO", "    - " .. name)
        end
    end
    clog("INFO", sep)

    -- Pre-allow non-pool equipment in equip_lock so they're usable from start.
    -- Pool equipment must be received as AP items (handled by ItemApply).
    local equip_lock = _G.AP and _G.AP.equip_lock or nil
    if equip_lock then
        local CAT = ItemData.CATEGORY
        -- Non-pool weapons
        for _, wname in ipairs(LocationData.weapon_names) do
            if not LocationData.is_pool_weapon(wname) then
                local fn, da = ItemData.get_da(CAT.WEAPON, wname)
                if fn then
                    equip_lock.allowed.weapon[fn] = true
                end
            end
        end
        -- Non-pool melee
        for _, mname in ipairs(LocationData.melee_names) do
            if not LocationData.is_pool_melee(mname) then
                local fn, da = ItemData.get_da(CAT.MELEE, mname)
                if fn then
                    equip_lock.allowed.melee[fn] = true
                end
            end
        end
        -- Non-pool abilities
        for _, aname in ipairs(LocationData.ability_names) do
            if not LocationData.is_pool_ability(aname) then
                local fn, da = ItemData.get_da(CAT.ABILITY, aname)
                if fn then
                    equip_lock.allowed.ability[fn] = true
                end
            end
        end
        local np_w = #LocationData.weapon_names - #pw
        local np_m = #LocationData.melee_names - #pm
        local np_a = #LocationData.ability_names - #pa
        clog("STATUS", "Non-pool equipment pre-allowed (" ..
            np_w .. " weapons, " .. np_m .. " melee, " .. np_a .. " abilities)")

        -- Force immediate enforcement in case player already has a disallowed weapon
        equip_lock.refresh_maps()
        -- Trigger a deferred enforce on next tick
        equip_lock.request_enforce("slot_connected")
    end

    -- Activate inventory sanitization so perks/mods/relics picked up in-game
    -- are stripped unless received from the AP server.
    local inv_sanitize = _G.AP and _G.AP.inv_sanitize or nil
    if inv_sanitize then
        inv_sanitize.active = true
        clog("STATUS", "Inventory sanitization active — game-given perks/mods/relics will be stripped until received from AP")
    end
end

local function on_deathlink(source, cause)
    clog("DEATHLINK", "From " .. tostring(source) .. (cause ~= "" and (": " .. cause) or ""))
    -- TODO: Kill the player
end

------------------------------------------------------------
-- Initialize AP Client
------------------------------------------------------------

APClient.on_item = on_item
APClient.on_message = on_message
APClient.on_slot_connected = on_slot_connected
APClient.on_deathlink = on_deathlink

local config_path = "Mods/ArchipelagoMod/Scripts/ap_config.json"
local init_ok = APClient:init(config_path)

if not init_ok then
    log("AP client failed to initialize — running without AP features")
end

-- Install pickup watcher (sends location checks + removes items)
PickupWatch.install(APClient)

-- Expose globally so other mod files can use it
AP = AP or {}
AP.Client = APClient

-- Expose EquipLock and InventorySanitize for ItemApply to use
local equip_lock_ok, equip_lock = pcall(require, "AP/EquipLock")
if equip_lock_ok then
    AP.equip_lock = equip_lock
    equip_lock.install()
    log("EquipLock loaded and installed")
else
    log("EquipLock not available: " .. tostring(equip_lock))
end

local inv_sanitize_ok, inv_sanitize = pcall(require, "AP/InventorySanitize")
if inv_sanitize_ok then
    AP.inv_sanitize = inv_sanitize

    -- Hook pickup events to sanitize inventory when game gives perks/mods/relics
    RegisterHook("/Script/CrabChampions.CrabPC:ClientOnPickedUpPickup", function(Context, PickupDA)
        -- Delay slightly so the game finishes adding the item to inventory
        LoopAsync(300, function()
            inv_sanitize.sanitize_all_players()
            return true  -- run once
        end)
    end)

    -- Hook portal/island events (game may grant items during transitions)
    RegisterHook("/Script/CrabChampions.CrabPC:ClientOnEnteredPortal", function(Context, ...)
        LoopAsync(500, function()
            inv_sanitize.sanitize_all_players()
            return true
        end)
    end)

    RegisterHook("/Script/CrabChampions.CrabPC:ClientOnClearedIsland", function(Context, ...)
        LoopAsync(500, function()
            inv_sanitize.sanitize_all_players()
            return true
        end)
    end)

    -- Periodic safety net: sanitize every 2 seconds if allowed sets are populated
    LoopAsync(2000, function()
        inv_sanitize.sanitize_all_players()
        return false  -- keep looping
    end)

    log("InventorySanitize loaded and hooked")
else
    log("InventorySanitize not available: " .. tostring(inv_sanitize))
end

-- Load console UI (keybinds + enhanced logging)
local console_ok, ConsoleModule = pcall(require, "AP/Console")
if console_ok then
    Console = ConsoleModule
    Console.init(APClient, config_path)
    AP.Console = Console
    log("Console controls loaded (F6/F7/F8)")
else
    log("Console module not available: " .. tostring(ConsoleModule))
end

log("Archipelago mod loaded" .. (APClient.enabled and " (AP enabled)" or " (AP disabled)"))
