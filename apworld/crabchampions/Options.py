import typing
from dataclasses import dataclass
from Options import Toggle, DefaultOnToggle, Range, Choice, ItemDict, DeathLink, PerGameCommonOptions


# Victory conditions

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


class RunLength(Choice):
    """How many islands must be completed for a run to count as finished.
    The game loops islands in cycles of 28. A normal run is 28 islands (1 cycle),
    a full run is 56 islands (2 cycles)."""
    display_name = "Run Length"
    option_short = 28
    option_full = 56
    default = 28


class WeaponsForCompletion(Range):
    """Number of different weapons the player must complete a run with for victory."""
    display_name = "Weapons for Completion"
    range_start = 1
    range_end = 20
    default = 5


class MeleeForCompletion(Range):
    """Number of different melee weapons the player must complete a run with for victory.
    Set to 0 to disable melee randomization and melee completion locations entirely."""
    display_name = "Melee for Completion"
    range_start = 0
    range_end = 5
    default = 3


class AbilityForCompletion(Range):
    """Number of different abilities the player must complete a run with for victory.
    Set to 0 to disable ability randomization and ability completion locations entirely."""
    display_name = "Abilities for Completion"
    range_start = 0
    range_end = 7
    default = 3


# Item pool / equipment

class WeaponsInPool(Range):
    """How many weapons are randomly selected and placed into the AP item pool.
    The player must find these weapons as AP items before they can use them.
    Each weapon in the pool generates its own run-completion location check,
    even if Weapons for Completion is lower than this value.
    For example, with 5 in pool and 3 for completion, all 5 weapons create
    location checks but only 3 must be completed for victory.
    Must be >= Weapons for Completion. Capped at 19 so the player always has
    at least one weapon available from the start."""
    display_name = "Weapons in Pool"
    range_start = 1
    range_end = 19
    default = 5


class MeleeInPool(Range):
    """How many melee weapons are randomly selected and placed into the AP item pool.
    Each melee weapon in the pool generates its own run-completion location check,
    even if Melee for Completion is lower than this value.
    For example, with 3 in pool and 1 for completion, all 3 melee weapons create
    location checks but only 1 must be completed for victory.
    Must be >= Melee for Completion. Forced to 0 when Melee for Completion is 0.
    Capped at 4 so the player always has at least one melee weapon available."""
    display_name = "Melee in Pool"
    range_start = 0
    range_end = 4
    default = 0


class AbilitiesInPool(Range):
    """How many abilities are randomly selected and placed into the AP item pool.
    Each ability in the pool generates its own run-completion location check,
    even if Abilities for Completion is lower than this value.
    For example, with 4 in pool and 2 for completion, all 4 abilities create
    location checks but only 2 must be completed for victory.
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
    default = 2


# Rank modifiers

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


class ExtraRankedIslandChecks(Toggle):
    """When enabled, island completions and equipment runs are tracked per rank
    for ALL ranks up to Max Rank, not just the Required Rank.
    For example, 'Complete Island 10 with Auto Rifle on Silver' becomes a check
    even if Required Rank is Bronze. Greatly increases location count."""
    display_name = "Extra Ranked Island Checks"


class NonProgressionAboveRequired(Toggle):
    """When enabled, items placed at locations for ranks above the Required Rank
    (but at or below Max Rank) are classified as useful/filler only, never progression.
    This prevents critical items from being locked behind higher difficulty ranks.
    Only has an effect when Extra Ranked Island Checks is enabled."""
    display_name = "Non-Progression Above Required Rank"


class CascadeRankedChecks(Toggle):
    """When enabled, completing a check at a higher rank also completes
    the equivalent check at all lower ranks. For example, completing
    Island 5 on Gold also checks Island 5 on Silver and Bronze."""
    display_name = "Cascade Ranked Checks"


class PickupChecks(DefaultOnToggle):
    """When enabled, picking up perks, relics, weapon mods, melee mods, and ability mods
    for the first time generates location checks (e.g., 'Perk: Driller', 'Relic: Time Ring').
    This adds up to 305 additional locations. When disabled, these pickup locations are
    not created and the item pool is smaller, focusing only on island completions,
    equipment runs, and rank runs."""
    display_name = "Pickup Checks"


# Filler / misc

class CrystalCachePercentage(Range):
    """Percentage of extra item pool slots filled with Crystal Cache (grants crystals)
    instead of additional perk/mod stacks. Higher values mean fewer duplicate
    perks/mods and more crystal rewards. At 0%, all extra slots are perks/mods.
    At 100%, all extra slots are Crystal Cache."""
    display_name = "Crystal Cache Percentage"
    range_start = 0
    range_end = 100
    default = 75


class GreedItemMode(Choice):
    """Controls how Greed items (perks/mods/relics with the Greed modifier) are handled.
    Greed items cannot be dropped once picked up, making them a permanent commitment.
    Auto: Greed items are added directly to your inventory when received from AP.
    Drop: Greed items are spawned on the floor in the lobby for you to pick up manually.
    Skip: Greed items are not granted at all — you find them naturally in-game."""
    display_name = "Greed Item Mode"
    option_auto = 0
    option_drop = 1
    option_skip = 2
    default = 0


class ProgressiveSlots(Toggle):
    """When enabled, the player starts with fewer inventory slots and receives
    additional slots as AP items. Slot purchases with crystals are blocked.
    When disabled, all slots are available from the start as normal."""
    display_name = "Progressive Inventory Slots"


class StartingPerkSlots(Range):
    """Number of perk slots the player starts with when Progressive Inventory Slots is enabled.
    The remaining slots (up to 24) are sent as 'Perk Slot' items in the AP pool."""
    display_name = "Starting Perk Slots"
    range_start = 1
    range_end = 24
    default = 6


class StartingWeaponModSlots(Range):
    """Number of weapon mod slots the player starts with when Progressive Inventory Slots is enabled.
    The remaining slots (up to 24) are sent as 'Weapon Mod Slot' items in the AP pool."""
    display_name = "Starting Weapon Mod Slots"
    range_start = 1
    range_end = 24
    default = 6


class StartingAbilityModSlots(Range):
    """Number of ability mod slots the player starts with when Progressive Inventory Slots is enabled.
    The remaining slots (up to 12) are sent as 'Ability Mod Slot' items in the AP pool."""
    display_name = "Starting Ability Mod Slots"
    range_start = 1
    range_end = 12
    default = 4


class StartingMeleeModSlots(Range):
    """Number of melee mod slots the player starts with when Progressive Inventory Slots is enabled.
    The remaining slots (up to 12) are sent as 'Melee Mod Slot' items in the AP pool."""
    display_name = "Starting Melee Mod Slots"
    range_start = 1
    range_end = 12
    default = 4



class GuaranteedItemsOption(ItemDict):
    """Guarantees that the specified items will be in the item pool"""
    display_name = "Guaranteed Items"


@dataclass
class CrabChampsOption(PerGameCommonOptions):
    # Victory conditions
    required_rank: RequiredRank
    run_length: RunLength
    weapons_for_completion: WeaponsForCompletion
    melee_for_completion: MeleeForCompletion
    ability_for_completion: AbilityForCompletion
    # Item pool / equipment
    weapons_in_pool: WeaponsInPool
    melee_in_pool: MeleeInPool
    abilities_in_pool: AbilitiesInPool
    starting_weapons: StartingWeapons
    equipment_check_mode: EquipmentCheckMode
    # Rank modifiers
    max_rank: MaxRank
    extra_ranked_island_checks: ExtraRankedIslandChecks
    non_progression_above_required: NonProgressionAboveRequired
    cascade_ranked_checks: CascadeRankedChecks
    pickup_checks: PickupChecks
    # Progressive slots
    progressive_slots: ProgressiveSlots
    starting_perk_slots: StartingPerkSlots
    starting_weapon_mod_slots: StartingWeaponModSlots
    starting_ability_mod_slots: StartingAbilityModSlots
    starting_melee_mod_slots: StartingMeleeModSlots
    # Filler / misc
    crystal_cache_percentage: CrystalCachePercentage
    greed_item_mode: GreedItemMode
    guaranteed_items: GuaranteedItemsOption
    death_link: DeathLink
