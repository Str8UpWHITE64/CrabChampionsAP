-- AP/PickupWatch.lua
-- Watches for player pickups and island clears, sends AP location checks.
--
-- Pickups: hooks ClientOnPickedUpPickup → send check → remove item
-- Islands: hooks ClientOnClearedIsland → send island + equipment run checks
-- Rank: reads CrabGS.Difficulty (ECrabRank) to determine current rank
-- Cascade: when enabled, completing at rank R also checks ranks < R

local LocationData = require("AP/LocationData")

local M = {}

local function log(msg) print("[CrabAP-Pickup] " .. tostring(msg)) end

-- Reference to APClient, set by install()
local client = nil

-- Island counter (incremented on each ClientOnClearedIsland)
local island_counter = 0

-- Shop island handling: when the next island is a shop, we set this flag
-- so the portal hook can send the shop check and bump the counter.
local pending_shop_island = nil

-- ---------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------

local function get_full_name(obj)
    if not obj then return nil end
    local ok, v = pcall(function()
        if obj.GetFullName then return tostring(obj:GetFullName()) end
        return nil
    end)
    if ok and v then return v end
    return nil
end

local function get_ps()
    local all = FindAllOf("CrabPS")
    if not all then return nil end
    for _, p in ipairs(all) do
        if p and p:IsValid() then return p end
    end
    return nil
end

--- Read the current island number from CrabGS.CurrentIsland.
--- This is the game's authoritative counter, so it persists across
--- save/load and doesn't depend on counting portals.
local function get_current_island()
    local ok, gs = pcall(function() return FindFirstOf("CrabGS") end)
    if not ok or not gs or not gs:IsValid() then return 0 end

    local i_ok, island = pcall(function() return gs.CurrentIsland end)
    if not i_ok then return 0 end

    return tonumber(island) or 0
end

--- Read the current rank from CrabGS.Difficulty (ECrabRank enum).
--- The Difficulty property already stores the rank index directly:
---   0=Bronze, 1=Silver, 2=Gold, 3=Sapphire, 4=Emerald,
---   5=Ruby, 6=Diamond, 7=Prismatic.
local function get_current_rank()
    local ok, gs = pcall(function() return FindFirstOf("CrabGS") end)
    if not ok or not gs or not gs:IsValid() then
        log("WARNING: CrabGS not found, defaulting to Bronze")
        return 0
    end

    local d_ok, diff = pcall(function() return gs.Difficulty end)
    if not d_ok then
        log("WARNING: Could not read CrabGS.Difficulty, defaulting to Bronze")
        return 0
    end

    local raw = tonumber(diff) or 0
    -- ECrabRank enum is 1-indexed: None=0, Bronze=1, Silver=2, ..., Prismatic=8
    -- Our AP rank is 0-indexed: Bronze=0, Silver=1, ..., Prismatic=7
    -- Subtract 1, clamping to 0 minimum (None -> Bronze)
    local rank = math.max(0, raw - 1)
    if rank > 7 then rank = 7 end

    -- Also read modifier count for debugging
    local mod_count = 0
    pcall(function()
        local mods = gs.DifficultyModifiers
        if mods then mod_count = mods:GetArrayNum() end
    end)

    -- Verbose rank logging only on first call or rank change
    log("Rank: " .. (LocationData.RANK_NAMES[rank + 1] or "?")
        .. " (modifiers=" .. tostring(mod_count) .. ")")
    return rank
end

-- ---------------------------------------------------------------
-- Item removal via ServerRemove* RPCs
-- ---------------------------------------------------------------

local REMOVE_RPC = {
    perk        = "ServerRemovePerk",
    relic       = "ServerRemoveRelic",
    weapon_mod  = "ServerRemoveWeaponMod",
    melee_mod   = "ServerRemoveMeleeMod",
    ability_mod = "ServerRemoveAbilityMod",
}

local ENUM_PATH = {
    perk        = "/Script/CrabChampions.ECrabPerkType",
    weapon_mod  = "/Script/CrabChampions.ECrabWeaponModType",
    ability_mod = "/Script/CrabChampions.ECrabAbilityModType",
    relic       = "/Script/CrabChampions.ECrabRelicType",
    melee_mod   = "/Script/CrabChampions.ECrabMeleeModType",
}

local function guess_enum_token(full_name)
    if not full_name then return nil end
    local leaf = full_name:match("%.(%w+)$") or full_name
    leaf = leaf:gsub("^DA_", "")
    leaf = leaf:gsub("^[A-Za-z]+_", "")
    return leaf
end

-- Enum resolution disabled — StaticFindObject returns nullptr userdata
-- that UE4SS logs as errors even inside pcall. The raw token fallback
-- in remove_item works correctly, so we just return nil here.
local function try_resolve_enum(kind, token)
    return nil
end

local function remove_item(kind, full_name)
    local rpc_name = REMOVE_RPC[kind]
    if not rpc_name then
        log("No removal RPC for kind=" .. tostring(kind))
        return
    end

    local ps = get_ps()
    if not ps then
        log("No CrabPS — cannot remove " .. tostring(kind))
        return
    end

    if not ps[rpc_name] then
        log("RPC " .. rpc_name .. " not found on CrabPS")
        return
    end

    local token = guess_enum_token(full_name)
    if not token then
        log("Could not extract enum token from " .. tostring(full_name))
        return
    end

    local param = try_resolve_enum(kind, token)
    if param == nil then
        param = token
        log("Using raw token '" .. token .. "' for " .. rpc_name)
    end

    local ok, err = pcall(function()
        ps[rpc_name](ps, param)
    end)

    if ok then
        log("Removed " .. kind .. ": " .. token)
    else
        log("Failed to remove " .. kind .. " (" .. token .. "): " .. tostring(err))
    end
end

-- ---------------------------------------------------------------
-- Rank check helpers
-- ---------------------------------------------------------------

--- Build list of ranks to send checks for.
--- With cascade: current rank + all lower ranks.
--- Without cascade: just current rank.
local function ranks_to_check(current_rank)
    local ranks = { current_rank }
    if LocationData.cascade_ranked_checks then
        for r = current_rank - 1, 0, -1 do
            ranks[#ranks + 1] = r
        end
    end
    return ranks
end

--- Send a location check if not already checked.
local function try_send_check(location_id, desc)
    if location_id and not client:is_location_checked(location_id) then
        client:send_check(location_id)
        if desc then log(desc .. " → " .. tostring(location_id)) end
        return true
    end
    return false
end

-- ---------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------

--- Check if all victory conditions are met and send victory if so.
--- Can be called at any time (e.g. on reconnect or after a run).
function M.check_victory()
    if not client then return false end

    local req_rank = LocationData.required_rank
    local final = LocationData.run_length
    local equip_mode = LocationData.equipment_check_mode

    -- Check rank run at required rank is completed
    local rank_loc = LocationData.rank_run_location_id(req_rank)
    if not rank_loc or not client:is_location_checked(rank_loc) then
        return false
    end

    -- Count completed weapon runs at final island on required rank
    -- Pool weapons always count; non-pool count when equip_mode != disabled
    local weapon_count = 0
    for wname, _ in pairs(LocationData.pool_weapons) do
        local loc_id = LocationData.weapon_run_location_id_by_name(final, wname, req_rank)
        if loc_id and client:is_location_checked(loc_id) then
            weapon_count = weapon_count + 1
        end
    end
    if equip_mode ~= 2 then
        for _, wname in ipairs(LocationData.weapon_names) do
            if not LocationData.is_pool_weapon(wname) then
                local loc_id = LocationData.weapon_run_location_id_by_name(final, wname, req_rank)
                if loc_id and client:is_location_checked(loc_id) then
                    weapon_count = weapon_count + 1
                end
            end
        end
    end

    -- Count completed melee runs at final island on required rank
    local melee_count = 0
    if LocationData.melee_for_completion > 0 then
        for mname, _ in pairs(LocationData.pool_melee) do
            local loc_id = LocationData.melee_run_location_id_by_name(final, mname, req_rank)
            if loc_id and client:is_location_checked(loc_id) then
                melee_count = melee_count + 1
            end
        end
        if equip_mode ~= 2 then
            for _, mname in ipairs(LocationData.melee_names) do
                if not LocationData.is_pool_melee(mname) then
                    local loc_id = LocationData.melee_run_location_id_by_name(final, mname, req_rank)
                    if loc_id and client:is_location_checked(loc_id) then
                        melee_count = melee_count + 1
                    end
                end
            end
        end
    end

    -- Count completed ability runs at final island on required rank
    local ability_count = 0
    if LocationData.ability_for_completion > 0 then
        for aname, _ in pairs(LocationData.pool_abilities) do
            local loc_id = LocationData.ability_run_location_id_by_name(final, aname, req_rank)
            if loc_id and client:is_location_checked(loc_id) then
                ability_count = ability_count + 1
            end
        end
        if equip_mode ~= 2 then
            for _, aname in ipairs(LocationData.ability_names) do
                if not LocationData.is_pool_ability(aname) then
                    local loc_id = LocationData.ability_run_location_id_by_name(final, aname, req_rank)
                    if loc_id and client:is_location_checked(loc_id) then
                        ability_count = ability_count + 1
                    end
                end
            end
        end
    end

    local w_needed = LocationData.weapons_for_completion
    local m_needed = LocationData.melee_for_completion
    local a_needed = LocationData.ability_for_completion

    log("Victory check: weapons=" .. weapon_count .. "/" .. w_needed
        .. " melee=" .. melee_count .. "/" .. m_needed
        .. " abilities=" .. ability_count .. "/" .. a_needed)

    if weapon_count >= w_needed and melee_count >= m_needed and ability_count >= a_needed then
        log("Victory conditions met!")
        client:send_victory()
        return true
    end
    return false
end

--- Install the pickup and island watch hooks.
---@param ap_client table The APClient instance
function M.install(ap_client)
    client = ap_client

    -- ---------------------------------------------------------------
    -- Pickup hook (not rank-dependent)
    -- ---------------------------------------------------------------
    RegisterHook("/Script/CrabChampions.CrabPC:ClientOnPickedUpPickup", function(Context, PickupDA)
        -- When pickup checks are disabled, don't process pickups as checks
        if not LocationData.pickup_checks then return end

        local pickup = PickupDA and PickupDA.get and PickupDA:get() or nil
        local full_name = get_full_name(pickup)

        if not full_name then
            log("Pickup with no full_name — skipping")
            return
        end

        -- Check if this mod is suppressed (bundled with a disallowed weapon being reverted)
        local equip_lock = _G.AP and _G.AP.equip_lock or nil
        if equip_lock and equip_lock.suppressed_mods then
            local display_name = LocationData.display_name(nil, full_name) or ""
            for mod_name, _ in pairs(equip_lock.suppressed_mods) do
                if display_name == mod_name or full_name:find(mod_name:gsub("%s+", "")) then
                    log("Suppressed pickup check for bundled mod: " .. display_name)
                    return
                end
            end
        end

        local location_id, kind = LocationData.from_da(full_name)

        if not location_id then
            if kind then
                log("No location ID for " .. kind .. " DA: " .. full_name)
            end
            return
        end

        local display = LocationData.display_name(kind, full_name)

        -- Skip pickups whose locations don't exist server-side (greed/skip
        -- mode, limit_pickup_locations, etc.).  These are "natural"
        -- pickups: the player keeps them in their inventory, and we never
        -- send a check.  Sending a check for a location the server didn't
        -- generate would crash the connection with a KeyError.
        if LocationData.is_pickup_location_excluded
                and LocationData.is_pickup_location_excluded(kind, display) then
            log("Pickup not AP-tracked (kept in inventory): " .. display
                .. " (kind=" .. tostring(kind) .. ")")
            return
        end

        log("Location check: " .. display .. " → " .. tostring(location_id))

        if client:is_location_checked(location_id) then
            log("Already checked — skipping removal")
            return
        end

        client:send_check(location_id)

        local remove_kind = kind
        local remove_fn = full_name
        LoopAsync(200, function()
            remove_item(remove_kind, remove_fn)
            -- Retry overflow items — removing an item freed a slot
            pcall(function()
                local ItemApply = require("AP/ItemApply")
                if ItemApply.overflow_count() > 0 then
                    ItemApply.retry_overflow()
                end
            end)
            return true
        end)
    end)

    -- ---------------------------------------------------------------
    -- Shared: send island + equipment checks for a given island number
    -- ---------------------------------------------------------------
    local function should_check_equip(equip_name, is_pool_fn)
        if is_pool_fn(equip_name) then return true end
        return LocationData.equipment_check_mode ~= 2
    end

    --- Send all location checks for a given island number.
    --- @param num number The island number (1-based)
    --- @param label string Log prefix ("Island cleared" or "Reached shop")
    local function send_island_checks(num, label)
        local rank = get_current_rank()
        log(label .. " — counter=" .. tostring(num) .. " rank=" .. tostring(rank)
            .. " (" .. (LocationData.RANK_NAMES[rank + 1] or "?") .. ")")

        local is_shop = LocationData.SHOP_ISLANDS[num] or false
        local check_ranks = ranks_to_check(rank)
        local pfx = is_shop and "Reach Shop on Island" or "Complete Island"

        -- Island completion checks
        if LocationData.extra_ranked_island_checks then
            -- Extra ranked mode: send ranked checks for all applicable ranks
            for _, r in ipairs(check_ranks) do
                if r <= LocationData.max_rank then
                    local rname = LocationData.RANK_NAMES[r + 1] or "?"
                    try_send_check(
                        LocationData.island_location_id(num, r),
                        "Ranked island: " .. pfx .. " " .. num .. " on " .. rname
                    )
                end
            end
        else
            -- Normal mode: send unranked check + ranked check at required_rank
            try_send_check(
                LocationData.island_location_id(num),
                "Island check: " .. pfx .. " " .. num
            )
            if rank >= LocationData.required_rank then
                local rname = LocationData.RANK_NAMES[LocationData.required_rank + 1] or "?"
                try_send_check(
                    LocationData.island_location_id(num, LocationData.required_rank),
                    "Ranked island: " .. pfx .. " " .. num .. " on " .. rname
                )
            end
        end

        -- Equipment run checks
        local ps = get_ps()
        if ps then
            local w_ok, w_da = pcall(function() return ps.WeaponDA end)
            local weapon_fn = w_ok and get_full_name(w_da) or nil

            local m_ok, m_da = pcall(function() return ps.MeleeDA end)
            local melee_fn = m_ok and get_full_name(m_da) or nil

            local a_ok, a_da = pcall(function() return ps.AbilityDA end)
            local ability_fn = a_ok and get_full_name(a_da) or nil

            -- Unranked + required-rank equipment checks (when extra_ranked is off)
            if not LocationData.extra_ranked_island_checks then
                local req_rank = LocationData.required_rank
                local rname = LocationData.RANK_NAMES[req_rank + 1] or "?"
                local at_req = rank >= req_rank

                if weapon_fn then
                    local wname = LocationData.equipment_name("weapon", weapon_fn)
                    if should_check_equip(wname, LocationData.is_pool_weapon) then
                        try_send_check(
                            LocationData.weapon_run_location_id(num, weapon_fn),
                            "Weapon run: Island " .. num .. " with " .. wname
                        )
                        if at_req then
                            try_send_check(
                                LocationData.weapon_run_location_id(num, weapon_fn, req_rank),
                                "Ranked weapon: Island " .. num .. " with " .. wname .. " on " .. rname
                            )
                        end
                    end
                end
                if melee_fn then
                    local mname = LocationData.equipment_name("melee", melee_fn)
                    if should_check_equip(mname, LocationData.is_pool_melee) then
                        try_send_check(
                            LocationData.melee_run_location_id(num, melee_fn),
                            "Melee run: Island " .. num .. " with " .. mname
                        )
                        if at_req then
                            try_send_check(
                                LocationData.melee_run_location_id(num, melee_fn, req_rank),
                                "Ranked melee: Island " .. num .. " with " .. mname .. " on " .. rname
                            )
                        end
                    end
                end
                if ability_fn then
                    local aname = LocationData.equipment_name("ability", ability_fn)
                    if should_check_equip(aname, LocationData.is_pool_ability) then
                        try_send_check(
                            LocationData.ability_run_location_id(num, ability_fn),
                            "Ability run: Island " .. num .. " with " .. aname
                        )
                        if at_req then
                            try_send_check(
                                LocationData.ability_run_location_id(num, ability_fn, req_rank),
                                "Ranked ability: Island " .. num .. " with " .. aname .. " on " .. rname
                            )
                        end
                    end
                end
            end

            -- Ranked equipment checks (only when extra_ranked is on)
            if LocationData.extra_ranked_island_checks then
                for _, r in ipairs(check_ranks) do
                    if r <= LocationData.max_rank then
                        local rname = LocationData.RANK_NAMES[r + 1] or "?"
                        if weapon_fn then
                            local wname = LocationData.equipment_name("weapon", weapon_fn)
                            if should_check_equip(wname, LocationData.is_pool_weapon) then
                                try_send_check(
                                    LocationData.weapon_run_location_id(num, weapon_fn, r),
                                    "Ranked weapon: Island " .. num .. " with " .. wname .. " on " .. rname
                                )
                            end
                        end
                        if melee_fn then
                            local mname = LocationData.equipment_name("melee", melee_fn)
                            if should_check_equip(mname, LocationData.is_pool_melee) then
                                try_send_check(
                                    LocationData.melee_run_location_id(num, melee_fn, r),
                                    "Ranked melee: Island " .. num .. " with " .. mname .. " on " .. rname
                                )
                            end
                        end
                        if ability_fn then
                            local aname = LocationData.equipment_name("ability", ability_fn)
                            if should_check_equip(aname, LocationData.is_pool_ability) then
                                try_send_check(
                                    LocationData.ability_run_location_id(num, ability_fn, r),
                                    "Ranked ability: Island " .. num .. " with " .. aname .. " on " .. rname
                                )
                            end
                        end
                    end
                end
            end
        else
            log("No CrabPS — could not send equipment run checks")
        end

        -- Run completion check (when player reaches the final island)
        if num >= LocationData.run_length then
            log("Run complete at island " .. num .. "!")
            if LocationData.extra_ranked_island_checks then
                -- Extra ranked mode: send rank runs for all applicable ranks
                for _, r in ipairs(check_ranks) do
                    if r <= LocationData.max_rank then
                        local rname = LocationData.RANK_NAMES[r + 1] or "?"
                        try_send_check(
                            LocationData.rank_run_location_id(r),
                            "Rank run: Complete Run on " .. rname
                        )
                    end
                end
            else
                -- Normal mode: only send rank run at required_rank
                if rank >= LocationData.required_rank then
                    local rname = LocationData.RANK_NAMES[LocationData.required_rank + 1] or "?"
                    try_send_check(
                        LocationData.rank_run_location_id(LocationData.required_rank),
                        "Rank run: Complete Run on " .. rname
                    )
                end
            end

            -- Check victory using shared function
            M.check_victory()
        end
    end

    -- ---------------------------------------------------------------
    -- Island clear hook (reads CurrentIsland from CrabGS)
    -- ---------------------------------------------------------------
    RegisterHook("/Script/CrabChampions.CrabPC:ClientOnClearedIsland", function(Context)
        local island = get_current_island()
        island_counter = island  -- keep in sync for get_island_counter()
        send_island_checks(island, "Island cleared")

        -- Check if the NEXT island is a shop (no combat clear will fire).
        -- If so, flag it so the portal hook can send the shop check.
        if LocationData.SHOP_ISLANDS[island + 1] then
            pending_shop_island = island + 1
            log("Next island (" .. (island + 1) .. ") is a shop — will send check on portal entry")
        end

        -- Retry overflow items — clearing an island may grant new inventory slots
        LoopAsync(500, function()
            local ok, ItemApply = pcall(require, "AP/ItemApply")
            if ok and ItemApply and ItemApply.retry_overflow then
                ItemApply.retry_overflow()
            end
            return true
        end)
    end)

    -- ---------------------------------------------------------------
    -- Portal detection: shop islands + lobby transitions
    -- ---------------------------------------------------------------

    RegisterHook("/Script/CrabChampions.CrabPC:ClientOnEnteredPortal", function(Context, ...)
        -- Lobby detection: if lobby actors exist, this is a new run
        local lobby_ok, lobby_actors = pcall(FindAllOf, "BP_Pickup_Lobby_C")
        if lobby_ok and lobby_actors and #lobby_actors > 0 then
            local gs_island = get_current_island()
            log("Portal from lobby detected — new run starting (GS island=" .. gs_island .. ")")
            island_counter = 0
            -- Signal ItemApply that we've left the lobby
            local ia_ok, ItemApply = pcall(require, "AP/ItemApply")
            if ia_ok and ItemApply then ItemApply.in_lobby = false end
            pending_shop_island = nil
            return
        end

        -- Shop island handling: read island from GS after portal
        if pending_shop_island then
            local shop_num = pending_shop_island
            pending_shop_island = nil
            island_counter = shop_num
            send_island_checks(shop_num, "Reached shop")
        end
    end)

    -- Detect lobby entry via CheatManager construction.
    -- The game creates a new CheatManager every time the player enters the lobby.
    -- We use this as a reliable signal to reset the island counter and re-apply items.
    local notify_ok = pcall(function()
        NotifyOnNewObject("/Script/Engine.CheatManager", function(CreatedObject)
            log("CheatManager constructed — lobby detected")
            -- Defer so the world is fully initialized and player objects exist
            LoopAsync(2000, function()
                log("Lobby re-apply: resetting island counter and re-spawning run items")
                island_counter = 0
                -- Signal ItemApply that we're back in the lobby (spawning is safe again)
                local ia_ok, ItemApply = pcall(require, "AP/ItemApply")
                if ia_ok and ItemApply then ItemApply.in_lobby = true end
                pending_shop_island = nil
                -- Signal equip_lock that the run ended
                local el = _G.AP and _G.AP.equip_lock or nil
                if el and el.on_lobby_entered then
                    el.on_lobby_entered()
                end
                -- Re-apply progressive slot locks (game resets to defaults on lobby)
                local sl = _G.AP and _G.AP.SlotLock or nil
                if sl and sl.is_active and sl.is_active() and sl.reapply then
                    sl.reapply()
                end
                -- Re-apply received items
                local ok, ItemApply = pcall(require, "AP/ItemApply")
                if ok and ItemApply and ItemApply.reapply_run_items then
                    ItemApply.reapply_run_items()
                end
                return true
            end)
        end)
    end)
    if not notify_ok then
        log("NotifyOnNewObject for CheatManager not available — run items won't re-apply on lobby return")
    end

    -- Hook inventory removal functions to retry overflow items when slots free up.
    -- OnRep_Inventory doesn't fire for local changes on a listen server, so we
    -- hook the actual removal RPCs and drop/salvage functions instead.
    local function on_inventory_freed()
        pcall(function()
            local ItemApply = require("AP/ItemApply")
            if ItemApply.overflow_count() > 0 then
                -- Delay to let the removal complete before retrying
                LoopAsync(500, function()
                    ItemApply.retry_overflow()
                    return true
                end)
            end
        end)
    end

    -- CrabPS removal functions (called when dropping individual items)
    local remove_hooks = {
        "/Script/CrabChampions.CrabPS:ServerRemovePerk",
        "/Script/CrabChampions.CrabPS:ServerRemoveWeaponMod",
        "/Script/CrabChampions.CrabPS:ServerRemoveMeleeMod",
        "/Script/CrabChampions.CrabPS:ServerRemoveAbilityMod",
        "/Script/CrabChampions.CrabPS:ServerRemoveRelic",
    }
    for _, hook_path in ipairs(remove_hooks) do
        pcall(function()
            RegisterHook(hook_path, function(Context)
                on_inventory_freed()
            end)
        end)
    end

    -- CrabPlayerC drop/salvage functions
    pcall(function()
        RegisterHook("/Script/CrabChampions.CrabPlayerC:ServerDropPickup", function(Context)
            on_inventory_freed()
        end)
    end)
    pcall(function()
        RegisterHook("/Script/CrabChampions.CrabPlayerC:ServerSalvage", function(Context)
            on_inventory_freed()
        end)
    end)

    -- Also keep OnRep_Inventory as a fallback for any other inventory changes
    pcall(function()
        RegisterHook("/Script/CrabChampions.CrabPS:OnRep_Inventory", function(Context)
            on_inventory_freed()
        end)
    end)

    log("Pickup and island watch installed")
end

--- Send a pickup location check by DA full_name.
--- Called by ItemApply when items are granted via C++ mod (bypassing ClientOnPickedUpPickup).
---@param full_name string The DA full name (e.g., "CrabPerkDA /Game/Blueprint/...")
function M.send_pickup_check(full_name)
    if not client then return end
    if not full_name then return end
    if not LocationData.pickup_checks then return end  -- pickups aren't checks

    local location_id, kind = LocationData.from_da(full_name)
    if not location_id then return end

    if client:is_location_checked(location_id) then return end

    local display = LocationData.display_name(kind, full_name)
    log("Location check (granted): " .. display .. " → " .. tostring(location_id))
    client:send_check(location_id)
end

--- Reset the island counter (call on new run / return to lobby).
function M.reset_island_counter()
    island_counter = 0
    log("Island counter reset")
end

--- Get the current island count.
--- Prefers the game's CrabGS.CurrentIsland, falls back to our local counter.
---@return number
function M.get_island_count()
    local gs_island = get_current_island()
    if gs_island > 0 then return gs_island end
    return island_counter
end

return M
