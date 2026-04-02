-- AP/EquipLock.lua
-- Equipment locking for Archipelago.
-- Restricts which weapons, abilities, and melee weapons the player can equip.
-- Uses C++ mod (AP_EquipLock_*) for enforcement when available,
-- falls back to Lua-based ServerEquipInventory calls otherwise.

local M = {}

local function log(msg) print("[CrabAP-EquipLock] " .. tostring(msg)) end

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

--- Enforce equipment restrictions now.
--- Uses C++ ProcessEvent when available, falls back to Lua RPC.
local function do_enforce(reason)
    if reentry then return end

    -- Nothing configured = nothing to enforce
    if not has_any(M.allowed.weapon) and not has_any(M.allowed.ability) and not has_any(M.allowed.melee) then
        return
    end

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
