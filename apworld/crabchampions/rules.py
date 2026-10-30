"""Access rules, written with Archipelago's rule builder."""
from typing import TYPE_CHECKING, List

from rule_builder.field_resolvers import FromOption
from rule_builder.options import OptionFilter
from rule_builder.rules import And, CanReachLocation, Has, HasAny, HasFromListUnique, Rule

from .Items import PICKUP_TAG_REQUIREMENTS, biome_access_item_names
from .Locations import (
    BIOME_BASE_CATEGORY, CrabChampsLocationCategory, biome_index_from_name, biome_index_to_biome,
)
from .Options import AbilityForCompletion, BiomeLock, MeleeForCompletion, WeaponsForCompletion

if TYPE_CHECKING:
    from . import CrabChampsWorld

_C = CrabChampsLocationCategory

EQUIPMENT_CATEGORIES = frozenset({
    _C.WEAPON_RUN, _C.MELEE_RUN, _C.ABILITY_RUN,
    _C.RANKED_WEAPON_RUN, _C.RANKED_MELEE_RUN, _C.RANKED_ABILITY_RUN,
    _C.RUN_WEAPON, _C.RUN_MELEE, _C.RUN_ABILITY,
})

PICKUP_CATEGORIES = frozenset({
    _C.PERK, _C.RELIC, _C.WEAPON_MOD, _C.MELEE_MOD, _C.ABILITY_MOD,
})

RUN_LEVEL_CATEGORIES = frozenset({_C.RUN_WEAPON, _C.RUN_MELEE, _C.RUN_ABILITY, _C.RANK_RUN})


def biome_access(biome: int) -> Rule:
    """Rule for entering a biome (game number 1-4).

    Island-number checks need no items: island numbers keep counting when a
    biome repeats, so every one is reachable with the starting biome alone.
    Biome-layout checks need that biome's Access item; with the lock off they
    are always open.
    """
    return Has(
        biome_access_item_names[biome - 1],
        options=[OptionFilter(BiomeLock, 1)],
        filtered_resolution=True,
    )


def set_all_rules(world: "CrabChampsWorld") -> None:
    set_location_rules(world)
    set_completion_rule(world)


def set_location_rules(world: "CrabChampsWorld") -> None:
    limit_pool = world.limit_pool
    biome_layout = world.options.check_layout.value == 1

    for location in world.get_locations():
        if not hasattr(location, "category"):
            continue
        cat = BIOME_BASE_CATEGORY.get(location.category, location.category)
        parts: List[Rule] = []

        if location.category in BIOME_BASE_CATEGORY:
            biome = biome_index_to_biome(biome_index_from_name(location.name))
            parts.append(biome_access(biome))

        if biome_layout and location.category in RUN_LEVEL_CATEGORIES:
            # A completed run clears all four biomes, so these need every biome unlocked.
            parts.extend(biome_access(b) for b in range(1, 5))

        if cat in EQUIPMENT_CATEGORIES:
            # Equipment outside the randomized pool is available from the start.
            equip_name = world._extract_equip_name(location.name)
            if world._is_pool_equipment(equip_name, cat):
                parts.append(Has(equip_name))

        elif cat in PICKUP_CATEGORIES:
            item_name = location.name.split(": ", 1)[-1] if ": " in location.name else ""
            providers = PICKUP_TAG_REQUIREMENTS.get(item_name)
            if providers and limit_pool:
                # Only providers in the chosen subset are ever sent as items.
                providers = [p for p in providers if p in world._allowed_pickup_names]
            if providers:
                parts.append(HasAny(*providers))

        if parts:
            world.set_rule(location, And(*parts) if len(parts) > 1 else parts[0])


def set_completion_rule(world: "CrabChampsWorld") -> None:
    # Only pool equipment counts toward completion.  Equipment outside the pool
    # is available from the start, so counting it would make the goal
    # satisfiable without receiving an item.  Setup guarantees each
    # *_for_completion is at most the matching pool size, so the pool alone can
    # always satisfy the rule.  Island reachability needs no items.
    # A category whose requirement is 0 adds no term: HasFromListUnique over an
    # empty pool (melee/abilities forced to 0 pool items) never passes.
    options = world.options
    terms = [
        HasFromListUnique(*pool, count=count)
        for pool, needed, count in (
            (world.pool_weapons, options.weapons_for_completion.value, FromOption(WeaponsForCompletion)),
            (world.pool_melee, options.melee_for_completion.value, FromOption(MeleeForCompletion)),
            (world.pool_abilities, options.ability_for_completion.value, FromOption(AbilityForCompletion)),
        )
        if needed > 0
    ]
    if options.check_layout.value == 1:
        # A completed run clears all four biomes in one run, so the goal needs every biome unlocked.
        terms.extend(biome_access(b) for b in range(1, 5))
    victory = And(*terms)
    world.set_rule(world.get_location("Victory"), victory)
    world.set_completion_rule(CanReachLocation("Victory"))
