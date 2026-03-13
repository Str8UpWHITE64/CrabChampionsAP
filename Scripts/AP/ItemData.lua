-- AP/ItemData.lua
-- Maps AP item IDs (base_id + cc_code) to game DataAsset objects.
-- Resolves items at runtime using FindAllOf() to build DA lookup maps.

local M = {}

local function log(msg) print("[CrabAP-ItemData] " .. tostring(msg)) end

-- ---------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------
M.BASE_ID = 1890000

M.CATEGORY = {
    SKIP       = 0,
    EVENT      = 1,
    PERK       = 2,
    RELIC      = 3,
    WEAPON     = 4,
    ABILITY    = 5,
    MELEE      = 6,
    WEAPON_MOD = 7,
    MELEE_MOD  = 8,
    ABILITY_MOD = 9,
    FILLER     = 10,
}

-- UE4 class name for each category
M.CATEGORY_CLASS = {
    [M.CATEGORY.PERK]       = "CrabPerkDA",
    [M.CATEGORY.RELIC]      = "CrabRelicDA",
    [M.CATEGORY.WEAPON]     = "CrabWeaponDA",
    [M.CATEGORY.ABILITY]    = "CrabAbilityDA",
    [M.CATEGORY.MELEE]      = "CrabMeleeDA",
    [M.CATEGORY.WEAPON_MOD] = "CrabWeaponModDA",
    [M.CATEGORY.MELEE_MOD]  = "CrabMeleeModDA",
    [M.CATEGORY.ABILITY_MOD] = "CrabAbilityModDA",
}

-- ---------------------------------------------------------------
-- cc_code -> {cat, name} table  (from Items.py)
-- ---------------------------------------------------------------
M.BY_CC_CODE = {}

local function add(cc_code, cat, name)
    M.BY_CC_CODE[cc_code] = { cat = cat, name = name }
end

-- Perks (cc_code 1-107)
local perk_names = {
    "Anti Crit", "Banana", "Bounty Hunter", "Bulletproof", "Bullseye",
    "Critical Arrow", "Critical Thinking", "Crystal Combo", "Crystal Fertilizer", "Damage Combo",
    "Danger Close", "Driller", "Eagle Eye", "Elemental Expert", "Elemental Specialist",
    "Endurance", "Enhanced Turrets", "Equalizer", "Explosive Armor", "Firestarter",
    "Fortitude", "Hard Target", "High Voltage", "Hot Shot", "Hot Steam",
    "Ice Cold", "Magnify", "Mango", "Paycheck", "Personal Space",
    "Poisonous Armor", "Potent Magic", "Power Armor", "Power Punch", "Regenerator",
    "Scavenger", "Sharpshooter", "Slugger", "Snatcher", "Special Delivery",
    "Speed Demon", "Stamina", "Streamer Loot", "Tony's Black Card", "Toxic",
    "Valued Customer", "Vitality", "All You Can Eat", "Amber Resin", "Assassin",
    "Big Chests", "Bonus Crystals", "Checklist", "Collector", "Crimson Haze",
    "Critical Blast", "Damage Aura", "Double Vision", "Exploding Enemies", "Fire Aura",
    "Flammable Armor", "Gemstone", "Gold Coating", "Grim Reaper", "Health Is Power",
    "Ice Aura", "Lightning Aura", "Mega Crit", "Money Is Power", "Orbiting Scythes",
    "Performance Bonus", "Poison Aura", "Shockwave", "Silver Lining", "Speed Is Power",
    "Sturdy Totems", "Survivor", "Tasty Orange", "Totem Enthusiast", "Big Bones",
    "Bribe", "Brute Force", "Damage Seeker", "Double Trouble", "Glass Cannon",
    "Juggernaut", "Leap Of Faith", "Limited Loot", "Rising Star", "Slippery Slope",
    "Up The Ante", "Workaholic", "Bonus Chests", "Care Package", "Critical Lightning",
    "Crystal Asteroids", "Dagger Dash", "Electric Enemies", "Faulty Chests", "Flammable Enemies",
    "Freezing Enemies", "Ice Dash", "Level Up", "Lightning Dash", "Poisonous Enemies",
    "Powerslide", "Rare Treasure",
}
for i, name in ipairs(perk_names) do add(i, M.CATEGORY.PERK, name) end

-- Relics (cc_code 200-252)
local relic_names = {
    "Adrenaline Amulet", "Blacksmith Amulet", "Combo Ring", "Coral Amulet", "Icebreaker",
    "Portal Ring", "Ring Of Armor", "Ring Of Destruction", "Ring Of Healing", "Ring Of Healthy Turrets",
    "Ring Of Reloading", "Ring Of Vigor", "Tony's Amulet", "Ammo Ring", "Arcane Ring",
    "Blacksmith Ring", "Duplication Ring", "Ethereal Armor", "Fire Ring", "Full Metal Jacket",
    "Ice Ring", "Lightning Ring", "Poison Ring", "Ring Of Defense", "Ring Of Deflection",
    "Ring Of Dividends", "Ring Of Fury", "Ring Of Potential", "Ring Of Power", "Ring Of Precision",
    "Ring Of Reinforcement", "Ring Of Repulsion", "Ring Of Rocket Jumping", "Ring Of Value", "Ring Of Wisdom",
    "Skill Ring", "Time Ring", "Turbo Ring", "High Roller", "Hoarder Backpack",
    "Overspill Goblet", "Ring Of Favoritism", "Ring Of Tankiness", "Trigger Ring", "Upgrade Ring",
    "Ability Ring", "Portal Amulet", "Ring Of Gravity", "Ring Of Luck", "Ring Of Protection",
    "Ring Of Regenerating Armor", "Ring Of Swiftness", "Twin Ring",
}
for i, name in ipairs(relic_names) do add(199 + i, M.CATEGORY.RELIC, name) end

-- Weapons (cc_code 300-319)
local weapon_names = {
    "Arcane Wand", "Auto Rifle", "Auto Shotgun", "Blade Launcher", "Burst Pistol",
    "Cluster Launcher", "Crossbow", "Dual Pistols", "Dual Shotguns", "Flamethrower",
    "Ice Staff", "Laser Cannons", "Lightning Scepter", "Marksman Rifle", "Minigun",
    "Orb Launcher", "Poison Cannon", "Rocket Launcher", "Seagle", "Sniper",
}
for i, name in ipairs(weapon_names) do add(299 + i, M.CATEGORY.WEAPON, name) end

-- Abilities (cc_code 400-406)
local ability_names = {
    "Air Strike", "Black Hole", "Electro Globe", "Grappling Hook",
    "Grenade", "Ice Blast", "Laser Beam",
}
for i, name in ipairs(ability_names) do add(399 + i, M.CATEGORY.ABILITY, name) end

-- Melee (cc_code 500-504)
local melee_names = {
    "Claw", "Dagger", "Hammer", "Katana", "Pickaxe",
}
for i, name in ipairs(melee_names) do add(499 + i, M.CATEGORY.MELEE, name) end

-- Weapon Mods (cc_code 600-689)
local weapon_mod_names = {
    "Accelerating Shot", "Arc Shot", "Arcane Blast", "Arcane Shot", "Aura Shot",
    "Beam Shot", "Big Mag", "Big Shot", "Blind Fire", "Bomb Shot",
    "Boomerang Shot", "Bouncing Shot", "Bubble Shot", "Chaotic Shot", "Dagger Arc",
    "Damage Shot", "Dice Shot", "Double Shot", "Double Tap", "Drill Shot",
    "Efficient Shot", "Escalating Shot", "Fast Shot", "Fire Shot", "Fire Storm",
    "Fire Strike", "Fireball Shot", "Firepower", "Firework Shot", "Glue Shot",
    "Grip Tape", "Health Shot", "Heavy Hitter", "Heavy Shot", "High Caliber",
    "Homing Blades", "Homing Shot", "Ice Shot", "Ice Storm", "Ice Strike",
    "Juiced", "Knockback Shot", "Landmine Shot", "Lightning Shot", "Lightning Storm",
    "Lightning Strike", "Link Shot", "Mace Shot", "Mag Shot", "Money Shot",
    "Orbiting Shot", "Piercing Shot", "Piercing Wave", "Poison Shot", "Poison Storm",
    "Poison Strike", "Proximity Barrage", "Pumpkin Shot", "Random Shot", "Rapid Fire",
    "Recoil Shot", "Reload Arc", "Scatter Shot", "Sharp Shot", "Sharpened Axe",
    "Shotgun Blast", "Snake Shot", "Sonic Boom", "Spark Shot", "Spike Strike",
    "Spiral Shot", "Splash Damage", "Split Shot", "Spore Shot", "Square Shot",
    "Steady Shot", "Streak Shot", "Supercharged", "Targeting Shot", "Thorn Shot",
    "Time Bolt", "Time Shot", "Torpedo Shot", "Triangle Shot", "Trick Shot",
    "Triple Shot", "Ultra Shot", "Wind Up", "X Shot", "Zig Zag Shot",
}
for i, name in ipairs(weapon_mod_names) do add(599 + i, M.CATEGORY.WEAPON_MOD, name) end

-- Melee Mods (cc_code 700-711)
local melee_mod_names = {
    "Arcane Claws", "Big Claws", "Blender", "Brawler", "Fire Claws",
    "Ice Claws", "Iron Claws", "Lightning Claws", "Poison Claws", "Sharp Claws",
    "Time Claws", "Vampire",
}
for i, name in ipairs(melee_mod_names) do add(699 + i, M.CATEGORY.MELEE_MOD, name) end

-- Ability Mods (cc_code 800-842)
local ability_mod_names = {
    "Aura Explosion", "Barrel Explosion", "Beam Turret", "Big Ability", "Bigger Boom",
    "Bomb Explosion", "Bouncing Explosion", "Bubble Blast", "Chaotic Explosion", "Clone Explosion",
    "Crystal Barrage", "Crystal Strike", "Dagger Blast", "Damage Explosion", "Energy Ring",
    "Fire Explosion", "Firework Explosion", "Giant Drill", "Glue Explosion", "Grenadier",
    "Heat Sink", "Ice Explosion", "Imploding Explosion", "Iron Explosion", "Landmine Explosion",
    "Layered Explosion", "Lightning Explosion", "Mortar Turret", "Poison Explosion", "Scythe Vortex",
    "Sentry Turret", "Sniper Turret", "Spark Explosion", "Spike Strike", "Spinning Blade",
    "Split Ability", "Spore Explosion", "Targeting Explosion", "Thorn Explosion", "Time Explosion",
    "Triple Ability", "Ultra Mushroom", "Wave Turret",
}
for i, name in ipairs(ability_mod_names) do add(799 + i, M.CATEGORY.ABILITY_MOD, name) end

-- Filler (cc_code 900-903)
add(900, M.CATEGORY.FILLER, "Crystal Cache")       -- 50 crystals
add(901, M.CATEGORY.FILLER, "Nothing")
add(902, M.CATEGORY.FILLER, "Crystal Hoard")        -- 100 crystals
add(903, M.CATEGORY.FILLER, "Crystal Jackpot")      -- 500 crystals

-- Event (cc_code 1000)
add(1000, M.CATEGORY.EVENT, "Victory")

-- ---------------------------------------------------------------
-- Name matching
--
-- UE4SS da.Name returns the UObject FName (e.g. "DA_Perk_Driller"),
-- NOT the display name StrProperty. We match by converting both
-- the item name and DA name to a lowercase key with no spaces/punctuation.
--
-- Item name:  "Tony's Black Card" -> "tonysblackcard"
-- DA name:    "DA_Perk_TonysBlackCard" -> strip prefix -> "tonysblackcard"
-- Items.py:   "Spike Strike (Ability)" -> strip parens -> "spikestrike"
-- ---------------------------------------------------------------
local function name_to_key(name)
    return name:gsub("%s*%b()%s*$", ""):gsub("'", ""):gsub("%s+", ""):lower()
end

local function da_name_to_key(obj_name)
    -- Strip "DA_Category_" prefix: "DA_Perk_Driller" -> "Driller"
    local suffix = obj_name:match("^DA_%w+_(.+)$") or obj_name
    return suffix:lower()
end

-- ---------------------------------------------------------------
-- Runtime DA resolution
-- ---------------------------------------------------------------

-- Per-category maps: key -> { full_name, da }
local resolved = {}   -- cat -> { key -> {full_name, da} }
local maps_built = false

local function safe_get_full_name(obj)
    if not obj then return nil end
    local ok, v = pcall(function()
        if obj.GetFullName then return obj:GetFullName() end
        return nil
    end)
    if ok and v then return tostring(v) end
    return nil
end

--- Extract the DA object name from a full_name string.
--- "CrabPerkDA /Game/.../DA_Perk_Driller.DA_Perk_Driller" -> "DA_Perk_Driller"
local function extract_da_name(full_name)
    if not full_name then return nil end
    -- Take the part after the last dot
    return full_name:match("%.([^%.]+)$")
end

--- Build DA lookup maps for all item categories.
--- Must be called after the game has loaded assets.
function M.resolve_game_objects()
    resolved = {}

    for cat, class_name in pairs(M.CATEGORY_CLASS) do
        local cat_map = {}
        local list = FindAllOf(class_name)
        if list then
            local first_logged = false
            for _, da in ipairs(list) do
                if da ~= nil and (not da.IsValid or da:IsValid()) then
                    local full_name = safe_get_full_name(da)
                    if full_name then
                        local da_name = extract_da_name(full_name)
                        if da_name then
                            local key = da_name_to_key(da_name)
                            cat_map[key] = { full_name = full_name, da = da }
                            -- Log first entry per category for debugging
                            if not first_logged then
                                log("  e.g. " .. da_name .. " -> key=" .. key)
                                first_logged = true
                            end
                        end
                    end
                end
            end
        end
        resolved[cat] = cat_map
        local count = 0
        for _ in pairs(cat_map) do count = count + 1 end
        log(class_name .. ": " .. count .. " DAs resolved")
    end

    maps_built = true
    log("Game object maps built")
end

--- Check if maps have been built.
function M.is_resolved()
    return maps_built
end

--- Look up an item by AP item ID.
---@param ap_item_id number The AP item ID (base_id + cc_code)
---@return table|nil  { cc_code, cat, name, full_name, da } or nil
function M.from_ap_id(ap_item_id)
    local cc_code = tonumber(ap_item_id) - M.BASE_ID
    local entry = M.BY_CC_CODE[cc_code]
    if not entry then
        log("Unknown cc_code: " .. tostring(cc_code) .. " (ap_id=" .. tostring(ap_item_id) .. ")")
        return nil
    end

    local result = {
        cc_code = cc_code,
        cat = entry.cat,
        name = entry.name,
        full_name = nil,
        da = nil,
    }

    -- Resolve game object if maps are built
    if maps_built and M.CATEGORY_CLASS[entry.cat] then
        local cat_map = resolved[entry.cat]
        if cat_map then
            local key = name_to_key(entry.name)
            local game_obj = cat_map[key]
            if game_obj then
                result.full_name = game_obj.full_name
                result.da = game_obj.da
            else
                log("WARN: No DA found for '" .. entry.name .. "' (key=" .. key .. ") in " .. M.CATEGORY_CLASS[entry.cat])
            end
        end
    end

    return result
end

--- Look up a game object by category and display name.
---@param cat number Category constant
---@param name string Display name
---@return string|nil full_name
---@return userdata|nil da
function M.get_da(cat, name)
    if not maps_built or not resolved[cat] then return nil, nil end
    local key = name_to_key(name)
    local entry = resolved[cat][key]
    if entry then
        return entry.full_name, entry.da
    end
    return nil, nil
end

return M
