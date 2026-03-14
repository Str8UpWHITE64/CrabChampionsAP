local M = {}

local function log(msg) print("[CrabAP-EquipLock] " .. tostring(msg)) end

-- Allowed sets (full_name strings)
M.allowed = { weapon = {}, ability = {}, melee = {} }

-- Defaults (full_name strings)
M.defaults = { weapon_full = nil, ability_full = nil, melee_full = nil }

-- DA maps: full_name -> DA
local weapon_by_full, ability_by_full, melee_by_full = nil, nil, nil
local weapon_full_by_name, ability_full_by_name, melee_full_by_name = nil, nil, nil

-- deferred enforcement state
local pending_enforce = false
local pending_reason = nil
local reentry = false

-- Run state: only enforce loadout at the start of a run, not mid-run
M.run_active = false

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

local function allow_from_names(target_set, names, name_map)
  for _, nm in ipairs(names or {}) do
    local fn = name_map[nm]
    if fn then target_set[fn] = true else log("WARN: couldn't resolve name: " .. tostring(nm)) end
  end
end

function M.set_allowed(opts)
  if not weapon_by_full then M.refresh_maps() end

  if opts.weapons then
    M.allowed.weapon = {}
    for _, fn in ipairs(opts.weapons.fullnames or {}) do M.allowed.weapon[fn] = true end
    allow_from_names(M.allowed.weapon, opts.weapons.names, weapon_full_by_name)
  end
  if opts.abilities then
    M.allowed.ability = {}
    for _, fn in ipairs(opts.abilities.fullnames or {}) do M.allowed.ability[fn] = true end
    allow_from_names(M.allowed.ability, opts.abilities.names, ability_full_by_name)
  end
  if opts.melee then
    M.allowed.melee = {}
    for _, fn in ipairs(opts.melee.fullnames or {}) do M.allowed.melee[fn] = true end
    allow_from_names(M.allowed.melee, opts.melee.names, melee_full_by_name)
  end
end

local function pick_fallback(kind)
  if kind == "weapon" then
    if M.defaults.weapon_full and M.allowed.weapon[M.defaults.weapon_full] and weapon_by_full[M.defaults.weapon_full] then
      return weapon_by_full[M.defaults.weapon_full], M.defaults.weapon_full
    end
    for fn,_ in pairs(M.allowed.weapon) do if weapon_by_full[fn] then return weapon_by_full[fn], fn end end
  elseif kind == "ability" then
    if M.defaults.ability_full and M.allowed.ability[M.defaults.ability_full] and ability_by_full[M.defaults.ability_full] then
      return ability_by_full[M.defaults.ability_full], M.defaults.ability_full
    end
    for fn,_ in pairs(M.allowed.ability) do if ability_by_full[fn] then return ability_by_full[fn], fn end end
  else
    if M.defaults.melee_full and M.allowed.melee[M.defaults.melee_full] and melee_by_full[M.defaults.melee_full] then
      return melee_by_full[M.defaults.melee_full], M.defaults.melee_full
    end
    for fn,_ in pairs(M.allowed.melee) do if melee_by_full[fn] then return melee_by_full[fn], fn end end
  end
  return nil, nil
end

local function mark_enforce(reason)
  pending_enforce = true
  pending_reason = reason
end

--- Public: request enforcement on next tick (e.g. after populating allowed sets).
function M.request_enforce(reason)
  mark_enforce(reason)
end

--- Public: signal that the player has returned to the lobby (run ended).
--- Resets run_active so the next portal will enforce loadout again.
function M.on_lobby_entered()
  if M.run_active then
    log("Lobby entered — run ended, enforcement re-armed for next run")
    M.run_active = false
  end
end

local function current_disallowed(ps)
  local w = ps.WeaponDA
  local a = ps.AbilityDA
  local m = ps.MeleeDA

  local w_fn = get_full_name(w)
  local a_fn = get_full_name(a)
  local m_fn = get_full_name(m)

  local needW = w_fn and has_any(M.allowed.weapon)  and (not M.allowed.weapon[w_fn])
  local needA = a_fn and has_any(M.allowed.ability) and (not M.allowed.ability[a_fn])
  local needM = m_fn and has_any(M.allowed.melee)   and (not M.allowed.melee[m_fn])

  return needW, needA, needM, w_fn, a_fn, m_fn
end

local function enforce_now()
  if reentry then return end
  if not pending_enforce then return end

  local pss = FindAllOf("CrabPS")
  if not pss then return end

  for _, ps in ipairs(pss) do
    if ps and ps:IsValid() then
      local needW, needA, needM, w_fn, a_fn, m_fn = current_disallowed(ps)
      if needW or needA or needM then
        local replW = needW and (select(1, pick_fallback("weapon")))  or ps.WeaponDA
        local replA = needA and (select(1, pick_fallback("ability"))) or ps.AbilityDA
        local replM = needM and (select(1, pick_fallback("melee")))   or ps.MeleeDA

        if replW and replA and replM then
          reentry = true
          pcall(function()
            ps:ServerEquipInventory(replW, replA, replM)
          end)
          reentry = false

          log("ENFORCED (deferred): " .. tostring(pending_reason))
          pending_enforce = false
          pending_reason = nil
          return
        end
      else
        -- Already fine
        pending_enforce = false
        pending_reason = nil
        return
      end
    end
  end
end

local function force_enforce(reason)
  if reentry then return end

  -- If nothing is configured, do nothing (prevents soft-lock during dev)
  if (not has_any(M.allowed.weapon)) and (not has_any(M.allowed.ability)) and (not has_any(M.allowed.melee)) then
    return
  end

  local pss = FindAllOf("CrabPS")
  if not pss then return end

  for _, ps in ipairs(pss) do
    if ps and ps:IsValid() then
      local needW, needA, needM, w_fn, a_fn, m_fn = current_disallowed(ps)

      -- If the current ones are already allowed, we still might want to “reassert” on portal transitions,
      -- but keeping the check reduces unnecessary RPC spam.
      if needW or needA or needM then
        local replW = needW and (select(1, pick_fallback("weapon")))  or ps.WeaponDA
        local replA = needA and (select(1, pick_fallback("ability"))) or ps.AbilityDA
        local replM = needM and (select(1, pick_fallback("melee")))   or ps.MeleeDA

        if replW and replA and replM then
          reentry = true
          pcall(function()
            ps:ServerEquipInventory(replW, replA, replM)
          end)
          reentry = false

          log("FORCED enforce: " .. tostring(reason))
        end
      end
    end
  end
end

------------------------------------------------------------
-- Install hooks
------------------------------------------------------------
function M.install()
  if not weapon_by_full then M.refresh_maps() end

  -- If any of these fire, we mark enforcement; the tick will do the actual fix.
  RegisterHook("/Script/CrabChampions.CrabPS:ServerSetWeaponDA", function(Context, NewWeaponDA)
    local req = NewWeaponDA and NewWeaponDA.get and NewWeaponDA:get() or nil
    local req_fn = get_full_name(req)
    if req_fn and has_any(M.allowed.weapon) and (not M.allowed.weapon[req_fn]) then
      log("Blocked weapon (will enforce next tick): " .. tostring(req_fn))
      mark_enforce("ServerSetWeaponDA")
    end
  end)

  RegisterHook("/Script/CrabChampions.CrabPS:ServerSetAbilityDA", function(Context, NewAbilityDA)
    local req = NewAbilityDA and NewAbilityDA.get and NewAbilityDA:get() or nil
    local req_fn = get_full_name(req)
    if req_fn and has_any(M.allowed.ability) and (not M.allowed.ability[req_fn]) then
      log("Blocked ability (will enforce next tick): " .. tostring(req_fn))
      mark_enforce("ServerSetAbilityDA")
    end
  end)

  RegisterHook("/Script/CrabChampions.CrabPS:ServerSetMeleeDA", function(Context, NewMeleeDA)
    local req = NewMeleeDA and NewMeleeDA.get and NewMeleeDA:get() or nil
    local req_fn = get_full_name(req)
    if req_fn and has_any(M.allowed.melee) and (not M.allowed.melee[req_fn]) then
      log("Blocked melee (will enforce next tick): " .. tostring(req_fn))
      mark_enforce("ServerSetMeleeDA")
    end
  end)

  -- OnRep hooks (treat first arg as Context and grab ps via :get() when available)
  local function get_ps_from_hook_arg(arg1)
    if arg1 == nil then return nil end
    if type(arg1) == "userdata" and arg1.get then
      local ok, v = pcall(function() return arg1:get() end)
      if ok then return v end
    end
    -- fallback: sometimes UE4SS passes self directly
    return arg1
  end

  RegisterHook("/Script/CrabChampions.CrabPS:OnRep_WeaponDA", function(arg1)
    local ps = get_ps_from_hook_arg(arg1)
    if ps and ps.IsValid and ps:IsValid() then
      local needW, needA, needM = current_disallowed(ps)
      if needW or needA or needM then
        log("OnRep detected disallowed loadout; will enforce next tick.")
        mark_enforce("OnRep_WeaponDA")
      end
    end
  end)

  RegisterHook("/Script/CrabChampions.CrabPS:OnRep_MeleeDA", function(arg1)
    local ps = get_ps_from_hook_arg(arg1)
    if ps and ps.IsValid and ps:IsValid() then
      local needW, needA, needM = current_disallowed(ps)
      if needW or needA or needM then
        log("OnRep detected disallowed loadout; will enforce next tick.")
        mark_enforce("OnRep_MeleeDA")
      end
    end
  end)

  RegisterHook("/Script/CrabChampions.CrabPS:OnRep_AbilityDA", function(arg1)
    local ps = get_ps_from_hook_arg(arg1)
    if ps and ps.IsValid and ps:IsValid() then
      local needW, needA, needM = current_disallowed(ps)
      if needW or needA or needM then
        log("OnRep detected disallowed loadout; will enforce next tick.")
        mark_enforce("OnRep_AbilityDA")
      end
    end
  end)

  -- Portal transition: only enforce when STARTING a run (leaving lobby).
  -- Mid-run portals should NOT change the player's loadout.
  RegisterHook("/Script/CrabChampions.CrabPC:ClientOnEnteredPortal", function(Context, ...)
    if M.run_active then
      log("ClientOnEnteredPortal mid-run — skipping enforcement")
      return
    end
    -- Check if we're in the lobby (BP_Pickup_Lobby_C actors present)
    local lobby_ok, lobby_actors = pcall(FindAllOf, "BP_Pickup_Lobby_C")
    if lobby_ok and lobby_actors and #lobby_actors > 0 then
      log("ClientOnEnteredPortal from lobby — enforcing loadout for run start")
      M.run_active = true
      force_enforce("RunStart")
    else
      log("ClientOnEnteredPortal (unknown context) — skipping enforcement")
    end
  end)

  -- Island clear: do NOT enforce mid-run. The player's loadout should stay stable.
  -- RegisterHook for ClientOnClearedIsland removed — no mid-run enforcement.



  -- Periodic enforcement loop: process deferred enforce flags.
  -- Only enforces if something disallowed is actively equipped (e.g., player
  -- picked up a weapon from a crate that isn't in their allowed set).
  -- This does NOT force-swap to newly unlocked items mid-run.
  LoopAsync(500, function()
    if pending_enforce then
      enforce_now()
    end
    return false -- keep looping
  end)

  log("Installed: Set* hooks + OnRep_* + periodic enforcement loop.")
end


return M
