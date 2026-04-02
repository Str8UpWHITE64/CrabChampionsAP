-- AP/LocationData.lua
-- Maps game events to AP location IDs.
--
-- Location ID formula (from Locations.py):
--   BASE_ID + TABLE_OFFSET * region_index + position_in_list
--
-- Regions:
--   0 = Island Completion (Victory + islands, unranked + ranked)
--   1 = Perk Pickups, 2 = Relic Pickups
--   3 = Rank Runs, 4 = Weapon Runs, 5 = Melee Runs, 6 = Ability Runs
--   7 = Weapon Mod Pickups, 8 = Melee Mod Pickups, 9 = Ability Mod Pickups

local M = {}

local function log(msg) print("[CrabAP-LocData] " .. tostring(msg)) end

-- ---------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------
M.BASE_ID = 1890000
M.TABLE_OFFSET = 12000

M.REGION = {
    island      = 0,
    perk        = 1,
    relic       = 2,
    rank_run    = 3,
    weapon_run  = 4,
    melee_run   = 5,
    ability_run = 6,
    weapon_mod  = 7,
    melee_mod   = 8,
    ability_mod = 9,
}

M.MAX_ISLANDS = 56
M.NUM_RANKS = 8

-- Shop islands: the 6th island in each biome (no combat clear).
-- Pattern: first at island 6, then every 7th.
M.SHOP_ISLANDS = {
    [6]=true, [13]=true, [20]=true, [27]=true,   -- cycle 1
    [34]=true, [41]=true, [48]=true, [55]=true,   -- cycle 2
}

M.RANK_NAMES = {
    "Bronze", "Silver", "Gold", "Sapphire",
    "Emerald", "Ruby", "Diamond", "Prismatic",
}

-- ---------------------------------------------------------------
-- Slot data configuration (set via M.configure)
-- ---------------------------------------------------------------
M.extra_ranked_island_checks = false
M.cascade_ranked_checks = false
M.max_rank = 0
M.required_rank = 0
M.run_length = 28
M.equipment_check_mode = 0  -- 0=regular, 1=filler_only, 2=disabled
M.greed_item_mode = 0       -- 0=auto, 1=drop, 2=skip
M.death_link = false
M.progressive_slots = false
M.starting_perk_slots = 24
M.starting_weapon_mod_slots = 24
M.starting_ability_mod_slots = 12
M.starting_melee_mod_slots = 12

-- Completion requirements: populated by configure()
M.weapons_for_completion = 1
M.melee_for_completion = 0
M.ability_for_completion = 0

-- Pool equipment sets (name -> true): populated by configure()
M.pool_weapons = {}
M.pool_melee = {}
M.pool_abilities = {}

--- Configure from slot_data received on connection.
function M.configure(slot_data)
    local opts = slot_data and slot_data.options or slot_data or {}
    M.extra_ranked_island_checks = opts.extra_ranked_island_checks or false
    M.cascade_ranked_checks = opts.cascade_ranked_checks or false
    M.max_rank = tonumber(opts.max_rank) or 0
    M.required_rank = tonumber(opts.required_rank) or 0
    M.run_length = tonumber(opts.run_length) or 28
    M.equipment_check_mode = tonumber(opts.equipment_check_mode) or 0
    M.greed_item_mode = tonumber(opts.greed_item_mode) or 0
    M.death_link = opts.death_link or (slot_data and slot_data.death_link) or false
    M.progressive_slots = opts.progressive_slots or false
    log("progressive_slots raw=" .. tostring(opts.progressive_slots) .. " resolved=" .. tostring(M.progressive_slots))
    M.starting_perk_slots = tonumber(opts.starting_perk_slots) or 24
    M.starting_weapon_mod_slots = tonumber(opts.starting_weapon_mod_slots) or 24
    M.starting_ability_mod_slots = tonumber(opts.starting_ability_mod_slots) or 12
    M.starting_melee_mod_slots = tonumber(opts.starting_melee_mod_slots) or 12
    M.weapons_for_completion = tonumber(opts.weapons_for_completion) or 1
    M.melee_for_completion = tonumber(opts.melee_for_completion) or 0
    M.ability_for_completion = tonumber(opts.ability_for_completion) or 0

    -- Build pool lookup sets from slot_data lists
    M.pool_weapons = {}
    M.pool_melee = {}
    M.pool_abilities = {}
    local pw = opts.pool_weapons or {}
    for _, name in ipairs(pw) do M.pool_weapons[name] = true end
    local pm = opts.pool_melee or {}
    for _, name in ipairs(pm) do M.pool_melee[name] = true end
    local pa = opts.pool_abilities or {}
    for _, name in ipairs(pa) do M.pool_abilities[name] = true end

    log("Configured: extra_ranked=" .. tostring(M.extra_ranked_island_checks)
        .. " cascade=" .. tostring(M.cascade_ranked_checks)
        .. " max_rank=" .. tostring(M.max_rank)
        .. " required_rank=" .. tostring(M.required_rank)
        .. " run_length=" .. tostring(M.run_length)
        .. " equip_mode=" .. tostring(M.equipment_check_mode)
        .. " pool_weapons=" .. tostring(#pw)
        .. " pool_melee=" .. tostring(#pm)
        .. " pool_abilities=" .. tostring(#pa))
end

--- Check if a weapon name is in the randomized pool.
function M.is_pool_weapon(name) return M.pool_weapons[name] == true end

--- Check if a melee name is in the randomized pool.
function M.is_pool_melee(name) return M.pool_melee[name] == true end

--- Check if an ability name is in the randomized pool.
function M.is_pool_ability(name) return M.pool_abilities[name] == true end

-- ---------------------------------------------------------------
-- Name normalization (same logic as ItemData.lua)
-- ---------------------------------------------------------------

local function name_to_key(name)
    return name:gsub("%s*%b()%s*$", ""):gsub("'", ""):gsub("%s+", ""):lower()
end

local function da_name_to_key(full_name)
    if not full_name then return nil end
    local leaf = full_name:match("%.([^%.]+)$")
    if not leaf then return nil end
    local suffix = leaf:match("^DA_%w+_(.+)$") or leaf
    return suffix:lower()
end

local function classify_da(full_name)
    if not full_name then return nil end
    if full_name:find("^CrabPerkDA ")       then return "perk" end
    if full_name:find("^CrabRelicDA ")      then return "relic" end
    if full_name:find("^CrabWeaponModDA ")  then return "weapon_mod" end
    if full_name:find("^CrabMeleeModDA ")   then return "melee_mod" end
    if full_name:find("^CrabAbilityModDA ") then return "ability_mod" end
    return nil
end

-- ---------------------------------------------------------------
-- Ordered name lists (same order as Items.py / Locations.py)
-- ---------------------------------------------------------------

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

local melee_mod_names = {
    "Arcane Claws", "Big Claws", "Blender", "Brawler", "Fire Claws",
    "Ice Claws", "Iron Claws", "Lightning Claws", "Poison Claws", "Sharp Claws",
    "Time Claws", "Vampire",
}

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

local weapon_names = {
    "Arcane Wand", "Auto Rifle", "Auto Shotgun", "Blade Launcher", "Burst Pistol",
    "Cluster Launcher", "Crossbow", "Dual Pistols", "Dual Shotguns", "Flamethrower",
    "Ice Staff", "Laser Cannons", "Lightning Scepter", "Marksman Rifle", "Minigun",
    "Orb Launcher", "Poison Cannon", "Rocket Launcher", "Seagle", "Sniper",
}

local melee_names = {
    "Claw", "Dagger", "Hammer", "Katana", "Pickaxe",
}

local ability_names = {
    "Air Strike", "Black Hole", "Electro Globe", "Grappling Hook",
    "Grenade", "Ice Blast", "Laser Beam",
}

-- ---------------------------------------------------------------
-- Build lookup tables: key -> 0-based position
-- ---------------------------------------------------------------

local function build_position_map(name_list)
    local map = {}
    for i, name in ipairs(name_list) do
        map[name_to_key(name)] = i - 1
    end
    return map
end

local position_maps = {
    perk        = build_position_map(perk_names),
    relic       = build_position_map(relic_names),
    weapon_mod  = build_position_map(weapon_mod_names),
    melee_mod   = build_position_map(melee_mod_names),
    ability_mod = build_position_map(ability_mod_names),
    weapon      = build_position_map(weapon_names),
    melee       = build_position_map(melee_names),
    ability     = build_position_map(ability_names),
}

-- ---------------------------------------------------------------
-- Pickup locations (not ranked)
-- ---------------------------------------------------------------

function M.from_da(full_name)
    local kind = classify_da(full_name)
    if not kind then return nil, nil end

    local region = M.REGION[kind]
    if not region then return nil, nil end

    local key = da_name_to_key(full_name)
    if not key then return nil, nil end

    local pos_map = position_maps[kind]
    if not pos_map then return nil, nil end

    local position = pos_map[key]
    if not position then
        log("WARN: No position for key='" .. key .. "' kind=" .. kind)
        return nil, kind
    end

    local location_id = M.BASE_ID + (M.TABLE_OFFSET * region) + position
    return location_id, kind
end

function M.display_name(kind, full_name)
    local key = da_name_to_key(full_name)
    if not key then return full_name end

    local name_lists = {
        perk = perk_names,
        relic = relic_names,
        weapon_mod = weapon_mod_names,
        melee_mod = melee_mod_names,
        ability_mod = ability_mod_names,
    }

    local list = name_lists[kind]
    if not list then return key end

    local pos_map = position_maps[kind]
    local pos = pos_map and pos_map[key]
    if pos then return list[pos + 1] end
    return key
end

-- ---------------------------------------------------------------
-- Island completion locations
-- ---------------------------------------------------------------

--- Get location ID for completing an island.
--- Unranked: position = island_num (1..56)
--- Ranked: position = 57 + rank*56 + (island_num-1)
---@param island_num number 1-based island number
---@param rank number|nil 0-based rank (nil = unranked)
---@return number|nil location_id
function M.island_location_id(island_num, rank)
    island_num = tonumber(island_num)
    if not island_num or island_num < 1 or island_num > M.MAX_ISLANDS then return nil end

    local position
    if rank ~= nil then
        rank = tonumber(rank) or 0
        if rank < 0 or rank >= M.NUM_RANKS then return nil end
        position = 57 + rank * M.MAX_ISLANDS + (island_num - 1)
    else
        position = island_num
    end

    return M.BASE_ID + (M.TABLE_OFFSET * M.REGION.island) + position
end

function M.victory_location_id()
    return M.BASE_ID
end

-- ---------------------------------------------------------------
-- Rank run locations
-- ---------------------------------------------------------------

--- Get location ID for "Complete Run on {RankName}".
---@param rank number 0-based rank (0=Bronze, 7=Prismatic)
---@return number|nil location_id
function M.rank_run_location_id(rank)
    rank = tonumber(rank) or 0
    if rank < 0 or rank >= M.NUM_RANKS then return nil end
    return M.BASE_ID + (M.TABLE_OFFSET * M.REGION.rank_run) + rank
end

-- ---------------------------------------------------------------
-- Equipment run locations
-- ---------------------------------------------------------------

--- Helper: compute equipment run location ID.
local function equipment_run_id(region, num_equip, island_num, equip_index, rank)
    island_num = tonumber(island_num)
    if not island_num or island_num < 1 or island_num > M.MAX_ISLANDS then return nil end

    local base_pos = (island_num - 1) * num_equip + equip_index
    local position

    if rank ~= nil then
        rank = tonumber(rank) or 0
        if rank < 0 or rank >= M.NUM_RANKS then return nil end
        local unranked_size = M.MAX_ISLANDS * num_equip
        position = unranked_size + rank * unranked_size + base_pos
    else
        position = base_pos
    end

    return M.BASE_ID + (M.TABLE_OFFSET * region) + position
end

--- Get location ID for weapon run.
---@param island_num number 1-based island number
---@param weapon_full_name string Full UObject name of weapon DA
---@param rank number|nil 0-based rank (nil = unranked)
---@return number|nil location_id
function M.weapon_run_location_id(island_num, weapon_full_name, rank)
    local key = da_name_to_key(weapon_full_name)
    if not key then return nil end
    local idx = position_maps.weapon and position_maps.weapon[key]
    if not idx then return nil end
    return equipment_run_id(M.REGION.weapon_run, #weapon_names, island_num, idx, rank)
end

--- Get location ID for melee run.
function M.melee_run_location_id(island_num, melee_full_name, rank)
    local key = da_name_to_key(melee_full_name)
    if not key then return nil end
    local idx = position_maps.melee and position_maps.melee[key]
    if not idx then return nil end
    return equipment_run_id(M.REGION.melee_run, #melee_names, island_num, idx, rank)
end

--- Get location ID for ability run.
function M.ability_run_location_id(island_num, ability_full_name, rank)
    local key = da_name_to_key(ability_full_name)
    if not key then return nil end
    local idx = position_maps.ability and position_maps.ability[key]
    if not idx then return nil end
    return equipment_run_id(M.REGION.ability_run, #ability_names, island_num, idx, rank)
end

--- Get location ID for weapon run by clean name (e.g. "Auto Rifle").
function M.weapon_run_location_id_by_name(island_num, weapon_name, rank)
    local key = name_to_key(weapon_name)
    local idx = position_maps.weapon and position_maps.weapon[key]
    if not idx then return nil end
    return equipment_run_id(M.REGION.weapon_run, #weapon_names, island_num, idx, rank)
end

--- Get location ID for melee run by clean name (e.g. "Hammer").
function M.melee_run_location_id_by_name(island_num, melee_name, rank)
    local key = name_to_key(melee_name)
    local idx = position_maps.melee and position_maps.melee[key]
    if not idx then return nil end
    return equipment_run_id(M.REGION.melee_run, #melee_names, island_num, idx, rank)
end

--- Get location ID for ability run by clean name (e.g. "Grenade").
function M.ability_run_location_id_by_name(island_num, ability_name, rank)
    local key = name_to_key(ability_name)
    local idx = position_maps.ability and position_maps.ability[key]
    if not idx then return nil end
    return equipment_run_id(M.REGION.ability_run, #ability_names, island_num, idx, rank)
end

--- Get display name for an equipment DA (for logging).
function M.equipment_name(equip_kind, full_name)
    local key = da_name_to_key(full_name)
    if not key then return full_name or "unknown" end

    local name_lists = {
        weapon = weapon_names,
        melee = melee_names,
        ability = ability_names,
    }
    local list = name_lists[equip_kind]
    if not list then return key end

    local pos_map = position_maps[equip_kind]
    local pos = pos_map and pos_map[key]
    if pos then return list[pos + 1] end
    return key
end

-- Expose name lists for other modules (e.g., pre-allowing non-pool equipment)
M.weapon_names = weapon_names
M.melee_names = melee_names
M.ability_names = ability_names

return M
