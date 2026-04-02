-- AP/EquipLock.lua
-- Equipment locking for Archipelago.
-- Restricts which weapons, abilities, and melee weapons the player can equip.
-- Uses C++ mod (AP_EquipLock_*) for enforcement when available,
-- falls back to Lua-based ServerEquipInventory calls otherwise.

local M = {}

local function log(msg) print("[CrabAP-EquipLock] " .. tostring(msg)) end

-- Weapons that grant bundled perks/mods when equipped.
-- When a disallowed weapon is reverted, these must be stripped.
-- Format: weapon name -> { {mod_name, count}, ... }
local WEAPON_BUNDLED_MODS = {
    ["Arcane Wand"]       = { {"Arcane Shot", 2} },
    ["Flamethrower"]      = { {"Fire Shot", 1} },
    ["Ice Staff"]         = { {"Ice Shot", 1} },
    ["Lightning Scepter"] = { {"Lightning Shot", 1} },
    ["Minigun"]           = { {"Escalating Shot", 1} },
    ["Poison Cannon"]     = { {"Poison Shot", 1} },
}

-- Mod names temporarily suppressed from sending pickup checks.
-- Set before enforcement, cleared after bundled mods are stripped.
M.suppressed_mods = {}  -- mod_name -> true

-- Allowed sets (full_name strings -> true)
M.allowed = { weapon = {}, ability = {}, melee = {} }

-- DA maps: full_name -> DA userdata
local weapon_by_full, ability_by_full, melee_by_full = nil, nil, nil
local weapon_full_by_name, ability_full_by_name, melee_full_by_name = nil, nil, nil

-- deferred enforcement state
local pending_enforce = false
local reentry = false

-- Run state: only enforce loadout at the start of a run, not mid-run
M.run_active = false

-- Whether C++ equip lock is available
local function has_cpp()
    return AP_EquipLock_SetActive ~= nil
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function safe_str(x)
    if x == nil then return nil end
    if type(x) == "string" then return x end
    if type(x) == "userdata" then
        local ok, s = pcall(function()
            if x.ToString then return x:ToString() end
            if x.GetFullName then return x:GetFullName() end
            return tostring(x)
        end)
        if ok then return tostring(s) end
    end
    return tostring(x)
end

local function get_full_name(obj)
    if not obj then return nil end
    local ok, v = pcall(function()
        if obj.GetFullName then return obj:GetFullName() end
        return nil
    end)
    if ok and v ~= nil then return safe_str(v) end
    return safe_str(obj)
end

local function get_name(obj)
    if not obj then return nil end
    local ok, v = pcall(function() return obj.Name end)
    if ok and v ~= nil then return safe_str(v) end
    return nil
end

local function has_any(set)
    for _ in pairs(set) do return true end
    return false
end

local function build_maps(class_name)
    local by_full, full_by_name = {}, {}
    local list = FindAllOf(class_name)
    if not list then return by_full, full_by_name end
    for _, da in ipairs(list) do
        if da ~= nil and (not da.IsValid or da:IsValid()) then
            local fn = get_full_name(da)
            if fn then
                by_full[fn] = da
                local nm = get_name(da)
                if nm and not full_by_name[nm] then
                    full_by_name[nm] = fn
                end
            end
        end
    end
    return by_full, full_by_name
end

function M.refresh_maps()
    weapon_by_full, weapon_full_by_name = build_maps("CrabWeaponDA")
    ability_by_full, ability_full_by_name = build_maps("CrabAbilityDA")
    melee_by_full, melee_full_by_name = build_maps("CrabMeleeDA")
    log("DA maps refreshed.")
end

------------------------------------------------------------
-- Sync allowed sets to C++ mod
------------------------------------------------------------

--- Sync a single allowed set to C++
local function sync_to_cpp(kind, lua_set, da_map)
    if not has_cpp() then return end
    AP_EquipLock_Clear(kind)
    for fn, _ in pairs(lua_set) do
        local da = da_map and da_map[fn]
        if da then
            local ok, addr = pcall(function() return da:GetAddress() end)
            if ok and addr then
                AP_EquipLock_Allow(kind, addr)
            end
        end
    end
end

--- Sync all allowed sets to C++
local function sync_all_to_cpp()
    if not has_cpp() then return end
    sync_to_cpp("weapon", M.allowed.weapon, weapon_by_full)
    sync_to_cpp("ability", M.allowed.ability, ability_by_full)
    sync_to_cpp("melee", M.allowed.melee, melee_by_full)
    AP_EquipLock_SetActive(true)
end

------------------------------------------------------------
-- Allow equipment
------------------------------------------------------------

--- Allow a specific equipment item by full_name.
--- Syncs to C++ immediately if available.
function M.allow_item(kind, full_name)
    if kind == "weapon" then
        M.allowed.weapon[full_name] = true
        if has_cpp() and weapon_by_full and weapon_by_full[full_name] then
            local ok, addr = pcall(function() return weapon_by_full[full_name]:GetAddress() end)
            if ok and addr then AP_EquipLock_Allow("weapon", addr) end
        end
    elseif kind == "ability" then
        M.allowed.ability[full_name] = true
        if has_cpp() and ability_by_full and ability_by_full[full_name] then
            local ok, addr = pcall(function() return ability_by_full[full_name]:GetAddress() end)
            if ok and addr then AP_EquipLock_Allow("ability", addr) end
        end
    elseif kind == "melee" then
        M.allowed.melee[full_name] = true
        if has_cpp() and melee_by_full and melee_by_full[full_name] then
            local ok, addr = pcall(function() return melee_by_full[full_name]:GetAddress() end)
            if ok and addr then AP_EquipLock_Allow("melee", addr) end
        end
    end
end

--- Set allowed lists from options (used during slot_connected).
function M.set_allowed(opts)
    if not weapon_by_full then M.refresh_maps() end

    if opts.weapons then
        M.allowed.weapon = {}
        for _, fn in ipairs(opts.weapons.fullnames or {}) do M.allowed.weapon[fn] = true end
        for _, nm in ipairs(opts.weapons.names or {}) do
            local fn = weapon_full_by_name[nm]
            if fn then M.allowed.weapon[fn] = true end
        end
    end
    if opts.abilities then
        M.allowed.ability = {}
        for _, fn in ipairs(opts.abilities.fullnames or {}) do M.allowed.ability[fn] = true end
        for _, nm in ipairs(opts.abilities.names or {}) do
            local fn = ability_full_by_name[nm]
            if fn then M.allowed.ability[fn] = true end
        end
    end
    if opts.melee then
        M.allowed.melee = {}
        for _, fn in ipairs(opts.melee.fullnames or {}) do M.allowed.melee[fn] = true end
        for _, nm in ipairs(opts.melee.names or {}) do
            local fn = melee_full_by_name[nm]
            if fn then M.allowed.melee[fn] = true end
        end
    end

    sync_all_to_cpp()
end

------------------------------------------------------------
-- Enforcement
------------------------------------------------------------

local function mark_enforce(reason)
    pending_enforce = true
end

--- Public: request enforcement on next tick.
function M.request_enforce(reason)
    mark_enforce(reason)
end

--- Public: signal that the player has returned to the lobby.
function M.on_lobby_entered()
    if M.run_active then
        log("Lobby entered — run ended, enforcement re-armed for next run")
        M.run_active = false
    end
end

--- Strip bundled weapon mods that were added when a disallowed weapon was equipped.
--- Finds the DA full_name and uses ServerRemoveWeaponMod (same as PickupWatch).
local function strip_bundled_mods(weapon_name)
    if not weapon_name then return end
    local bundled = WEAPON_BUNDLED_MODS[weapon_name]
    if not bundled then return end

    -- Build mod DA lookup if needed
    local mod_full_names = {}
    pcall(function()
        local all = FindAllOf("CrabWeaponModDA")
        if all then
            for _, da in ipairs(all) do
                if da and da:IsValid() then
                    local fn = get_full_name(da)
                    if fn then
                        local leaf = fn:match("DA_WeaponMod_(%w+)")
                        if leaf then mod_full_names[leaf] = fn end
                    end
                end
            end
        end
    end)

    local ps = nil
    pcall(function()
        local pss = FindAllOf("CrabPS")
        if pss and #pss > 0 then ps = pss[1] end
    end)
    if not ps then return end

    for _, entry in ipairs(bundled) do
        local mod_name = entry[1]
        local mod_count = entry[2]
        local da_key = mod_name:gsub("%s+", "")
        local full_name = mod_full_names[da_key]

        if full_name then
            for i = 1, mod_count do
                pcall(function()
                    ps:ServerRemoveWeaponMod(full_name)
                end)
            end
            log("Stripped bundled mod: " .. mod_name .. " x" .. mod_count .. " (from " .. weapon_name .. ")")
        else
            log("Could not find DA for bundled mod: " .. mod_name)
        end
    end
end

--- Get the clean weapon name from a full DA name.
--- e.g., "CrabWeaponDA /Game/.../DA_Weapon_ArcaneWand.DA_Weapon_ArcaneWand" -> "Arcane Wand"
local function weapon_name_from_full(full_name)
    if not full_name then return nil end
    -- Extract leaf: DA_Weapon_ArcaneWand -> ArcaneWand
    local leaf = full_name:match("DA_Weapon_(%w+)")
    if not leaf then return nil end
    -- Convert CamelCase to spaced: ArcaneWand -> Arcane Wand
    return leaf:gsub("(%l)(%u)", "%1 %2")
end

--- Enforce equipment restrictions now.
--- Uses C++ ProcessEvent when available, falls back to Lua RPC.
local function do_enforce(reason)
    if reentry then return end

    -- Nothing configured = nothing to enforce
    if not has_any(M.allowed.weapon) and not has_any(M.allowed.ability) and not has_any(M.allowed.melee) then
        return
    end

    -- Capture current weapon before enforcement to check for bundled mods
    local current_weapon_name = nil
    pcall(function()
        local pss = FindAllOf("CrabPS")
        if pss and #pss > 0 then
            local w = pss[1].WeaponDA
            local w_fn = get_full_name(w)
            if w_fn and has_any(M.allowed.weapon) and not M.allowed.weapon[w_fn] then
                current_weapon_name = weapon_name_from_full(w_fn)
            end
        end
    end)

    -- C++ path: fast, reliable
    if has_cpp() then
        reentry = true
        local ok, swapped = pcall(AP_EquipLock_Enforce)
        reentry = false
        if ok and swapped then
            log("ENFORCED via C++: " .. tostring(reason))
        end
        return
    end

    -- Lua fallback: uses ServerEquipInventory RPC
    local pss = FindAllOf("CrabPS")
    if not pss then return end

    for _, ps in ipairs(pss) do
        if ps and ps:IsValid() then
            local w = ps.WeaponDA
            local a = ps.AbilityDA
            local m = ps.MeleeDA
            local w_fn = get_full_name(w)
            local a_fn = get_full_name(a)
            local m_fn = get_full_name(m)

            local needW = w_fn and has_any(M.allowed.weapon) and not M.allowed.weapon[w_fn]
            local needA = a_fn and has_any(M.allowed.ability) and not M.allowed.ability[a_fn]
            local needM = m_fn and has_any(M.allowed.melee) and not M.allowed.melee[m_fn]

            if needW or needA or needM then
                local replW = w
                local replA = a
                local replM = m

                if needW then
                    for fn, _ in pairs(M.allowed.weapon) do
                        if weapon_by_full[fn] then replW = weapon_by_full[fn]; break end
                    end
                end
                if needA then
                    for fn, _ in pairs(M.allowed.ability) do
                        if ability_by_full[fn] then replA = ability_by_full[fn]; break end
                    end
                end
                if needM then
                    for fn, _ in pairs(M.allowed.melee) do
                        if melee_by_full[fn] then replM = melee_by_full[fn]; break end
                    end
                end

                if replW and replA and replM then
                    reentry = true
                    pcall(function() ps:ServerEquipInventory(replW, replA, replM) end)
                    reentry = false
                    log("ENFORCED via Lua: " .. tostring(reason))
                end
            end
            return
        end
    end
end

------------------------------------------------------------
-- Install hooks
------------------------------------------------------------
function M.install()
    if not weapon_by_full then M.refresh_maps() end

    -- Hook ServerSet* to detect disallowed equipment changes
    RegisterHook("/Script/CrabChampions.CrabPS:ServerSetWeaponDA", function(Context, NewWeaponDA)
        local req = NewWeaponDA and NewWeaponDA.get and NewWeaponDA:get() or nil
        local req_fn = get_full_name(req)
        if req_fn and has_any(M.allowed.weapon) and not M.allowed.weapon[req_fn] then
            -- Immediately suppress bundled mod pickup checks before they fire
            local wname = weapon_name_from_full(req_fn)
            if wname then
                local bundled = WEAPON_BUNDLED_MODS[wname]
                if bundled then
                    for _, entry in ipairs(bundled) do
                        M.suppressed_mods[entry[1]] = true
                    end
                    log("Suppressed mods for disallowed weapon: " .. wname)
                end
                -- Strip the bundled mods directly on the hook thread (RPCs work here)
                strip_bundled_mods(wname)
                -- Clear suppression after a delay to ensure pickup hooks have fired
                LoopAsync(1000, function()
                    M.suppressed_mods = {}
                    return true
                end)
            end
            mark_enforce("ServerSetWeaponDA")
        end
    end)

    RegisterHook("/Script/CrabChampions.CrabPS:ServerSetAbilityDA", function(Context, NewAbilityDA)
        local req = NewAbilityDA and NewAbilityDA.get and NewAbilityDA:get() or nil
        local req_fn = get_full_name(req)
        if req_fn and has_any(M.allowed.ability) and not M.allowed.ability[req_fn] then
            mark_enforce("ServerSetAbilityDA")
        end
    end)

    RegisterHook("/Script/CrabChampions.CrabPS:ServerSetMeleeDA", function(Context, NewMeleeDA)
        local req = NewMeleeDA and NewMeleeDA.get and NewMeleeDA:get() or nil
        local req_fn = get_full_name(req)
        if req_fn and has_any(M.allowed.melee) and not M.allowed.melee[req_fn] then
            mark_enforce("ServerSetMeleeDA")
        end
    end)

    -- OnRep hooks
    local function get_ps_from_hook_arg(arg1)
        if arg1 == nil then return nil end
        if type(arg1) == "userdata" and arg1.get then
            local ok, v = pcall(function() return arg1:get() end)
            if ok then return v end
        end
        return arg1
    end

    for _, rep_name in ipairs({"OnRep_WeaponDA", "OnRep_MeleeDA", "OnRep_AbilityDA"}) do
        RegisterHook("/Script/CrabChampions.CrabPS:" .. rep_name, function(arg1)
            local ps = get_ps_from_hook_arg(arg1)
            if ps and ps.IsValid and ps:IsValid() then
                local w_fn = get_full_name(ps.WeaponDA)
                local a_fn = get_full_name(ps.AbilityDA)
                local m_fn = get_full_name(ps.MeleeDA)
                local bad = (w_fn and has_any(M.allowed.weapon) and not M.allowed.weapon[w_fn])
                         or (a_fn and has_any(M.allowed.ability) and not M.allowed.ability[a_fn])
                         or (m_fn and has_any(M.allowed.melee) and not M.allowed.melee[m_fn])
                if bad then mark_enforce(rep_name) end
            end
        end)
    end

    -- Portal transition: enforce when starting a run
    RegisterHook("/Script/CrabChampions.CrabPC:ClientOnEnteredPortal", function(Context, ...)
        if M.run_active then return end
        local lobby_ok, lobby_actors = pcall(FindAllOf, "BP_Pickup_Lobby_C")
        if lobby_ok and lobby_actors and #lobby_actors > 0 then
            log("Portal from lobby — enforcing loadout")
            M.run_active = true
            do_enforce("RunStart")
        end
    end)

    -- Periodic enforcement loop
    LoopAsync(500, function()
        if pending_enforce then
            pending_enforce = false
            do_enforce("deferred")
        end
        return false  -- keep looping
    end)

    -- Sync to C++ if available
    if has_cpp() then
        sync_all_to_cpp()
        log("Installed with C++ enforcement")
    else
        log("Installed with Lua fallback enforcement")
    end
end

return M
