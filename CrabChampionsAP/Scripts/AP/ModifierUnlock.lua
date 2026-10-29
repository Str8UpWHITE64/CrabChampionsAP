-- Unlocks the difficulty modifier buttons while the mod is connected, without touching the account rank or level.
--
-- The menu draws a Locked overlay (and disables the button) on each modifier the account rank does not allow. While
-- the unlock is on, every live modifier button (CrabDifficultyModifierUI) that still shows that overlay gets the
-- overlay collapsed and the button enabled. Only widgets are changed: CrabPS.AccountRank and AccountLevel are never
-- written, so nothing rank related reaches the game's saves or the achievement checks.
--
-- In the current game build every modifier button is already unlocked at any account rank (none shows a
-- Locked overlay), so the sweep finds nothing to change. It stays so that a build which locks buttons again is
-- handled without a client change.

local M = {}

local COLLAPSED = 1      -- ESlateVisibility::Collapsed
local VISIBLE = 0        -- ESlateVisibility::Visible

local active = false
local fixed_total = 0
local last_error = nil

local function alive(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

local function num(v)
    if type(v) == "number" then return v end
    local ok, n = pcall(function() return tonumber(v) end)
    return ok and n or nil
end

-- A live button belongs to an open menu. The templates inside the Blueprint packages live under /Game/ and are
-- left alone.
local function is_live(w)
    local ok, name = pcall(function() return w:GetFullName() end)
    if not ok or type(name) ~= "string" then return false end
    if name:find("Default__", 1, true) then return false end
    return name:find("/Engine/Transient", 1, true) ~= nil
end

--- Unlock every live modifier button once. Returns how many were changed.
function M.sweep()
    local ok, all = pcall(FindAllOf, "CrabDifficultyModifierUI")
    if not ok or type(all) ~= "table" then return 0 end
    local changed = 0
    for _, w in ipairs(all) do
        if alive(w) and is_live(w) then
            local fixed = false
            local okw, err = pcall(function()
                local ov = w.LockedDifficultyModifierOverlay
                if alive(ov) and num(ov.Visibility) == VISIBLE then
                    ov:SetVisibility(COLLAPSED)
                    fixed = true
                end
                local btn = w.DifficultyModifierButton
                if alive(btn) and btn.bIsEnabled == false then
                    btn:SetIsEnabled(true)
                    fixed = true
                end
            end)
            if not okw then last_error = tostring(err) end
            if fixed then changed = changed + 1 end
        end
    end
    fixed_total = fixed_total + changed
    return changed
end

-- True only while the difficulty menu is the focused menu. Replaceable for tests.
function M.menu_open()
    local ok, res = pcall(function()
        local pcs = FindAllOf("CrabPC")
        local pc = pcs and pcs[1]
        if not alive(pc) then return false end
        local menu = pc.ActiveFocusMenuUI
        if not alive(menu) then return false end
        local name = menu:GetFullName()
        return type(name) == "string" and name:find("DifficultyMenu", 1, true) ~= nil
    end)
    return ok and res == true
end

local pause_until = 0

--- Stop sweeping for a few seconds (portal entry / level change, when widgets are being torn down).
function M.pause(seconds)
    pause_until = os.clock() + (seconds or 8)
end

--- Poll step: sweeps only while the unlock is on, no level change is in progress and the difficulty menu is open.
function M.tick()
    if not active then return 0 end
    if os.clock() < pause_until then return 0 end
    if not M.menu_open() then return 0 end
    return M.sweep()
end

function M.set_active(on) active = on == true end
function M.is_active() return active end
function M.stats() return { fixed = fixed_total, last_error = last_error } end

return M
