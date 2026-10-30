-- AP/PickupWatch.lua
-- Watches for player pickups and island clears, sends AP location checks.
--
-- Pickups: hooks ClientOnPickedUpPickup → send check → remove item
-- Islands: hooks ClientOnClearedIsland → send island + equipment run checks
-- Rank: reads CrabGS.Difficulty (ECrabRank) to determine current rank
-- Cascade: when enabled, completing at rank R also checks ranks < R

local LocationData = require("AP/LocationData")
local GameThread = require("AP/GameThread")

local M = {}

local function log(msg) print("[CrabAP-Pickup] " .. tostring(msg)) end

-- Reference to APClient, set by install()
local client = nil

-- Island counter (incremented on each ClientOnClearedIsland)
local island_counter = 0

-- Biome each island of this run was cleared in (island -> biome number), for the biome check layout. The last
-- island of a biome may be cleared after the game has moved on to the next one, so it takes the biome of the
-- island before it.
local biome_of_island = {}

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

-- Fields of a pickup DA that hold the enum its ServerRemove* RPC takes.
local ENUM_FIELDS = {
    perk        = { "PerkType", "Type" },
    relic       = { "RelicType", "Type" },
    weapon_mod  = { "WeaponModType", "Type" },
    melee_mod   = { "MeleeModType", "Type" },
    ability_mod = { "AbilityModType", "Type" },
}

--- The enum value the DA itself carries, or nil.
local function enum_from_da(kind, da)
    if not da then return nil end
    for _, field in ipairs(ENUM_FIELDS[kind] or {}) do
        local ok, v = pcall(function() return da[field] end)
        if ok and v ~= nil then return v end
    end
    return nil
end

local function remove_item(kind, full_name, da)
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

    -- The DA's own enum field removes exactly this item. A name token cut from
    -- the asset path is only a fallback and does not resolve to an enum.
    local param = enum_from_da(kind, da) or try_resolve_enum(kind, token)
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
    -- Without Bronze checks the plain checks are the Bronze checks, and every
    -- clear counts as Bronze whatever its rank.
    if not LocationData.bronze_checks and current_rank > 0
            and not LocationData.cascade_ranked_checks then
        ranks[#ranks + 1] = 0
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
    local equip_mode = LocationData.equipment_check_mode

    -- Check rank run at required rank is completed. Bronze has no rank run
    -- of its own; the final-island equipment checks below show the run is done.
    if LocationData.rank_is_separate(req_rank) then
        local rank_loc = LocationData.rank_run_location_id(req_rank)
        if not rank_loc or not client:is_location_checked(rank_loc) then
            return false
        end
    end

    --- Count completed runs at the final island on the required rank.
    --- Only pool equipment counts: non-pool equipment is available from the
    --- start, so counting it would let the goal be met without receiving a
    --- single AP item.  Seeds made before 1.4 were generated with non-pool
    --- runs counting whenever equipment_check_mode wasn't disabled, so they
    --- keep that rule and a client update can't change their goal mid-run.
    local count_non_pool = not LocationData.pool_only_completion and equip_mode ~= 2
    ---@param pool_set table Set of pool equipment names (name -> true)
    ---@param all_names table Ordered list of every name of this kind
    ---@param loc_id_fn function (check index, name, rank) -> location_id
    local function count_completed_runs(pool_set, all_names, loc_id_fn)
        local count = 0
        for _, name in ipairs(all_names) do
            if pool_set[name] or count_non_pool then
                if LocationData.final_run_checked(loc_id_fn, name, req_rank,
                        function(id) return client:is_location_checked(id) end,
                        function(kind, n) return client.is_run_completed and client:is_run_completed(kind, n) end) then
                    count = count + 1
                end
            end
        end
        return count
    end

    local weapon_count = count_completed_runs(
        LocationData.pool_weapons, LocationData.weapon_names,
        LocationData.weapon_run_location_id_by_name)

    local melee_count = 0
    if LocationData.melee_for_completion > 0 then
        melee_count = count_completed_runs(
            LocationData.pool_melee, LocationData.melee_names,
            LocationData.melee_run_location_id_by_name)
    end

    local ability_count = 0
    if LocationData.ability_for_completion > 0 then
        ability_count = count_completed_runs(
            LocationData.pool_abilities, LocationData.ability_names,
            LocationData.ability_run_location_id_by_name)
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
-- ---------------------------------------------------------------
-- Full-inventory pickups
--
-- The dll lets a pickup through a full inventory when its check is still
-- open (see CrabInvMngmt). Such a pickup is always stripped after the check
-- is sent, so the inventory never ends up over capacity.
-- ---------------------------------------------------------------

local gate_installed = false
local gate_sig = nil

local function gate_available()
    return type(AP_InstallPickupGate) == "function" and type(AP_SetOpenPickupChecks) == "function"
end

local function ensure_gate()
    if gate_installed or not gate_available() then return end
    local ok, cdo = pcall(StaticFindObject, "/Script/CrabChampions.Default__CrabInteractPickup")
    if not ok or not cdo or not cdo:IsValid() then return end
    local ok2, installed = pcall(AP_InstallPickupGate, cdo:GetAddress())
    if ok2 and installed then
        gate_installed = true
        log("Full-inventory pickup gate: " .. tostring(AP_PickupGateStatus and AP_PickupGateStatus()))
    else
        log("Full-inventory pickup gate unavailable, pickups keep the game's rules: "
            .. tostring(AP_PickupGateStatus and AP_PickupGateStatus()))
        gate_available = function() return false end
    end
end

--- Tell the dll which pickups still have an open check.
function M.refresh_open_checks()
    if not gate_available() then return end
    local keys = {}
    if client and client.slot_data and LocationData.pickup_checks then
        keys = LocationData.open_pickup_keys(function(id) return client:is_location_checked(id) end)
    end
    local sig = table.concat(keys, ",")
    if sig == gate_sig then return end
    gate_sig = sig
    pcall(AP_SetOpenPickupChecks, keys)
end

function M.install(ap_client)
    client = ap_client

    -- Keep the dll's open-check set current (checks arrive from the server too).
    if gate_available() then
        GameThread.loop(2500, function()
            ensure_gate()
            M.refresh_open_checks()
            return false
        end)
    end

    -- ---------------------------------------------------------------
    -- Where a pickup came from
    --
    -- Loot, chest and totem items are owned by the player who earned them,
    -- and shop items have a price. Items the player dropped, the lobby key
    -- totem's free item and pickups this mod spawns have neither, so they
    -- aren't finds. The interact event carries the pickup actor; the pickup
    -- event that follows only has the item.
    -- ---------------------------------------------------------------
    local pending_pickup = nil   -- { da_addr = integer, is_find = bool }
    local pickup_class = nil

    -- Portals, chests and totems also go through ServerInteract, and
    -- reading PickupInfo on them returns junk, so check the class.
    local function is_item_pickup(actor)
        if pickup_class == nil then
            local ok, cls = pcall(StaticFindObject, "/Script/CrabChampions.CrabInteractPickup")
            pickup_class = (ok and cls and cls:IsValid()) and cls or false
        end
        if pickup_class then
            local ok, yes = pcall(function() return actor:IsA(pickup_class) end)
            if ok then return yes end
        end
        local fn = get_full_name(actor) or ""
        return fn:find("^CrabInteractPickup ") ~= nil or fn:find("^BP_Pickup_") ~= nil
    end

    -- PickupInfo.OwningPS can still point at a player state the game has
    -- already destroyed (seen right after the final island). Reading it from
    -- Lua wraps the pointer and crashes the game, so the dll compares it as a
    -- raw pointer instead. Without that dll function the origin stays unknown
    -- and the pickup counts as a find.
    RegisterHook("/Script/CrabChampions.CrabPlayerC:ServerInteract", function(Context, Actor)
        pending_pickup = nil
        if type(AP_PickupIsFind) ~= "function" then return end
        local actor = Actor and Actor.get and Actor:get() or nil
        if not actor or not actor:IsValid() or not is_item_pickup(actor) then return end
        pcall(function()
            local ps = Context:get().PlayerState
            local ps_addr = (ps and ps:IsValid()) and ps:GetAddress() or 0
            local is_find, da_addr = AP_PickupIsFind(actor:GetAddress(), ps_addr)
            if is_find == nil then return end
            pending_pickup = { da_addr = da_addr, is_find = is_find }
        end)
    end)

    -- ---------------------------------------------------------------
    -- Pickup hook (not rank-dependent)
    -- ---------------------------------------------------------------
    local function strip_later(kind, full_name, da)
        GameThread.loop(200, function()
            remove_item(kind, full_name, da)
            -- Retry overflow items — removing an item freed a slot
            pcall(function()
                local ItemApply = require("AP/ItemApply")
                if ItemApply.overflow_count() > 0 then
                    ItemApply.retry_overflow()
                end
            end)
            return true
        end)
    end

    RegisterHook("/Script/CrabChampions.CrabPC:ClientOnPickedUpPickup", function(Context, PickupDA)
        -- When pickup checks are disabled, don't process pickups as checks
        if not LocationData.pickup_checks then return end
        -- Not connected to a seed this session: leave the game alone.
        if not client or not client.slot_data then return end

        local pickup = PickupDA and PickupDA.get and PickupDA:get() or nil
        local full_name = get_full_name(pickup)

        if not full_name then
            log("Pickup with no full_name — skipping")
            return
        end

        -- Let through a full inventory by the dll: whatever happens below, it
        -- has to be stripped, or the inventory stays over capacity.
        local lifted = false
        local gate_key = LocationData.gate_key(full_name)
        if gate_key and type(AP_ConsumePickupLift) == "function" then
            local ok, hit = pcall(AP_ConsumePickupLift, gate_key)
            lifted = ok and hit == true
        end
        local lifted_kind = lifted and select(2, LocationData.from_da(full_name)) or nil
        if lifted then log("Picked up past a full inventory: " .. full_name) end

        -- Check if this mod is suppressed (bundled with a disallowed weapon being reverted)
        local equip_lock = _G.AP and _G.AP.equip_lock or nil
        if equip_lock and equip_lock.suppressed_mods then
            local display_name = LocationData.display_name(nil, full_name) or ""
            for mod_name, _ in pairs(equip_lock.suppressed_mods) do
                if display_name == mod_name or full_name:find(mod_name:gsub("%s+", "")) then
                    log("Suppressed pickup check for bundled mod: " .. display_name)
                    if lifted_kind then strip_later(lifted_kind, full_name, pickup) end
                    return
                end
            end
        end

        -- Only a real find counts. Without a matching interact (hook not
        -- available) fall back to treating it as one.
        local origin = pending_pickup
        pending_pickup = nil
        local pickup_addr = nil
        if origin then
            local ok, addr = pcall(function() return pickup:GetAddress() end)
            pickup_addr = ok and addr or nil
        end
        if origin and pickup_addr ~= nil and origin.da_addr == pickup_addr and not origin.is_find then
            log("Not a find (dropped, lobby or mod-spawned), ignored: " .. full_name)
            if lifted_kind then strip_later(lifted_kind, full_name, pickup) end
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
            if lifted then
                log("Already checked, stripping the extra copy: " .. display)
                strip_later(kind, full_name, pickup)
            else
                log("Already checked — skipping removal")
            end
            return
        end

        client:send_check(location_id)
        M.refresh_open_checks()

        -- A received item is the player's already, so the found copy stays,
        -- unless it only fit because the dll lifted the capacity limit.
        local ia_ok, ItemApply = pcall(require, "AP/ItemApply")
        if not lifted and ia_ok and ItemApply and ItemApply.unlocked[full_name] then
            log("Found an item already received, keeping it: " .. display)
            return
        end

        strip_later(kind, full_name, pickup)
    end)

    -- ---------------------------------------------------------------
    -- Shared: send island + equipment checks for a given island number
    -- ---------------------------------------------------------------
    local function should_check_equip(equip_name, is_pool_fn)
        if is_pool_fn(equip_name) then return true end
        return LocationData.equipment_check_mode ~= 2
    end

    local function biome_for_island(num)
        if not LocationData.biome_layout then return nil end
        local ok, BiomeLock = pcall(require, "AP/BiomeLock")
        local cur = ok and BiomeLock and BiomeLock.current_biome and BiomeLock.current_biome() or nil
        if num % LocationData.BIOME_LENGTH == 0 then
            -- The latest island of this biome seen so far (the shop, or an earlier one if the shop was not seen).
            for back = 1, LocationData.BIOME_LENGTH - 1 do
                if biome_of_island[num - back] then
                    cur = biome_of_island[num - back]
                    break
                end
            end
        end
        if cur then biome_of_island[num] = cur end
        return cur
    end

    --- Whether this run has cleared islands in all four biomes (biome layout only; the other layouts have no
    --- such rule). A run that stays in fewer biomes (a locked biome repeats) is not a completed run.
    local function run_covers_all_biomes()
        if not LocationData.biome_layout then return true end
        local seen, n = {}, 0
        for _, b in pairs(biome_of_island) do
            if not seen[b] then seen[b] = true; n = n + 1 end
        end
        return n >= 4
    end
    M.run_covers_all_biomes = run_covers_all_biomes

    --- Send all location checks for a given island number.
    --- @param num number The island number (1-based)
    --- @param label string Log prefix ("Island cleared" or "Reached shop")
    local function send_island_checks(num, label)
        local rank = get_current_rank()
        log(label .. " — counter=" .. tostring(num) .. " rank=" .. tostring(rank)
            .. " (" .. (LocationData.RANK_NAMES[rank + 1] or "?") .. ")")

        -- The number the ID functions take: the island number, or the biome check index.
        local idx = LocationData.check_index(num, biome_for_island(num))
        if not idx then
            log("Biome unknown for island " .. tostring(num) .. " — skipping island checks")
            return
        end

        local is_shop = LocationData.SHOP_ISLANDS[num] or false
        local check_ranks = ranks_to_check(rank)
        local pfx = is_shop and "Reach Shop on Island" or "Complete Island"
        -- Names for the log: the check's own name (biome layout: "Complete Tropical Island 3").
        local lname = LocationData.biome_layout and LocationData.check_name(idx) or (pfx .. " " .. num)
        local iname = LocationData.biome_layout and lname or ("Island " .. num)

        -- Island completion checks
        if LocationData.extra_ranked_island_checks then
            -- Extra ranked mode: send ranked checks for all applicable ranks
            for _, r in ipairs(check_ranks) do
                if r <= LocationData.max_rank then
                    local rname = LocationData.RANK_NAMES[r + 1] or "?"
                    -- Bronze without Bronze checks is the plain check: log it by its own name.
                    local rsfx = LocationData.rank_is_separate(r) and (" on " .. rname) or ""
                    try_send_check(
                        LocationData.island_location_id(idx, LocationData.tier_rank(r)),
                        "Ranked island: " .. lname .. rsfx
                    )
                end
            end
        else
            -- Normal mode: send unranked check + ranked check at required_rank
            try_send_check(
                LocationData.island_location_id(idx),
                "Island check: " .. lname
            )
            if rank >= LocationData.required_rank
                    and LocationData.rank_is_separate(LocationData.required_rank) then
                local rname = LocationData.RANK_NAMES[LocationData.required_rank + 1] or "?"
                try_send_check(
                    LocationData.island_location_id(idx, LocationData.required_rank),
                    "Ranked island: " .. lname .. " on " .. rname
                )
            end
        end

        -- Equipment run checks
        local ps = get_ps()
        local weapon_fn, melee_fn, ability_fn
        if ps then
            local w_ok, w_da = pcall(function() return ps.WeaponDA end)
            weapon_fn = w_ok and get_full_name(w_da) or nil

            local m_ok, m_da = pcall(function() return ps.MeleeDA end)
            melee_fn = m_ok and get_full_name(m_da) or nil

            local a_ok, a_da = pcall(function() return ps.AbilityDA end)
            ability_fn = a_ok and get_full_name(a_da) or nil

            -- Unranked + required-rank equipment checks (when extra_ranked is off)
            if not LocationData.extra_ranked_island_checks then
                local req_rank = LocationData.required_rank
                local rname = LocationData.RANK_NAMES[req_rank + 1] or "?"
                local at_req = rank >= req_rank and LocationData.rank_is_separate(req_rank)

                if weapon_fn then
                    local wname = LocationData.equipment_name("weapon", weapon_fn)
                    if should_check_equip(wname, LocationData.is_pool_weapon) then
                        try_send_check(
                            LocationData.weapon_run_location_id(idx, weapon_fn),
                            "Weapon run: " .. iname .. " with " .. wname
                        )
                        if at_req then
                            try_send_check(
                                LocationData.weapon_run_location_id(idx, weapon_fn, req_rank),
                                "Ranked weapon: " .. iname .. " with " .. wname .. " on " .. rname
                            )
                        end
                    end
                end
                if melee_fn then
                    local mname = LocationData.equipment_name("melee", melee_fn)
                    if should_check_equip(mname, LocationData.is_pool_melee) then
                        try_send_check(
                            LocationData.melee_run_location_id(idx, melee_fn),
                            "Melee run: " .. iname .. " with " .. mname
                        )
                        if at_req then
                            try_send_check(
                                LocationData.melee_run_location_id(idx, melee_fn, req_rank),
                                "Ranked melee: " .. iname .. " with " .. mname .. " on " .. rname
                            )
                        end
                    end
                end
                if ability_fn then
                    local aname = LocationData.equipment_name("ability", ability_fn)
                    if should_check_equip(aname, LocationData.is_pool_ability) then
                        try_send_check(
                            LocationData.ability_run_location_id(idx, ability_fn),
                            "Ability run: " .. iname .. " with " .. aname
                        )
                        if at_req then
                            try_send_check(
                                LocationData.ability_run_location_id(idx, ability_fn, req_rank),
                                "Ranked ability: " .. iname .. " with " .. aname .. " on " .. rname
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
                        local rsfx = LocationData.rank_is_separate(r) and (" on " .. rname) or ""
                        if weapon_fn then
                            local wname = LocationData.equipment_name("weapon", weapon_fn)
                            if should_check_equip(wname, LocationData.is_pool_weapon) then
                                try_send_check(
                                    LocationData.weapon_run_location_id(idx, weapon_fn, LocationData.tier_rank(r)),
                                    "Ranked weapon: " .. iname .. " with " .. wname .. rsfx
                                )
                            end
                        end
                        if melee_fn then
                            local mname = LocationData.equipment_name("melee", melee_fn)
                            if should_check_equip(mname, LocationData.is_pool_melee) then
                                try_send_check(
                                    LocationData.melee_run_location_id(idx, melee_fn, LocationData.tier_rank(r)),
                                    "Ranked melee: " .. iname .. " with " .. mname .. rsfx
                                )
                            end
                        end
                        if ability_fn then
                            local aname = LocationData.equipment_name("ability", ability_fn)
                            if should_check_equip(aname, LocationData.is_pool_ability) then
                                try_send_check(
                                    LocationData.ability_run_location_id(idx, ability_fn, LocationData.tier_rank(r)),
                                    "Ranked ability: " .. iname .. " with " .. aname .. rsfx
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
        if num >= LocationData.run_length and not run_covers_all_biomes() then
            log("Island " .. num .. " reached, but the run did not clear all four biomes — not a completed run")
        elseif num >= LocationData.run_length then
            log("Run complete at island " .. num .. "!")
            if LocationData.extra_ranked_island_checks then
                -- Extra ranked mode: send rank runs for all applicable ranks
                for _, r in ipairs(check_ranks) do
                    if r <= LocationData.max_rank and LocationData.rank_is_separate(r) then
                        local rname = LocationData.RANK_NAMES[r + 1] or "?"
                        try_send_check(
                            LocationData.rank_run_location_id(r),
                            "Rank run: Complete Run on " .. rname
                        )
                    end
                end
            else
                -- Normal mode: only send rank run at required_rank
                if rank >= LocationData.required_rank
                        and LocationData.rank_is_separate(LocationData.required_rank) then
                    local rname = LocationData.RANK_NAMES[LocationData.required_rank + 1] or "?"
                    try_send_check(
                        LocationData.rank_run_location_id(LocationData.required_rank),
                        "Rank run: Complete Run on " .. rname
                    )
                end
            end

            -- Biome layout: the goal counts run-level equipment checks, which fire on the final island in any biome.
            if LocationData.biome_layout then
                local run_ranks = {}
                if LocationData.extra_ranked_island_checks then
                    for _, r in ipairs(check_ranks) do
                        if r <= LocationData.max_rank then run_ranks[#run_ranks + 1] = r end
                    end
                elseif rank >= LocationData.required_rank then
                    run_ranks[1] = LocationData.required_rank
                end
                local kinds = {
                    { "weapon", weapon_fn, LocationData.is_pool_weapon },
                    { "melee", melee_fn, LocationData.is_pool_melee },
                    { "ability", ability_fn, LocationData.is_pool_ability },
                }
                for _, k in ipairs(kinds) do
                    if k[2] then
                        local ename = LocationData.equipment_name(k[1], k[2])
                        if should_check_equip(ename, k[3]) then
                            for _, r in ipairs(run_ranks) do
                                -- Bronze has no run-level check; the final island's
                                -- plain check above is the one that counts.
                                if LocationData.rank_is_separate(r) then try_send_check(
                                    LocationData.run_equipment_location_id(k[1], ename, r),
                                    "Run " .. k[1] .. ": Complete Run with " .. ename .. " on "
                                        .. (LocationData.RANK_NAMES[r + 1] or "?")
                                ) end
                            end
                        end
                    end
                end
            end

            -- Bronze has no run-level check, and the final island's equipment checks are ordinary checks that
            -- send whatever the run was. The goal counts the equipment of runs that cleared all four biomes,
            -- kept in the server's data storage.
            if LocationData.biome_layout and not LocationData.rank_is_separate(LocationData.required_rank)
                    and client.record_run_completed then
                for _, k in ipairs({ { "weapon", weapon_fn }, { "melee", melee_fn }, { "ability", ability_fn } }) do
                    if k[2] then
                        client:record_run_completed(k[1], LocationData.equipment_name(k[1], k[2]))
                    end
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

        -- Clearing a biome's last island: grant biome_item_percentage of
        -- the received items not yet in this run.
        if island % LocationData.BIOME_LENGTH == 0 and island < LocationData.run_length then
            local ia_ok, ItemApply = pcall(require, "AP/ItemApply")
            if ia_ok and ItemApply and ItemApply.on_biome_cleared then
                ItemApply.on_biome_cleared()
            end
        end

        -- Check if the NEXT island is a shop (no combat clear will fire).
        -- If so, flag it so the portal hook can send the shop check.
        if LocationData.SHOP_ISLANDS[island + 1] then
            pending_shop_island = island + 1
            log("Next island (" .. (island + 1) .. ") is a shop — will send check on portal entry")
        end

        -- Retry overflow items — clearing an island may grant new inventory slots
        GameThread.loop(500, function()
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
            biome_of_island = {}
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
            GameThread.loop(2000, function()
                log("Lobby re-apply: resetting island counter and re-spawning run items")
                island_counter = 0
                biome_of_island = {}
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
                GameThread.loop(500, function()
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
    biome_of_island = {}
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
