-- AP/SlotLock.lua
-- Progressive inventory slot management for Archipelago.
--
-- Controls how many inventory slots the player has for each type.
-- Slots beyond the allowed count are locked and cannot be purchased
-- with crystals — the game's purchase is reverted and crystals refunded.
--
-- USAGE:
--   local SlotLock = require("AP/SlotLock")
--   SlotLock.install()  -- must be called once to set up the hook
--
--   -- Set initial slot counts (call on slot_connected with slot_data)
--   SlotLock.set_slots("Perks", 6)        -- lock perks to 6 slots
--   SlotLock.set_slots("WeaponMods", 8)   -- lock weapon mods to 8
--   SlotLock.set_slots("AbilityMods", 4)  -- lock ability mods to 4
--   SlotLock.set_slots("MeleeMods", 4)    -- lock melee mods to 4
--
--   -- Grant additional slots (call when AP item received)
--   SlotLock.add_slots("Perks", 2)        -- unlock 2 more perk slots (6 -> 8)
--   SlotLock.add_slots("WeaponMods", 1)   -- unlock 1 more weapon mod slot
--
--   -- Query current state
--   SlotLock.get_slots("Perks")           -- returns current allowed count
--   SlotLock.is_active()                  -- returns true if slot locking is enabled
--
--   -- Disable slot locking (restore defaults)
--   SlotLock.disable()
--
-- SUPPORTED SLOT TYPES:
--   "Perks"       — default 24, maps to NumPerkSlots
--   "WeaponMods"  — default 24, maps to NumWeaponModSlots
--   "AbilityMods" — default 12, maps to NumAbilityModSlots
--   "MeleeMods"   — default 12, maps to NumMeleeModSlots
--
-- GAME DEFAULTS (max values):
--   Perks: 24, WeaponMods: 24, AbilityMods: 12, MeleeMods: 12
--
-- REQUIRES:
--   C++ mod functions: AP_SetSlotCount, AP_GetSlotCount, AP_RefreshInventoryUI

local GameThread = require("AP/GameThread")

local M = {}

local function log(msg) print("[CrabAP-SlotLock] " .. tostring(msg)) end

-- State
local active = false
local locked_counts = {}  -- type -> allowed count
local pre_purchase_crystals = nil

-- Defaults (game maximums)
local DEFAULTS = {
    Perks = 24,
    WeaponMods = 24,
    AbilityMods = 12,
    MeleeMods = 12,
    Relics = 10,
}

-- Types that use hard limits (no UE property) instead of AP_SetSlotCount
local HARD_LIMIT_TYPES = { Relics = true }

-- CrabPS property behind each slot type, read by the watchdog
local SLOT_PROPS = {
    Perks = "NumPerkSlots",
    WeaponMods = "NumWeaponModSlots",
    AbilityMods = "NumAbilityModSlots",
    MeleeMods = "NumMeleeModSlots",
}

-- How often the watchdog compares the game's slot counts to ours
local WATCHDOG_MS = 1000

-- Last mismatch logged per type, so a value that won't stick logs once
local last_logged = {}

-- ECrabPickupType enum -> slot type mapping
local PICKUP_TYPE_TO_SLOT = {
    [4] = "WeaponMods",
    [5] = "AbilityMods",
    [6] = "MeleeMods",
    [7] = "Perks",
}

--- Install the slot lock hook. Call once during mod initialization.
function M.install()
    RegisterHook("/Script/CrabChampions.CrabPS:ServerIncrementNumInventorySlots", function(Context, PickupType, Cost)
        if not active then return end

        local ptype = PickupType:get()
        local slot_type = PICKUP_TYPE_TO_SLOT[ptype]
        if not slot_type then return end

        local target = locked_counts[slot_type]
        if not target then return end

        -- Capture crystals before the game deducts the cost
        pcall(function()
            local ps = Context:get()
            if ps then
                pre_purchase_crystals = ps.Crystals or 0
            end
        end)

        -- After the function runs, revert slot count and refund crystals
        GameThread.loop(1, function()
            if AP_SetSlotCount and target then
                AP_SetSlotCount(slot_type, target)

                if pre_purchase_crystals then
                    pcall(function()
                        local pss = FindAllOf("CrabPS")
                        if pss and #pss > 0 then
                            local ia_ok, ItemApply = pcall(require, "AP/ItemApply")
                            if ia_ok and ItemApply and ItemApply.write_crystals then
                                ItemApply.write_crystals(pss[1], pre_purchase_crystals)
                            else
                                pss[1].Crystals = pre_purchase_crystals
                            end
                        end
                    end)
                    log("Blocked " .. slot_type .. " purchase — reverted to " .. target .. " slots, crystals refunded")
                    pre_purchase_crystals = nil
                end
            end
            pcall(AP_RefreshInventoryUI)
            return true
        end)
    end)

    -- Starting a run resets every slot count to the game's own default (8),
    -- which hides received slots past 8 and hands out unearned ones below it.
    -- No hook marks that moment reliably, so poll and correct any drift.
    GameThread.loop(WATCHDOG_MS, function()
        pcall(M.enforce)
        return false
    end)

    log("Slot lock hook installed")
end

local function get_ps()
    local all = FindAllOf("CrabPS")
    if not all then return nil end
    for _, p in ipairs(all) do
        if p and p:IsValid() then return p end
    end
    return nil
end

--- Put any slot count the game changed back to the AP-granted value.
--- @return number how many slot types were corrected
function M.enforce()
    if not active or not AP_SetSlotCount then return 0 end
    local ps = get_ps()
    if not ps then return 0 end

    local fixed = 0
    for slot_type, count in pairs(locked_counts) do
        local prop = SLOT_PROPS[slot_type]
        if prop then
            local ok, cur = pcall(function() return ps[prop] end)
            if ok and type(cur) == "number" and cur ~= count then
                AP_SetSlotCount(slot_type, count)
                fixed = fixed + 1
                if last_logged[slot_type] ~= cur then
                    last_logged[slot_type] = cur
                    log("Game set " .. slot_type .. " to " .. cur .. ", restored " .. count)
                end
            elseif ok and cur == count then
                last_logged[slot_type] = nil
            end
        end
    end
    if fixed > 0 then pcall(AP_RefreshInventoryUI) end
    return fixed
end

--- Set the allowed slot count for a type. Activates slot locking.
--- @param slot_type string "Perks"|"WeaponMods"|"AbilityMods"|"MeleeMods"
--- @param count number Allowed number of slots (clamped to 0..default max)
function M.set_slots(slot_type, count)
    local max = DEFAULTS[slot_type]
    if not max then
        log("Unknown slot type: " .. tostring(slot_type))
        return
    end

    count = math.max(0, math.min(count, max))
    locked_counts[slot_type] = count
    active = true

    -- Apply immediately via C++ mod
    GameThread.loop(1, function()
        if HARD_LIMIT_TYPES[slot_type] then
            if AP_SetHardLimit then
                AP_SetHardLimit(slot_type, count)
                log("Set " .. slot_type .. " = " .. count .. " (hard limit)")
            end
        elseif AP_SetSlotCount then
            AP_SetSlotCount(slot_type, count)
            log("Set " .. slot_type .. " = " .. count)
        end
        pcall(AP_RefreshInventoryUI)
        return true
    end)
end

--- Add slots to a type (e.g., when receiving an AP "Progressive Perk Slot" item).
--- @param slot_type string "Perks"|"WeaponMods"|"AbilityMods"|"MeleeMods"
--- @param amount number Number of slots to add
function M.add_slots(slot_type, amount)
    local max = DEFAULTS[slot_type]
    if not max then
        log("Unknown slot type: " .. tostring(slot_type))
        return
    end

    local current = locked_counts[slot_type] or max
    local new_count = math.min(current + amount, max)
    locked_counts[slot_type] = new_count

    GameThread.loop(1, function()
        if HARD_LIMIT_TYPES[slot_type] then
            if AP_SetHardLimit then
                AP_SetHardLimit(slot_type, new_count)
                log(slot_type .. " slots: " .. current .. " -> " .. new_count .. " (hard limit)")
            end
        elseif AP_SetSlotCount then
            AP_SetSlotCount(slot_type, new_count)
            log(slot_type .. " slots: " .. current .. " -> " .. new_count)
        end
        pcall(AP_RefreshInventoryUI)
        return true
    end)
end

--- Get the current allowed slot count for a type.
--- @param slot_type string
--- @return number
function M.get_slots(slot_type)
    return locked_counts[slot_type] or DEFAULTS[slot_type] or 0
end

--- Check if slot locking is active.
--- @return boolean
function M.is_active()
    return active
end

--- Re-apply all stored slot counts. Call on lobby return to restore locks
--- after the game resets slot counts to defaults.
--- Runs synchronously: the lobby re-adds run items right after this, and
--- they must see the locked counts, not the lobby's 24, or extras land in
--- slots the player hasn't received.
function M.reapply()
    if not active then return end

    for slot_type, count in pairs(locked_counts) do
        if HARD_LIMIT_TYPES[slot_type] then
            if AP_SetHardLimit then
                AP_SetHardLimit(slot_type, count)
                log("Re-applied " .. slot_type .. " = " .. count .. " (hard limit)")
            end
        elseif AP_SetSlotCount then
            AP_SetSlotCount(slot_type, count)
            log("Re-applied " .. slot_type .. " = " .. count)
        end
    end
    pcall(AP_RefreshInventoryUI)
end

--- Disable slot locking and restore all slots to defaults.
function M.disable()
    active = false

    GameThread.loop(1, function()
        for slot_type, max in pairs(DEFAULTS) do
            if HARD_LIMIT_TYPES[slot_type] then
                if AP_SetHardLimit then AP_SetHardLimit(slot_type, max) end
            elseif AP_SetSlotCount then
                AP_SetSlotCount(slot_type, max)
            end
        end
        log("Slot locking disabled — all slots restored to defaults")
        pcall(AP_RefreshInventoryUI)
        return true
    end)

    locked_counts = {}
end

return M
