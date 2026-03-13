import typing
from dataclasses import dataclass
from Options import Toggle, DefaultOnToggle, Range, Choice, ItemDict, DeathLink, PerGameCommonOptions


class RequiredRank(Choice):
    """The minimum rank that must be completed for victory.
    Rank is determined by difficulty modifier points:
    Bronze(0), Silver(1), Gold(2-3), Sapphire(4-5), Emerald(6-7),
    Ruby(8-9), Diamond(10-15), Prismatic(16+).
    Run-completion locations are generated for all ranks up to this level."""
    display_name = "Required Rank"
    option_bronze = 0
    option_silver = 1
    option_gold = 2
    option_sapphire = 3
    option_emerald = 4
    option_ruby = 5
    option_diamond = 6
    option_prismatic = 7
    default = 0


class MaxRank(Choice):
    """Maximum rank that generates location checks.
    Ranks above this produce no locations. Must be >= Required Rank.
    Locations between Required Rank and Max Rank are optional extras."""
    display_name = "Max Rank"
    option_bronze = 0
    option_silver = 1
    option_gold = 2
    option_sapphire = 3
    option_emerald = 4
    option_ruby = 5
    option_diamond = 6
    option_prismatic = 7
    default = 3


class NonProgressionAboveRequired(Toggle):
    """When enabled, items placed at locations for ranks above the Required Rank
    (but at or below Max Rank) are classified as useful/filler only, never progression.
    This prevents critical items from being locked behind higher difficulty ranks."""
    display_name = "Non-Progression Above Required Rank"


class ExtraRankedIslandChecks(Toggle):
    """When enabled, island completions and equipment runs are tracked per rank
    for ALL ranks up to Max Rank, not just the Required Rank.
    For example, 'Complete Island 10 with Auto Rifle on Silver' becomes a check
    even if Required Rank is Bronze. Greatly increases location count."""
    display_name = "Extra Ranked Island Checks"


class CascadeRankedChecks(Toggle):
    """When enabled, completing a check at a higher rank also completes
    the equivalent check at all lower ranks. For example, completing
    Island 5 on Gold also checks Island 5 on Silver and Bronze."""
    display_name = "Cascade Ranked Checks"


class WeaponsForCompletion(Range):
    """Number of different weapons the player must complete a run with for victory."""
    display_name = "Weapons for Completion"
    range_start = 1
    range_end = 20
    default = 5


class RunLength(Choice):
    """How many islands must be completed for a run to count as finished.
    The game loops islands in cycles of 28. A normal run is 28 islands (1 cycle),
    a full run is 56 islands (2 cycles)."""
    display_name = "Run Length"
    option_short = 28
    option_full = 56
    default = 28


class WeaponsInPool(Range):
    """How many weapons are randomly selected and placed into the AP item pool.
    The player must find these weapons as AP items before they can use them.
    Must be >= Weapons for Completion. Capped at 19 so the player always has
    at least one weapon available from the start."""
    display_name = "Weapons in Pool"
    range_start = 1
    range_end = 19
    default = 5


class MeleeForCompletion(Range):
    """Number of different melee weapons the player must complete a run with for victory.
    Set to 0 to disable melee randomization and melee completion locations entirely."""
    display_name = "Melee for Completion"
    range_start = 0
    range_end = 5
    default = 3


class MeleeInPool(Range):
    """How many melee weapons are randomly selected and placed into the AP item pool.
    Must be >= Melee for Completion. Forced to 0 when Melee for Completion is 0.
    Capped at 4 so the player always has at least one melee weapon available."""
    display_name = "Melee in Pool"
    range_start = 0
    range_end = 4
    default = 0


class AbilityForCompletion(Range):
    """Number of different abilities the player must complete a run with for victory.
    Set to 0 to disable ability randomization and ability completion locations entirely."""
    display_name = "Abilities for Completion"
    range_start = 0
    range_end = 7
    default = 3


class AbilitiesInPool(Range):
    """How many abilities are randomly selected and placed into the AP item pool.
    Must be >= Abilities for Completion. Forced to 0 when Abilities for Completion is 0.
    Capped at 6 so the player always has at least one ability available."""
    display_name = "Abilities in Pool"
    range_start = 0
    range_end = 6
    default = 0


class StartingWeapons(Range):
    """Number of pool weapons the player starts with already unlocked.
    These weapons are randomly selected from the pool and given at the start,
    so the player can begin working on equipment run checks immediately.
    Must be less than Weapons in Pool (at least one weapon must be found).
    Set to 0 to start with no weapons unlocked."""
    display_name = "Starting Weapons"
    range_start = 0
    range_end = 19
    default = 0


class EquipmentCheckMode(Choice):
    """Controls how non-pool equipment run locations behave.
    Pool equipment (randomized into AP items) always has regular locations.
    This option controls non-pool equipment (available from the start):
    Regular: non-pool equipment run checks are normal locations.
    Filler Only: non-pool equipment run checks exist but only hold filler items.
    Disabled: non-pool equipment run locations are not created at all."""
    display_name = "Equipment Check Mode"
    option_regular = 0
    option_filler_only = 1
    option_disabled = 2
    default = 0


class CrystalCachePercentage(Range):
    """Percentage of extra item pool slots filled with Crystal Cache (grants crystals)
    instead of additional perk/mod stacks. Higher values mean fewer duplicate
    perks/mods and more crystal rewards. At 0%, all extra slots are perks/mods.
    At 100%, all extra slots are Crystal Cache."""
    display_name = "Crystal Cache Percentage"
    range_start = 0
    range_end = 100
    default = 75


class GuaranteedItemsOption(ItemDict):
    """Guarantees that the specified items will be in the item pool"""
    display_name = "Guaranteed Items"


@dataclass
class CrabChampsOption(PerGameCommonOptions):
    required_rank: RequiredRank
    max_rank: MaxRank
    non_progression_above_required: NonProgressionAboveRequired
    extra_ranked_island_checks: ExtraRankedIslandChecks
    cascade_ranked_checks: CascadeRankedChecks
    run_length: RunLength
    weapons_for_completion: WeaponsForCompletion
    weapons_in_pool: WeaponsInPool
    starting_weapons: StartingWeapons
    melee_for_completion: MeleeForCompletion
    melee_in_pool: MeleeInPool
    ability_for_completion: AbilityForCompletion
    abilities_in_pool: AbilitiesInPool
    equipment_check_mode: EquipmentCheckMode
    crystal_cache_percentage: CrystalCachePercentage
    guaranteed_items: GuaranteedItemsOption
    death_link: DeathLink
