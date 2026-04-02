local M = {}

local function log(msg) print("[CrabAP-Sanitize] " .. tostring(msg)) end

-- Allowed by full_name (AP-authoritative)
M.allowed_weapon_mod_full = {}
M.allowed_perk_full = {}
M.allowed_ability_mod_full = {}
M.allowed_relic_full = {}
M.allowed_melee_mod_full = {}

-- When true, sanitization is active even if allowed sets are empty.
-- Empty allowed set + active = strip ALL items of that kind.
-- This prevents the game from giving perks/mods/relics before AP sends them.
M.active = false

-- Fallback defaults by full_name (must exist)
M.default_weapon_mod_full = nil
M.default_perk_full = nil
M.default_ability_mod_full = nil
M.default_relic_full = nil
M.default_melee_mod_full = nil

-- ------------------------------------------------------------------
-- Common helpers
-- ------------------------------------------------------------------

local function safe_pcall(fn, fallback)
  local ok, v = pcall(fn)
  if ok then return v end
  return fallback
end

local function is_valid(obj)
  if not obj then return false end
  if obj.IsValid then
    return safe_pcall(function() return obj:IsValid() end, false)
  end
  return true
end

local function safe_str(x)
  if x == nil then return "nil" end
  local t = type(x)
  if t == "string" or t == "number" or t == "boolean" then return tostring(x) end
  if t == "userdata" then
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

local function has_any(set)
  for _ in pairs(set) do return true end
  return false
end

local function try_get(obj, prop)
  if not obj then return nil end
  return safe_pcall(function() return obj:GetPropertyValue(prop) end, nil)
end

local function try_field(obj, field)
  return safe_pcall(function() return obj[field] end, nil)
end

local function get_entry_obj(entry)
  -- UE4SS containers often return a proxy with entry:get()
  if entry and entry.get then
    local e = safe_pcall(function() return entry:get() end, nil)
    if e ~= nil then return e end
  end
  return entry
end

local function count_list(list_obj, max_items)
  max_items = max_items or 9999
  if not list_obj then return 0 end
  if list_obj.IsValid and (not list_obj:IsValid()) then return 0 end

  local n = safe_pcall(function()
    if list_obj.Num then return list_obj:Num() end
    if list_obj.Length then return list_obj:Length() end
    if list_obj.Count then return list_obj:Count() end
    return nil
  end, nil)
  if n ~= nil then return n end

  local c = 0
  if list_obj.ForEach then
    safe_pcall(function()
      list_obj:ForEach(function()
        c = c + 1
        if c >= max_items then return end
      end)
    end, nil)
  end
  return c
end


-- ------------------------------------------------------------
-- ServerRemove helpers (removes ghost slots cleanly)
-- ------------------------------------------------------------

local REMOVE_RPC = {
  weapon_mod  = "ServerRemoveWeaponMod",
  perk        = "ServerRemovePerk",
  ability_mod = "ServerRemoveAbilityMod",
  relic       = "ServerRemoveRelic",
  melee_mod   = "ServerRemoveMeleeMod",
}

-- Guess enum name token from a DA full path:
-- "DA_Perk_Driller" -> "Driller"
-- "DA_WeaponMod_PoisonStorm" -> "PoisonStorm"
local function guess_type_token_from_fullname(full_name)
  if not full_name then return nil end
  -- grab leaf object name after last dot
  local leaf = full_name:match("%.(%w+)$") or full_name
  -- strip leading "DA_"
  leaf = leaf:gsub("^DA_", "")
  -- drop category prefix like "Perk_", "WeaponMod_", etc.
  leaf = leaf:gsub("^[A-Za-z]+_", "")
  return leaf
end

-- Try to fetch a type-like field from an object/struct (entry or DA)
local function probe_type_field(obj, fields)
  if not obj then return nil end
  for _, f in ipairs(fields) do
    local v = try_field(obj, f)
    if v ~= nil then return v, f end
  end
  return nil
end

-- Best-effort resolution of "Type" param to pass into ServerRemoveXxx
local function resolve_remove_param(kind, entry_obj, da_obj, full_name)
  -- Try obvious fields on entry or DA
  local field_sets = {
    perk        = { "PerkType", "Type" },
    weapon_mod  = { "WeaponModType", "ModType", "Type" },
    ability_mod = { "AbilityModType", "ModType", "Type" },
    relic       = { "RelicType", "Type" },
    melee_mod   = { "MeleeModType", "ModType", "Type" },
  }


  local fields = field_sets[kind] or { "Type", "ID", "Name" }

  local v, f = probe_type_field(entry_obj, fields)
  if v ~= nil then return v, ("entry." .. tostring(f)) end

  v, f = probe_type_field(da_obj, fields)
  if v ~= nil then return v, ("da." .. tostring(f)) end

  -- Fall back: guess a token from DA name
  local token = guess_type_token_from_fullname(full_name)
  if token then
    return token, "guessed-token"
  end

  return nil, "none"
end

-- Optional: convert string token -> enum value (if you know enum paths).
-- If you don't know them yet, this will just return nil and we'll pass token.
local ENUM_PATH = {
  perk        = "Enum /Script/CrabChampions.EPerkType",
  weapon_mod  = "Enum /Script/CrabChampions.EWeaponModType",
  ability_mod = "Enum /Script/CrabChampions.EAbilityModType",
  relic       = "Enum /Script/CrabChampions.ERelicType",
  melee_mod   = "Enum /Script/CrabChampions.EMeleeModType",
}

local function try_resolve_enum(kind, token)
  if not token or type(token) ~= "string" then return nil end
  local path = ENUM_PATH[kind]
  if not path then return nil end

  local enum = safe_pcall(function() return FindObject(path) end, nil)
  if not enum then return nil end

  -- Different UE4SS builds expose different UEnum helpers.
  local val = safe_pcall(function()
    if enum.GetValueByNameString then
      return enum:GetValueByNameString(token)
    end
    if enum.GetValueByName then
      return enum:GetValueByName(token)
    end
    return nil
  end, nil)

  return val
end

local function call_server_remove(ps, kind, param)
  local rpc = REMOVE_RPC[kind]
  if not rpc then return false, "no-rpc" end
  if not ps or not ps[rpc] then return false, "rpc-missing" end

  local ok, err = pcall(function()
    ps[rpc](ps, param)
  end)
  if ok then return true end
  return false, tostring(err)
end

-- Remove a "ghost" entry using game RPC.
-- We pass enum value if we can, otherwise string/whatever we have.
local function remove_entry_via_rpc(ps, kind, entry_obj, da_obj)
  local fn = get_full_name(da_obj)
  local param, how = resolve_remove_param(kind, entry_obj, da_obj, fn)

  if param == nil then
    log(("RPC remove: kind=%s fn=%s failed to resolve param"):format(kind, tostring(fn)))
    return false
  end

  local enum_val = nil
  if type(param) == "string" then
    enum_val = try_resolve_enum(kind, param)
  end

  local to_send = enum_val or param
  local ok, err = call_server_remove(ps, kind, to_send)

  if ok then
    log(("RPC removed %s via %s (param=%s source=%s)"):format(
      tostring(fn), REMOVE_RPC[kind], safe_str(to_send), how
    ))
    return true
  else
    log(("RPC remove FAILED %s via %s (param=%s source=%s) err=%s"):format(
      tostring(fn), REMOVE_RPC[kind], safe_str(to_send), how, tostring(err)
    ))
    return false
  end
end

-- ------------------------------------------------------------
-- Merge helpers: when replacing a disallowed slot with fallback,
-- merge its Level into an existing fallback slot instead of duplicating.
-- ------------------------------------------------------------

local function get_level_from_entry(e)
  local info = try_field(e, "InventoryInfo")
  if not info then return 1 end
  local lvl = try_field(info, "Level")
  local n = tonumber(lvl)
  return n or 1
end

local function set_level_on_entry(e, new_level)
  local info = try_field(e, "InventoryInfo")
  if not info then return false end
  info.Level = new_level
  return true
end

local function try_remove_at(tarray, idx)
  -- UE4SS exposure varies. We try common remove methods.
  if not tarray then return false end

  if tarray.RemoveAt then
    local ok = pcall(function() tarray:RemoveAt(idx) end)
    return ok
  end
  if tarray.RemoveAtSwap then
    local ok = pcall(function() tarray:RemoveAtSwap(idx) end)
    return ok
  end
  return false
end

-- kind: "perk" | "weapon_mod" | "ability_mod" | "relic" | "melee_mod"
local function sanitize_and_merge(ps, kind, list_prop, da_field, allowed_set, fallback_obj, fallback_fn)
  if not has_any(allowed_set) then return end

  local list = ps:GetPropertyValue(list_prop)
  if not list or (list.IsValid and not list:IsValid()) then return end
  if not fallback_obj then return end

  -- Pass 1: find existing fallback slot and collect disallowed slots
  local fallback_entry = nil
  local to_fix = {} -- { idx, entry, cur_fn, cur_da, cur_level }

  list:ForEach(function(i, entry)
    local e = get_entry_obj(entry)
    if not is_valid(e) then return end

    local cur_da = e[da_field]
    local cur_fn = get_full_name(cur_da)

    if cur_fn == fallback_fn then
      if not fallback_entry then fallback_entry = e end
      return
    end

    if cur_fn and (not allowed_set[cur_fn]) then
      to_fix[#to_fix+1] = {
        idx = i,
        entry = e,
        cur_fn = cur_fn,
        cur_da = cur_da,                 -- keep original DA for ServerRemove*
        cur_level = get_level_from_entry(e),
      }
    end
  end)

  if #to_fix == 0 then return end

  -- Pass 2: apply fixes in reverse order
  for n = #to_fix, 1, -1 do
    local fix = to_fix[n]
    local i = fix.idx
    local e = fix.entry

    if not is_valid(e) then goto continue end

    if fallback_entry and is_valid(fallback_entry) and (fallback_entry ~= e) then
      -- Merge stacks into fallback slot
      local add = tonumber(fix.cur_level) or 1
      local old = get_level_from_entry(fallback_entry)
      local new = old + add
      set_level_on_entry(fallback_entry, new)

      log(("Merged %s %s (Level=%d) into %s: %d -> %d, removing slot %d")
        :format(tostring(list_prop), tostring(fix.cur_fn), add, tostring(fallback_fn), old, new, i))

      -- Try RemoveAt first
      local removed = try_remove_at(list, i)
      if removed then
        log(("RemoveAt succeeded for %s slot %d"):format(list_prop, i))
      else
        local ok = false
        if fix.cur_da ~= nil then
          ok = remove_entry_via_rpc(ps, kind, e, fix.cur_da)
        else
          log(("RPC remove skipped for %s slot %d: missing original DA"):format(list_prop, i))
        end

        if not ok then
          log(("ServerRemove* failed for %s slot %d (fn=%s)"):format(list_prop, i, tostring(fix.cur_fn)))
        end
      end
      if is_valid(e) then
        e[da_field] = fallback_obj
      end
    else
      -- No existing fallback slot: replace in-place
      e[da_field] = fallback_obj
      log(("Replaced %s slot %d: %s -> %s"):format(list_prop, i, tostring(fix.cur_fn), tostring(fallback_fn)))
    end

    ::continue::
  end
end



-- ------------------------------------------------------------------
-- Data maps (full_name -> DA object)
-- ------------------------------------------------------------------

local weaponMod_by_full = nil
local perk_by_full = nil
local abilityMod_by_full = nil
local relic_by_full = nil
local meleeMod_by_full = nil

local function refresh_maps()
  weaponMod_by_full = {}
  perk_by_full = {}
  abilityMod_by_full = {}
  relic_by_full = {}
  meleeMod_by_full = {}

  local w = FindAllOf("CrabWeaponModDA")
  if w then
    for _, da in ipairs(w) do
      if is_valid(da) then
        local fn = get_full_name(da)
        if fn then weaponMod_by_full[fn] = da end
      end
    end
  end

  local p = FindAllOf("CrabPerkDA")
  if p then
    for _, da in ipairs(p) do
      if is_valid(da) then
        local fn = get_full_name(da)
        if fn then perk_by_full[fn] = da end
      end
    end
  end

  local a = FindAllOf("CrabAbilityModDA")
  if a then
    for _, da in ipairs(a) do
      if is_valid(da) then
        local fn = get_full_name(da)
        if fn then abilityMod_by_full[fn] = da end
      end
    end
  end

  local r = FindAllOf("CrabRelicDA")
  if r then
    for _, da in ipairs(r) do
      if is_valid(da) then
        local fn = get_full_name(da)
        if fn then relic_by_full[fn] = da end
      end
    end
  end

  local m = FindAllOf("CrabMeleeModDA")
  if m then
    for _, da in ipairs(m) do
      if is_valid(da) then
        local fn = get_full_name(da)
        if fn then meleeMod_by_full[fn] = da end
      end
    end
  end

  log("Maps refreshed.")
end

local function pick_fallback(kind)
  if kind == "weapon_mod" then
    if M.default_weapon_mod_full and M.allowed_weapon_mod_full[M.default_weapon_mod_full] and weaponMod_by_full[M.default_weapon_mod_full] then
      return weaponMod_by_full[M.default_weapon_mod_full], M.default_weapon_mod_full
    end
    for fn,_ in pairs(M.allowed_weapon_mod_full) do
      if weaponMod_by_full[fn] then return weaponMod_by_full[fn], fn end
    end

  elseif kind == "perk" then
    if M.default_perk_full and M.allowed_perk_full[M.default_perk_full] and perk_by_full[M.default_perk_full] then
      return perk_by_full[M.default_perk_full], M.default_perk_full
    end
    for fn,_ in pairs(M.allowed_perk_full) do
      if perk_by_full[fn] then return perk_by_full[fn], fn end
    end

  elseif kind == "ability_mod" then
    if M.default_ability_mod_full and M.allowed_ability_mod_full[M.default_ability_mod_full] and abilityMod_by_full[M.default_ability_mod_full] then
      return abilityMod_by_full[M.default_ability_mod_full], M.default_ability_mod_full
    end
    for fn,_ in pairs(M.allowed_ability_mod_full) do
      if abilityMod_by_full[fn] then return abilityMod_by_full[fn], fn end
    end

  elseif kind == "relic" then
    if M.default_relic_full and M.allowed_relic_full[M.default_relic_full] and relic_by_full[M.default_relic_full] then
      return relic_by_full[M.default_relic_full], M.default_relic_full
    end
    for fn,_ in pairs(M.allowed_relic_full) do
      if relic_by_full[fn] then return relic_by_full[fn], fn end
    end

  else -- melee_mod
    if M.default_melee_mod_full and M.allowed_melee_mod_full[M.default_melee_mod_full] and meleeMod_by_full[M.default_melee_mod_full] then
      return meleeMod_by_full[M.default_melee_mod_full], M.default_melee_mod_full
    end
    for fn,_ in pairs(M.allowed_melee_mod_full) do
      if meleeMod_by_full[fn] then return meleeMod_by_full[fn], fn end
    end
  end

  return nil, nil
end

-- ------------------------------------------------------------------
-- Inventory Snapshot (NEW)
-- ------------------------------------------------------------------

local function read_inventory_info(e)
  local info = try_field(e, "InventoryInfo")
  if info == nil then return nil end

  local level = try_field(info, "Level")
  local accumulated = try_field(info, "AccumulatedBuff")
  local enhancements = try_field(info, "Enhancements")
  local enh_count = (enhancements ~= nil) and count_list(enhancements, 2048) or nil

  return {
    level = level,
    accumulated = accumulated,
    enhancements = enh_count,
  }
end

local function build_bucket(ps, prop_name, da_field)
  local bucket = {} -- keyed by full_name
  local list_obj = try_get(ps, prop_name)
  if not list_obj then return bucket end
  if list_obj.IsValid and (not list_obj:IsValid()) then return bucket end

  if list_obj.ForEach then
    safe_pcall(function()
      list_obj:ForEach(function(_, entry)
        local e = get_entry_obj(entry)
        if not is_valid(e) then return end

        local da = try_field(e, da_field)
        if not is_valid(da) then return end

        local fn = get_full_name(da)
        if not fn then return end

        local info = read_inventory_info(e) or { level = 1, enhancements = nil, accumulated = nil }

        -- Most CC inventory uses single entry with InventoryInfo.Level as stack/count.
        bucket[fn] = {
          level = tonumber(info.level) or info.level,
          enhancements = info.enhancements,
          accumulated = info.accumulated,
          da = da,
        }
      end)
    end, nil)
  end

  return bucket
end

-- Public: Build a normalized snapshot for one CrabPS
function M.build_inventory_snapshot(ps)
  if not is_valid(ps) then return nil end
  return {
    weapon_mods  = build_bucket(ps, "WeaponMods",  "WeaponModDA"),
    perks        = build_bucket(ps, "Perks",       "PerkDA"),
    ability_mods = build_bucket(ps, "AbilityMods", "AbilityModDA"),
    relics       = build_bucket(ps, "Relics",      "RelicDA"),
    melee_mods   = build_bucket(ps, "MeleeMods",   "MeleeModDA"),
  }
end

function M.get_count(inv, kind, full_name)
  if not inv or not inv[kind] or not full_name then return 0 end
  local e = inv[kind][full_name]
  if not e then return 0 end
  local lvl = e.level
  if type(lvl) == "number" then return lvl end
  return tonumber(lvl) or 0
end

function M.get_flat_list(inv, kind)
  local out = {}
  if not inv or not inv[kind] then return out end
  for fn, e in pairs(inv[kind]) do
    out[#out+1] = {
      full_name = fn,
      level = e.level,
      enhancements = e.enhancements,
      accumulated = e.accumulated
    }
  end
  table.sort(out, function(a,b) return tostring(a.full_name) < tostring(b.full_name) end)
  return out
end

function M.dump_inventory(inv)
  if not inv then log("(nil inventory snapshot)") return end
  local kinds = { "weapon_mods", "perks", "ability_mods", "relics", "melee_mods" }
  for _, k in ipairs(kinds) do
    log(k .. ":")
    local flat = M.get_flat_list(inv, k)
    if #flat == 0 then
      log("  (empty)")
    else
      for _, it in ipairs(flat) do
        log(("  %s | Level=%s | Enh=%s | Acc=%s"):format(
          tostring(it.full_name),
          safe_str(it.level),
          safe_str(it.enhancements),
          safe_str(it.accumulated)
        ))
      end
    end
  end
end

-- ------------------------------------------------------------------
-- Sanitizers
-- ------------------------------------------------------------------

--- Strip entries of a kind via ServerRemove RPC.
--- If allowed_set is provided, only strips entries NOT in the allowed set.
--- If allowed_set is nil, strips ALL entries.
local function strip_entries_via_rpc(ps, kind, list_prop, da_field, allowed_set)
  local list = safe_pcall(function() return ps:GetPropertyValue(list_prop) end, nil)
  if not list or (list.IsValid and not list:IsValid()) then return end

  local to_remove = {}
  if list.ForEach then
    safe_pcall(function()
      list:ForEach(function(i, entry)
        local e = get_entry_obj(entry)
        if not is_valid(e) then return end
        local da = try_field(e, da_field)
        if is_valid(da) then
          local fn = get_full_name(da)
          -- Strip if no allowed set (strip all) or if not in allowed set
          if not allowed_set or (fn and not allowed_set[fn]) then
            to_remove[#to_remove + 1] = { entry = e, da = da, fn = fn }
          end
        end
      end)
    end, nil)
  end

  for _, item in ipairs(to_remove) do
    remove_entry_via_rpc(ps, kind, item.entry, item.da)
    log("Stripped " .. kind .. ": " .. tostring(item.fn))
  end
end

local function sanitize_kind(ps, kind, list_prop, da_field, allowed_set, fallback_kind)
  if not M.active then
    -- Legacy mode: only sanitize if allowed set is populated
    if not has_any(allowed_set) then return end
  end

  -- Active mode: always use RPC removal (strip disallowed, don't replace).
  -- Pass nil to strip all when nothing is allowed, or allowed_set to strip only disallowed.
  if M.active then
    local effective_set = has_any(allowed_set) and allowed_set or nil
    strip_entries_via_rpc(ps, kind, list_prop, da_field, effective_set)
    return
  end

  -- Legacy fallback path (M.active == false): use merge behavior
  local fallback, fallback_fn = pick_fallback(fallback_kind)
  if not fallback then
    strip_entries_via_rpc(ps, kind, list_prop, da_field, allowed_set)
    return
  end
  sanitize_and_merge(ps, kind, list_prop, da_field, allowed_set, fallback, fallback_fn)
end

function M.sanitize_all_players()
  if not M.active then return end

  if not weaponMod_by_full or not perk_by_full or not abilityMod_by_full then
    refresh_maps()
  end

  local pss = FindAllOf("CrabPS")
  if not pss then return end

  for _, ps in ipairs(pss) do
    if is_valid(ps) then
      sanitize_kind(ps, "weapon_mod",  "WeaponMods",  "WeaponModDA",  M.allowed_weapon_mod_full,  "weapon_mod")
      sanitize_kind(ps, "perk",        "Perks",       "PerkDA",       M.allowed_perk_full,        "perk")
      sanitize_kind(ps, "ability_mod", "AbilityMods", "AbilityModDA", M.allowed_ability_mod_full, "ability_mod")
      sanitize_kind(ps, "relic",       "Relics",      "RelicDA",      M.allowed_relic_full,       "relic")
      sanitize_kind(ps, "melee_mod",   "MeleeMods",   "MeleeModDA",   M.allowed_melee_mod_full,   "melee_mod")
    end
  end
end

return M
