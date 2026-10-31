-- Crab Champions Archipelago Mod (UE4SS Lua)
-- Connects directly to the AP server via lua-apclientpp.
-- No external Python bridge required.
--
-- THREADING MODEL:
-- Everything runs on the game thread, through one scheduler (AP/GameThread.lua):
-- timers use GameThread.loop / GameThread.after, deferred work GameThread.run,
-- and key binds (which UE4SS calls from another thread) GameThread.signal.
-- UE4SS 3.0.1 shares one Lua state between its LoopAsync thread and the game
-- thread without a lock, so Lua running on both at once corrupts it (crashes in
-- UE4SS.dll, freezes). Never call LoopAsync or ExecuteInGameThread directly.
-- The AP client is created and polled inside one persistent coroutine, as
-- lua-apclientpp requires (see AP/APClient.lua).

local APClient = require("AP/APClient")
local ItemApply = require("AP/ItemApply")
local ItemData = require("AP/ItemData")
local LocationData = require("AP/LocationData")
local PickupWatch = require("AP/PickupWatch")
local Traps = require("AP/Traps")
local Achievements = require("AP/Achievements")
local ModifierUnlock = require("AP/ModifierUnlock")
local BiomeLock = require("AP/BiomeLock")
local GameThread = require("AP/GameThread")
-- The scheduler starts here, outside any coroutine (LoopAsync is a UE4SS function): the dll's per-frame callback
-- when available, else the LoopAsync driver. Neither runs work before GameThread.loaded() at the end of this file:
-- hooks registered while work is queued can lose their Lua thread.
GameThread.start()

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
            APOverlay.update_equipment_progress(LocationData, ItemApply, ItemData, APClient)
        else
            APOverlay.set_disconnected()
        end
    end)
end

------------------------------------------------------------
-- AP Callbacks (fired during poll, run on the game thread via GameThread.wrap)
------------------------------------------------------------

-- Forward declaration: set later once the description system is defined
local _on_item_received_for_descriptions = nil

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

    -- The window's Recent Items list: what arrived and who it came from
    if APOverlay and APOverlay.add_item_log then
        local sender = nil
        pcall(function() sender = APClient._client:get_player_alias(tonumber(it.player)) end)
        APOverlay.add_item_log(name .. " from " .. tostring(sender or "Archipelago"))
    end

    -- Traps and Perk Boosts are handled by their own module (with its own
    -- replay ledger); everything else is applied right away.
    local identity = tostring(APClient.slot_data and APClient.slot_data.seed) .. "/" .. tostring(APClient.slot)
    local trap_ok, trap_handled = pcall(Traps.on_item, info, it.index, identity)
    local biome_ok, biome_handled = pcall(BiomeLock.on_item, info)
    if not ((trap_ok and trap_handled) or (biome_ok and biome_handled)) then
        ItemApply.apply_item(item_id)
    end

    -- Track received item for description updates
    if _on_item_received_for_descriptions then _on_item_received_for_descriptions(it) end

    -- Update equipment checklist if this was a weapon/melee/ability
    if APOverlay then
        if info and (info.cat == ItemData.CATEGORY.WEAPON
                  or info.cat == ItemData.CATEGORY.MELEE
                  or info.cat == ItemData.CATEGORY.ABILITY
                  or (biome_ok and biome_handled)) then
            APOverlay.update_equipment_progress(LocationData, ItemApply, ItemData, APClient)
        end
    end
end

local function on_message(msg)
    clog("MSG", tostring(msg))
end

------------------------------------------------------------
-- Equipment unlock: manage bRequiresUnlock on equipment DAs
-- and save game unlocked arrays to control which equipment
-- the player can select. Pool items start locked and unlock
-- as AP sends them. Non-pool items are unlocked on connect.
--
-- Save game safety: before modifying the SG unlocked arrays,
-- we copy SaveSlot.sav → SaveSlot_AP_backup.sav. On disconnect
-- we restore from the in-memory snapshot and delete the backup.
-- If the game crashes mid-session, the backup file persists and
-- is auto-restored on next mod startup — zero risk to player data.
------------------------------------------------------------
local original_unlock_flags = {}  -- full_name -> original bRequiresUnlock value

-- Save game array names for equipment unlock tracking
local SG_UNLOCK_ARRAYS = {"UnlockedWeapons", "UnlockedAbilities", "UnlockedMeleeWeapons"}

-- Map DA class name → SG array name
local CLASS_TO_SG_ARRAY = {
    CrabWeaponDA  = "UnlockedWeapons",
    CrabAbilityDA = "UnlockedAbilities",
    CrabMeleeDA   = "UnlockedMeleeWeapons",
}

-- Resolve save game directory path
local SAVE_DIR = nil
pcall(function()
    local appdata = os.getenv("LOCALAPPDATA")
    if appdata then
        SAVE_DIR = appdata .. "\\CrabChampions\\Saved\\SaveGames\\"
    end
end)

local SAVE_FILE = SAVE_DIR and (SAVE_DIR .. "SaveSlot.sav") or nil
local BACKUP_FILE = SAVE_DIR and (SAVE_DIR .. "SaveSlot_AP_backup.sav") or nil

--- Copy a file from src to dst (binary). Returns true on success.
local function copy_file(src, dst)
    local inp, err1 = io.open(src, "rb")
    if not inp then
        log("File copy failed (open src): " .. tostring(err1))
        return false
    end
    local data = inp:read("*a")
    inp:close()
    local out, err2 = io.open(dst, "wb")
    if not out then
        log("File copy failed (open dst): " .. tostring(err2))
        return false
    end
    out:write(data)
    out:close()
    return true
end

--- Check if a file exists.
local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

--- Crash recovery: if a backup exists from a previous crashed session,
--- restore it over SaveSlot.sav before the game loads the save.
local function recover_backup_save()
    if not BACKUP_FILE or not SAVE_FILE then return end
    if file_exists(BACKUP_FILE) then
        log("RECOVERY: Found AP backup save from a previous crashed session")
        if copy_file(BACKUP_FILE, SAVE_FILE) then
            os.remove(BACKUP_FILE)
            log("RECOVERY: Restored original save and deleted backup")
        else
            log("RECOVERY: Failed to restore — backup preserved at " .. BACKUP_FILE)
        end
    end
end

--- Create a backup of the save file before modifying SG arrays.
local function create_save_backup()
    if not SAVE_FILE or not BACKUP_FILE then
        log("Save backup: cannot resolve save path")
        return false
    end
    if copy_file(SAVE_FILE, BACKUP_FILE) then
        log("Save backup created: " .. BACKUP_FILE)
        return true
    end
    return false
end

--- Delete the backup file (called on clean disconnect).
local function delete_save_backup()
    if not BACKUP_FILE then return end
    if file_exists(BACKUP_FILE) then
        os.remove(BACKUP_FILE)
        log("Save backup deleted (clean disconnect)")
    end
end

--- Lock ALL equipment: backup save, snapshot+clear SG arrays, set bRequiresUnlock.
local function lock_all_equipment()
    -- Block achievement writes before the rank is raised, and until it is put back.
    Achievements.set_active(true)
    original_unlock_flags = {}
    local locked = 0

    -- 1) Create filesystem backup of save file (crash safety net)
    create_save_backup()

    -- 2) Snapshot + clear save game unlocked arrays so lobby UI hides locked items
    if AP_SG_Snapshot then
        for _, arr in ipairs(SG_UNLOCK_ARRAYS) do
            pcall(AP_SG_Snapshot, arr)
        end
        for _, arr in ipairs(SG_UNLOCK_ARRAYS) do
            pcall(AP_SG_Clear, arr)
        end
        log("Save game unlocked arrays: snapshotted and cleared")
    end

    -- 3) Set bRequiresUnlock=true on all equipment DAs
    for _, class_name in ipairs({"CrabWeaponDA", "CrabAbilityDA", "CrabMeleeDA"}) do
        pcall(function()
            local all = FindAllOf(class_name)
            if not all then return end
            for _, da in ipairs(all) do
                if da and (not da.IsValid or da:IsValid()) then
                    pcall(function()
                        local fn = da:GetFullName()
                        original_unlock_flags[fn] = da.bRequiresUnlock or false
                        da.bRequiresUnlock = true
                        locked = locked + 1
                    end)
                end
            end
        end)
    end

    log("Equipment lock: set bRequiresUnlock=true on " .. locked .. " DAs")

    -- 4) Difficulty modifiers: unlocked by ModifierUnlock (button level), never by raising the account rank/level.
    ModifierUnlock.set_active(true)
end

--- Unlock a specific equipment DA by full_name (set bRequiresUnlock=false + add to SG).
--- Called when non-pool equipment is pre-allowed or AP items are received.
local function unlock_equipment_da(full_name)
    for _, class_name in ipairs({"CrabWeaponDA", "CrabAbilityDA", "CrabMeleeDA"}) do
        pcall(function()
            local all = FindAllOf(class_name)
            if not all then return end
            for _, da in ipairs(all) do
                if da and (not da.IsValid or da:IsValid()) then
                    pcall(function()
                        if da:GetFullName() == full_name then
                            da.bRequiresUnlock = false
                            -- Also add to save game unlocked array so lobby UI shows it
                            local sg_arr = CLASS_TO_SG_ARRAY[class_name]
                            if sg_arr and AP_SG_Add then
                                pcall(AP_SG_Add, sg_arr, da:GetAddress())
                            end
                        end
                    end)
                end
            end
        end)
    end
end

--- Restore equipment locks: restore SG arrays, bRequiresUnlock flags, account rank.
local function restore_equipment_locks()
    -- 1) Restore save game unlocked arrays from in-memory snapshot
    if AP_SG_Restore then
        for _, arr in ipairs(SG_UNLOCK_ARRAYS) do
            pcall(AP_SG_Restore, arr)
        end
        log("Save game unlocked arrays: restored from snapshot")
    end

    -- 2) Delete the filesystem backup (clean disconnect = no recovery needed)
    delete_save_backup()

    -- 3) Restore bRequiresUnlock on all DAs
    if next(original_unlock_flags) then
        local total = 0
        for _, class_name in ipairs({"CrabWeaponDA", "CrabAbilityDA", "CrabMeleeDA"}) do
            pcall(function()
                local all = FindAllOf(class_name)
                if not all then return end
                for _, da in ipairs(all) do
                    if da and (not da.IsValid or da:IsValid()) then
                        pcall(function()
                            local fn = da:GetFullName()
                            if original_unlock_flags[fn] ~= nil then
                                da.bRequiresUnlock = original_unlock_flags[fn]
                                total = total + 1
                            end
                        end)
                    end
                end
            end)
        end
        original_unlock_flags = {}
        log("Equipment unlock: restored bRequiresUnlock on " .. total .. " DAs")
    end

    -- 4) Deactivate C++ equip lock enforcement
    if AP_EquipLock_SetActive then
        pcall(AP_EquipLock_SetActive, false)
        log("EquipLock deactivated")
    end

    -- 5) Difficulty modifier unlock off (rank and level were never changed, so there is nothing to restore)
    ModifierUnlock.set_active(false)
    Achievements.set_active(false)
end

-- Run crash recovery on mod startup (before game loads the save)
recover_backup_save()

-- Expose unlock function globally so ItemApply can unlock DAs as items arrive
AP = AP or {}
AP.unlock_equipment_da = unlock_equipment_da

------------------------------------------------------------
-- Pickup description updates: show what AP item is at each
-- location, whether it's already been checked, and whether
-- own items have been received.
------------------------------------------------------------
local original_descriptions = {}  -- full_name -> original Description string
local location_to_da = {}         -- location_id -> { full_name, da }
local scouted_info = {}           -- location_id -> { item_name, player_name, player_slot, item_id, flags }
local received_da_set = {}        -- da_full_name -> true, for items we've been sent via AP

--- Build a reverse map from location_id → DA for all pickup-type DAs.
local function build_location_da_map()
    location_to_da = {}
    local count = 0
    local pickup_classes = {
        { class = "CrabPerkDA",       kind = "perk" },
        { class = "CrabRelicDA",      kind = "relic" },
        { class = "CrabWeaponModDA",  kind = "weapon_mod" },
        { class = "CrabMeleeModDA",   kind = "melee_mod" },
        { class = "CrabAbilityModDA", kind = "ability_mod" },
    }
    for _, info in ipairs(pickup_classes) do
        pcall(function()
            local all = FindAllOf(info.class)
            if not all then return end
            for _, da in ipairs(all) do
                if da and (not da.IsValid or da:IsValid()) then
                    pcall(function()
                        local fn = da:GetFullName()
                        local loc_id = LocationData.from_da(fn)
                        if loc_id then
                            location_to_da[loc_id] = { full_name = fn, da = da }
                            count = count + 1
                        end
                    end)
                end
            end
        end)
    end
    log("Built location→DA map: " .. count .. " pickup locations")
    return count
end

--- Scout all pickup locations to get item info from the AP server.
local function scout_all_pickups()
    local ids = {}
    for loc_id, _ in pairs(location_to_da) do
        ids[#ids + 1] = loc_id
    end
    if #ids > 0 then
        APClient:send_scouts(ids)
        log("Scouting " .. #ids .. " pickup locations...")
    end
end

--- Update a single DA's Description with AP info.
local function update_da_description(da, full_name, item_name, player_name, is_checked, is_received)
    pcall(function()
        -- Snapshot original description once
        if original_descriptions[full_name] == nil then
            original_descriptions[full_name] = da.Description or ""
        end

        local parts = {}

        if is_checked then
            parts[#parts + 1] = "[CHECKED]"
        end
        if is_received then
            parts[#parts + 1] = "[RECEIVED]"
        end

        parts[#parts + 1] = tostring(player_name) .. "'s " .. tostring(item_name)

        da.Description = table.concat(parts, " ")
    end)
end

--- Re-render a single location's DA description from cached scouted info.
local function refresh_da_description(loc_id)
    local da_info = location_to_da[loc_id]
    local info = scouted_info[loc_id]
    if not da_info or not info then return end

    local is_checked = APClient:is_location_checked(loc_id)
    -- [RECEIVED] means the player has been sent this in-game item via AP,
    -- so picking it up won't get stripped from inventory.
    local is_received = received_da_set[da_info.full_name] == true
    update_da_description(da_info.da, da_info.full_name, info.item_name, info.player_name, is_checked, is_received)
end

--- Restore all DA descriptions to their original values.
local function restore_all_descriptions()
    if not next(original_descriptions) then return end
    local total = 0
    local pickup_classes = {"CrabPerkDA", "CrabRelicDA", "CrabWeaponModDA", "CrabMeleeModDA", "CrabAbilityModDA"}
    for _, class_name in ipairs(pickup_classes) do
        pcall(function()
            local all = FindAllOf(class_name)
            if not all then return end
            for _, da in ipairs(all) do
                if da and (not da.IsValid or da:IsValid()) then
                    pcall(function()
                        local fn = da:GetFullName()
                        if original_descriptions[fn] ~= nil then
                            da.Description = original_descriptions[fn]
                            total = total + 1
                        end
                    end)
                end
            end
        end)
    end
    original_descriptions = {}
    log("Restored original descriptions on " .. total .. " DAs")
end

--- Look up the item and player names for scouted entries. Uses the AP client,
--- so it runs on the client's poll thread, before the entries go to the game thread.
local function resolve_scout_names(items)
    if type(items) ~= "table" then return end
    for _, entry in ipairs(items) do
        pcall(function()
            local item_id = tonumber(entry.item)
            local player_slot = tonumber(entry.player)
            if not item_id or not player_slot then return end
            local player_game = nil
            pcall(function() player_game = APClient._client:get_player_game(player_slot) end)
            pcall(function() entry.item_name = APClient._client:get_item_name(item_id, player_game or "") end)
            pcall(function() entry.player_name = APClient._client:get_player_alias(player_slot) end)
        end)
    end
end

--- Handle scouted location info from the AP server.
local function on_location_info(items)
    if type(items) ~= "table" then return end
    local updated = 0
    for _, entry in ipairs(items) do
        pcall(function()
            local loc_id = tonumber(entry.location)
            local item_id = tonumber(entry.item)
            local player_slot = tonumber(entry.player)
            local flags = tonumber(entry.flags) or 0

            if not loc_id or not item_id then return end

            local da_info = location_to_da[loc_id]
            if not da_info then return end

            -- Names were looked up by resolve_scout_names on the poll thread
            local item_name = entry.item_name or ("Item#" .. tostring(item_id))
            local player_name = entry.player_name or ("Player" .. tostring(player_slot))

            -- Cache scouted info for live re-rendering
            scouted_info[loc_id] = {
                item_name = item_name,
                player_name = player_name,
                player_slot = player_slot,
                item_id = item_id,
                flags = flags,
            }

            -- Render the description
            refresh_da_description(loc_id)
            updated = updated + 1
        end)
    end
    log("Updated descriptions on " .. updated .. " pickup DAs")
end

--- Called when locations are checked (during a run or from server sync).
--- Updates DA descriptions to show [CHECKED] status live, and refreshes
--- the equipment-progress overlay so completion check marks appear.
local function on_location_checked(location_ids)
    if type(location_ids) ~= "table" then return end
    local saw_equipment_run = false
    for _, loc_id in ipairs(location_ids) do
        refresh_da_description(loc_id)
        -- Detect equipment-run regions (4=weapon, 5=melee, 6=ability) so we
        -- only refresh the overlay for relevant checks.
        local region = math.floor((loc_id - LocationData.BASE_ID) / LocationData.TABLE_OFFSET)
        if region == LocationData.REGION.weapon_run
           or region == LocationData.REGION.melee_run
           or region == LocationData.REGION.ability_run
           or region == LocationData.BIOME_REGION.weapon_run
           or region == LocationData.BIOME_REGION.melee_run
           or region == LocationData.BIOME_REGION.ability_run then
            saw_equipment_run = true
        end
    end
    if saw_equipment_run and APOverlay then
        APOverlay.update_equipment_progress(LocationData, ItemApply, ItemData, APClient)
    end
end

--- Called when we receive an item — track its DA so descriptions can show [RECEIVED].
--- [RECEIVED] means the player has this in-game item via AP and it won't be stripped.
local function on_item_received_for_descriptions(it)
    local item_id = tonumber(it.item)
    if not item_id then return end

    -- Resolve this AP item to its DA full_name
    local info = ItemData.from_ap_id(item_id)
    if not info or not info.full_name then return end

    received_da_set[info.full_name] = true

    -- Refresh the location that corresponds to this DA (if scouted)
    for loc_id, da_info in pairs(location_to_da) do
        if da_info.full_name == info.full_name then
            refresh_da_description(loc_id)
        end
    end
end
-- Wire up the forward declaration now that the function exists
_on_item_received_for_descriptions = on_item_received_for_descriptions

-- seed/slot of the last slot connect, to tell a reconnect from a new session
local last_connect_identity = nil

local function on_slot_connected(slot_data)
    clog("STATUS", "Slot data received")

    -- Reset description caches for a fresh session
    scouted_info = {}
    received_da_set = {}
    location_to_da = {}

    -- Same seed and slot as the last connect: keep the inventory. The server
    -- re-sends every item and only the difference is applied, so a dropped
    -- connection no longer wipes and rebuilds what the player holds. A first
    -- connect, or a different seed or slot, starts from an empty inventory.
    local identity = tostring(slot_data and slot_data.seed) .. "/" .. tostring(APClient.slot)
    local same_session = (last_connect_identity == identity)
    last_connect_identity = identity
    ItemApply.reset({ soft = same_session })

    if not same_session then
        -- Reset equip_lock allowed sets so they're rebuilt from slot_data
        local el = _G.AP and _G.AP.equip_lock or nil
        if el then
            el.allowed = { weapon = {}, ability = {}, melee = {} }
        end

        -- Reset inv_sanitize allowed sets so they're rebuilt from received items.
        -- On a soft reconnect they stay: the items are still in the inventory and
        -- the sanitizer would strip them while the re-send is still arriving.
        local is = _G.AP and _G.AP.inv_sanitize or nil
        if is then
            is.allowed_perk_full = {}
            is.allowed_relic_full = {}
            is.allowed_weapon_mod_full = {}
            is.allowed_ability_mod_full = {}
            is.allowed_melee_mod_full = {}
        end
    end

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
    BiomeLock.configure(slot_data and slot_data.options or slot_data, same_session)

    -- Pre-allow items that are intentionally NOT AP-tracked, so picking
    -- them up naturally during a run doesn't trigger InventorySanitize to
    -- strip them.  Two cases require this:
    --   1. greed_item_mode == skip — greed items aren't in the AP pool
    --      and the player must find them naturally
    --   2. limit_pickup_locations == true — items not in the chosen
    --      subset have no AP location and are pure in-game pickups
    do
        local is = _G.AP and _G.AP.inv_sanitize or nil
        if is then
            local kind_to_set = {
                perk        = is.allowed_perk_full,
                relic       = is.allowed_relic_full,
                weapon_mod  = is.allowed_weapon_mod_full,
                melee_mod   = is.allowed_melee_mod_full,
                ability_mod = is.allowed_ability_mod_full,
            }
            local kind_to_cat = {
                perk        = ItemData.CATEGORY.PERK,
                relic       = ItemData.CATEGORY.RELIC,
                weapon_mod  = ItemData.CATEGORY.WEAPON_MOD,
                melee_mod   = ItemData.CATEGORY.MELEE_MOD,
                ability_mod = ItemData.CATEGORY.ABILITY_MOD,
            }

            local function pre_allow(kind, names)
                local set = kind_to_set[kind]
                local cat = kind_to_cat[kind]
                if not set or not cat or not names then return 0 end
                local count = 0
                for _, name in ipairs(names) do
                    local fn = ItemData.get_da(cat, name)
                    if fn and not set[fn] then
                        set[fn] = true
                        count = count + 1
                    end
                end
                return count
            end

            -- 1. Greed items in skip mode
            if LocationData.greed_item_mode == 2 then
                local total = 0
                for kind, names in pairs(LocationData.GREED_BY_KIND or {}) do
                    total = total + pre_allow(kind, names)
                end
                clog("INFO", "  Greed mode = skip: pre-allowed " .. total
                    .. " greed items in inventory")
            end

            -- 2. Items outside the chosen subset for limit_pickup_locations
            if LocationData.limit_pickup_locations
                    and LocationData._has_pickup_subsets then
                local total = 0
                for kind, all_names in pairs(LocationData.PICKUP_NAMES_BY_KIND or {}) do
                    local non_chosen = {}
                    for _, name in ipairs(all_names) do
                        -- The subset lists the item under its kind in the seed.
                        local subset = LocationData.pickup_subsets[LocationData.seed_kind(kind, name)] or {}
                        if not subset[name] then
                            non_chosen[#non_chosen + 1] = name
                        end
                    end
                    total = total + pre_allow(kind, non_chosen)
                end
                clog("INFO", "  Limit pickup locations: pre-allowed "
                    .. total .. " non-subset items in inventory")
            end

            -- 3. Items the game added after the seed's ID layout: the seed
            --    has no item or check for them (empty for current seeds)
            local untracked = 0
            for kind in pairs(LocationData.PICKUP_NAMES_BY_KIND or {}) do
                untracked = untracked + pre_allow(kind, LocationData.untracked_pickup_names(kind))
            end
            if untracked > 0 then
                clog("INFO", "  Seed ID layout " .. tostring(LocationData.id_layout) .. ": pre-allowed "
                    .. untracked .. " items the seed doesn't have")
            end
        end
    end

    -- Sync the DeathLink tag with the slot's death_link option.
    -- We connected with just {"AP"} as tags; if death_link is enabled, add
    -- "DeathLink" via ConnectUpdate so the server includes us in deathlink
    -- broadcasts.  Otherwise leave tags as-is.
    if LocationData.death_link then
        APClient:update_tags({ "AP", "DeathLink" })
    end

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

    -- Lock all equipment first, then selectively unlock non-pool items.
    -- Pool equipment stays locked (bRequiresUnlock=true) until AP sends it.
    -- This also snapshots original values and maxes account rank.
    lock_all_equipment()

    -- Pre-allow non-pool equipment: unlock in game UI + add to equip_lock allowed set.
    local equip_lock = _G.AP and _G.AP.equip_lock or nil
    local CAT = ItemData.CATEGORY
    local np_w, np_m, np_a = 0, 0, 0

    -- Non-pool weapons
    for _, wname in ipairs(LocationData.weapon_names) do
        if not LocationData.is_pool_weapon(wname) then
            local fn, da = ItemData.get_da(CAT.WEAPON, wname)
            if fn then
                unlock_equipment_da(fn)
                if equip_lock then equip_lock.allow_item("weapon", fn) end
                np_w = np_w + 1
            end
        end
    end
    -- Non-pool melee
    for _, mname in ipairs(LocationData.melee_names) do
        if not LocationData.is_pool_melee(mname) then
            local fn, da = ItemData.get_da(CAT.MELEE, mname)
            if fn then
                unlock_equipment_da(fn)
                if equip_lock then equip_lock.allow_item("melee", fn) end
                np_m = np_m + 1
            end
        end
    end
    -- Non-pool abilities
    for _, aname in ipairs(LocationData.ability_names) do
        if not LocationData.is_pool_ability(aname) then
            local fn, da = ItemData.get_da(CAT.ABILITY, aname)
            if fn then
                unlock_equipment_da(fn)
                if equip_lock then equip_lock.allow_item("ability", fn) end
                np_a = np_a + 1
            end
        end
    end
    clog("STATUS", "Non-pool equipment unlocked (" ..
        np_w .. " weapons, " .. np_m .. " melee, " .. np_a .. " abilities)")

    if equip_lock then
        equip_lock.refresh_maps()
        equip_lock.request_enforce("slot_connected")
    end

    -- Update overlay
    if APOverlay then
        APOverlay.set_connected(APClient.slot or "Connected")
        APOverlay.update_equipment_progress(LocationData, ItemApply, ItemData, APClient)
    end

    -- Deferred victory check: on reconnect, the server sends already-checked
    -- locations via location_checked handler AFTER slot_connected.  Wait a few
    -- poll cycles so _checked is populated, then see if victory was already earned.
    GameThread.loop(3000, function()
        if PickupWatch.check_victory() then
            clog("STATUS", "Victory conditions already met on reconnect — sending goal!")
        end
        return true  -- run once
    end)

    -- An older seed can have pickup checks for items the game no longer has
    -- (Aura Explosion in ID layout 1). They can't be found in a run, so they
    -- are sent now.
    if LocationData.pickup_checks then
        for _, lid in ipairs(LocationData.unfindable_location_ids()) do
            if LocationData.is_valid_location_id(lid) and not APClient:is_location_checked(lid) then
                clog("STATUS", "Sending check " .. lid .. ": its item is no longer in the game")
                APClient:send_check(lid)
            end
        end
    end

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

    -- Scout all pickup locations to update DA descriptions with AP item info.
    -- Build the location→DA map, then send scout requests to the server.
    -- The on_location_info callback will update descriptions when results arrive.
    if LocationData.pickup_checks then
        build_location_da_map()
        -- Delay scouting slightly so the server has time to send checked locations first
        GameThread.loop(2000, function()
            scout_all_pickups()
            return true
        end)
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
        GameThread.loop(1500, function()
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
    GameThread.loop(2000, function()
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
        GameThread.loop(250, function()
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

-- The client fires these during its poll; each one runs afterwards on the game thread, in order.
APClient.on_item = GameThread.wrap(on_item)
APClient.on_message = GameThread.wrap(on_message)
APClient.on_slot_connected = GameThread.wrap(on_slot_connected)
APClient.on_deathlink = GameThread.wrap(on_deathlink)
APClient.on_item_send = GameThread.wrap(function(info)
    if APOverlay then APOverlay.add_feed_item(info) end
end)
local on_location_info_game = GameThread.wrap(on_location_info)
APClient.on_location_info = function(items)
    resolve_scout_names(items)
    on_location_info_game(items)
end
APClient.on_location_checked = GameThread.wrap(on_location_checked)
-- The completed-run record arrived or changed: the goal may be met, and the checklist counts it.
APClient.on_runs_loaded = GameThread.wrap(function()
    PickupWatch.check_victory()
    if APOverlay then APOverlay.update_equipment_progress(LocationData, ItemApply, ItemData, APClient) end
end)
APClient.on_disconnected = GameThread.wrap(function(reason)
    restore_equipment_locks()
    pcall(BiomeLock.deactivate)
    restore_all_descriptions()
    -- Clear description caches
    scouted_info = {}
    received_da_set = {}
    location_to_da = {}
    if APOverlay then APOverlay.set_disconnected(reason) end
end)
APClient.on_slot_refused = GameThread.wrap(function(reason_str)
    if APOverlay then APOverlay.set_disconnected("Refused: " .. tostring(reason_str)) end
end)

local config_path = "Mods/CrabChampionsAP/Scripts/ap_config.json"
local init_ok = APClient:init(config_path)

if not init_ok then
    log("AP client failed to initialize — running without AP features")
end

-- Install pickup watcher (sends location checks + removes items)
PickupWatch.install(APClient)

-- Trap watcher: delivers received traps and Perk Boosts, undoes timed effects
Traps.install()

-- Biome lock: keeps the next biome to one the player owns, and the HUD biome name right
BiomeLock.install()

-- Achievement block: on while connected
Achievements.also_active = function() return APClient:is_slot_connected() end
Achievements.install()

-- Keep the difficulty modifier buttons unlocked while connected (the menu redraws them whenever it opens).
GameThread.loop(300, function()
    pcall(ModifierUnlock.tick)
    return false
end)
pcall(function()
    RegisterHook("/Script/CrabChampions.CrabPC:ClientOnEliminated", function()
        pcall(Traps.on_run_over)
    end)
end)

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
        GameThread.loop(300, function()
            inv_sanitize.sanitize_all_players()
            return true  -- run once
        end)
    end)

    -- Hook portal/island events (game may grant items during transitions)
    RegisterHook("/Script/CrabChampions.CrabPC:ClientOnEnteredPortal", function(Context, ...)
        pcall(ModifierUnlock.pause, 8)
        GameThread.loop(500, function()
            inv_sanitize.sanitize_all_players()
            return true
        end)
    end)

    RegisterHook("/Script/CrabChampions.CrabPC:ClientOnClearedIsland", function(Context, ...)
        GameThread.loop(500, function()
            inv_sanitize.sanitize_all_players()
            return true
        end)
    end)

    -- Periodic safety net: sanitize every 2 seconds if allowed sets are populated
    GameThread.loop(2000, function()
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
    log("Console controls loaded (F7/F8)")
else
    log("Console module not available: " .. tostring(ConsoleModule))
end

-- Expose overlay globally
if APOverlay then
    AP.Overlay = APOverlay
end

-- Connect/disconnect using the overlay's input fields. the panel's Connect button runs this,
-- on the game thread.
local function toggle_connection(source)
    if APClient:is_slot_connected() or APClient:is_connected() then
        log("Disconnecting from AP server (" .. tostring(source) .. ")...")
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
        log("Connecting to " .. tostring(APClient.server) .. " as '" .. tostring(APClient.slot) .. "' ("
            .. tostring(source) .. ")...")
        if APOverlay then APOverlay.set_connecting(APClient.server) end
        APClient:queue_command("connect")
    end
end

if APOverlay and APOverlay.set_connect_handler then
    APOverlay.set_connect_handler(toggle_connection)
end

-- "Archipelago" button in the pause menu: opens the connection window.
if APOverlay then
    local pb_ok, PauseButton = pcall(require, "AP/PauseButton")
    if pb_ok then
        PauseButton.install(function()
            if not APOverlay.is_initialized() then try_create_overlay() end
            if APOverlay.is_initialized() then APOverlay.show_panel() end
        end)
        AP.PauseButton = PauseButton
    else
        log("Pause menu button not available: " .. tostring(PauseButton))
    end
end

-- What the panel shows while connected, and what to do when the server never answers.
if APOverlay and APOverlay.set_info_provider then
    APOverlay.set_info_provider(function()
        local checked = 0
        for _ in pairs(APClient._checked or {}) do checked = checked + 1 end
        return {
            server = APClient.server,
            slot = APClient.slot,
            seed = APClient.slot_data and APClient.slot_data.seed or nil,
            items = math.max(0, (APClient._applied_index or -1) + 1),
            checked = checked,
        }
    end)
    APOverlay.set_timeout_handler(function(msg)
        APClient:queue_command("disconnect", { reason = msg })
    end)
end

-- An old UE4SS-settings.ini that still hooks LoadMap crashes the game while it
-- loads. Only reads the file next to the game exe; no game calls.
do
    local ok, ConnStatus = pcall(require, "AP/ConnStatus")
    local warning = ok and ConnStatus.read_settings_warning("UE4SS-settings.ini") or nil
    if warning then
        log("WARNING: " .. warning)
        if APOverlay and APOverlay.set_settings_warning then
            pcall(APOverlay.set_settings_warning, warning)
        end
    end
end

-- Close the panel (and give the pointer back) when a run starts or ends, or the player is eliminated.
do
    local last_lobby = nil
    if APOverlay and APOverlay.set_release_check then
        APOverlay.set_release_check(function(reset)
            local in_lobby = ItemApply and ItemApply.in_lobby
            if reset or last_lobby == nil then last_lobby = in_lobby return false end
            if in_lobby ~= last_lobby then last_lobby = in_lobby return true end
            local pc = FindFirstOf("CrabPlayerC")
            if pc and pc:IsValid() and pc.bIsEliminated == true then return true end
            return false
        end)
    end
end

-- Recreate overlay on level transitions
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
        GameThread.run(function()
            try_create_overlay()
        end)
    end)
end)

-- Initial overlay creation (deferred to game thread)
GameThread.run(function()
    try_create_overlay()
end)

log("Archipelago mod loaded" .. (APClient.enabled and " (AP enabled)" or " (AP disabled)"))

-- Slot Lock module (progressive inventory slots)
local SlotLock = require("AP/SlotLock")
SlotLock.install()
AP.SlotLock = SlotLock
log("SlotLock loaded and installed")

-- F1: Test equip lock — only Auto Rifle allowed
RegisterKeyBind(Key.F1, GameThread.signal(function()
    GameThread.loop(1, function()
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
end))

-- F2: Unlock Crossbow as additional weapon
RegisterKeyBind(Key.F2, GameThread.signal(function()
    GameThread.loop(1, function()
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
end))

-- F9: Dump every pickup DA to a timestamped file: asset and display name,
-- rarity (greed is a rarity), loot pool and pickup tag. Used when porting a
-- new game build, so it also flags items the client doesn't know yet and
-- prints every tag ID it finds rather than a fixed range.
RegisterKeyBind(Key.F9, GameThread.signal(function()
    GameThread.loop(1, function()
        log("=== DUMPING PICKUP DATA ===")
        if not ItemData.is_resolved() then ItemData.resolve_game_objects() end

        -- Enum names from the game's header dump. IDs missing here are
        -- printed as numbers, so values added in a newer build still show up.
        local TAG_NAMES = {
            [0] = "None", [1] = "Armor", [2] = "Healing", [3] = "HighHealth",
            [4] = "Block", [5] = "DamageOverTime", [6] = "Critical", [7] = "Speed",
            [8] = "Bounce", [9] = "Ice", [10] = "Fire", [11] = "Lightning",
            [12] = "Poison", [13] = "Arcane", [14] = "Turret", [15] = "Combo",
            [16] = "GlueShot", [17] = "Charger",
        }
        local RARITY_NAMES = {
            [0] = "None", [1] = "Common", [2] = "Epic", [3] = "Legendary", [4] = "Greed",
        }
        local GREED = 4

        local function label(names, id)
            return (names[id] or "?") .. " (" .. id .. ")"
        end

        -- Same normalisation ItemData uses to match item names to DAs.
        local function name_key(name)
            return (name:gsub("%s*%b()%s*$", ""):gsub("'", ""):gsub("%s+", ""):lower())
        end
        local known = {}
        for _, entry in pairs(ItemData.CURRENT_BY_CC_CODE or ItemData.BY_CC_CODE) do
            known[name_key(entry.name)] = true
        end

        local CLASSES = {
            "CrabPerkDA", "CrabRelicDA", "CrabWeaponModDA", "CrabMeleeModDA",
            "CrabAbilityModDA", "CrabWeaponDA", "CrabAbilityDA", "CrabMeleeDA",
        }

        local rows_by_class = {}
        local providers, requirers, tag_ids = {}, {}, {}
        local new_items, greed_items = {}, {}
        local total = 0

        for _, class_name in ipairs(CLASSES) do
            local rows = {}
            rows_by_class[class_name] = rows
            for _, da in ipairs(FindAllOf(class_name) or {}) do
                pcall(function()
                    if not da or not da:IsValid() then return end
                    local full = tostring(da:GetFullName())
                    local asset = full:match("%.([^%.]+)$") or full
                    local display = da.Name
                    if type(display) ~= "string" then
                        pcall(function() display = display:ToString() end)
                    end
                    display = tostring(display)

                    local tag = tonumber(da.PickupTag) or 0
                    local requires = da.bRequiresMatchingPickupTag and true or false
                    local rarity = tonumber(da.Rarity) or 0
                    local loot_pool = tonumber(da.LootPool) or 0
                    local is_new = not known[(asset:match("^DA_%w+_(.+)$") or asset):lower()]
                    local who = display .. " [" .. asset .. "] (" .. class_name .. ")"

                    rows[#rows + 1] = string.format(
                        "  %-38s | %-26s | rarity %-15s | loot pool %-3d | tag %-18s%s%s",
                        asset, display, label(RARITY_NAMES, rarity), loot_pool,
                        label(TAG_NAMES, tag), requires and " REQUIRES" or "",
                        is_new and "  NEW" or "")
                    total = total + 1

                    if is_new then new_items[#new_items + 1] = who end
                    if rarity == GREED then greed_items[#greed_items + 1] = who end
                    if requires then
                        requirers[tag] = requirers[tag] or {}
                        table.insert(requirers[tag], who)
                        tag_ids[tag] = true
                    elseif tag > 0 then
                        providers[tag] = providers[tag] or {}
                        table.insert(providers[tag], who)
                        tag_ids[tag] = true
                    end
                end)
            end
            table.sort(rows)
        end

        local lines = {}
        local function add(s) lines[#lines + 1] = s end
        local function add_list(title, list)
            table.sort(list)
            add("=== " .. title .. ": " .. #list .. " ===")
            for _, s in ipairs(list) do add("  " .. s) end
            add("")
        end

        add("=== PICKUP DATA DUMP ===")
        add("Taken " .. os.date("%Y-%m-%d %H:%M:%S") .. ", " .. total .. " DAs")
        add("")
        add_list("NEW (not in ItemData.lua)", new_items)
        add_list("GREED (rarity Greed)", greed_items)

        add("=== PICKUP TAGS ===")
        local sorted_tags = {}
        for id in pairs(tag_ids) do sorted_tags[#sorted_tags + 1] = id end
        table.sort(sorted_tags)
        for _, id in ipairs(sorted_tags) do
            add("--- Tag: " .. label(TAG_NAMES, id) .. " ---")
            for _, group in ipairs({ { "PROVIDES", providers[id] }, { "REQUIRES", requirers[id] } }) do
                if group[2] then
                    table.sort(group[2])
                    add("  " .. group[1] .. " this tag:")
                    for _, s in ipairs(group[2]) do add("    " .. s) end
                end
            end
        end
        add("")

        add("=== ALL DAs ===")
        for _, class_name in ipairs(CLASSES) do
            add("--- " .. class_name .. ": " .. #rows_by_class[class_name] .. " ---")
            for _, row in ipairs(rows_by_class[class_name]) do add(row) end
        end

        -- Timestamped so dumps from different builds sit side by side.
        local path = "Mods/CrabChampionsAP/Scripts/pickup_dump_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"
        local f = io.open(path, "w")
        if f then
            f:write(table.concat(lines, "\n") .. "\n")
            f:close()
            log("  " .. total .. " DAs, " .. #new_items .. " new, " .. #greed_items
                .. " greed, " .. #sorted_tags .. " tags -> " .. path)
        else
            log("  ERROR: Could not write to " .. path)
        end

        return true
    end)
end))

-- F11: Toggle equipment lock state (lock all / restore originals)
RegisterKeyBind(Key.F11, GameThread.signal(function()
    GameThread.loop(1, function()
        if next(original_unlock_flags) then
            restore_equipment_locks()
            log("F11: Equipment locks restored")
        else
            lock_all_equipment()
            log("F11: All equipment locked (bRequiresUnlock=true)")
        end
        return true
    end)
end))

log("  F1 = Lock to Auto Rifle | F2 = Unlock Crossbow | F9 = Dump pickup data | F11 = Toggle unlock all")

-- Every hook is registered: the scheduler may start running work on the game thread (after a short grace).
GameThread.loaded()
