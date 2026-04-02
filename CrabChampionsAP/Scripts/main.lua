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

local APOverlay = nil
pcall(function() APOverlay = require("AP/APOverlay") end)

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
-- Overlay helpers
------------------------------------------------------------

local function try_create_overlay()
    if not APOverlay then return end
    if APOverlay.is_initialized() then return end
    local config = { server = APClient.server, slot = APClient.slot, password = APClient.password }
    pcall(function()
        APOverlay.create(config)
        log("In-game overlay created")
        if APClient:is_slot_connected() then
            APOverlay.set_connected(APClient.slot or "Connected")
            APOverlay.update_equipment_progress(LocationData, ItemApply, ItemData)
        else
            APOverlay.set_disconnected()
        end
    end)
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

    -- Update equipment checklist if this was a weapon/melee/ability
    if APOverlay then
        if info and (info.cat == ItemData.CATEGORY.WEAPON
                  or info.cat == ItemData.CATEGORY.MELEE
                  or info.cat == ItemData.CATEGORY.ABILITY) then
            APOverlay.update_equipment_progress(LocationData, ItemApply, ItemData)
        end
    end
end

local function on_message(msg)
    clog("MSG", tostring(msg))
    if APOverlay then APOverlay.add_item_log(tostring(msg)) end
end

local function on_slot_connected(slot_data)
    clog("STATUS", "Slot data received")

    -- Save working connection info so it auto-loads next launch
    pcall(function()
        local APConfig = require("AP/APConfig")
        local path = APClient._config_path or "Mods/CrabChampionsAP/Scripts/ap_config.json"
        APConfig.save(path, APClient.server, APClient.slot, APClient.password)
    end)

    -- Resolve game objects now that we're connected and in-game
    ItemData.resolve_game_objects()
    -- Configure location data and pickup watcher with slot options
    LocationData.configure(slot_data)

    -- DeathLink tag is always included in connection tags.
    -- The death_link guard in LocationData controls whether we actually
    -- send/receive deaths — the tag alone is harmless when disabled.

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
                if fn then equip_lock.allow_item("weapon", fn) end
            end
        end
        -- Non-pool melee
        for _, mname in ipairs(LocationData.melee_names) do
            if not LocationData.is_pool_melee(mname) then
                local fn, da = ItemData.get_da(CAT.MELEE, mname)
                if fn then equip_lock.allow_item("melee", fn) end
            end
        end
        -- Non-pool abilities
        for _, aname in ipairs(LocationData.ability_names) do
            if not LocationData.is_pool_ability(aname) then
                local fn, da = ItemData.get_da(CAT.ABILITY, aname)
                if fn then equip_lock.allow_item("ability", fn) end
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

    -- Update overlay
    if APOverlay then
        APOverlay.set_connected(APClient.slot or "Connected")
        APOverlay.hide_panel()
        APOverlay.update_equipment_progress(LocationData, ItemApply, ItemData)
    end

    -- Deferred victory check: on reconnect, the server sends already-checked
    -- locations via location_checked handler AFTER slot_connected.  Wait a few
    -- poll cycles so _checked is populated, then see if victory was already earned.
    LoopAsync(3000, function()
        if PickupWatch.check_victory() then
            clog("STATUS", "Victory conditions already met on reconnect — sending goal!")
        end
        return true  -- run once
    end)

    -- Progressive inventory slots: lock slots to starting counts
    local sl = _G.AP and _G.AP.SlotLock or nil
    if sl then
        if LocationData.progressive_slots then
            sl.set_slots("Perks", LocationData.starting_perk_slots)
            sl.set_slots("WeaponMods", LocationData.starting_weapon_mod_slots)
            sl.set_slots("AbilityMods", LocationData.starting_ability_mod_slots)
            sl.set_slots("MeleeMods", LocationData.starting_melee_mod_slots)
            clog("STATUS", "Progressive slots: Perks=" .. LocationData.starting_perk_slots
                .. " WMods=" .. LocationData.starting_weapon_mod_slots
                .. " AMods=" .. LocationData.starting_ability_mod_slots
                .. " MMods=" .. LocationData.starting_melee_mod_slots)
        else
            sl.disable()
        end
    end

    -- Activate inventory sanitization so perks/mods/relics picked up in-game
    -- are stripped unless received from the AP server.
    -- Only active when pickup_checks is on — when off, players keep items normally.
    local inv_sanitize = _G.AP and _G.AP.inv_sanitize or nil
    if inv_sanitize then
        if LocationData.pickup_checks then
            inv_sanitize.active = true
            clog("STATUS", "Inventory sanitization active — game-given perks/mods/relics will be stripped until received from AP")
        else
            inv_sanitize.active = false
            clog("STATUS", "Pickup checks disabled — inventory sanitization off, items kept normally")
        end
    end
end

-- DeathLink state: prevent loops when we kill the player from a received deathlink
local deathlink_killing = false

local function kill_player(cause)
    local ok, err = pcall(function()
        -- Step 1: Kill the crab (death animation + ragdoll)
        local all_pc = FindAllOf("CrabPlayerC")
        if all_pc and all_pc[1] and all_pc[1]:IsValid() then
            all_pc[1].bIsEliminated = true
            all_pc[1]:OnRep_IsEliminated()
            log("DeathLink: Eliminated player (death animation)")
        end

        -- Step 2: After a delay, trigger the game over screen
        LoopAsync(1500, function()
            pcall(function()
                local all_gm = FindAllOf("CrabGM")
                if all_gm and all_gm[1] and all_gm[1]:IsValid() then
                    all_gm[1]:DebugEndRun()
                    log("DeathLink: Called DebugEndRun (game over screen)")
                end
            end)
            return true -- run once
        end)
    end)
    if not ok then log("DeathLink kill_player error: " .. tostring(err)) end
end

local function execute_deathlink(kill_cause)
    deathlink_killing = true
    kill_player(kill_cause)
    -- Reset flag after a delay to prevent bounce-back
    LoopAsync(2000, function()
        deathlink_killing = false
        return true
    end)
end

local function is_game_paused()
    local paused = false
    pcall(function()
        -- Check if any focus menu is active (pause menu, inventory, settings, etc.)
        local all_pc = FindAllOf("CrabPC")
        if all_pc and all_pc[1] and all_pc[1]:IsValid() then
            local active_menu = all_pc[1].ActiveFocusMenuUI
            if active_menu and active_menu:IsValid() then
                paused = true
            end
        end
        -- Also check GS time pause as fallback (multiplayer)
        if not paused then
            local all_gs = FindAllOf("CrabGS")
            if all_gs and all_gs[1] and all_gs[1]:IsValid() then
                if all_gs[1].bIsTimePaused then
                    paused = true
                end
            end
        end
    end)
    return paused
end

local function on_deathlink(source, cause)
    -- Ignore if death_link is not enabled for this slot
    if not LocationData.death_link then
        log("DeathLink received but death_link is disabled for this slot — ignoring")
        return
    end

    local msg = "DeathLink from " .. tostring(source)
    if cause and cause ~= "" then msg = msg .. ": " .. cause end
    clog("DEATHLINK", msg)
    if APOverlay then APOverlay.add_feed_line(msg, 0) end

    -- Don't kill in lobby — only during runs
    if ItemApply.in_lobby then
        log("DeathLink received but player is in lobby — ignoring")
        return
    end

    local kill_cause = source or "DeathLink"
    if cause and cause ~= "" then kill_cause = kill_cause .. ": " .. cause end

    -- If paused, wait until unpaused to apply the kill
    if is_game_paused() then
        log("DeathLink received while paused — waiting for unpause...")
        LoopAsync(250, function()
            if ItemApply.in_lobby then
                log("DeathLink cancelled — player returned to lobby while paused")
                return true  -- stop polling
            end
            if not is_game_paused() then
                log("Game unpaused — applying queued DeathLink")
                execute_deathlink(kill_cause)
                return true  -- stop polling
            end
            return false  -- keep polling
        end)
        return
    end

    execute_deathlink(kill_cause)
end

------------------------------------------------------------
-- Initialize AP Client
------------------------------------------------------------

APClient.on_item = on_item
APClient.on_message = on_message
APClient.on_slot_connected = on_slot_connected
APClient.on_deathlink = on_deathlink
APClient.on_item_send = function(info)
    if APOverlay then APOverlay.add_feed_item(info) end
end
APClient.on_disconnected = function()
    if APOverlay then APOverlay.set_disconnected() end
end
APClient.on_slot_refused = function(reason_str)
    if APOverlay then APOverlay.set_disconnected("Refused: " .. tostring(reason_str)) end
end

local config_path = "Mods/CrabChampionsAP/Scripts/ap_config.json"
local init_ok = APClient:init(config_path)

if not init_ok then
    log("AP client failed to initialize — running without AP features")
end

-- Install pickup watcher (sends location checks + removes items)
PickupWatch.install(APClient)

-- DeathLink: send when player is eliminated during a run
pcall(function()
    RegisterHook("/Script/CrabChampions.CrabPC:ClientOnEliminated", function(Context, EliminationCause)
        -- Don't send if death_link is disabled for this slot
        if not LocationData.death_link then return end
        -- Don't send if we caused this death (received deathlink)
        if deathlink_killing then return end
        -- Don't send if in lobby
        if ItemApply.in_lobby then return end
        -- Don't send if not connected
        if not APClient:is_slot_connected() then return end

        local cause = ""
        pcall(function()
            if EliminationCause then
                cause = EliminationCause:get():ToString()
            end
        end)

        log("Player eliminated — sending DeathLink" .. (cause ~= "" and (": " .. cause) or ""))
        APClient:send_deathlink(APClient.slot or "Crab Champions", cause)

        if APOverlay then
            APOverlay.add_feed_line("DeathLink sent!", 0)
        end
    end)
    log("DeathLink send hook installed")
end)

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

-- Expose overlay globally
if APOverlay then
    AP.Overlay = APOverlay
end

-- Overlay keybinds
-- F4: Toggle connection/progress panel
RegisterKeyBind(Key.F4, function()
    ExecuteInGameThread(function()
        if APOverlay then
            if not APOverlay.is_initialized() then try_create_overlay() end
            if APOverlay.is_initialized() then
                APOverlay.toggle_panel()
            else
                log("Overlay not available (game not fully loaded?)")
            end
        end
    end)
end)

-- F3: Connect/disconnect using overlay input fields
RegisterKeyBind(Key.F3, function()
    ExecuteInGameThread(function()
        if APClient:is_slot_connected() or APClient:is_connected() then
            log("Disconnecting from AP server...")
            APClient:queue_command("disconnect")
            if APOverlay then APOverlay.set_disconnected() end
        else
            -- Read connection details from overlay inputs if available
            if APOverlay and APOverlay.is_initialized() then
                local server = APOverlay.get_server()
                local slot = APOverlay.get_slot()
                local password = APOverlay.get_password()
                if server and server ~= "" then APClient.server = server end
                if slot and slot ~= "" then APClient.slot = slot end
                if password then APClient.password = password end
            end
            log("Connecting to " .. tostring(APClient.server) .. " as '" .. tostring(APClient.slot) .. "'...")
            if APOverlay then APOverlay.set_connecting() end
            APClient:queue_command("connect")
        end
    end)
end)

-- Recreate overlay on level transitions
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
        ExecuteInGameThread(function()
            try_create_overlay()
        end)
    end)
end)

-- Initial overlay creation (deferred to game thread)
ExecuteInGameThread(function()
    try_create_overlay()
end)

log("Archipelago mod loaded" .. (APClient.enabled and " (AP enabled)" or " (AP disabled)"))

-- Slot Lock module (progressive inventory slots)
local SlotLock = require("AP/SlotLock")
SlotLock.install()
AP.SlotLock = SlotLock
log("SlotLock loaded and installed")

-- F1: Test equip lock — only Auto Rifle allowed
RegisterKeyBind(Key.F1, function()
    LoopAsync(1, function()
        if not ItemData.is_resolved() then ItemData.resolve_game_objects() end
        local equip_lock = _G.AP and _G.AP.equip_lock or nil
        if not equip_lock then log("F1: No equip_lock"); return true end

        -- Reset and allow only Auto Rifle + first ability + first melee
        equip_lock.allowed = { weapon = {}, ability = {}, melee = {} }

        local fn_w = ItemData.get_da(ItemData.CATEGORY.WEAPON, "Auto Rifle")
        local fn_a = ItemData.get_da(ItemData.CATEGORY.ABILITY, "Grenade")
        local fn_m = ItemData.get_da(ItemData.CATEGORY.MELEE, "Hammer")

        if fn_w then equip_lock.allow_item("weapon", fn_w) end
        if fn_a then equip_lock.allow_item("ability", fn_a) end
        if fn_m then equip_lock.allow_item("melee", fn_m) end

        equip_lock.request_enforce("F1 test")
        log("F1: Locked to Auto Rifle / Grenade / Hammer — try switching weapons!")
        return true
    end)
end)

-- F2: Unlock Crossbow as additional weapon
RegisterKeyBind(Key.F2, function()
    LoopAsync(1, function()
        if not ItemData.is_resolved() then ItemData.resolve_game_objects() end
        local equip_lock = _G.AP and _G.AP.equip_lock or nil
        if not equip_lock then log("F2: No equip_lock"); return true end

        local fn = ItemData.get_da(ItemData.CATEGORY.WEAPON, "Crossbow")
        if fn then
            equip_lock.allow_item("weapon", fn)
            log("F2: Unlocked Crossbow!")
        end
        return true
    end)
end)

-- F9: Dump all pickup DA tags and requirements to file
RegisterKeyBind(Key.F9, function()
    LoopAsync(1, function()
        log("=== DUMPING PICKUP TAGS ===")
        if not ItemData.is_resolved() then ItemData.resolve_game_objects() end

        local TAG_NAMES = {
            [0] = "None", [1] = "Healing", [2] = "DamageOverTime", [3] = "Critical",
            [4] = "Speed", [5] = "Bounce", [6] = "Ice", [7] = "Fire",
            [8] = "Lightning", [9] = "Poison", [10] = "Arcane", [11] = "Turret",
            [12] = "Combo", [13] = "GlueShot", [14] = "Charger",
        }

        local lines = {}
        lines[#lines + 1] = "=== PICKUP TAG DUMP ==="
        lines[#lines + 1] = ""

        -- Items that PROVIDE a tag (tag providers)
        local providers = {}  -- tag_id -> list of item names
        -- Items that REQUIRE a matching tag
        local requirers = {}  -- tag_id -> list of item names

        local classes = {
            "CrabPerkDA", "CrabRelicDA", "CrabWeaponModDA",
            "CrabMeleeModDA", "CrabAbilityModDA",
        }

        for _, class_name in ipairs(classes) do
            local all = FindAllOf(class_name)
            if all then
                for _, da in ipairs(all) do
                    pcall(function()
                        if not da or not da:IsValid() then return end
                        local name = da.Name or "?"
                        local tag = tonumber(da.PickupTag) or 0
                        local requires = da.bRequiresMatchingPickupTag

                        if type(name) ~= "string" then
                            pcall(function() name = name:ToString() end)
                        end
                        name = tostring(name)

                        local tag_name = TAG_NAMES[tag] or tostring(tag)

                        if tag > 0 and not requires then
                            if not providers[tag] then providers[tag] = {} end
                            table.insert(providers[tag], name .. " (" .. class_name .. ")")
                        end

                        if requires then
                            if not requirers[tag] then requirers[tag] = {} end
                            table.insert(requirers[tag], name .. " (" .. class_name .. ")")
                        end
                    end)
                end
            end
        end

        -- Format output grouped by tag
        for tag_id = 0, 14 do
            local tag_name = TAG_NAMES[tag_id] or tostring(tag_id)
            local provs = providers[tag_id]
            local reqs = requirers[tag_id]

            if provs or reqs then
                lines[#lines + 1] = "--- Tag: " .. tag_name .. " (" .. tag_id .. ") ---"
                if provs then
                    lines[#lines + 1] = "  PROVIDES this tag:"
                    table.sort(provs)
                    for _, p in ipairs(provs) do
                        lines[#lines + 1] = "    " .. p
                    end
                end
                if reqs then
                    lines[#lines + 1] = "  REQUIRES this tag:"
                    table.sort(reqs)
                    for _, r in ipairs(reqs) do
                        lines[#lines + 1] = "    " .. r
                    end
                end
                lines[#lines + 1] = ""
            end
        end

        -- Write to file
        local path = "Mods/CrabChampionsAP/Scripts/pickup_tags.txt"
        local f = io.open(path, "w")
        if f then
            f:write(table.concat(lines, "\n") .. "\n")
            f:close()
            log("  Written to " .. path .. " (" .. #lines .. " lines)")
        else
            log("  ERROR: Could not write to " .. path)
        end

        return true
    end)
end)

log("  F1 = Lock to Auto Rifle | F2 = Unlock Crossbow | F3 = Connect | F4 = Overlay | F9 = Dump tags")
