from enum import IntEnum
from typing import NamedTuple, List, Dict
from BaseClasses import Item
import math


class CrabChampsItemCategory(IntEnum):
    SKIP = 0
    EVENT = 1
    PERK = 2
    RELIC = 3
    WEAPON = 4
    ABILITY = 5
    MELEE = 6
    WEAPON_MOD = 7
    MELEE_MOD = 8
    ABILITY_MOD = 9
    FILLER = 10
    SLOT = 11


class CrabChampsItemData(NamedTuple):
    name: str
    cc_code: int
    category: CrabChampsItemCategory


class CrabChampsItem(Item):
    game: str = "Crab Champions"

    @staticmethod
    def get_name_to_id() -> dict:
        base_id = 1890000
        return {item_data.name: (base_id + item_data.cc_code if item_data.cc_code is not None else None)
                for item_data in _all_items}


# Items that gate progression
key_item_names = set()

# ──────────────────────────────────────────────
# Perks  (cc_code 1–107)  — stackable
# ──────────────────────────────────────────────
_perk_names = [
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
]

_perk_items = [
    CrabChampsItemData(name, i + 1, CrabChampsItemCategory.PERK)
    for i, name in enumerate(_perk_names)
]

# ──────────────────────────────────────────────
# Relics  (cc_code 200–252)  — unique (one copy each)
# ──────────────────────────────────────────────
_relic_names = [
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
]

_relic_items = [
    CrabChampsItemData(name, 200 + i, CrabChampsItemCategory.RELIC)
    for i, name in enumerate(_relic_names)
]

# ──────────────────────────────────────────────
# Weapons  (cc_code 300–319)
# ──────────────────────────────────────────────
_weapon_names = [
    "Arcane Wand", "Auto Rifle", "Auto Shotgun", "Blade Launcher", "Burst Pistol",
    "Cluster Launcher", "Crossbow", "Dual Pistols", "Dual Shotguns", "Flamethrower",
    "Ice Staff", "Laser Cannons", "Lightning Scepter", "Marksman Rifle", "Minigun",
    "Orb Launcher", "Poison Cannon", "Rocket Launcher", "Seagle", "Sniper",
]

_weapon_items = [
    CrabChampsItemData(name, 300 + i, CrabChampsItemCategory.WEAPON)
    for i, name in enumerate(_weapon_names)
]

# ──────────────────────────────────────────────
# Abilities  (cc_code 400–406)
# ──────────────────────────────────────────────
_ability_names = [
    "Air Strike", "Black Hole", "Electro Globe", "Grappling Hook",
    "Grenade", "Ice Blast", "Laser Beam",
]

_ability_items = [
    CrabChampsItemData(name, 400 + i, CrabChampsItemCategory.ABILITY)
    for i, name in enumerate(_ability_names)
]

# ──────────────────────────────────────────────
# Melee Weapons  (cc_code 500–504)
# ──────────────────────────────────────────────
_melee_names = [
    "Claw", "Dagger", "Hammer", "Katana", "Pickaxe",
]

_melee_items = [
    CrabChampsItemData(name, 500 + i, CrabChampsItemCategory.MELEE)
    for i, name in enumerate(_melee_names)
]

# ──────────────────────────────────────────────
# Weapon Mods  (cc_code 600–689)  — stackable
# ──────────────────────────────────────────────
_weapon_mod_names = [
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
]

_weapon_mod_items = [
    CrabChampsItemData(name, 600 + i, CrabChampsItemCategory.WEAPON_MOD)
    for i, name in enumerate(_weapon_mod_names)
]

# ──────────────────────────────────────────────
# Melee Mods  (cc_code 700–711)  — stackable
# ──────────────────────────────────────────────
_melee_mod_names = [
    "Arcane Claws", "Big Claws", "Blender", "Brawler", "Fire Claws",
    "Ice Claws", "Iron Claws", "Lightning Claws", "Poison Claws", "Sharp Claws",
    "Time Claws", "Vampire",
]

_melee_mod_items = [
    CrabChampsItemData(name, 700 + i, CrabChampsItemCategory.MELEE_MOD)
    for i, name in enumerate(_melee_mod_names)
]

# ──────────────────────────────────────────────
# Ability Mods  (cc_code 800–842)  — stackable
# Note: "Spike Strike" is renamed to "Spike Strike (Ability)"
# to avoid collision with the weapon mod of the same name.
# ──────────────────────────────────────────────
_ability_mod_names = [
    "Aura Explosion", "Barrel Explosion", "Beam Turret", "Big Ability", "Bigger Boom",
    "Bomb Explosion", "Bouncing Explosion", "Bubble Blast", "Chaotic Explosion", "Clone Explosion",
    "Crystal Barrage", "Crystal Strike", "Dagger Blast", "Damage Explosion", "Energy Ring",
    "Fire Explosion", "Firework Explosion", "Giant Drill", "Glue Explosion", "Grenadier",
    "Heat Sink", "Ice Explosion", "Imploding Explosion", "Iron Explosion", "Landmine Explosion",
    "Layered Explosion", "Lightning Explosion", "Mortar Turret", "Poison Explosion", "Scythe Vortex",
    "Sentry Turret", "Sniper Turret", "Spark Explosion", "Spike Strike (Ability)", "Spinning Blade",
    "Split Ability", "Spore Explosion", "Targeting Explosion", "Thorn Explosion", "Time Explosion",
    "Triple Ability", "Ultra Mushroom", "Wave Turret",
]

_ability_mod_items = [
    CrabChampsItemData(name, 800 + i, CrabChampsItemCategory.ABILITY_MOD)
    for i, name in enumerate(_ability_mod_names)
]

# ──────────────────────────────────────────────
# Events & Filler  (cc_code 900+, 1000)
# ──────────────────────────────────────────────
_event_items = [
    CrabChampsItemData("Victory", 1000, CrabChampsItemCategory.EVENT),
]

_filler_items = [
    CrabChampsItemData("Crystal Cache", 900, CrabChampsItemCategory.FILLER),        # 50 crystals
    CrabChampsItemData("Nothing", 901, CrabChampsItemCategory.FILLER),
    CrabChampsItemData("Crystal Hoard", 902, CrabChampsItemCategory.FILLER),         # 100 crystals
    CrabChampsItemData("Crystal Jackpot", 903, CrabChampsItemCategory.FILLER),       # 500 crystals
]

# ──────────────────────────────────────────────
# Slot items  (cc_code 950–953)
# ──────────────────────────────────────────────
_slot_items = [
    CrabChampsItemData("Progressive Perk Slot", 950, CrabChampsItemCategory.SLOT),
    CrabChampsItemData("Progressive Weapon Mod Slot", 951, CrabChampsItemCategory.SLOT),
    CrabChampsItemData("Progressive Ability Mod Slot", 952, CrabChampsItemCategory.SLOT),
    CrabChampsItemData("Progressive Melee Mod Slot", 953, CrabChampsItemCategory.SLOT),
]

# Crystal filler distribution weights (must sum to 100)
CRYSTAL_FILLER_WEIGHTS = [
    ("Crystal Cache", 60),      # 50 crystals   — 60%
    ("Crystal Hoard", 35),      # 100 crystals  — 35%
    ("Crystal Jackpot", 5),     # 500 crystals  —  5%
]

# ──────────────────────────────────────────────
# Combined item list
# ──────────────────────────────────────────────
_all_items: List[CrabChampsItemData] = (
    _perk_items
    + _relic_items
    + _weapon_items
    + _ability_items
    + _melee_items
    + _weapon_mod_items
    + _melee_mod_items
    + _ability_mod_items
    + _event_items
    + _filler_items
    + _slot_items
)

item_descriptions: Dict[str, str] = {}

item_dictionary: Dict[str, CrabChampsItemData] = {item.name: item for item in _all_items}

# Convenience lookups
perk_item_names = [item.name for item in _perk_items]
relic_item_names = [item.name for item in _relic_items]
weapon_item_names = [item.name for item in _weapon_items]
ability_item_names = [item.name for item in _ability_items]
melee_item_names = [item.name for item in _melee_items]
weapon_mod_item_names = [item.name for item in _weapon_mod_items]
melee_mod_item_names = [item.name for item in _melee_mod_items]
ability_mod_item_names = [item.name for item in _ability_mod_items]

# Greed items: cannot be dropped once picked up.
# When greed_item_mode == "skip", these are excluded from the item/location pools.
GREED_ITEM_NAMES: frozenset = frozenset({
    # Perks
    "Big Bones", "Bribe", "Brute Force", "Damage Seeker", "Double Trouble",
    "Glass Cannon", "Juggernaut", "Leap Of Faith", "Limited Loot", "Rising Star",
    "Slippery Slope", "Up The Ante", "Workaholic",
    # Relics
    "High Roller", "Hoarder Backpack", "Overspill Goblet", "Ring Of Favoritism",
    "Ring Of Tankiness", "Trigger Ring", "Upgrade Ring",
    # Melee Mods
    "Brawler",
})

# Stackable categories: perks, weapon mods, melee mods, ability mods
# These items can appear more than once in the pool.
_stackable_items: List[CrabChampsItemData] = (
    _perk_items + _weapon_mod_items + _melee_mod_items + _ability_mod_items
)


# ──────────────────────────────────────────────
# Pickup tag prerequisites
# ──────────────────────────────────────────────
# Items that require the player to already have an item with a matching PickupTag.
# Key = item that REQUIRES the tag (its pickup location gets an access rule)
# Value = list of items that PROVIDE the tag (player needs any one of these)
PICKUP_TAG_REQUIREMENTS: Dict[str, List[str]] = {
    # Healing
    "Amber Resin": ["Endurance", "Grim Reaper", "Health Shot", "Regenerator",
                     "Ring Of Healing", "Scavenger", "Vampire"],
    # DamageOverTime
    "Time Ring": ["Time Bolt", "Time Claws", "Time Explosion", "Time Shot"],
    # Critical
    "Critical Arrow": ["Hot Shot", "Ring Of Wisdom", "Sharpshooter"],
    "Critical Blast": ["Hot Shot", "Ring Of Wisdom", "Sharpshooter"],
    "Critical Lightning": ["Hot Shot", "Ring Of Wisdom", "Sharpshooter"],
    "Critical Thinking": ["Hot Shot", "Ring Of Wisdom", "Sharpshooter"],
    "Mega Crit": ["Hot Shot", "Ring Of Wisdom", "Sharpshooter"],
    "Overspill Goblet": ["Hot Shot", "Ring Of Wisdom", "Sharpshooter"],
    "Power Punch": ["Hot Shot", "Ring Of Wisdom", "Sharpshooter"],
    "Ring Of Precision": ["Hot Shot", "Ring Of Wisdom", "Sharpshooter"],
    # Speed
    "Speed Is Power": ["Ring Of Swiftness", "Speed Demon"],
    # Bounce
    "Heavy Shot": ["Bouncing Shot"],
    # Ice
    "Ice Cold": ["Freezing Enemies", "Ice Aura", "Ice Claws", "Ice Dash",
                  "Ice Explosion", "Ice Shot", "Ice Storm", "Ice Strike"],
    "Ice Ring": ["Freezing Enemies", "Ice Aura", "Ice Claws", "Ice Dash",
                  "Ice Explosion", "Ice Shot", "Ice Storm", "Ice Strike"],
    "Icebreaker": ["Freezing Enemies", "Ice Aura", "Ice Claws", "Ice Dash",
                    "Ice Explosion", "Ice Shot", "Ice Storm", "Ice Strike"],
    # Fire
    "Fire Ring": ["Fire Aura", "Fire Claws", "Fire Explosion", "Fire Shot",
                   "Fire Storm", "Fire Strike", "Fireball Shot", "Flammable Armor",
                   "Flammable Enemies", "Powerslide"],
    "Firestarter": ["Fire Aura", "Fire Claws", "Fire Explosion", "Fire Shot",
                     "Fire Storm", "Fire Strike", "Fireball Shot", "Flammable Armor",
                     "Flammable Enemies", "Powerslide"],
    "Hot Steam": ["Fire Aura", "Fire Claws", "Fire Explosion", "Fire Shot",
                   "Fire Storm", "Fire Strike", "Fireball Shot", "Flammable Armor",
                   "Flammable Enemies", "Powerslide"],
    # Lightning
    "High Voltage": ["Electric Enemies", "Lightning Aura", "Lightning Claws",
                      "Lightning Dash", "Lightning Explosion", "Lightning Shot",
                      "Lightning Storm", "Lightning Strike"],
    "Lightning Ring": ["Electric Enemies", "Lightning Aura", "Lightning Claws",
                        "Lightning Dash", "Lightning Explosion", "Lightning Shot",
                        "Lightning Storm", "Lightning Strike"],
    # Poison
    "Poison Ring": ["Poison Aura", "Poison Claws", "Poison Explosion", "Poison Shot",
                     "Poison Storm", "Poison Strike", "Poisonous Armor", "Poisonous Enemies"],
    "Toxic": ["Poison Aura", "Poison Claws", "Poison Explosion", "Poison Shot",
               "Poison Storm", "Poison Strike", "Poisonous Armor", "Poisonous Enemies"],
    # Arcane
    "Arcane Ring": ["Arcane Claws", "Arcane Shot"],
    "Potent Magic": ["Arcane Claws", "Arcane Shot"],
    # Turret
    "Enhanced Turrets": ["Beam Turret", "Mortar Turret", "Sentry Turret",
                          "Sniper Turret", "Wave Turret"],
    "Ring Of Healthy Turrets": ["Beam Turret", "Mortar Turret", "Sentry Turret",
                                 "Sniper Turret", "Wave Turret"],
    "Twin Ring": ["Beam Turret", "Mortar Turret", "Sentry Turret",
                   "Sniper Turret", "Wave Turret"],
    # Combo
    "Combo Ring": ["Crystal Combo", "Damage Combo"],
    # GlueShot
    "Aura Shot": ["Glue Shot"],
}

# Set of all item names that provide tags (must be progression for state.has() to work)
TAG_PROVIDER_NAMES: frozenset = frozenset(
    name for providers in PICKUP_TAG_REQUIREMENTS.values() for name in providers
)


def BuildItemPool(multiworld, count, options,
                  pool_weapons=None, pool_melee=None, pool_abilities=None,
                  exclude_names=None) -> List[CrabChampsItemData]:
    """Build an item pool of exactly `count` items, respecting options.

    Pool construction order:
      1. Guaranteed items (from options)
      2. Pool equipment: weapons, melee, abilities selected for AP randomization
      3. Relics (one copy each — relics don't stack)
      4. One copy of every stackable item (perks, weapon mods, melee mods)
      5. Distribute remaining slots evenly across stackable items
         so no single item dominates the pool.

    Items in `exclude_names` (e.g., greed items when greed_item_mode == skip)
    are excluded from steps 3-5.
    """
    if pool_weapons is None:
        pool_weapons = []
    if pool_melee is None:
        pool_melee = []
    if pool_abilities is None:
        pool_abilities = []
    if exclude_names is None:
        exclude_names = frozenset()

    item_pool: List[CrabChampsItemData] = []
    pool_names: List[str] = []  # parallel tracker for fast lookups

    def _add(item: CrabChampsItemData):
        item_pool.append(item)
        pool_names.append(item.name)

    # 1. Guaranteed items from options
    if options.guaranteed_items.value:
        for item_name in options.guaranteed_items.value:
            if item_name in item_dictionary and item_name not in exclude_names:
                _add(item_dictionary[item_name])

    # 2. Pool equipment: only the randomly-selected subset becomes AP items
    for name in pool_weapons + pool_melee + pool_abilities:
        if name not in pool_names:
            _add(item_dictionary[name])

    # 4. Relics — one copy each (they don't stack)
    for item in _relic_items:
        if item.name not in pool_names and item.name not in exclude_names:
            _add(item)

    # 5. One copy of every stackable item not yet in pool
    for item in _stackable_items:
        if item.name not in pool_names and item.name not in exclude_names:
            _add(item)

    remaining = count - len(item_pool)

    # 6. Split remaining slots between Crystal Cache filler and extra stackable items.
    #    crystal_cache_percentage controls the ratio (default 50%).
    crystal_pct = getattr(options, 'crystal_cache_percentage', None)
    crystal_pct = crystal_pct.value if crystal_pct is not None else 50

    if remaining > 0:
        crystal_slots = round(remaining * crystal_pct / 100)
        stackable_slots = remaining - crystal_slots

        # Fill crystal slots using weighted distribution across crystal tiers
        # Build a list of crystal items according to weights, then trim/pad to exact count
        crystal_list = []
        for name, weight in CRYSTAL_FILLER_WEIGHTS:
            tier_count = round(crystal_slots * weight / 100)
            crystal_list.extend([item_dictionary[name]] * tier_count)
        # Adjust for rounding: trim excess or pad with common tier
        while len(crystal_list) > crystal_slots:
            crystal_list.pop()
        while len(crystal_list) < crystal_slots:
            crystal_list.append(item_dictionary["Crystal Cache"])
        for item in crystal_list:
            _add(item)

        # Distribute stackable slots evenly across stackable items
        if stackable_slots > 0:
            eligible_stackable = [it for it in _stackable_items if it.name not in exclude_names]
            stackable_count = len(eligible_stackable)
            if stackable_count > 0:
                base_copies = stackable_slots // stackable_count
                extras = stackable_slots % stackable_count

                for item in eligible_stackable:
                    for _ in range(base_copies):
                        _add(item)

                if extras > 0:
                    extra_items = list(eligible_stackable)
                    multiworld.random.shuffle(extra_items)
                    for item in extra_items[:extras]:
                        _add(item)

    # Trim if somehow over (shouldn't happen, but safety)
    item_pool = item_pool[:count]

    multiworld.random.shuffle(item_pool)
    return item_pool
