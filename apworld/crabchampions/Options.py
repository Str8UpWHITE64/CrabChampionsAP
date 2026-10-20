import typing
from dataclasses import dataclass
from Options import Toggle, DefaultOnToggle, Range, Choice, ItemDict, DeathLink, PerGameCommonOptions


# ──────────────────────────────────────────────────────────────────────────
# Victory conditions
# ──────────────────────────────────────────────────────────────────────────

class RequiredRank(Choice):
    """The minimum rank you must complete to win.  A run is "completed at
    Rank X" when you finish the final island while accumulating at least
    Rank X's worth of difficulty modifier points.

    Difficulty thresholds:
      Bronze (0), Silver (1), Gold (2-3), Sapphire (4-5), Emerald (6-7),
      Ruby (8-9), Diamond (10-15), Prismatic (16+)

    Higher ranks demand stacking more modifier cards before each island, so
    higher requirements mean tougher runs.  Run-completion locations are
    generated for this rank by default; see Extra Rank Checks to also
    generate locations for higher ranks."""
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

    All island/equipment/rank locations scale with this value - a Full run
    has roughly twice the location count of a Short run."""
    display_name = "Run Length"
    option_short = 28
    option_full = 56
    default = 28


class WeaponsForCompletion(Range):
    """How many DIFFERENT weapons must be used to complete victory-rank runs
    before you can win.  E.g. with this set to 5, you'll need to finish the
    final island five separate times, each with a different weapon, all at
    Required Rank or higher.

    Only weapons in the AP pool count toward this.  Weapons you have from
    the start can still generate location checks (see Equipment Check
    Mode), but they never advance the goal.  Weapons in Pool is raised to
    match this value when it is lower.

    Capped at the total number of weapons in the game (20)."""
    display_name = "Weapons for Completion"
    range_start = 1
    range_end = 20
    default = 5


class MeleeForCompletion(Range):
    """How many DIFFERENT melee weapons must be used to complete victory-rank
    runs before you can win.  Works the same as Weapons for Completion but
    for melee.

    Set to 0 to disable melee entirely - no melee items in the pool, no
    melee location checks, and no melee requirement for victory."""
    display_name = "Melee for Completion"
    range_start = 0
    range_end = 5
    default = 3


class AbilityForCompletion(Range):
    """How many DIFFERENT abilities must be used to complete victory-rank
    runs before you can win.  Works the same as Weapons for Completion but
    for abilities.

    Set to 0 to disable abilities entirely - no ability items in the pool,
    no ability location checks, and no ability requirement for victory."""
    display_name = "Abilities for Completion"
    range_start = 0
    range_end = 7
    default = 3


# ──────────────────────────────────────────────────────────────────────────
# Item pool / equipment
# ──────────────────────────────────────────────────────────────────────────

class WeaponsInPool(Range):
    """How many weapons are randomly selected from the 20 available to be
    AP items.  Pool weapons must be received via Archipelago before you can
    use them.  Non-pool weapons are always available from the start.

    Each pool weapon also generates its own per-island run-completion
    location, so a larger pool means more checks.

    Example: pool=5, for_completion=3 means 5 weapons are AP items, all 5
    have location checks, but only 3 distinct ones must be used to win.

    Must be >= Weapons for Completion (auto-clamped).  Set to 20 to put
    every weapon in the pool - Starting Weapons is then forced to at least
    1 so you always begin with something usable."""
    display_name = "Weapons in Pool"
    range_start = 1
    range_end = 20
    default = 5


class MeleeInPool(Range):
    """How many melee weapons (out of 5) are randomly selected to be AP
    items.  See Weapons in Pool for the full mechanic.

    Must be >= Melee for Completion (auto-clamped).  Forced to 0 when
    Melee for Completion is 0.  Set to 5 to put every melee weapon in the
    pool - one random pool melee is then added to your starting inventory
    so you always begin with something usable."""
    display_name = "Melee in Pool"
    range_start = 0
    range_end = 5
    default = 0


class AbilitiesInPool(Range):
    """How many abilities (out of 7) are randomly selected to be AP items.
    See Weapons in Pool for the full mechanic.

    Must be >= Abilities for Completion (auto-clamped).  Forced to 0 when
    Abilities for Completion is 0.  Set to 7 to put every ability in the
    pool - one random pool ability is then added to your starting
    inventory so you always begin with something usable."""
    display_name = "Abilities in Pool"
    range_start = 0
    range_end = 7
    default = 0


class StartingWeapons(Range):
    """How many of your pool weapons you begin the game already holding.
    These are randomly selected from Weapons in Pool and pre-collected, so
    you can start working on equipment-run checks immediately without
    waiting to receive a weapon from another player.

    A weapon you start with is removed from the item pool rather than
    duplicated, so its slot goes to filler instead of a second copy of
    something you already hold.

    Must be < Weapons in Pool (at least one weapon must still be findable
    via AP).  Set to 0 to start with no pool weapons unlocked - except
    when Weapons in Pool is 20, where this is forced to at least 1 because
    no weapon would otherwise be available at the start."""
    display_name = "Starting Weapons"
    range_start = 0
    range_end = 19
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
    """The highest rank for which any location checks are generated.  Must
    be >= Required Rank (auto-clamped).

    Has no effect unless Extra Rank Checks is set to something other than
    "none" - without extra rank checks, only Required Rank generates
    locations and Max Rank is ignored."""
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
    """Controls whether ranks ABOVE Required Rank generate additional
    location checks.  Replaces the legacy Extra Ranked Island Checks +
    Non-Progression Above Required pair with one option that captures
    the meaningful combinations.

    none:
        Only Required Rank produces ranked checks.  Higher ranks are
        ignored and produce no additional locations.  Smallest pool.
    progression:
        Ranks above Required (up to Max Rank) add new ranked checks AND
        those locations can hold progression items.  Greatly increases
        location count and turns higher difficulty into real progression.
    filler_only:
        Ranks above Required add new ranked checks but those locations
        are marked excluded - they only hold filler.  Use this to add
        more checks for variety/filler without forcing yourself to grind
        higher ranks for critical items.

    Has no effect when Required Rank == Max Rank (no extra ranks exist)."""
    display_name = "Extra Rank Checks"
    option_none = 0
    option_progression = 1
    option_filler_only = 2
    default = 0


class CascadeRankedChecks(Toggle):
    """When enabled, completing an in-game check at a higher rank also
    triggers the equivalent check at every lower rank.  E.g. completing
    "Island 5 with Auto Rifle on Gold" also sends checks for "Island 5
    with Auto Rifle on Silver" and "...on Bronze".

    Convenient when playing at high ranks - you don't have to redo runs
    at lower ranks for the easier checks.  Has no effect on generation
    or fill, only on what the in-game client sends as you play."""
    display_name = "Cascade Ranked Checks"


class MinimizeRunChecks(Toggle):
    """When enabled, drops generalized run-completion checks that are made
    redundant by the most-specific equipment-and-rank check.  Pool weapons
    always have these locations, so the redundant ones are always covered:

      - "Complete Island X on Rank" checks are removed
      - "Complete Island X with Weapon" checks are removed

    The most specific "Complete Island X with Weapon on Rank" check is
    always kept, since completing it implies completing all the dropped
    variants.  Plain "Complete Island X" (unranked) is also kept.

    Has no effect only in the unusual case where there are no equipment
    runs at all (which currently can't happen since Weapons in Pool is
    forced to >= 1)."""
    display_name = "Minimize Run Checks"


# ──────────────────────────────────────────────────────────────────────────
# Pickup checks
# ──────────────────────────────────────────────────────────────────────────

class PickupChecks(DefaultOnToggle):
    """When enabled, picking up perks, relics, weapon mods, melee mods,
    or ability mods for the FIRST TIME (per item, per multiworld) sends
    a location check, e.g. "Perk: Driller" or "Relic: Time Ring".

    Adds up to 305 location checks.  When disabled, these pickup
    locations don't exist and the item pool focuses on island/equipment/
    rank-run checks only.

    See also Limit Pickup Pool / Limit Pickup Locations to scale this
    down to per-run inventory caps."""
    display_name = "Pickup Checks"


class LimitPickupPool(Toggle):
    """When enabled, the AP item pool is limited to a randomly-selected
    subset of pickups matching your per-run inventory caps:
      24 perks, 24 weapon mods, 12 ability mods, 12 melee mods, 10 relics

    Items NOT in the chosen subset stay in-game and can be picked up
    normally during runs, but are never sent or received via AP.

    Tag-group coverage is enforced - at least one provider per pickup-tag
    group is guaranteed in the subset, so tag-gated locations (like
    "Relic: Time Ring") remain reachable.

    Pairs naturally with Limit Pickup Locations.  Either option can be
    enabled independently; both share the same chosen subset."""
    display_name = "Limit Pickup Pool"


class LimitPickupLocations(Toggle):
    """When enabled, pickup location checks are only generated for items
    in the randomly-selected subset (see Limit Pickup Pool for the
    subset sizes).  Items not in the subset still appear in-game but
    produce no location check when picked up.

    Pairs naturally with Limit Pickup Pool.  Either option can be
    enabled independently; both share the same chosen subset when both
    are on."""
    display_name = "Limit Pickup Locations"


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
    """Percentage of "extra" item pool slots filled with Crystal Cache
    (in-game currency rewards) instead of duplicate perk/mod stacks.

    The pool is built by first adding required items (pool equipment,
    one of each pickup, etc.).  Whatever slots remain are split between
    crystal filler and extra stackable copies based on this percentage:
      0%   = all extras are duplicate perks/mods (more variety in
             received items)
      75%  = default; balanced mix
      100% = all extras are Crystal Cache (less spam of duplicates)

    Crystal Cache items grant in-game currency for shops/upgrades."""
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
    """Forces specific items into the item pool regardless of other
    settings.  Format is a YAML mapping of item names to copy counts:

      guaranteed_items:
        Auto Rifle: 1
        Time Bolt: 2

    Useful for ensuring favorite items end up randomized.  Item names
    must match exactly (case-sensitive).  Only stackable items (perks and
    mods) take extra copies; relics and equipment are unique, so they get
    one copy whatever the count."""
    display_name = "Guaranteed Items"


# ──────────────────────────────────────────────────────────────────────────
# Traps
# ──────────────────────────────────────────────────────────────────────────

class TrapPercentage(Range):
    """Percentage of the filler slots that become traps.  Traps are
    received items that make a run harder for a short time; none of them
    is permanent, removes your equipment, or can kill you outright.

    0 = no traps (default).  Filler slots are the slots left over after
    equipment, one of each pickup and any Perk Boosts are placed."""
    display_name = "Trap Percentage"
    range_start = 0
    range_end = 100
    default = 0


class TrapWeightCrystalTax(Range):
    """Relative chance that a trap is Crystal Tax (you lose a share of your
    crystals).  0 removes this trap from the pool."""
    display_name = "Trap Weight: Crystal Tax"
    range_start = 0
    range_end = 100
    default = 20


class TrapWeightSlowdown(Range):
    """Relative chance that a trap is a Slowdown Trap (you move slower until
    the next island is cleared).  0 removes this trap from the pool."""
    display_name = "Trap Weight: Slowdown"
    range_start = 0
    range_end = 100
    default = 20


class TrapWeightWeakShots(Range):
    """Relative chance that a trap is a Weak Shots Trap (your outgoing damage
    is cut for the trap duration).  0 removes this trap from the pool."""
    display_name = "Trap Weight: Weak Shots"
    range_start = 0
    range_end = 100
    default = 20


class TrapWeightBruise(Range):
    """Relative chance that a trap is a Bruise Trap (you lose a share of your
    current health, never the last point).  0 removes this trap."""
    display_name = "Trap Weight: Bruise"
    range_start = 0
    range_end = 100
    default = 20


class TrapWeightGrow(Range):
    """Relative chance that a trap is a Grow Trap (a bigger crab for the trap
    duration).  0 removes this trap from the pool."""
    display_name = "Trap Weight: Grow"
    range_start = 0
    range_end = 100
    default = 10


class TrapWeightShrink(Range):
    """Relative chance that a trap is a Shrink Trap (a smaller crab for the
    trap duration).  0 removes this trap from the pool."""
    display_name = "Trap Weight: Shrink"
    range_start = 0
    range_end = 100
    default = 10


class TrapWeightHeavyGravity(Range):
    """Relative chance that a trap is a Heavy Gravity Trap (stronger gravity
    for the trap duration).  0 removes this trap from the pool."""
    display_name = "Trap Weight: Heavy Gravity"
    range_start = 0
    range_end = 100
    default = 10


class TrapWeightFloatyGravity(Range):
    """Relative chance that a trap is a Floaty Gravity Trap (weaker gravity
    for the trap duration).  0 removes this trap from the pool."""
    display_name = "Trap Weight: Floaty Gravity"
    range_start = 0
    range_end = 100
    default = 10


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
    """How many Perk Boost items are added to the pool (taking filler
    slots).  A Perk Boost adds one level to a random perk you are holding
    in the current run.  It is strong, so it is limited three ways: this
    count per seed, Perk Boost Max Per Run, and Perk Boost Level Cap.

    0 = none (default)."""
    display_name = "Perk Boost Count"
    range_start = 0
    range_end = 50
    default = 0


class PerkBoostMaxPerRun(Range):
    """The most Perk Boosts that can take effect in one run.  Boosts over the
    limit wait for the next run."""
    display_name = "Perk Boost Max Per Run"
    range_start = 1
    range_end = 20
    default = 3


class PerkBoostLevelCap(Range):
    """A Perk Boost never raises a perk above this level.  Perks already at
    the cap are skipped; if every perk you hold is capped, the boost waits."""
    display_name = "Perk Boost Level Cap"
    range_start = 2
    range_end = 10
    default = 5


# ──────────────────────────────────────────────────────────────────────────
# Dataclass - option order controls display order in the WebUI
# ──────────────────────────────────────────────────────────────────────────

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
    extra_rank_checks: ExtraRankChecks
    cascade_ranked_checks: CascadeRankedChecks
    minimize_run_checks: MinimizeRunChecks
    # Pickup checks
    pickup_checks: PickupChecks
    limit_pickup_pool: LimitPickupPool
    limit_pickup_locations: LimitPickupLocations
    granted_item_checks: GrantedItemChecks
    # Progressive inventory slots
    progressive_slots: ProgressiveSlots
    starting_perk_slots: StartingPerkSlots
    starting_weapon_mod_slots: StartingWeaponModSlots
    starting_ability_mod_slots: StartingAbilityModSlots
    starting_melee_mod_slots: StartingMeleeModSlots
    # Received items per run
    starting_item_percentage: StartingItemPercentage
    biome_item_percentage: BiomeItemPercentage
    # Filler / misc
    crystal_cache_percentage: CrystalCachePercentage
    greed_item_mode: GreedItemMode
    guaranteed_items: GuaranteedItemsOption
    # Traps
    trap_percentage: TrapPercentage
    trap_weight_crystal_tax: TrapWeightCrystalTax
    trap_weight_slowdown: TrapWeightSlowdown
    trap_weight_weak_shots: TrapWeightWeakShots
    trap_weight_bruise: TrapWeightBruise
    trap_weight_grow: TrapWeightGrow
    trap_weight_shrink: TrapWeightShrink
    trap_weight_heavy_gravity: TrapWeightHeavyGravity
    trap_weight_floaty_gravity: TrapWeightFloatyGravity
    trap_duration: TrapDuration
    trap_grace_seconds: TrapGraceSeconds
    crystal_tax_percent: CrystalTaxPercent
    slowdown_percent: SlowdownPercent
    weak_shots_percent: WeakShotsPercent
    bruise_percent: BruisePercent
    # Perk Boost
    perk_boost_count: PerkBoostCount
    perk_boost_max_per_run: PerkBoostMaxPerRun
    perk_boost_level_cap: PerkBoostLevelCap
    death_link: DeathLink
