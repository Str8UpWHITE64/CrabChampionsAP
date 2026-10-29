-- AP/IdLayouts.lua
-- Item and location ID tables of older seeds.
--
-- Item and location IDs are list positions (see ItemData.lua and
-- LocationData.lua), so a seed's IDs only mean something with the lists of
-- the layout it was made with. A seed names its layout in slot_data.id_layout;
-- seeds without the field are layout 1.
--
--   Layout 1: every release up to and including 1.4.0, made for the game
--             before its 2.0 update.
--   Layout 4: the current lists, kept in ItemData.lua and LocationData.lua.
--
-- Layouts 2 and 3 were never released and are not readable.
--
-- The lists here only decide IDs. What exists in the game is always the
-- current lists: items the 2.0 update added are simply not part of a
-- layout 1 seed.

local M = {}

M.CURRENT = 4

-- Layouts this client can play.
M.SUPPORTED = { [1] = true, [4] = true }

M[1] = {
    perk = {
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
    },
    relic = {
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
    },
    weapon = {
        "Arcane Wand", "Auto Rifle", "Auto Shotgun", "Blade Launcher", "Burst Pistol",
        "Cluster Launcher", "Crossbow", "Dual Pistols", "Dual Shotguns", "Flamethrower",
        "Ice Staff", "Laser Cannons", "Lightning Scepter", "Marksman Rifle", "Minigun",
        "Orb Launcher", "Poison Cannon", "Rocket Launcher", "Seagle", "Sniper",
    },
    ability = {
        "Air Strike", "Black Hole", "Electro Globe", "Grappling Hook",
        "Grenade", "Ice Blast", "Laser Beam",
    },
    melee = {
        "Claw", "Dagger", "Hammer", "Katana", "Pickaxe",
    },
    weapon_mod = {
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
    },
    melee_mod = {
        "Arcane Claws", "Big Claws", "Blender", "Brawler", "Fire Claws",
        "Ice Claws", "Iron Claws", "Lightning Claws", "Poison Claws", "Sharp Claws",
        "Time Claws", "Vampire",
    },
    ability_mod = {
        "Aura Explosion", "Barrel Explosion", "Beam Turret", "Big Ability", "Bigger Boom",
        "Bomb Explosion", "Bouncing Explosion", "Bubble Blast", "Chaotic Explosion", "Clone Explosion",
        "Crystal Barrage", "Crystal Strike", "Dagger Blast", "Damage Explosion", "Energy Ring",
        "Fire Explosion", "Firework Explosion", "Giant Drill", "Glue Explosion", "Grenadier",
        "Heat Sink", "Ice Explosion", "Imploding Explosion", "Iron Explosion", "Landmine Explosion",
        "Layered Explosion", "Lightning Explosion", "Mortar Turret", "Poison Explosion", "Scythe Vortex",
        "Sentry Turret", "Sniper Turret", "Spark Explosion", "Spike Strike", "Spinning Blade",
        "Split Ability", "Spore Explosion", "Targeting Explosion", "Thorn Explosion", "Time Explosion",
        "Triple Ability", "Ultra Mushroom", "Wave Turret",
    },

    -- Items the game has since moved to another kind: the seed's kind ->
    -- name -> the kind the game has it as now. The seed's item gives the
    -- game's item, and picking that up sends the seed's check.
    moved = {
        perk = { ["All You Can Eat"] = "relic" },
    },

    -- Items the game no longer has. Their item can't be given, and their
    -- pickup check can't be found, so the client sends it by itself.
    removed = {
        ability_mod = { ["Aura Explosion"] = true },
    },

    -- Layout 1 has no traps, Perk Boost or biome access items.
    extra_items = false,
}

--- Whether a layout can be played by this client.
function M.supported(layout)
    return M.SUPPORTED[tonumber(layout) or -1] == true
end

return M
