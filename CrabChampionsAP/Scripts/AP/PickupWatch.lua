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

    local rank = tonumber(diff) or 0
    -- Clamp to valid range 0-7
    if rank < 0 then rank = 0 end
    if rank > 7 then rank = 7 end
    log("Rank detection: Difficulty=" .. tostring(diff)
        .. " rank=" .. tostring(rank)
        .. " (" .. (LocationData.RANK_NAMES[rank + 1] or "?") .. ")")
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
    perk        = "Enum /Script/CrabChampions.EPerkType",
    weapon_mod  = "Enum /Script/CrabChampions.EWeaponModType",
    ability_mod = "Enum /Script/CrabChampions.EAbilityModType",
    relic       = "Enum /Script/CrabChampions.ERelicType",
    melee_mod   = "Enum /Script/CrabChampions.EMeleeModType",
}

local function guess_enum_token(full_name)
    if not full_name then return nil end
    local leaf = full_name:match("%.(%w+)$") or full_name
    leaf = leaf:gsub("^DA_", "")
    leaf = leaf:gsub("^[A-Za-z]+_", "")
    return leaf
end

local function try_resolve_enum(kind, token)
    if not token or type(token) ~= "string" then return nil end
    local path = ENUM_PATH[kind]
    if not path then return nil end

    local ok, enum = pcall(function() return FindObject(path) end)
    if not ok or not enum then return nil end

    local val_ok, val = pcall(function()
        if enum.GetValueByNameString then
            return enum:GetValueByNameString(token)
        end
        if enum.GetValueByName then
            return enum:GetValueByName(token)
        end
        return nil
    end)

    if val_ok then return val end
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

    -- Check rank run at required rank is completed
    local rank_loc = LocationData.rank_run_location_id(req_rank)
    if not rank_loc or not client:is_location_checked(rank_loc) then
        return false
    end

    -- Count completed pool weapon runs at final island on required rank
    local weapon_count = 0
    for wname, _ in pairs(LocationData.pool_weapons) do
        local loc_id = LocationData.weapon_run_location_id_by_name(final, wname, req_rank)
        if loc_id and client:is_location_checked(loc_id) then
            weapon_count = weapon_count + 1
        end
    end

    -- Count completed pool melee runs at final island on required rank
    local melee_count = 0
    if LocationData.melee_for_completion > 0 then
        for mname, _ in pairs(LocationData.pool_melee) do
            local loc_id = LocationData.melee_run_location_id_by_name(final, mname, req_rank)
            if loc_id and client:is_location_checked(loc_id) then
                melee_count = melee_count + 1
            end
        end
    end

    -- Count completed pool ability runs at final island on required rank
    local ability_count = 0
    if LocationData.ability_for_completion > 0 then
        for aname, _ in pairs(LocationData.pool_abilities) do
            local loc_id = LocationData.ability_run_location_id_by_name(final, aname, req_rank)
            if loc_id and client:is_location_checked(loc_id) then
                ability_count = ability_count + 1
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
        local pickup = PickupDA and PickupDA.get and PickupDA:get() or nil
        local full_name = get_full_name(pickup)

        if not full_name then
            log("Pickup with no full_name — skipping")
            return
        end

        local location_id, kind = LocationData.from_da(full_name)

        if not location_id then
            if kind then
                log("No location ID for " .. kind .. " DA: " .. full_name)
            end
            return
        end

        local display = LocationData.display_name(kind, full_name)
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
    -- Island clear hook (rank-aware)
    -- ---------------------------------------------------------------
    RegisterHook("/Script/CrabChampions.CrabPC:ClientOnClearedIsland", function(Context)
        island_counter = island_counter + 1
        send_island_checks(island_counter, "Island cleared")

        -- Check if the NEXT island is a shop (no combat clear will fire).
        -- If so, flag it so the portal hook can send the shop check.
        if LocationData.SHOP_ISLANDS[island_counter + 1] then
            pending_shop_island = island_counter + 1
            log("Next island (" .. (island_counter + 1) .. ") is a shop — will send check on portal entry")
        end
    end)

    -- ---------------------------------------------------------------
    -- Run boundary detection: reset island counter on new run
    -- ---------------------------------------------------------------

    -- Detect leaving the lobby via portal = new run starting.
    -- Also handles shop island checks: when the player enters a portal
    -- after clearing the island before a shop, send the shop checks.
    RegisterHook("/Script/CrabChampions.CrabPC:ClientOnEnteredPortal", function(Context, ...)
        -- Lobby detection: if lobby actors exist, this is a new run
        local lobby_ok, lobby_actors = pcall(FindAllOf, "BP_Pickup_Lobby_C")
        if lobby_ok and lobby_actors and #lobby_actors > 0 then
            log("Portal from lobby detected — new run starting (island counter was " .. island_counter .. ")")
            island_counter = 0
            -- Signal ItemApply that we've left the lobby (no more spawning mid-run)
            local ia_ok, ItemApply = pcall(require, "AP/ItemApply")
            if ia_ok and ItemApply then ItemApply.in_lobby = false end
            pending_shop_island = nil
            return
        end

        -- Shop island handling: send checks for the shop and bump counter
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

    log("Pickup and island watch installed")
end

--- Reset the island counter (call on new run / return to lobby).
function M.reset_island_counter()
    island_counter = 0
    log("Island counter reset")
end

--- Get the current island count.
---@return number
function M.get_island_count()
    return island_counter
end

return M
