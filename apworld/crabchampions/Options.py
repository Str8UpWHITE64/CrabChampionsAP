import typing
from dataclasses import dataclass
from Options import Toggle, DefaultOnToggle, Range, Choice, ItemDict, OptionCounter, DeathLink, PerGameCommonOptions, OptionGroup


# ──────────────────────────────────────────────────────────────────────────
# Victory conditions
# ──────────────────────────────────────────────────────────────────────────

class RequiredRank(Choice):
    """The rank you must reach to win.  A run counts when you finish the
    final island at this rank or higher, so a Gold run also counts for Silver.

    Rank comes from the difficulty modifier points you have active:
      Bronze (0), Silver (1), Gold (2-3), Sapphire (4-5), Emerald (6-7),
      Ruby (8-9), Diamond (10-15), Prismatic (16+)

    Bronze means any clear: it has no checks of its own, the plain
    "Complete Island X" and "Complete Island X with Weapon" checks stand in
    for it.  Higher ranks need more modifier cards, so they are harder.
    See Extra Rank Checks to also get checks for the other ranks."""
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
    """How many islands a run must complete to count as finished.  The game
    cycles biomes every 28 islands, so:
      short (28): one full biome cycle
      full  (56): two full biome cycles

    Island and equipment checks scale with this value: a Full run has about
    twice as many of them as a Short run.  Pickup checks and the per-rank
    Complete Run checks do not change."""
    display_name = "Run Length"
    option_short = 28
    option_full = 56
    default = 28


class CheckLayout(Choice):
    """How island checks are named and counted.
      island_number: one check per island number, "Complete Island 15".
      biome: one check per biome and island slot, "Complete Ice Island 1",
        "Reach Desert Shop".  The same biome and slot only counts once, so
        repeating a biome in a run sends nothing new.  A full-length run also
        gets a second set of checks for its second pass, "Complete Ice
        Island 1 (Loop 2)".

    The number of checks is the same in both layouts.  With Biome Lock on,
    a biome check needs that biome's Access item.  Rank and equipment checks
    follow the same layout."""
    display_name = "Check Layout"
    option_island_number = 0
    option_biome = 1
    default = 0


class WeaponsForCompletion(Range):
    """How many DIFFERENT weapons must be used to complete victory-rank runs
    before you can win.  E.g. with this set to 5, you'll need to finish the
    final island five separate times, each with a different weapon, all at
    Required Rank or higher.

    Only weapons in the AP pool count toward this.  Weapons you have from
    the start can still generate location checks (see Equipment Check
    Mode), but they never advance the goal.  Weapons in Pool is raised to
    match this value when it is lower.

    Capped at the total number of weapons in the game (21)."""
    display_name = "Weapons for Completion"
    range_start = 1
    range_end = 21
    default = 5


class MeleeForCompletion(Range):
    """How many DIFFERENT melee weapons must be used to complete victory-rank
    runs before you can win.  Works the same as Weapons for Completion but
    for melee.

    Set to 0 to disable melee entirely - no melee items in the pool, no
    melee location checks, and no melee requirement for victory."""
    display_name = "Melee for Completion"
    range_start = 0
    range_end = 6
    default = 3


class AbilityForCompletion(Range):
    """How many DIFFERENT abilities must be used to complete victory-rank
    runs before you can win.  Works the same as Weapons for Completion but
    for abilities.

    Set to 0 to disable abilities entirely - no ability items in the pool,
    no ability location checks, and no ability requirement for victory."""
    display_name = "Abilities for Completion"
    range_start = 0
    range_end = 9
    default = 3


# ──────────────────────────────────────────────────────────────────────────
# Item pool / equipment
# ──────────────────────────────────────────────────────────────────────────

class WeaponsInPool(Range):
    """How many weapons are randomly selected from the 21 available to be
    AP items.  Pool weapons must be received via Archipelago before you can
    use them.  Weapons not in the pool are always available from the start.

    Each pool weapon also gets its own per-island run checks, so a larger
    pool means more checks.

    Example: pool=5, for_completion=3 means 5 weapons are AP items, all 5
    have location checks, but only 3 distinct ones must be used to win.

    Raised to Weapons for Completion when lower.  Set to 21 to put every
    weapon in the pool; Starting Weapons is then at least 1 so you always
    begin with something usable."""
    display_name = "Weapons in Pool"
    range_start = 1
    range_end = 21
    default = 5


class MeleeInPool(Range):
    """How many melee weapons (out of 6) are randomly selected to be AP
    items.  See Weapons in Pool for the full mechanic.

    Raised to Melee for Completion when lower, and forced to 0 when Melee
    for Completion is 0.  Set to 6 to put every melee weapon in the pool;
    Starting Melee is then at least 1 so you always begin with something
    usable."""
    display_name = "Melee in Pool"
    range_start = 0
    range_end = 6
    default = 3


class AbilitiesInPool(Range):
    """How many abilities (out of 9) are randomly selected to be AP items.
    See Weapons in Pool for the full mechanic.

    Raised to Abilities for Completion when lower, and forced to 0 when
    Abilities for Completion is 0.  Set to 9 to put every ability in the
    pool; Starting Abilities is then at least 1 so you always begin with
    something usable."""
    display_name = "Abilities in Pool"
    range_start = 0
    range_end = 9
    default = 3


class StartingWeapons(Range):
    """How many of your pool weapons you begin the game already holding.
    They are picked at random from Weapons in Pool, so you can start on
    equipment checks without waiting for a weapon from another player.  A
    pool weapon you start with already counts toward Weapons for Completion.

    A weapon you start with is removed from the item pool, so its slot goes
    to filler.  Must be less than Weapons in Pool (reduced if not), except
    that a full pool of 21 forces at least 1."""
    display_name = "Starting Weapons"
    range_start = 0
    range_end = 20
    default = 0


class StartingMelee(Range):
    """How many of your pool melee weapons you begin the game already
    holding.  Works like Starting Weapons.  Must be less than Melee in Pool
    (reduced if not), except that a full pool of 6 forces at least 1."""
    display_name = "Starting Melee"
    range_start = 0
    range_end = 5
    default = 0


class StartingAbilities(Range):
    """How many of your pool abilities you begin the game already holding.
    Works like Starting Weapons.  Must be less than Abilities in Pool
    (reduced if not), except that a full pool of 9 forces at least 1."""
    display_name = "Starting Abilities"
    range_start = 0
    range_end = 8
    default = 0


class EquipmentCheckMode(Choice):
    """Controls whether non-pool weapons/melee/abilities have their own
    run-completion location checks.  (Pool equipment ALWAYS has checks -
    this option is only about non-pool items, which are available from
    the start.)

    These are bonus locations only.  Non-pool equipment NEVER counts
    toward Weapons/Melee/Abilities for Completion, no matter which mode
    is picked - otherwise the goal could be met without receiving a
    single AP item.

    regular:
        Non-pool equipment runs are normal location checks that can hold
        any item, including progression.  Maximum locations.
    filler_only:
        Non-pool equipment runs exist as locations but are marked excluded
        - they only ever hold filler.  Adds checks for variety without
        requiring you to use every weapon for progression.
    disabled:
        Non-pool equipment run locations are not generated at all.  This
        is the default due to how many extra locations it creates."""
    display_name = "Equipment Check Mode"
    option_regular = 0
    option_filler_only = 1
    option_disabled = 2
    default = 2


# ──────────────────────────────────────────────────────────────────────────
# Rank modifiers
# ──────────────────────────────────────────────────────────────────────────

class MaxRank(Choice):
    """The highest rank that gets its own checks.  Raised to Required Rank
    when lower.  A run above Max Rank still counts for every rank up to Max
    Rank.  Bronze here means only the plain checks.

    Only used when Extra Rank Checks is not "none"; otherwise just Required
    Rank has ranked checks."""
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


class ExtraRankChecks(Choice):
    """Whether ranks besides Required Rank get their own checks.  A higher
    rank counts for all lower ranks, so one Gold clear also covers the Silver
    and plain checks.

    none:
        Only Required Rank has ranked checks (plus the plain checks, which
        any clear sends).  Smallest pool.
    progression:
        Every rank from Silver up to Max Rank gets ranked checks, and they
        can hold progression items.  Many more checks, and higher difficulty
        becomes real progression.
    filler_only:
        The same checks as progression, but those above Required Rank only
        hold filler.  Extra checks for variety without having to grind high
        ranks for important items.

    Does nothing when Required Rank and Max Rank are both Bronze."""
    display_name = "Extra Rank Checks"
    option_none = 0
    option_progression = 1
    option_filler_only = 2
    default = 0


class MinimizeRunChecks(Toggle):
    """Leaves out checks that a more specific check already covers, for a
    smaller world:

      - "Complete Island X on Rank" (the per-rank island checks) are removed;
        the plain "Complete Island X" stays.
      - "Complete Island X with Weapon" (plain equipment checks) are removed
        when the goal is above Bronze, since "with Weapon on Rank" covers
        them.  With a Bronze goal or Extra Rank Checks on they stay, as they
        are the Bronze checks.

    "Complete Island X with Weapon on Rank" is always kept."""
    display_name = "Minimize Run Checks"


# ──────────────────────────────────────────────────────────────────────────
# Pickup checks
# ──────────────────────────────────────────────────────────────────────────

class PickupChecks(DefaultOnToggle):
    """Picking up a perk, relic, weapon mod, melee mod or ability mod for
    the first time sends a check, e.g. "Perk: Driller" or "Relic: Time Ring".

    Up to 341 checks (318 with Greed Item Mode on skip).  When off, these
    checks do not exist and the world is only island, equipment and rank
    checks.  Perks, mods and relics are still received as items, but a small
    world only holds a random part of them.

    See Limit Pickups to scale this down."""
    display_name = "Pickup Checks"


class LimitPickups(Choice):
    """Limit pickups to a random set matching your per-run inventory caps
    (24 perks, 24 weapon mods, 12 ability mods, 12 melee mods, 10 relics).

    off: every pickup can be an item and has a check.
    pool_and_checks: only the chosen set is sent as items and has checks.
    pool_only: only the chosen set is sent as items; every pickup keeps its
        check, so the rest are filled with other things.
    checks_only: every pickup can be an item, but only the chosen set has
        checks.

    Pickups outside the set can still be found in a run; they just are not
    sent or received, and where checks are limited they send no check.  The
    set always has a provider for each pickup that needs another one, so no
    check becomes unreachable.  Checks need Pickup Checks."""
    display_name = "Limit Pickups"
    option_off = 0
    option_pool_and_checks = 1
    option_pool_only = 2
    option_checks_only = 3
    default = 0


class GrantedItemChecks(DefaultOnToggle):
    """When on, receiving a perk, mod or relic from the multiworld also
    completes that item's pickup check, e.g. being sent Driller checks
    "Perk: Driller".

    When off, pickup checks only come from finding items in a run: loot,
    chests, totems and shop purchases.  Items you drop and pick back up, and
    the lobby's free item, never count either way.

    Has no effect when Pickup Checks is off."""
    display_name = "Granted Item Checks"


# ──────────────────────────────────────────────────────────────────────────
# Progressive inventory slots
# ──────────────────────────────────────────────────────────────────────────

class ProgressiveSlots(Toggle):
    """When enabled, you start with fewer inventory slots than the game
    normally allows, and receive additional slots as AP items.  The
    in-game crystal-purchase upgrade for slots is blocked.

    When disabled, you have all slots available from the start as
    normal.

    See Starting Perk/Weapon Mod/Ability Mod/Melee Mod Slots to control
    how many slots you start with."""
    display_name = "Progressive Inventory Slots"


class StartingPerkSlots(Range):
    """When Progressive Inventory Slots is enabled, how many perk slots
    you start with.  The remaining (24 - this value) slots are sent as
    "Progressive Perk Slot" items in the AP pool.

    Has no effect when Progressive Inventory Slots is disabled."""
    display_name = "Starting Perk Slots"
    range_start = 1
    range_end = 24
    default = 6


class StartingWeaponModSlots(Range):
    """When Progressive Inventory Slots is enabled, how many weapon mod
    slots you start with.  The remaining (24 - this value) slots are
    sent as "Progressive Weapon Mod Slot" items in the AP pool.

    Has no effect when Progressive Inventory Slots is disabled."""
    display_name = "Starting Weapon Mod Slots"
    range_start = 1
    range_end = 24
    default = 6


class StartingAbilityModSlots(Range):
    """When Progressive Inventory Slots is enabled, how many ability mod
    slots you start with.  The remaining (12 - this value) slots are
    sent as "Progressive Ability Mod Slot" items in the AP pool.

    Has no effect when Progressive Inventory Slots is disabled."""
    display_name = "Starting Ability Mod Slots"
    range_start = 1
    range_end = 12
    default = 4


class StartingMeleeModSlots(Range):
    """When Progressive Inventory Slots is enabled, how many melee mod
    slots you start with.  The remaining (12 - this value) slots are
    sent as "Progressive Melee Mod Slot" items in the AP pool.

    Has no effect when Progressive Inventory Slots is disabled."""
    display_name = "Starting Melee Mod Slots"
    range_start = 1
    range_end = 12
    default = 4


# ──────────────────────────────────────────────────────────────────────────
# Received items per run
# ──────────────────────────────────────────────────────────────────────────

class StartingItemPercentage(Range):
    """Percentage of your received perks, mods and relics that you start each
    run with, picked at random (rounded up).  The rest can arrive at each new
    biome, see Biome Item Percentage.  Crystals always come in full, and items
    received during a run are applied right away.

    Set to 100 to start every run with everything you have received."""
    display_name = "Starting Item Percentage"
    range_start = 0
    range_end = 100
    default = 5


class BiomeItemPercentage(Range):
    """When you clear the last island of a biome, this percentage of the
    received perks, mods and relics you don't have yet this run is granted,
    picked at random (rounded up).  Higher values make runs easier as they go
    on.

    Set to 0 to only ever get the items from Starting Item Percentage.  Has no
    effect when Starting Item Percentage is 100."""
    display_name = "Biome Item Percentage"
    range_start = 0
    range_end = 100
    default = 5


# ──────────────────────────────────────────────────────────────────────────
# Filler / misc
# ──────────────────────────────────────────────────────────────────────────

class CrystalCachePercentage(Range):
    """Share of the spare item slots that become crystals rather than extra
    copies of perks and mods.  Spare slots are what is left after equipment,
    one of each pickup, Biome Access, slot items, traps and Perk Boosts.

      0%   = all spare slots are extra perks/mods
      75%  = default mix
      100% = all spare slots are crystals

    Crystals come in three sizes: Cache (50 crystals, 60% of them), Hoard
    (100, 35%) and Jackpot (500, 5%)."""
    display_name = "Crystal Cache Percentage"
    range_start = 0
    range_end = 100
    default = 75


class GreedItemMode(Choice):
    """How to handle Greed items - perks/relics/mods that can't be dropped
    once picked up, making them a permanent commitment for the run.

    auto:
        Greed items received from AP go directly to your inventory the
        next time you start a run, even though you can't drop them.
    drop:
        Greed items received from AP spawn on the lobby floor for you
        to pick up only when you're ready to commit.
    skip:
        Greed items are never granted via AP at all.  You can only
        find them naturally in-game.  Their pickup locations are also
        excluded from generation."""
    display_name = "Greed Item Mode"
    option_auto = 0
    option_drop = 1
    option_skip = 2
    default = 2


class GuaranteedItemsOption(ItemDict):
    """Extra copies of perks and mods, by exact item name. Example:
      guaranteed_items:
        Time Bolt: 2
        Driller: 3"""
    display_name = "Guaranteed Items"


# ──────────────────────────────────────────────────────────────────────────
# Traps
# ──────────────────────────────────────────────────────────────────────────

class TrapPercentage(Range):
    """Share of the spare item slots that become traps.  Traps make a run
    harder for a short time; none of them is permanent, removes your
    equipment, or can kill you outright.

    0 = no traps (default).  Spare slots are what is left after equipment,
    one of each pickup, Biome Access and slot items.  Traps are placed
    before Perk Boosts, so 100 leaves no room for them."""
    display_name = "Trap Percentage"
    range_start = 0
    range_end = 100
    default = 0


class TrapWeights(OptionCounter):
    """Relative chance of each trap kind (0 to 100). Traps left out never appear. Example:
      trap_weights:
        Crystal Tax: 30
        Bruise Trap: 10"""
    display_name = "Trap Weights"
    min = 0
    max = 100
    valid_keys = frozenset({
        "Crystal Tax", "Slowdown Trap", "Weak Shots Trap", "Bruise Trap",
        "Grow Trap", "Shrink Trap", "Heavy Gravity Trap", "Floaty Gravity Trap",
    })
    default = {
        "Crystal Tax": 20,
        "Slowdown Trap": 20,
        "Weak Shots Trap": 20,
        "Bruise Trap": 20,
        "Grow Trap": 10,
        "Shrink Trap": 10,
        "Heavy Gravity Trap": 10,
        "Floaty Gravity Trap": 10,
    }


class TrapDuration(Range):
    """How many seconds the timed traps last: Weak Shots, Grow, Shrink and
    both gravity traps.  (Slowdown lasts one island instead.)"""
    display_name = "Trap Duration (seconds)"
    range_start = 5
    range_end = 120
    default = 30


class TrapGraceSeconds(Range):
    """A trap received in the lobby or just as an island begins waits this
    many seconds into the island before it hits, so you can look around
    first.  0 = no wait."""
    display_name = "Trap Grace (seconds)"
    range_start = 0
    range_end = 60
    default = 10


class CrystalTaxPercent(Range):
    """Share of your current crystals a Crystal Tax takes."""
    display_name = "Crystal Tax Percent"
    range_start = 5
    range_end = 100
    default = 25


class SlowdownPercent(Range):
    """How much slower a Slowdown Trap makes you, as a percentage of your
    normal walk speed."""
    display_name = "Slowdown Percent"
    range_start = 10
    range_end = 80
    default = 35


class WeakShotsPercent(Range):
    """Share of your normal outgoing damage you still deal during a Weak
    Shots Trap.  50 = half damage."""
    display_name = "Weak Shots Damage Percent"
    range_start = 10
    range_end = 90
    default = 50


class BruisePercent(Range):
    """Share of your current health a Bruise Trap takes.  It never takes
    the last point."""
    display_name = "Bruise Percent"
    range_start = 5
    range_end = 90
    default = 30


# ──────────────────────────────────────────────────────────────────────────
# Perk Boost filler
# ──────────────────────────────────────────────────────────────────────────

class PerkBoostCount(Range):
    """How many Perk Boost items are in the pool. When you receive one during a run, a random
    perk you are holding goes up by Perk Boost Levels levels, like picking up that perk again
    several times. Boosts take spare filler slots after traps. 0 = none."""
    display_name = "Perk Boost Count"
    range_start = 0
    range_end = 50
    default = 0


class PerkBoostLevels(Range):
    """How many levels one Perk Boost adds to the perk it picks. Greed perks are never picked;
    if you hold no other perk, the boost waits until you do."""
    display_name = "Perk Boost Levels"
    range_start = 1
    range_end = 10
    default = 3


class BiomeLock(DefaultOnToggle):
    """Runs can only enter biomes you own the Access item for (Tropical, Ice,
    Desert and Volcano Access).  You start with the Access item of your
    starting biome.  When the next biome of a run is one you do not own, the
    run goes to a biome you do own instead, and repeats the same biome if it
    is the only one.

    With the island number Check Layout, island checks stay reachable with a
    single biome, because a repeated biome keeps counting up the island
    numbers.  With the biome layout, each biome's checks need its Access item.

    Turn this off to play the game's normal biome order, with no Access items."""
    display_name = "Biome Lock"


class StartingBiome(Choice):
    """The biome your runs start in when Biome Lock is on.  You own its Access
    item from the start.  Random picks one of the four biomes for the seed."""
    display_name = "Starting Biome"
    # Numbered like the game's own biomes.
    option_tropical = 1
    option_ice = 2
    alias_arctic = 2
    option_desert = 3
    option_volcano = 4
    alias_volcanic = 4
    default = "random"


# ──────────────────────────────────────────────────────────────────────────
# Dataclass - option order controls order in the YAML template and WebUI
# ──────────────────────────────────────────────────────────────────────────

@dataclass
class CrabChampsOption(PerGameCommonOptions):
    # Goal
    required_rank: RequiredRank
    run_length: RunLength
    weapons_for_completion: WeaponsForCompletion
    melee_for_completion: MeleeForCompletion
    ability_for_completion: AbilityForCompletion
    # Equipment
    weapons_in_pool: WeaponsInPool
    melee_in_pool: MeleeInPool
    abilities_in_pool: AbilitiesInPool
    starting_weapons: StartingWeapons
    starting_melee: StartingMelee
    starting_abilities: StartingAbilities
    equipment_check_mode: EquipmentCheckMode
    # Run checks
    check_layout: CheckLayout
    extra_rank_checks: ExtraRankChecks
    max_rank: MaxRank
    minimize_run_checks: MinimizeRunChecks
    # Biomes
    biome_lock: BiomeLock
    starting_biome: StartingBiome
    # Pickups
    pickup_checks: PickupChecks
    granted_item_checks: GrantedItemChecks
    limit_pickups: LimitPickups
    greed_item_mode: GreedItemMode
    # Inventory slots
    progressive_slots: ProgressiveSlots
    starting_perk_slots: StartingPerkSlots
    starting_weapon_mod_slots: StartingWeaponModSlots
    starting_ability_mod_slots: StartingAbilityModSlots
    starting_melee_mod_slots: StartingMeleeModSlots
    # Received items
    starting_item_percentage: StartingItemPercentage
    biome_item_percentage: BiomeItemPercentage
    crystal_cache_percentage: CrystalCachePercentage
    guaranteed_items: GuaranteedItemsOption
    # Traps
    trap_percentage: TrapPercentage
    trap_weights: TrapWeights
    trap_duration: TrapDuration
    trap_grace_seconds: TrapGraceSeconds
    crystal_tax_percent: CrystalTaxPercent
    slowdown_percent: SlowdownPercent
    weak_shots_percent: WeakShotsPercent
    bruise_percent: BruisePercent
    # Perk Boost
    perk_boost_count: PerkBoostCount
    perk_boost_levels: PerkBoostLevels
    death_link: DeathLink


# Groups for the WebUI and the YAML template.  Every option must be in one.
crab_option_groups = [
    OptionGroup("Goal", [
        RequiredRank, RunLength, WeaponsForCompletion, MeleeForCompletion, AbilityForCompletion,
    ]),
    OptionGroup("Equipment", [
        WeaponsInPool, MeleeInPool, AbilitiesInPool,
        StartingWeapons, StartingMelee, StartingAbilities, EquipmentCheckMode,
    ]),
    OptionGroup("Run Checks", [
        CheckLayout, ExtraRankChecks, MaxRank, MinimizeRunChecks,
    ]),
    OptionGroup("Biomes", [
        BiomeLock, StartingBiome,
    ]),
    OptionGroup("Pickup Checks", [
        PickupChecks, GrantedItemChecks, LimitPickups, GreedItemMode,
    ]),
    OptionGroup("Inventory Slots", [
        ProgressiveSlots, StartingPerkSlots, StartingWeaponModSlots,
        StartingAbilityModSlots, StartingMeleeModSlots,
    ]),
    OptionGroup("Received Items", [
        StartingItemPercentage, BiomeItemPercentage, CrystalCachePercentage, GuaranteedItemsOption,
    ]),
    OptionGroup("Traps", [
        TrapPercentage,
        TrapWeights,
        TrapDuration, TrapGraceSeconds,
        CrystalTaxPercent, SlowdownPercent, WeakShotsPercent, BruisePercent,
    ]),
    OptionGroup("Perk Boost", [
        PerkBoostCount, PerkBoostLevels,
    ]),
    OptionGroup("Multiplayer", [
        DeathLink,
    ]),
]


# Ready-made settings for the WebUI.  Anything not listed keeps its default.
crab_option_presets = {
    "Short and easy": {
        "required_rank": "bronze",
        "run_length": "short",
        "weapons_for_completion": 2,
        "melee_for_completion": 1,
        "ability_for_completion": 1,
        "weapons_in_pool": 3,
        "melee_in_pool": 1,
        "abilities_in_pool": 1,
        "pickup_checks": False,
        "extra_rank_checks": "none",
    },
    "Standard": {},
    "Long grind": {
        "required_rank": "gold",
        "run_length": "full",
        "weapons_for_completion": 8,
        "melee_for_completion": 4,
        "ability_for_completion": 5,
        "weapons_in_pool": 12,
        "melee_in_pool": 5,
        "abilities_in_pool": 7,
        "extra_rank_checks": "filler_only",
        "max_rank": "ruby",
        "equipment_check_mode": "filler_only",
        "limit_pickups": "pool_and_checks",
    },
}
