from enum import IntEnum
from typing import Optional, NamedTuple, Dict, List

from BaseClasses import Location, Region
from .Items import (
    CrabChampsItem, perk_item_names, relic_item_names, weapon_item_names,
    ability_item_names, melee_item_names, weapon_mod_item_names,
    melee_mod_item_names, ability_mod_item_names,
)


class CrabChampsLocationCategory(IntEnum):
    SKIP = 0
    EVENT = 1
    ISLAND = 2
    PERK = 3
    RELIC = 4
    RANK_RUN = 5
    WEAPON_RUN = 6
    MELEE_RUN = 7
    ABILITY_RUN = 8
    WEAPON_MOD = 9
    MELEE_MOD = 10
    ABILITY_MOD = 11
    # Ranked variants (only generated when ranked_island_checks is on)
    RANKED_ISLAND = 12
    RANKED_WEAPON_RUN = 13
    RANKED_MELEE_RUN = 14
    RANKED_ABILITY_RUN = 15


class CrabChampsLocationData(NamedTuple):
    name: str
    default_item: str
    category: CrabChampsLocationCategory


class CrabChampsLocation(Location):
    game: str = "Crab Champions"
    category: CrabChampsLocationCategory
    default_item_name: str

    def __init__(
            self,
            player: int,
            name: str,
            category: CrabChampsLocationCategory,
            default_item_name: str,
            address: Optional[int] = None,
            parent: Optional[Region] = None
    ):
        super().__init__(player, name, address, parent)
        self.default_item_name = default_item_name
        self.category = category
        self.name = name

    @staticmethod
    def get_name_to_id() -> dict:
        base_id = BASE_ID
        T = TABLE_OFFSET

        output = {}

        # Region 0: Island Completion
        # Victory at position 0
        # Unranked islands at positions 1..56
        for i in range(1, MAX_ISLANDS + 1):
            output[f"{_island_prefix(i)} {i}"] = base_id + i
        # Ranked islands at positions 57 + R*56 + (i-1)
        for r, rname in enumerate(RANK_NAMES):
            for i in range(1, MAX_ISLANDS + 1):
                output[f"{_island_prefix(i)} {i} on {rname}"] = base_id + 57 + r * MAX_ISLANDS + (i - 1)

        # Region 1: Perk Pickups
        for idx, name in enumerate(perk_item_names):
            output[f"Perk: {name}"] = base_id + T * 1 + idx

        # Region 2: Relic Pickups
        for idx, name in enumerate(relic_item_names):
            output[f"Relic: {name}"] = base_id + T * 2 + idx

        # Region 3: Rank Runs
        for r, rname in enumerate(RANK_NAMES):
            output[f"Complete Run on {rname}"] = base_id + T * 3 + r

        # Region 4: Weapon Runs
        NW = len(weapon_item_names)
        for i in range(1, MAX_ISLANDS + 1):
            pfx = _island_prefix(i)
            for wi, wname in enumerate(weapon_item_names):
                # Unranked
                output[f"{pfx} {i} with {wname}"] = (
                    base_id + T * 4 + (i - 1) * NW + wi
                )
                # Ranked
                for r, rname in enumerate(RANK_NAMES):
                    output[f"{pfx} {i} with {wname} on {rname}"] = (
                        base_id + T * 4 + NW * MAX_ISLANDS + r * NW * MAX_ISLANDS + (i - 1) * NW + wi
                    )

        # Region 5: Melee Runs
        NM = len(melee_item_names)
        for i in range(1, MAX_ISLANDS + 1):
            pfx = _island_prefix(i)
            for mi, mname in enumerate(melee_item_names):
                # Unranked
                output[f"{pfx} {i} with {mname}"] = (
                    base_id + T * 5 + (i - 1) * NM + mi
                )
                # Ranked
                for r, rname in enumerate(RANK_NAMES):
                    output[f"{pfx} {i} with {mname} on {rname}"] = (
                        base_id + T * 5 + NM * MAX_ISLANDS + r * NM * MAX_ISLANDS + (i - 1) * NM + mi
                    )

        # Region 6: Ability Runs
        NA = len(ability_item_names)
        for i in range(1, MAX_ISLANDS + 1):
            pfx = _island_prefix(i)
            for ai, aname in enumerate(ability_item_names):
                # Unranked
                output[f"{pfx} {i} with {aname}"] = (
                    base_id + T * 6 + (i - 1) * NA + ai
                )
                # Ranked
                for r, rname in enumerate(RANK_NAMES):
                    output[f"{pfx} {i} with {aname} on {rname}"] = (
                        base_id + T * 6 + NA * MAX_ISLANDS + r * NA * MAX_ISLANDS + (i - 1) * NA + ai
                    )

        # Region 7: Weapon Mod Pickups
        for idx, name in enumerate(weapon_mod_item_names):
            output[f"Weapon Mod: {name}"] = base_id + T * 7 + idx

        # Region 8: Melee Mod Pickups
        for idx, name in enumerate(melee_mod_item_names):
            output[f"Melee Mod: {name}"] = base_id + T * 8 + idx

        # Region 9: Ability Mod Pickups
        for idx, name in enumerate(ability_mod_item_names):
            output[f"Ability Mod: {name}"] = base_id + T * 9 + idx

        return output

    def place_locked_item(self, item: CrabChampsItem):
        self.item = item
        self.locked = True
        item.location = self


# ──────────────────────────────────────────────
# Constants
# ──────────────────────────────────────────────
BASE_ID = 1890000
TABLE_OFFSET = 12000
MAX_ISLANDS = 56
NUM_RANKS = 8

RANK_NAMES = ["Bronze", "Silver", "Gold", "Sapphire", "Emerald", "Ruby", "Diamond", "Prismatic"]

# Shop islands: the 6th island in each biome (no combat, just a shop).
# Pattern: first at island 6, then every 7th (6, 13, 20, 27 in cycle 1; +28 for cycle 2).
SHOP_ISLANDS = frozenset({6, 13, 20, 27, 34, 41, 48, 55})


def _island_prefix(i: int) -> str:
    """Return the location name prefix for an island number."""
    return "Reach Shop on Island" if i in SHOP_ISLANDS else "Complete Island"

# ──────────────────────────────────────────────
# Static location tables (for region creation)
# These contain ALL possible locations. Filtering happens in __init__.py.
# ──────────────────────────────────────────────

# Island Completion: Victory + 56 unranked islands
_island_locations = [
    CrabChampsLocationData("Victory", "Victory", CrabChampsLocationCategory.EVENT),
] + [
    CrabChampsLocationData(f"{_island_prefix(i)} {i}", "Crystal Cache", CrabChampsLocationCategory.ISLAND)
    for i in range(1, MAX_ISLANDS + 1)
]

# Ranked Island Completion: 8 ranks × 56 islands
_ranked_island_locations = [
    CrabChampsLocationData(
        f"{_island_prefix(i)} {i} on {rname}",
        "Crystal Cache",
        CrabChampsLocationCategory.RANKED_ISLAND,
    )
    for rname in RANK_NAMES
    for i in range(1, MAX_ISLANDS + 1)
]

# Perk Pickups
_perk_locations = [
    CrabChampsLocationData(f"Perk: {name}", "Crystal Cache", CrabChampsLocationCategory.PERK)
    for name in perk_item_names
]

# Relic Pickups
_relic_locations = [
    CrabChampsLocationData(f"Relic: {name}", "Crystal Cache", CrabChampsLocationCategory.RELIC)
    for name in relic_item_names
]

# Rank Run Completions
_rank_locations = [
    CrabChampsLocationData(f"Complete Run on {name}", "Crystal Cache", CrabChampsLocationCategory.RANK_RUN)
    for name in RANK_NAMES
]

# Weapon Island Completions (unranked)
_weapon_run_locations = [
    CrabChampsLocationData(
        f"{_island_prefix(island)} {island} with {weapon}",
        "Crystal Cache",
        CrabChampsLocationCategory.WEAPON_RUN,
    )
    for island in range(1, MAX_ISLANDS + 1)
    for weapon in weapon_item_names
]

# Weapon Island Completions (ranked)
_ranked_weapon_run_locations = [
    CrabChampsLocationData(
        f"{_island_prefix(island)} {island} with {weapon} on {rname}",
        "Crystal Cache",
        CrabChampsLocationCategory.RANKED_WEAPON_RUN,
    )
    for rname in RANK_NAMES
    for island in range(1, MAX_ISLANDS + 1)
    for weapon in weapon_item_names
]

# Melee Island Completions (unranked)
_melee_run_locations = [
    CrabChampsLocationData(
        f"{_island_prefix(island)} {island} with {melee}",
        "Crystal Cache",
        CrabChampsLocationCategory.MELEE_RUN,
    )
    for island in range(1, MAX_ISLANDS + 1)
    for melee in melee_item_names
]

# Melee Island Completions (ranked)
_ranked_melee_run_locations = [
    CrabChampsLocationData(
        f"{_island_prefix(island)} {island} with {melee} on {rname}",
        "Crystal Cache",
        CrabChampsLocationCategory.RANKED_MELEE_RUN,
    )
    for rname in RANK_NAMES
    for island in range(1, MAX_ISLANDS + 1)
    for melee in melee_item_names
]

# Ability Island Completions (unranked)
_ability_run_locations = [
    CrabChampsLocationData(
        f"{_island_prefix(island)} {island} with {ability}",
        "Crystal Cache",
        CrabChampsLocationCategory.ABILITY_RUN,
    )
    for island in range(1, MAX_ISLANDS + 1)
    for ability in ability_item_names
]

# Ability Island Completions (ranked)
_ranked_ability_run_locations = [
    CrabChampsLocationData(
        f"{_island_prefix(island)} {island} with {ability} on {rname}",
        "Crystal Cache",
        CrabChampsLocationCategory.RANKED_ABILITY_RUN,
    )
    for rname in RANK_NAMES
    for island in range(1, MAX_ISLANDS + 1)
    for ability in ability_item_names
]

# Weapon Mod Pickups
_weapon_mod_locations = [
    CrabChampsLocationData(f"Weapon Mod: {name}", "Crystal Cache", CrabChampsLocationCategory.WEAPON_MOD)
    for name in weapon_mod_item_names
]

# Melee Mod Pickups
_melee_mod_locations = [
    CrabChampsLocationData(f"Melee Mod: {name}", "Crystal Cache", CrabChampsLocationCategory.MELEE_MOD)
    for name in melee_mod_item_names
]

# Ability Mod Pickups
_ability_mod_locations = [
    CrabChampsLocationData(f"Ability Mod: {name}", "Crystal Cache", CrabChampsLocationCategory.ABILITY_MOD)
    for name in ability_mod_item_names
]

# ──────────────────────────────────────────────
# Location tables (keyed by region name)
# ──────────────────────────────────────────────
location_tables: Dict[str, List[CrabChampsLocationData]] = {
    "Island Completion": _island_locations,
    "Ranked Island Completion": _ranked_island_locations,
    "Perk Pickups": _perk_locations,
    "Relic Pickups": _relic_locations,
    "Rank Runs": _rank_locations,
    "Weapon Runs": _weapon_run_locations,
    "Ranked Weapon Runs": _ranked_weapon_run_locations,
    "Melee Runs": _melee_run_locations,
    "Ranked Melee Runs": _ranked_melee_run_locations,
    "Ability Runs": _ability_run_locations,
    "Ranked Ability Runs": _ranked_ability_run_locations,
    "Weapon Mod Pickups": _weapon_mod_locations,
    "Melee Mod Pickups": _melee_mod_locations,
    "Ability Mod Pickups": _ability_mod_locations,
}

location_dictionary: Dict[str, CrabChampsLocationData] = {}
for location_table in location_tables.values():
    location_dictionary.update({loc.name: loc for loc in location_table})


_RANK_NAME_TO_INDEX = {rname: r for r, rname in enumerate(RANK_NAMES)}


def rank_from_location_name(name: str) -> int:
    """Extract the rank index from a ranked location name, or -1 if unranked."""
    idx = name.rfind(" on ")
    if idx == -1:
        return -1
    return _RANK_NAME_TO_INDEX.get(name[idx + 4:], -1)
