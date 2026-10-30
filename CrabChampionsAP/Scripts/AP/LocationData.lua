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
--   10-13 = the same island and equipment checks in the biome layout
--           (check_layout = biome): 10 = islands, 11 = weapon, 12 = melee, 13 = ability runs.
--           A biome check's index replaces the island number: loop * 28 + (biome - 1) * 7 + slot.

local M = {}

local function log(msg) print("[CrabAP-LocData] " .. tostring(msg)) end

-- ---------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------
M.BASE_ID = 1890000
M.TABLE_OFFSET = 12000
-- Must match ID_LAYOUT in Locations.py. Seeds of older layouts are read with
-- their own lists (IdLayouts.lua, set_layout); APClient refuses any other.
M.ID_LAYOUT = 4

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

-- Regions used instead of island / weapon_run / melee_run / ability_run in the biome layout.
M.BIOME_REGION = {
    island      = 10,
    weapon_run  = 11,
    melee_run   = 12,
    ability_run = 13,
}

M.MAX_ISLANDS = 56
M.NUM_RANKS = 8

-- Shop islands: the 6th island in each biome (no combat clear).
-- Pattern: first at island 6, then every 7th.
M.SHOP_ISLANDS = {
    [6]=true, [13]=true, [20]=true, [27]=true,   -- cycle 1
    [34]=true, [41]=true, [48]=true, [55]=true,   -- cycle 2
}

-- Islands per biome: the shop is the 6th, the 7th is the last. Clearing an
-- island that is a multiple of this means the next one starts a new biome.
M.BIOME_LENGTH = 7

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
-- Whether "... on Bronze" locations exist. New seeds have none (the plain
-- checks are the Bronze checks); seeds made before that still do.
M.bronze_checks = true
M.run_length = 28
M.check_layout = 0          -- 0=island_number, 1=biome
M.biome_layout = false
M.equipment_check_mode = 0  -- 0=regular, 1=filler_only, 2=disabled
M.greed_item_mode = 0       -- 0=auto, 1=drop, 2=skip
M.pickup_checks = true
M.death_link = false
M.progressive_slots = false
M.starting_perk_slots = 24
M.starting_weapon_mod_slots = 24
M.starting_ability_mod_slots = 12
M.starting_melee_mod_slots = 12
M.limit_pickup_pool = false
M.limit_pickup_locations = false

-- Greed items grouped by pickup kind — kept in sync with apworld
-- GREED_ITEM_NAMES.  Used both to filter pickup checks (so locations the
-- server doesn't have don't get sent) AND to pre-allow these items in
-- InventorySanitize when greed_item_mode == skip (so natural in-game
-- pickups stay in the player's inventory).
M.GREED_BY_KIND = {
    perk = {
        "Big Bones", "Bribe", "Brute Force", "Damage Seeker", "Double Trouble",
        "Glass Cannon", "Juggernaut", "Leap Of Faith", "Limited Loot",
        "Rising Star", "Slippery Slope", "Up The Ante", "Workaholic",
    },
    relic = {
        "High Roller", "Hoarder Backpack", "Overspill Goblet",
        "Ring Of Favoritism", "Ring Of Tankiness", "Trigger Ring",
        "Upgrade Ring", "Crushing Blow", "Mega Greed",
    },
    melee_mod = { "Brawler" },
}

-- Flat lookup: name -> true.  Built from GREED_BY_KIND for fast checks.
M.GREED_ITEM_NAMES = {}
for _, names in pairs(M.GREED_BY_KIND) do
    for _, n in ipairs(names) do
        M.GREED_ITEM_NAMES[n] = true
    end
end

-- Per-category pickup subsets (name -> true) populated from slot_data when
-- the slot enables limit_pickup_locations or limit_pickup_pool.
M.pickup_subsets = {
    perk = {}, relic = {},
    weapon_mod = {}, melee_mod = {}, ability_mod = {},
}
M._has_pickup_subsets = false

-- Completion requirements: populated by configure()
M.weapons_for_completion = 1
-- False for seeds made before 1.4, whose goal also counted non-pool runs.
M.pool_only_completion = false

-- Share of received perks/mods/relics given at the start of a run and at each
-- new biome. Seeds without these options get everything, as before 1.5.
M.starting_item_percentage = 100
M.biome_item_percentage = 0

-- Traps and Perk Boost (layout 3). Every effect is temporary; these set how strong.
M.trap_duration = 30
M.trap_grace_seconds = 10
M.crystal_tax_percent = 25
M.slowdown_percent = 35
M.weak_shots_percent = 50
M.bruise_percent = 30
M.perk_boost_levels = 1

-- Whether receiving an item completes its pickup check. Seeds from before the
-- option existed did this, so it defaults to on.
M.granted_item_checks = true
M.melee_for_completion = 0
M.ability_for_completion = 0

-- Pool equipment sets (name -> true): populated by configure()
M.pool_weapons = {}
M.pool_melee = {}
M.pool_abilities = {}

-- Set of valid location IDs known to the server (location_id -> true).
-- Populated by APClient from the Connected packet's missing_locations +
-- checked_locations arrays via set_location_allowlist().  Used by
-- is_valid_location_id() so the client never sends a check for a location
-- the server didn't generate (which would otherwise crash the server with
-- a KeyError).
M.valid_location_ids = {}
M._has_location_allowlist = false

--- Configure from slot_data received on connection.
function M.configure(slot_data)
    local opts = slot_data and slot_data.options or slot_data or {}
    M.extra_ranked_island_checks = opts.extra_ranked_island_checks or false
    M.cascade_ranked_checks = opts.cascade_ranked_checks or false
    M.max_rank = tonumber(opts.max_rank) or 0
    M.required_rank = tonumber(opts.required_rank) or 0
    M.bronze_checks = opts.bronze_checks ~= false
    M.run_length = tonumber(opts.run_length) or 28
    M.check_layout = tonumber(opts.check_layout) or 0
    M.biome_layout = M.check_layout == 1
    M.equipment_check_mode = tonumber(opts.equipment_check_mode) or 0
    M.greed_item_mode = tonumber(opts.greed_item_mode) or 0
    M.pickup_checks = (opts.pickup_checks == nil) and true or opts.pickup_checks
    M.death_link = opts.death_link or (slot_data and slot_data.death_link) or false
    M.progressive_slots = opts.progressive_slots or false
    log("progressive_slots raw=" .. tostring(opts.progressive_slots) .. " resolved=" .. tostring(M.progressive_slots))
    M.starting_perk_slots = tonumber(opts.starting_perk_slots) or 24
    M.starting_weapon_mod_slots = tonumber(opts.starting_weapon_mod_slots) or 24
    M.starting_ability_mod_slots = tonumber(opts.starting_ability_mod_slots) or 12
    M.starting_melee_mod_slots = tonumber(opts.starting_melee_mod_slots) or 12
    M.weapons_for_completion = tonumber(opts.weapons_for_completion) or 1
    M.pool_only_completion = opts.pool_only_completion == true
    M.starting_item_percentage = tonumber(opts.starting_item_percentage) or 100
    M.biome_item_percentage = tonumber(opts.biome_item_percentage) or 0
    M.trap_duration = tonumber(opts.trap_duration) or 30
    M.trap_grace_seconds = tonumber(opts.trap_grace_seconds) or 10
    M.crystal_tax_percent = tonumber(opts.crystal_tax_percent) or 25
    M.slowdown_percent = tonumber(opts.slowdown_percent) or 35
    M.weak_shots_percent = tonumber(opts.weak_shots_percent) or 50
    M.bruise_percent = tonumber(opts.bruise_percent) or 30
    M.perk_boost_levels = tonumber(opts.perk_boost_levels) or 1
    M.granted_item_checks = opts.granted_item_checks ~= false
    M.melee_for_completion = tonumber(opts.melee_for_completion) or 0
    M.ability_for_completion = tonumber(opts.ability_for_completion) or 0
    M.limit_pickup_pool = opts.limit_pickup_pool or false
    M.limit_pickup_locations = opts.limit_pickup_locations or false

    -- Per-category pickup subsets (used when limit_pickup_pool /
    -- limit_pickup_locations is enabled).  Each subset is a list of item
    -- names; convert to set form for fast lookup.
    M.pickup_subsets = {
        perk = {}, relic = {},
        weapon_mod = {}, melee_mod = {}, ability_mod = {},
    }
    M._has_pickup_subsets = false
    local subsets = (slot_data and slot_data.pickup_subsets)
        or (opts and opts.pickup_subsets)
    if type(subsets) == "table" then
        local total = 0
        for cat_key, names in pairs(subsets) do
            local target = M.pickup_subsets[cat_key]
            if target and type(names) == "table" then
                for _, n in ipairs(names) do
                    target[n] = true
                    total = total + 1
                end
            end
        end
        if total > 0 then
            M._has_pickup_subsets = true
            log("Loaded pickup subsets (" .. total .. " items across categories)")
        end
    end

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

    -- The location allowlist is populated separately by APClient via
    -- set_location_allowlist() once it has read the Connected packet's
    -- missing_locations + checked_locations arrays.  See those functions.

    log("Configured: extra_ranked=" .. tostring(M.extra_ranked_island_checks)
        .. " cascade=" .. tostring(M.cascade_ranked_checks)
        .. " max_rank=" .. tostring(M.max_rank)
        .. " required_rank=" .. tostring(M.required_rank)
        .. " bronze_checks=" .. tostring(M.bronze_checks)
        .. " run_length=" .. tostring(M.run_length)
        .. " check_layout=" .. tostring(M.check_layout)
        .. " equip_mode=" .. tostring(M.equipment_check_mode)
        .. " greed_mode=" .. tostring(M.greed_item_mode)
        .. " pickup_checks=" .. tostring(M.pickup_checks)
        .. " limit_pool=" .. tostring(M.limit_pickup_pool)
        .. " limit_locs=" .. tostring(M.limit_pickup_locations)
        .. " pool_weapons=" .. tostring(#pw)
        .. " pool_melee=" .. tostring(#pm)
        .. " pool_abilities=" .. tostring(#pa))
end

--- Populate the valid-location allowlist from two arrays: the AP protocol's
--- `missing_locations` (locations not yet checked for this slot) and
--- `checked_locations` (locations already checked).  Their union is the
--- complete authoritative set of location IDs the server knows about for
--- this slot.  Called by APClient after the Connected packet arrives.
---@param missing table|nil Array of location IDs (numeric)
---@param checked table|nil Array of location IDs (numeric)
function M.set_location_allowlist(missing, checked)
    M.valid_location_ids = {}
    M._has_location_allowlist = false
    local count = 0
    local function ingest(t)
        if type(t) ~= "table" then return end
        -- Try ipairs first (typical apclientpp delivery), then pairs as a
        -- fallback in case the table comes back with non-sequential keys.
        for _, lid in ipairs(t) do
            local nid = tonumber(lid)
            if nid and not M.valid_location_ids[nid] then
                M.valid_location_ids[nid] = true
                count = count + 1
            end
        end
        for _, lid in pairs(t) do
            local nid = tonumber(lid)
            if nid and not M.valid_location_ids[nid] then
                M.valid_location_ids[nid] = true
                count = count + 1
            end
        end
    end
    ingest(missing)
    ingest(checked)
    if count > 0 then
        M._has_location_allowlist = true
        log("Loaded location allowlist (" .. count .. " valid IDs from "
            .. "missing_locations + checked_locations)")
    else
        log("WARN: Connected packet had no missing/checked locations — "
            .. "running without an allowlist; the server may reject some checks")
    end
end

--- Check whether a location ID is valid for this slot — i.e. the server
--- knows about a location with that ID.  Returns true if no allowlist was
--- populated yet (fail-open) so this is safe to call before slot_connected.
function M.is_valid_location_id(location_id)
    if not M._has_location_allowlist then return true end
    return M.valid_location_ids[tonumber(location_id)] == true
end

--- Check whether a pickup item's location is excluded by current options
--- (greed_item_mode == skip, limit_pickup_locations subset).  Returns true
--- if we should NOT send a check for this pickup.
---@param kind string "perk" | "relic" | "weapon_mod" | "melee_mod" | "ability_mod"
---@param item_name string Display name of the picked-up item
function M.is_pickup_location_excluded(kind, item_name)
    if not item_name or not kind then return false end
    -- pickup_checks disabled → no pickup locations exist at all
    if not M.pickup_checks then return true end
    -- The seed's options name the item under its kind in the seed.
    kind = M.seed_kind(kind, item_name)
    -- Greed items excluded when greed_item_mode == skip (2)
    -- Apworld _should_include_location only excludes for perks/relics/
    -- melee_mods (matches GREED_ITEM_NAMES coverage).
    if M.greed_item_mode == 2
            and (kind == "perk" or kind == "relic" or kind == "melee_mod")
            and M.GREED_ITEM_NAMES[item_name] then
        return true
    end
    -- limit_pickup_locations: only items in the chosen subset have locations
    if M.limit_pickup_locations and M._has_pickup_subsets then
        local subset = M.pickup_subsets[kind]
        if subset and not subset[item_name] then return true end
    end
    return false
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
    "Valued Customer", "Vitality", "Amber Resin", "Assassin",
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
    -- Added in the 2.0 update
    "Charger", "Giant Slayer", "Liquid Core", "Weightlifter",
    "Fireslide", "Golden Hammer", "Heavy Impact", "Minimalist", "Quality Shipments",
    "Tempered",
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
    -- Added in the 2.0 update
    "AOE Ring", "Barter Ring", "Blessed Ring", "Corrupt Stocktaker",
    "Lingering Fumes", "Overcharge Ring", "Sweet Spot",
    "All You Can Eat", "Ammo Cache", "Crushing Blow", "Lucky Lock", "Mega Greed",
    "Nourishing Salvage", "Ring Of Confidence", "Ring Of Deceit", "Sand Shield", "Thrusters",
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
    -- Added in the 2.0 update
    "Full Focus", "Popcorn Shot", "Tornado Shot",
}

local melee_mod_names = {
    "Arcane Claws", "Big Claws", "Blender", "Brawler", "Fire Claws",
    "Ice Claws", "Iron Claws", "Lightning Claws", "Poison Claws", "Sharp Claws",
    "Time Claws", "Vampire",
    -- Added in the 2.0 update
    "Crystal Claws", "Hard Landing", "Knockback Claws", "Potent Claws", "Prismatic Claws",
}

local ability_mod_names = {
    "Barrel Explosion", "Beam Turret", "Big Ability", "Bigger Boom",
    "Bomb Explosion", "Bouncing Explosion", "Bubble Blast", "Chaotic Explosion", "Clone Explosion",
    "Crystal Barrage", "Crystal Strike", "Dagger Blast", "Damage Explosion", "Energy Ring",
    "Fire Explosion", "Firework Explosion", "Giant Drill", "Glue Explosion", "Grenadier",
    "Heat Sink", "Ice Explosion", "Imploding Explosion", "Iron Explosion", "Landmine Explosion",
    "Layered Explosion", "Lightning Explosion", "Mortar Turret", "Poison Explosion", "Scythe Vortex",
    "Sentry Turret", "Sniper Turret", "Spark Explosion", "Spike Strike", "Spinning Blade",
    "Split Ability", "Spore Explosion", "Targeting Explosion", "Thorn Explosion", "Time Explosion",
    "Triple Ability", "Ultra Mushroom", "Wave Turret",
    -- Added in the 2.0 update
    "Fast Ability", "Homing Ability", "Orbiting Ability",
}

local weapon_names = {
    "Arcane Wand", "Auto Rifle", "Auto Shotgun", "Blade Launcher", "Burst Pistol",
    "Cluster Launcher", "Crossbow", "Dual Pistols", "Dual Shotguns", "Flamethrower",
    "Ice Staff", "Laser Cannons", "Lightning Scepter", "Marksman Rifle", "Minigun",
    "Orb Launcher", "Poison Cannon", "Rocket Launcher", "Seagle", "Sniper",
    -- Added in the 2.0 update
    "Popcorn Shotgun",
}

local melee_names = {
    "Claw", "Dagger", "Hammer", "Katana", "Pickaxe",
    -- Added in the 2.0 update
    "Baseball Bat",
}

local ability_names = {
    "Air Strike", "Black Hole", "Electro Globe", "Grappling Hook",
    "Grenade", "Ice Blast", "Laser Beam",
    -- Added in the 2.0 update
    "Boomerang", "Tornado",
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
-- ID layout of the connected seed
--
-- The lists above are what the game has. A seed's IDs are positions in the
-- lists of its own layout (IdLayouts.lua), which set_layout selects. Until
-- a seed sets one, the current layout is used.
-- ---------------------------------------------------------------

local current_lists = {
    perk = perk_names, relic = relic_names,
    weapon_mod = weapon_mod_names, melee_mod = melee_mod_names, ability_mod = ability_mod_names,
    weapon = weapon_names, melee = melee_names, ability = ability_names,
}
local id_lists = current_lists     -- kind -> the seed's name list
local id_maps = position_maps      -- kind -> key -> 0-based position in the seed's list
local id_moved = {}                -- game kind -> key -> the seed's kind for that item
local id_removed = {}              -- { kind, name } the seed has but the game no longer does
M.id_layout = nil

--- Use the ID lists of a seed's layout. Returns false for a layout this
--- client can't read (the lists are left as they were).
---@param layout number|nil slot_data.id_layout (nil = 1)
function M.set_layout(layout)
    local IdLayouts = require("AP/IdLayouts")
    layout = tonumber(layout) or 1
    if not IdLayouts.supported(layout) then return false end
    M.id_layout = layout
    id_moved, id_removed = {}, {}
    if layout == IdLayouts.CURRENT then
        id_lists, id_maps = current_lists, position_maps
        return true
    end
    local L = IdLayouts[layout]
    id_lists, id_maps = {}, {}
    for kind in pairs(current_lists) do
        id_lists[kind] = L[kind]
        id_maps[kind] = build_position_map(L[kind])
    end
    for seed_kind, names in pairs(L.moved or {}) do
        for name, game_kind in pairs(names) do
            id_moved[game_kind] = id_moved[game_kind] or {}
            id_moved[game_kind][name_to_key(name)] = seed_kind
        end
    end
    for kind, names in pairs(L.removed or {}) do
        for name in pairs(names) do id_removed[#id_removed + 1] = { kind, name } end
    end
    return true
end

--- The kind a game item has in the seed: differs only for an item the game
--- has moved to another kind since the seed's layout.
---@param kind string game kind ("perk", "relic", ...)
---@param name string item name or name key
function M.seed_kind(kind, name)
    local moved = id_moved[kind]
    return (moved and name and moved[name_to_key(name)]) or kind
end

--- Location ID of picking up a game item, or nil when the seed's layout has
--- no such pickup. Also returns the item's kind in the seed.
---@param kind string game kind
---@param name string item name or name key
function M.pickup_location_id(kind, name)
    if not kind or not name then return nil end
    local key = name_to_key(name)
    local seed_kind = M.seed_kind(kind, key)
    local region = M.REGION[seed_kind]
    local position = id_maps[seed_kind] and id_maps[seed_kind][key]
    if not region or not position then return nil, seed_kind end
    return M.BASE_ID + (M.TABLE_OFFSET * region) + position, seed_kind
end

--- Pickup checks of the seed whose item the game no longer has, so they
--- can't be found in a run.
function M.unfindable_location_ids()
    local ids = {}
    for _, entry in ipairs(id_removed) do
        local kind, name = entry[1], entry[2]
        local position = id_maps[kind] and id_maps[kind][name_to_key(name)]
        if position then
            ids[#ids + 1] = M.BASE_ID + (M.TABLE_OFFSET * M.REGION[kind]) + position
        end
    end
    return ids
end

--- Game items of a kind that have no pickup check in the seed's layout at
--- all (added to the game after the seed's layout). Empty for the current layout.
---@param kind string game kind
function M.untracked_pickup_names(kind)
    local names = {}
    for _, name in ipairs(current_lists[kind] or {}) do
        if not M.pickup_location_id(kind, name) then names[#names + 1] = name end
    end
    return names
end

-- ---------------------------------------------------------------
-- Pickup locations (not ranked)
-- ---------------------------------------------------------------

--- Location ID of picking up a DA, its game kind, and its kind in the seed.
function M.from_da(full_name)
    local kind = classify_da(full_name)
    if not kind then return nil, nil end

    local key = da_name_to_key(full_name)
    if not key then return nil, nil end

    local location_id, seed_kind = M.pickup_location_id(kind, key)
    if not location_id then
        if id_maps == position_maps then
            log("WARN: No position for key='" .. key .. "' kind=" .. kind)
        else
            log("No check for key='" .. key .. "' kind=" .. kind .. " in ID layout " .. tostring(M.id_layout))
        end
        return nil, kind
    end

    return location_id, kind, seed_kind
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
-- Check layout
-- ---------------------------------------------------------------

local BIOME_CYCLE = 28

--- Region a kind of island/equipment check lives in for the current layout.
---@param kind string "island" | "weapon_run" | "melee_run" | "ability_run"
local function region_of(kind)
    if M.biome_layout then return M.BIOME_REGION[kind] end
    return M.REGION[kind]
end

--- Whether a rank has location checks of its own. Without Bronze checks the
--- plain (unranked) checks stand in for Bronze.
---@param rank number 0-based rank
function M.rank_is_separate(rank)
    return (tonumber(rank) or 0) > 0 or M.bronze_checks
end

--- The rank argument the ID functions take for a rank tier: the rank itself,
--- or nil (the plain check) for Bronze when there are no Bronze checks.
---@param rank number 0-based rank
function M.tier_rank(rank)
    if M.rank_is_separate(rank) then return rank end
    return nil
end

--- The number the island/equipment ID functions take for a cleared island.
--- Island layout: the island number. Biome layout: the biome check index
--- (1..56) from the biome (game number 1-4) the island was cleared in, or nil
--- when the biome is not known. Only the second pass of a full-length run is
--- Loop 2; a short run never leaves the first.
---@param island_num number 1-based island number of the run
---@param biome number|nil game biome number 1-4
function M.check_index(island_num, biome)
    island_num = tonumber(island_num)
    if not island_num or island_num < 1 then return nil end
    if not M.biome_layout then return island_num end
    biome = tonumber(biome)
    if not biome or biome < 1 or biome > 4 then return nil end
    local slot = (island_num - 1) % M.BIOME_LENGTH + 1
    local loop = (M.run_length > BIOME_CYCLE and island_num > BIOME_CYCLE) and 1 or 0
    return loop * BIOME_CYCLE + (biome - 1) * M.BIOME_LENGTH + slot
end

local BIOME_LABELS = { "Tropical", "Ice", "Desert", "Volcano" }

--- Name of a biome-layout island check, as the apworld calls it: "Complete Tropical Island 3",
--- "Reach Ice Shop (Loop 2)". Used for log lines.
---@param idx number biome check index (1..56)
function M.check_name(idx)
    idx = tonumber(idx)
    if not idx or idx < 1 or idx > M.MAX_ISLANDS then return "?" end
    local loop = (idx - 1) // BIOME_CYCLE
    local rest = (idx - 1) % BIOME_CYCLE
    local biome = BIOME_LABELS[rest // M.BIOME_LENGTH + 1]
    local slot = rest % M.BIOME_LENGTH + 1
    local base = (slot == 6) and ("Reach " .. biome .. " Shop") or ("Complete " .. biome .. " Island " .. slot)
    return base .. (loop > 0 and " (Loop 2)" or "")
end

-- Biome layout: "Complete Run with <item> on <Rank>", sent on the run's final island in whatever biome it is.
M.RUN_REGION = { weapon = 14, melee = 15, ability = 16 }

--- Location ID of a run-level equipment check (biome layout only).
---@param kind string "weapon" | "melee" | "ability"
---@param name string clean item name
---@param rank number 0-based rank
function M.run_equipment_location_id(kind, name, rank)
    local names = ({ weapon = M.weapon_names, melee = M.melee_names, ability = M.ability_names })[kind]
    local region = M.RUN_REGION[kind]
    rank = tonumber(rank)
    if not names or not region or not rank or rank < 0 or rank >= M.NUM_RANKS then return nil end
    local key = name_to_key(name)
    for i, n in ipairs(names) do
        if name_to_key(n) == key then
            return M.BASE_ID + M.TABLE_OFFSET * region + rank * #names + (i - 1)
        end
    end
    return nil
end

--- Whether an equipment run was completed on the run's final island. `loc_id_fn` is one of the
--- *_run_location_id_by_name functions and `is_checked` takes a location ID. The island layout looks at its
--- final-island check; the biome layout at the run-level check.
function M.final_run_checked(loc_id_fn, name, rank, is_checked)
    local lid
    if not M.rank_is_separate(rank) then
        -- Bronze without Bronze checks: the final island's plain check. In the
        -- biome layout the final island can be in any biome.
        if M.biome_layout then
            for biome = 1, 4 do
                local idx = M.check_index(M.run_length, biome)
                local id = idx and loc_id_fn(idx, name, nil)
                if id and is_checked(id) == true then return true end
            end
            return false
        end
        lid = loc_id_fn(M.run_length, name, nil)
    elseif M.biome_layout then
        local kind = (loc_id_fn == M.weapon_run_location_id_by_name and "weapon")
            or (loc_id_fn == M.melee_run_location_id_by_name and "melee")
            or (loc_id_fn == M.ability_run_location_id_by_name and "ability")
        lid = kind and M.run_equipment_location_id(kind, name, rank)
    else
        lid = loc_id_fn(M.run_length, name, rank)
    end
    return lid ~= nil and is_checked(lid) == true
end

-- ---------------------------------------------------------------
-- Full-inventory gate keys
--
-- The C++ side lets a pickup through a full inventory only when its key is
-- in the open set. Key = DA class name + ":" + lower-case DA suffix, the
-- same string the dll builds from the pickup's data asset.
-- ---------------------------------------------------------------

local GATE_CLASS = {
    perk = "CrabPerkDA", relic = "CrabRelicDA", weapon_mod = "CrabWeaponModDA",
    melee_mod = "CrabMeleeModDA", ability_mod = "CrabAbilityModDA",
}
local GATE_KINDS = { "perk", "relic", "weapon_mod", "melee_mod", "ability_mod" }
local gate_names = {
    perk = perk_names, relic = relic_names, weapon_mod = weapon_mod_names,
    melee_mod = melee_mod_names, ability_mod = ability_mod_names,
}

--- Gate key for a pickup DA full name, or nil for other assets.
function M.gate_key(full_name)
    local kind = classify_da(full_name)
    local key = da_name_to_key(full_name)
    if not kind or not key then return nil end
    return GATE_CLASS[kind] .. ":" .. key
end

--- Keys of every pickup whose check exists in this seed and isn't sent yet.
---@param is_checked fun(location_id: number): boolean
function M.open_pickup_keys(is_checked)
    local keys = {}
    if not M.pickup_checks then return keys end
    for _, kind in ipairs(GATE_KINDS) do
        for _, name in ipairs(gate_names[kind]) do
            local location_id = M.pickup_location_id(kind, name)
            if location_id and M.is_valid_location_id(location_id)
                    and not M.is_pickup_location_excluded(kind, name)
                    and not is_checked(location_id) then
                keys[#keys + 1] = GATE_CLASS[kind] .. ":" .. name_to_key(name)
            end
        end
    end
    return keys
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

    return M.BASE_ID + (M.TABLE_OFFSET * region_of("island")) + position
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
    local idx = id_maps.weapon and id_maps.weapon[key]
    if not idx then return nil end
    return equipment_run_id(region_of("weapon_run"), #id_lists.weapon, island_num, idx, rank)
end

--- Get location ID for melee run.
function M.melee_run_location_id(island_num, melee_full_name, rank)
    local key = da_name_to_key(melee_full_name)
    if not key then return nil end
    local idx = id_maps.melee and id_maps.melee[key]
    if not idx then return nil end
    return equipment_run_id(region_of("melee_run"), #id_lists.melee, island_num, idx, rank)
end

--- Get location ID for ability run.
function M.ability_run_location_id(island_num, ability_full_name, rank)
    local key = da_name_to_key(ability_full_name)
    if not key then return nil end
    local idx = id_maps.ability and id_maps.ability[key]
    if not idx then return nil end
    return equipment_run_id(region_of("ability_run"), #id_lists.ability, island_num, idx, rank)
end

--- Get location ID for weapon run by clean name (e.g. "Auto Rifle").
function M.weapon_run_location_id_by_name(island_num, weapon_name, rank)
    local key = name_to_key(weapon_name)
    local idx = id_maps.weapon and id_maps.weapon[key]
    if not idx then return nil end
    return equipment_run_id(region_of("weapon_run"), #id_lists.weapon, island_num, idx, rank)
end

--- Get location ID for melee run by clean name (e.g. "Hammer").
function M.melee_run_location_id_by_name(island_num, melee_name, rank)
    local key = name_to_key(melee_name)
    local idx = id_maps.melee and id_maps.melee[key]
    if not idx then return nil end
    return equipment_run_id(region_of("melee_run"), #id_lists.melee, island_num, idx, rank)
end

--- Get location ID for ability run by clean name (e.g. "Grenade").
function M.ability_run_location_id_by_name(island_num, ability_name, rank)
    local key = name_to_key(ability_name)
    local idx = id_maps.ability and id_maps.ability[key]
    if not idx then return nil end
    return equipment_run_id(region_of("ability_run"), #id_lists.ability, island_num, idx, rank)
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

-- Expose name lists for other modules (e.g., pre-allowing non-pool equipment,
-- or pre-allowing items not in a pickup subset).
M.weapon_names = weapon_names
M.melee_names = melee_names
M.ability_names = ability_names
M.perk_names = perk_names
M.relic_names = relic_names
M.weapon_mod_names = weapon_mod_names
M.melee_mod_names = melee_mod_names
M.ability_mod_names = ability_mod_names

-- Map kind string -> name list (handy for iteration).
M.PICKUP_NAMES_BY_KIND = {
    perk        = perk_names,
    relic       = relic_names,
    weapon_mod  = weapon_mod_names,
    melee_mod   = melee_mod_names,
    ability_mod = ability_mod_names,
}

return M
