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
    TRAP = 12
    BIOME = 13


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
# Perks  (cc_code 1–116)  — stackable
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
    # Added in the 2.0 update
    "Charger", "Giant Slayer", "Liquid Core", "Weightlifter",
    "Fireslide", "Golden Hammer", "Heavy Impact", "Minimalist", "Quality Shipments",
    "Tempered",
]

_perk_items = [
    CrabChampsItemData(name, i + 1, CrabChampsItemCategory.PERK)
    for i, name in enumerate(_perk_names)
]

# ──────────────────────────────────────────────
# Relics  (cc_code 200–269)  — unique (one copy each)
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
    # Added in the 2.0 update
    "AOE Ring", "Barter Ring", "Blessed Ring", "Corrupt Stocktaker",
    "Lingering Fumes", "Overcharge Ring", "Sweet Spot",
    "All You Can Eat", "Ammo Cache", "Crushing Blow", "Lucky Lock", "Mega Greed",
    "Nourishing Salvage", "Ring Of Confidence", "Ring Of Deceit", "Sand Shield", "Thrusters",
]

_relic_items = [
    CrabChampsItemData(name, 200 + i, CrabChampsItemCategory.RELIC)
    for i, name in enumerate(_relic_names)
]

# ──────────────────────────────────────────────
# Weapons  (cc_code 300–320)
# ──────────────────────────────────────────────
_weapon_names = [
    "Arcane Wand", "Auto Rifle", "Auto Shotgun", "Blade Launcher", "Burst Pistol",
    "Cluster Launcher", "Crossbow", "Dual Pistols", "Dual Shotguns", "Flamethrower",
    "Ice Staff", "Laser Cannons", "Lightning Scepter", "Marksman Rifle", "Minigun",
    "Orb Launcher", "Poison Cannon", "Rocket Launcher", "Seagle", "Sniper",
    # Added in the 2.0 update
    "Popcorn Shotgun",
]

_weapon_items = [
    CrabChampsItemData(name, 300 + i, CrabChampsItemCategory.WEAPON)
    for i, name in enumerate(_weapon_names)
]

# ──────────────────────────────────────────────
# Abilities  (cc_code 400–408)
# ──────────────────────────────────────────────
_ability_names = [
    "Air Strike", "Black Hole", "Electro Globe", "Grappling Hook",
    "Grenade", "Ice Blast", "Laser Beam",
    # Added in the 2.0 update
    "Boomerang", "Tornado",
]

_ability_items = [
    CrabChampsItemData(name, 400 + i, CrabChampsItemCategory.ABILITY)
    for i, name in enumerate(_ability_names)
]

# ──────────────────────────────────────────────
# Melee Weapons  (cc_code 500–505)
# ──────────────────────────────────────────────
_melee_names = [
    "Claw", "Dagger", "Hammer", "Katana", "Pickaxe",
    # Added in the 2.0 update
    "Baseball Bat",
]

_melee_items = [
    CrabChampsItemData(name, 500 + i, CrabChampsItemCategory.MELEE)
    for i, name in enumerate(_melee_names)
]

# ──────────────────────────────────────────────
# Weapon Mods  (cc_code 600–692)  — stackable
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
    # Added in the 2.0 update
    "Full Focus", "Popcorn Shot", "Tornado Shot",
]

_weapon_mod_items = [
    CrabChampsItemData(name, 600 + i, CrabChampsItemCategory.WEAPON_MOD)
    for i, name in enumerate(_weapon_mod_names)
]

# ──────────────────────────────────────────────
# Melee Mods  (cc_code 700–716)  — stackable
# ──────────────────────────────────────────────
_melee_mod_names = [
    "Arcane Claws", "Big Claws", "Blender", "Brawler", "Fire Claws",
    "Ice Claws", "Iron Claws", "Lightning Claws", "Poison Claws", "Sharp Claws",
    "Time Claws", "Vampire",
    # Added in the 2.0 update
    "Crystal Claws", "Hard Landing", "Knockback Claws", "Potent Claws", "Prismatic Claws",
]

_melee_mod_items = [
    CrabChampsItemData(name, 700 + i, CrabChampsItemCategory.MELEE_MOD)
    for i, name in enumerate(_melee_mod_names)
]

# ──────────────────────────────────────────────
# Ability Mods  (cc_code 800–844)  — stackable
# Note: "Spike Strike" is renamed to "Spike Strike (Ability)"
# to avoid collision with the weapon mod of the same name.
# ──────────────────────────────────────────────
_ability_mod_names = [
    "Barrel Explosion", "Beam Turret", "Big Ability", "Bigger Boom",
    "Bomb Explosion", "Bouncing Explosion", "Bubble Blast", "Chaotic Explosion", "Clone Explosion",
    "Crystal Barrage", "Crystal Strike", "Dagger Blast", "Damage Explosion", "Energy Ring",
    "Fire Explosion", "Firework Explosion", "Giant Drill", "Glue Explosion", "Grenadier",
    "Heat Sink", "Ice Explosion", "Imploding Explosion", "Iron Explosion", "Landmine Explosion",
    "Layered Explosion", "Lightning Explosion", "Mortar Turret", "Poison Explosion", "Scythe Vortex",
    "Sentry Turret", "Sniper Turret", "Spark Explosion", "Spike Strike (Ability)", "Spinning Blade",
    "Split Ability", "Spore Explosion", "Targeting Explosion", "Thorn Explosion", "Time Explosion",
    "Triple Ability", "Ultra Mushroom", "Wave Turret",
    # Added in the 2.0 update
    "Fast Ability", "Homing Ability", "Orbiting Ability",
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

# ──────────────────────────────────────────────
# Perk boost filler  (cc_code 970)
# ──────────────────────────────────────────────
_boost_items = [
    CrabChampsItemData("Perk Boost", 970, CrabChampsItemCategory.FILLER),            # +1 level on a perk you hold
]

# ──────────────────────────────────────────────
# Traps  (cc_code 960–967).  Every effect is temporary.
# ──────────────────────────────────────────────
_trap_items = [
    CrabChampsItemData("Crystal Tax", 960, CrabChampsItemCategory.TRAP),             # lose a share of your crystals
    CrabChampsItemData("Slowdown Trap", 961, CrabChampsItemCategory.TRAP),           # slower for one island
    CrabChampsItemData("Weak Shots Trap", 962, CrabChampsItemCategory.TRAP),         # outgoing damage cut for a while
    CrabChampsItemData("Bruise Trap", 963, CrabChampsItemCategory.TRAP),            # lose a share of current health
    CrabChampsItemData("Grow Trap", 964, CrabChampsItemCategory.TRAP),              # bigger crab for a while
    CrabChampsItemData("Shrink Trap", 965, CrabChampsItemCategory.TRAP),            # smaller crab for a while
    CrabChampsItemData("Heavy Gravity Trap", 966, CrabChampsItemCategory.TRAP),     # stronger gravity for a while
    CrabChampsItemData("Floaty Gravity Trap", 967, CrabChampsItemCategory.TRAP),    # weaker gravity for a while
]

# ──────────────────────────────────────────────
# Biome access  (cc_code 980–983), one per biome in the game's own order
# (Tropical 1, Ice 2, Desert 3, Volcano 4).  Only used with biome_lock.
# ──────────────────────────────────────────────
_biome_items = [
    CrabChampsItemData("Tropical Access", 980, CrabChampsItemCategory.BIOME),
    CrabChampsItemData("Ice Access", 981, CrabChampsItemCategory.BIOME),
    CrabChampsItemData("Desert Access", 982, CrabChampsItemCategory.BIOME),
    CrabChampsItemData("Volcano Access", 983, CrabChampsItemCategory.BIOME),
]

# Trap item names in a fixed order (the keys of the Trap Weights option)
TRAP_NAMES = [item.name for item in _trap_items]

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
    + _trap_items
    + _boost_items
    + _biome_items
)

item_descriptions: Dict[str, str] = {
    item.name: "Lets your runs enter the " + item.name.split()[0] + " biome."
    for item in _biome_items
}

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

# Biome names and access items, indexed by the game's biome number minus one.
BIOME_NAMES = ["Tropical", "Ice", "Desert", "Volcano"]
biome_access_item_names = [item.name for item in _biome_items]

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
    # Added in the 2.0 update
    "Crushing Blow", "Mega Greed",
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
    # Armor
    "Power Armor": ["Ethereal Armor", "Nourishing Salvage", "Ring Of Armor",
                    "Ring Of Regenerating Armor"],
    "Tempered": ["Ethereal Armor", "Nourishing Salvage", "Ring Of Armor",
                 "Ring Of Regenerating Armor"],
    # Healing
    "Amber Resin": ["Endurance", "Grim Reaper", "Health Shot", "Liquid Core",
                    "Regenerator", "Ring Of Healing", "Scavenger", "Vampire"],
    # HighHealth
    "Ring Of Deceit": ["Crushing Blow", "Vitality"],
    # Block
    "Ring Of Confidence": ["Bulletproof", "Ring Of Deflection", "Survivor"],
    # DamageOverTime
    "Time Ring": ["Time Bolt", "Time Claws", "Time Explosion", "Time Shot"],
    # Critical
    "Critical Arrow": ["Full Focus", "Hot Shot", "Ring Of Wisdom", "Sharpshooter"],
    "Critical Blast": ["Full Focus", "Hot Shot", "Ring Of Wisdom", "Sharpshooter"],
    "Critical Lightning": ["Full Focus", "Hot Shot", "Ring Of Wisdom", "Sharpshooter"],
    "Critical Thinking": ["Full Focus", "Hot Shot", "Ring Of Wisdom", "Sharpshooter"],
    "Mega Crit": ["Full Focus", "Hot Shot", "Ring Of Wisdom", "Sharpshooter"],
    "Overspill Goblet": ["Full Focus", "Hot Shot", "Ring Of Wisdom", "Sharpshooter"],
    "Power Punch": ["Full Focus", "Hot Shot", "Ring Of Wisdom", "Sharpshooter"],
    "Ring Of Precision": ["Full Focus", "Hot Shot", "Ring Of Wisdom", "Sharpshooter"],
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
                  "Fire Storm", "Fire Strike", "Fireball Shot", "Fireslide",
                  "Flammable Armor", "Flammable Enemies"],
    "Firestarter": ["Fire Aura", "Fire Claws", "Fire Explosion", "Fire Shot",
                    "Fire Storm", "Fire Strike", "Fireball Shot", "Fireslide",
                    "Flammable Armor", "Flammable Enemies"],
    "Hot Steam": ["Fire Aura", "Fire Claws", "Fire Explosion", "Fire Shot",
                  "Fire Storm", "Fire Strike", "Fireball Shot", "Fireslide",
                  "Flammable Armor", "Flammable Enemies"],
    # Lightning
    "High Voltage": ["Electric Enemies", "Lightning Aura", "Lightning Claws",
                     "Lightning Dash", "Lightning Explosion", "Lightning Shot",
                     "Lightning Storm", "Lightning Strike"],
    "Lightning Ring": ["Electric Enemies", "Lightning Aura", "Lightning Claws",
                       "Lightning Dash", "Lightning Explosion", "Lightning Shot",
                       "Lightning Storm", "Lightning Strike"],
    # Poison
    "Lingering Fumes": ["Poison Aura", "Poison Claws", "Poison Explosion",
                        "Poison Shot", "Poison Storm", "Poison Strike",
                        "Poisonous Armor", "Poisonous Enemies"],
    "Poison Ring": ["Poison Aura", "Poison Claws", "Poison Explosion", "Poison Shot",
                    "Poison Storm", "Poison Strike", "Poisonous Armor",
                    "Poisonous Enemies"],
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
    "Twin Ring": ["Beam Turret", "Mortar Turret", "Sentry Turret", "Sniper Turret",
                  "Wave Turret"],
    # Combo
    "Combo Ring": ["Crystal Combo", "Damage Combo"],
    # GlueShot
    "Aura Shot": ["Glue Shot"],
    # Charger
    "Overcharge Ring": ["Charger"],
}

# Set of all item names that provide tags (must be progression for state.has() to work)
TAG_PROVIDER_NAMES: frozenset = frozenset(
    name for providers in PICKUP_TAG_REQUIREMENTS.values() for name in providers
)

# Per-run inventory caps for pickup categories.
# Used by the LimitPickupPool / LimitPickupLocations options.
PICKUP_INVENTORY_CAPS: Dict[str, int] = {
    "perk": 24,
    "weapon_mod": 24,
    "ability_mod": 12,
    "melee_mod": 12,
    "relic": 10,
}


def select_pickup_subsets(rng, exclude_names: frozenset = frozenset()
                          ) -> Dict[str, List[str]]:
    """Randomly choose a per-category subset of pickup items, sized to the
    inventory caps in PICKUP_INVENTORY_CAPS.

    Tag-group coverage is enforced: at least one provider per pickup-tag
    group is guaranteed to be included so tag-gated locations stay reachable.

    Items in `exclude_names` (e.g. greed items when greed_item_mode == skip)
    are removed from the eligible candidates before sampling.

    Returns a dict mapping category key -> sorted list of chosen item names.
    """
    # Map category key -> (full population list, item-category)
    populations = {
        "perk": (perk_item_names, CrabChampsItemCategory.PERK),
        "weapon_mod": (weapon_mod_item_names, CrabChampsItemCategory.WEAPON_MOD),
        "ability_mod": (ability_mod_item_names, CrabChampsItemCategory.ABILITY_MOD),
        "melee_mod": (melee_mod_item_names, CrabChampsItemCategory.MELEE_MOD),
        "relic": (relic_item_names, CrabChampsItemCategory.RELIC),
    }

    # Build category-key for each provider name once.
    name_to_cat_key: Dict[str, str] = {}
    for cat_key, (names, _) in populations.items():
        for n in names:
            name_to_cat_key[n] = cat_key

    chosen: Dict[str, set] = {key: set() for key in populations}

    # 1. Tag-group coverage pass: pick one provider per tag group, into the
    #    appropriate category.  If a group has multiple providers in
    #    different categories, pick one that fits (whichever the rng grabs
    #    first that hasn't already been chosen).
    for providers in PICKUP_TAG_REQUIREMENTS.values():
        eligible = [p for p in providers if p in name_to_cat_key
                    and p not in exclude_names]
        if not eligible:
            continue
        # If any provider is already chosen for its tag group, this group is
        # already covered.
        if any(p in chosen[name_to_cat_key[p]] for p in eligible):
            continue
        # Pick a random provider whose category still has room.
        rng.shuffle(eligible)
        picked = None
        for p in eligible:
            cat_key = name_to_cat_key[p]
            cap = PICKUP_INVENTORY_CAPS[cat_key]
            if len(chosen[cat_key]) < cap:
                picked = p
                chosen[cat_key].add(p)
                break
        # If every category is already at cap, we have to overrun the cap
        # to keep coverage.  Pick anyway — better to slightly exceed cap
        # than to leave a tag-gated location unreachable.
        if picked is None:
            p = eligible[0]
            chosen[name_to_cat_key[p]].add(p)

    # 2. Random fill pass: for each category, fill remaining slots from
    #    candidates not yet chosen.
    for cat_key, (names, _) in populations.items():
        cap = PICKUP_INVENTORY_CAPS[cat_key]
        remaining = cap - len(chosen[cat_key])
        if remaining <= 0:
            continue
        candidates = [n for n in names
                      if n not in chosen[cat_key] and n not in exclude_names]
        if remaining >= len(candidates):
            chosen[cat_key].update(candidates)
        else:
            chosen[cat_key].update(rng.sample(candidates, remaining))

    return {key: sorted(names) for key, names in chosen.items()}


def BuildItemPool(multiworld, count, options,
                  pool_weapons=None, pool_melee=None, pool_abilities=None,
                  exclude_names=None,
                  pickup_subsets=None,
                  skip_equipment=None) -> List[CrabChampsItemData]:
    """Build an item pool of exactly `count` items, respecting options.

    Pool construction order:
      1. Pool equipment: weapons, melee, abilities selected for AP randomization
      2. Guaranteed items (from options)
      3. Relics (one copy each — relics don't stack)
      4. One copy of every stackable item (perks, weapon mods, melee mods)
      5. Distribute remaining slots evenly across stackable items
         so no single item dominates the pool.

    Items in `exclude_names` (e.g., greed items when greed_item_mode == skip)
    are excluded from steps 3-5.

    `pickup_subsets`: optional dict mapping category key (perk/weapon_mod/
    ability_mod/melee_mod/relic) -> list of allowed item names.  When provided,
    only those items participate in steps 3-5; other pickups are not added.

    `skip_equipment`: optional set of pool equipment names the player already
    holds (precollected starting equipment).  These are left out of step 1 so
    the player is not sent a second copy of something they start with; the
    freed slots go to filler in the final step.
    """
    if pool_weapons is None:
        pool_weapons = []
    if pool_melee is None:
        pool_melee = []
    if pool_abilities is None:
        pool_abilities = []
    if exclude_names is None:
        exclude_names = frozenset()
    if skip_equipment is None:
        skip_equipment = frozenset()

    # Resolve which pickup items are eligible.  When subsets are provided,
    # only items in the subset for each category are eligible.
    if pickup_subsets is not None:
        allowed_pickups = set()
        for names in pickup_subsets.values():
            allowed_pickups.update(names)
    else:
        allowed_pickups = None  # no restriction

    item_pool: List[CrabChampsItemData] = []
    pool_names: List[str] = []  # parallel tracker for fast lookups

    def _add(item: CrabChampsItemData):
        item_pool.append(item)
        pool_names.append(item.name)

    # 1. Pool equipment: only the randomly-selected subset becomes AP items.
    #    Added first so the final trim can never drop progression.
    #    Precollected starting equipment is skipped — the player already has
    #    it, so a second copy would waste a location on a no-op item.
    for name in pool_weapons + pool_melee + pool_abilities:
        if name in skip_equipment:
            continue
        if name not in pool_names:
            _add(item_dictionary[name])

    # 2. Guaranteed items from options, at the requested copy count.  Only
    #    stackable items take extra copies; relics and equipment are unique.
    stackable_names = {item.name for item in _stackable_items}
    for item_name, copies in options.guaranteed_items.value.items():
        item = item_dictionary.get(item_name)
        if item is None or item_name in exclude_names:
            continue
        if item_name not in stackable_names:
            if item_name not in pool_names:
                _add(item)
            continue
        for _ in range(min(max(0, int(copies)), count + 1)):
            _add(item)

    n_fixed = len(item_pool)  # equipment and guaranteed items: never dropped
    if n_fixed > count:
        from Options import OptionError
        raise OptionError(
            "Crab Champions: the equipment and Guaranteed Items alone need %d item slots but there are only "
            "%d checks. Lower the Guaranteed Items copies or turn on more checks." % (n_fixed, count))

    # 3. Relics — one copy each (they don't stack).
    #    Skip relics not in the chosen subset when limited.
    for item in _relic_items:
        if item.name in pool_names or item.name in exclude_names:
            continue
        if allowed_pickups is not None and item.name not in allowed_pickups:
            continue
        _add(item)

    # 4. One copy of every stackable item not yet in pool.
    #    Skip stackable items not in the chosen subset when limited.
    for item in _stackable_items:
        if item.name in pool_names or item.name in exclude_names:
            continue
        if allowed_pickups is not None and item.name not in allowed_pickups:
            continue
        _add(item)

    if len(item_pool) > count:
        # A small world (few checks) cannot hold one of every pickup: keep a
        # random part of them rather than the first ones in the lists.
        fixed, pickups = item_pool[:n_fixed], item_pool[n_fixed:]
        item_pool = fixed + multiworld.random.sample(pickups, count - n_fixed)
        pool_names = [i.name for i in item_pool]

    remaining = count - len(item_pool)

    # 5a. Traps and Perk Boosts take their share of the remaining slots first.
    #     Traps: trap_percentage of the slots, kind chosen by the weight options.
    #     Perk Boosts: perk_boost_count, never more than the slots left.
    trap_pct = getattr(options, "trap_percentage", None)
    trap_pct = trap_pct.value if trap_pct is not None else 0
    weight_opt = getattr(options, "trap_weights", None)
    given = weight_opt.value if weight_opt is not None else {}
    trap_names = [n for n in TRAP_NAMES if given.get(n, 0) > 0]
    trap_weights = [given[n] for n in trap_names]
    if remaining > 0 and trap_pct > 0 and trap_names:
        trap_slots = min(remaining, round(remaining * trap_pct / 100))
        for name in multiworld.random.choices(trap_names, weights=trap_weights, k=trap_slots):
            _add(item_dictionary[name])
        remaining -= trap_slots
    boost_opt = getattr(options, "perk_boost_count", None)
    boost_count = boost_opt.value if boost_opt is not None else 0
    if remaining > 0 and boost_count > 0:
        boost_slots = min(remaining, boost_count)
        for _ in range(boost_slots):
            _add(item_dictionary["Perk Boost"])
        remaining -= boost_slots

    # 5. Split remaining slots between Crystal Cache filler and extra stackable items.
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

        # Distribute stackable slots evenly across stackable items.
        # When limited, only chosen stackables are eligible for duplication.
        if stackable_slots > 0:
            eligible_stackable = [
                it for it in _stackable_items
                if it.name not in exclude_names
                and (allowed_pickups is None or it.name in allowed_pickups)
            ]
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
