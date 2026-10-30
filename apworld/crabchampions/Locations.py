import re
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
    # Biome layout (check_layout = biome): the same checks keyed by
    # (biome, slot, loop) instead of island number.
    BIOME_ISLAND = 16
    RANKED_BIOME_ISLAND = 17
    BIOME_WEAPON_RUN = 18
    RANKED_BIOME_WEAPON_RUN = 19
    BIOME_MELEE_RUN = 20
    RANKED_BIOME_MELEE_RUN = 21
    BIOME_ABILITY_RUN = 22
    RANKED_BIOME_ABILITY_RUN = 23
    # Biome layout only: the goal's checks, "Complete Run with <item> on <Rank>", sent on the run's final island
    # whatever biome it is in.
    RUN_WEAPON = 24
    RUN_MELEE = 25
    RUN_ABILITY = 26


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

        # Regions 10-13: the biome layout. A check's position is its biome
        # index k = loop * 28 + (biome - 1) * 7 + (slot - 1), 0..55, used where
        # the island layout uses (island - 1).
        for k in range(MAX_ISLANDS):
            bp = biome_check_prefix(k)
            output[bp] = base_id + T * 10 + 1 + k
            for r, rname in enumerate(RANK_NAMES):
                output[f"{bp} on {rname}"] = base_id + T * 10 + 57 + r * MAX_ISLANDS + k
        for region, names in ((11, weapon_item_names), (12, melee_item_names), (13, ability_item_names)):
            n = len(names)
            for k in range(MAX_ISLANDS):
                bp = biome_check_prefix(k)
                for ei, ename in enumerate(names):
                    output[f"{bp} with {ename}"] = base_id + T * region + k * n + ei
                    for r, rname in enumerate(RANK_NAMES):
                        output[f"{bp} with {ename} on {rname}"] = (
                            base_id + T * region + n * MAX_ISLANDS + r * n * MAX_ISLANDS + k * n + ei
                        )

        # Regions 14-16: run-level equipment checks (biome layout). Position = rank * count + item index.
        for region, names in ((14, weapon_item_names), (15, melee_item_names), (16, ability_item_names)):
            for r, rname in enumerate(RANK_NAMES):
                for ei, ename in enumerate(names):
                    output[f"Complete Run with {ename} on {rname}"] = base_id + T * region + r * len(names) + ei

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
# Bump whenever an item or location ID changes. The client refuses seeds
# from any other layout instead of sending checks under the wrong IDs.
ID_LAYOUT = 4
MAX_ISLANDS = 56
NUM_RANKS = 8

RANK_NAMES = ["Bronze", "Silver", "Gold", "Sapphire", "Emerald", "Ruby", "Diamond", "Prismatic"]

# Shop islands: the 6th island in each biome (no combat, just a shop).
# Pattern: first at island 6, then every 7th (6, 13, 20, 27 in cycle 1; +28 for cycle 2).
SHOP_ISLANDS = frozenset({6, 13, 20, 27, 34, 41, 48, 55})


BIOME_NAMES = ["Tropical", "Ice", "Desert", "Volcano"]
BIOME_LENGTH = 7        # islands per biome; the 6th is the shop
BIOME_CYCLE = 28        # islands in one pass through the four biomes


def biome_check_prefix(k: int) -> str:
    """Name of the biome-layout check with index k (0..55), without rank or
    equipment: 'Complete Tropical Island 3', 'Reach Ice Shop (Loop 2)'."""
    loop, rest = divmod(k, BIOME_CYCLE)
    biome, slot = divmod(rest, BIOME_LENGTH)
    name = BIOME_NAMES[biome]
    base = f"Reach {name} Shop" if slot == 5 else f"Complete {name} Island {slot + 1}"
    return base + (" (Loop 2)" if loop else "")


_BIOME_NAME_RE = re.compile(
    r"^(?:Complete|Reach) (" + "|".join(BIOME_NAMES) + r")(?: Island (\d)| Shop)( \(Loop 2\))?(?: |$)")


def biome_index_from_name(name: str) -> int:
    """Biome-layout index (0..55) of a location name, or -1 if it is not one."""
    m = _BIOME_NAME_RE.match(name)
    if not m:
        return -1
    slot = 5 if m.group(2) is None else int(m.group(2)) - 1
    return ((BIOME_CYCLE if m.group(3) else 0) + BIOME_NAMES.index(m.group(1)) * BIOME_LENGTH + slot)


def biome_index_to_biome(k: int) -> int:
    """Game biome number (1-4) of a biome-layout index."""
    return (k % BIOME_CYCLE) // BIOME_LENGTH + 1


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

# Biome layout tables, mirroring the island tables with the biome index.
_biome_island_locations = [
    CrabChampsLocationData(biome_check_prefix(k), "Crystal Cache", CrabChampsLocationCategory.BIOME_ISLAND)
    for k in range(MAX_ISLANDS)
]
_ranked_biome_island_locations = [
    CrabChampsLocationData(f"{biome_check_prefix(k)} on {rname}", "Crystal Cache",
                           CrabChampsLocationCategory.RANKED_BIOME_ISLAND)
    for rname in RANK_NAMES
    for k in range(MAX_ISLANDS)
]


def _biome_equipment(names, plain_cat, ranked_cat):
    plain = [
        CrabChampsLocationData(f"{biome_check_prefix(k)} with {n}", "Crystal Cache", plain_cat)
        for k in range(MAX_ISLANDS) for n in names
    ]
    ranked = [
        CrabChampsLocationData(f"{biome_check_prefix(k)} with {n} on {rname}", "Crystal Cache", ranked_cat)
        for rname in RANK_NAMES for k in range(MAX_ISLANDS) for n in names
    ]
    return plain, ranked


_biome_weapon_run_locations, _ranked_biome_weapon_run_locations = _biome_equipment(
    weapon_item_names, CrabChampsLocationCategory.BIOME_WEAPON_RUN,
    CrabChampsLocationCategory.RANKED_BIOME_WEAPON_RUN)
_biome_melee_run_locations, _ranked_biome_melee_run_locations = _biome_equipment(
    melee_item_names, CrabChampsLocationCategory.BIOME_MELEE_RUN,
    CrabChampsLocationCategory.RANKED_BIOME_MELEE_RUN)
_biome_ability_run_locations, _ranked_biome_ability_run_locations = _biome_equipment(
    ability_item_names, CrabChampsLocationCategory.BIOME_ABILITY_RUN,
    CrabChampsLocationCategory.RANKED_BIOME_ABILITY_RUN)

def _run_equipment(names, cat):
    return [
        CrabChampsLocationData(f"Complete Run with {n} on {rname}", "Crystal Cache", cat)
        for rname in RANK_NAMES for n in names
    ]


_run_weapon_locations = _run_equipment(weapon_item_names, CrabChampsLocationCategory.RUN_WEAPON)
_run_melee_locations = _run_equipment(melee_item_names, CrabChampsLocationCategory.RUN_MELEE)
_run_ability_locations = _run_equipment(ability_item_names, CrabChampsLocationCategory.RUN_ABILITY)

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
    "Biome Island Completion": _biome_island_locations,
    "Ranked Biome Island Completion": _ranked_biome_island_locations,
    "Biome Weapon Runs": _biome_weapon_run_locations,
    "Ranked Biome Weapon Runs": _ranked_biome_weapon_run_locations,
    "Biome Melee Runs": _biome_melee_run_locations,
    "Ranked Biome Melee Runs": _ranked_biome_melee_run_locations,
    "Biome Ability Runs": _biome_ability_run_locations,
    "Ranked Biome Ability Runs": _ranked_biome_ability_run_locations,
    "Run Weapon Completion": _run_weapon_locations,
    "Run Melee Completion": _run_melee_locations,
    "Run Ability Completion": _run_ability_locations,
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


# Biome-layout category -> the island-layout category it mirrors.
_C = CrabChampsLocationCategory
BIOME_BASE_CATEGORY = {
    _C.BIOME_ISLAND: _C.ISLAND,
    _C.RANKED_BIOME_ISLAND: _C.RANKED_ISLAND,
    _C.BIOME_WEAPON_RUN: _C.WEAPON_RUN,
    _C.RANKED_BIOME_WEAPON_RUN: _C.RANKED_WEAPON_RUN,
    _C.BIOME_MELEE_RUN: _C.MELEE_RUN,
    _C.RANKED_BIOME_MELEE_RUN: _C.RANKED_MELEE_RUN,
    _C.BIOME_ABILITY_RUN: _C.ABILITY_RUN,
    _C.RANKED_BIOME_ABILITY_RUN: _C.RANKED_ABILITY_RUN,
}
ISLAND_TO_BIOME_CATEGORY = {v: k for k, v in BIOME_BASE_CATEGORY.items()}
