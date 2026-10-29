from typing import Dict, Set, List

from Options import OptionError
from BaseClasses import MultiWorld, Region, Item, Entrance, Tutorial, ItemClassification, LocationProgressType

from worlds.AutoWorld import World, WebWorld

from .Items import (
    CrabChampsItem, CrabChampsItemCategory, item_dictionary, key_item_names,
    item_descriptions, BuildItemPool, weapon_item_names, melee_item_names,
    ability_item_names, GREED_ITEM_NAMES, PICKUP_TAG_REQUIREMENTS, TAG_PROVIDER_NAMES,
    select_pickup_subsets, PICKUP_INVENTORY_CAPS,
    biome_access_item_names,
)
from .Locations import (
    CrabChampsLocation, CrabChampsLocationCategory, location_tables,
    RANK_NAMES, MAX_ISLANDS, NUM_RANKS, ID_LAYOUT,
    rank_from_location_name, SHOP_ISLANDS, _island_prefix,
    BIOME_BASE_CATEGORY, ISLAND_TO_BIOME_CATEGORY, biome_index_from_name,
    biome_index_to_biome,
)
from .Options import CrabChampsOption
from .rules import EQUIPMENT_CATEGORIES, set_all_rules


class CrabChampsWeb(WebWorld):
    bug_report_page = ""
    theme = "stone"
    setup_en = Tutorial(
        "Multiworld Setup Guide",
        "A guide to setting up the Archipelago Crab Champions randomizer on your computer.",
        "English",
        "setup_en.md",
        "setup/en",
        ["Str8UpWHITE64"]
    )
    game_info_languages = ["en"]
    tutorials = [setup_en]


class CrabChampsWorld(World):
    """
    Crab Champions is a rogue-like crab game.
    """

    game: str = "Crab Champions"
    options_dataclass = CrabChampsOption
    options: CrabChampsOption
    topology_present: bool = False
    web = CrabChampsWeb()
    base_id = 1890000
    enabled_location_categories: Set[CrabChampsLocationCategory]
    required_client_version = (0, 5, 0)
    item_name_to_id = CrabChampsItem.get_name_to_id()
    location_name_to_id = CrabChampsLocation.get_name_to_id()
    item_name_groups = {}
    item_descriptions = item_descriptions

    def __init__(self, multiworld: MultiWorld, player: int):
        super().__init__(multiworld, player)
        self.enabled_location_categories = set()
        # Pool selections — populated in generate_early
        self.pool_weapons: List[str] = []
        self.pool_melee: List[str] = []
        self.pool_abilities: List[str] = []
        self.non_pool_weapons: List[str] = []
        self.non_pool_melee: List[str] = []
        self.non_pool_abilities: List[str] = []
        # Precollected pool equipment — the player starts holding these, so
        # they are left out of the item pool in create_items.
        self.starting_weapon_names: List[str] = []
        self.starting_melee: List[str] = []
        self.starting_abilities: List[str] = []
        # Pickup-subset selections — populated when limit_pickup_pool or
        # limit_pickup_locations is enabled.  Maps category key
        # (perk/weapon_mod/ability_mod/melee_mod/relic) -> list of names.
        self.pickup_subsets: Dict[str, List[str]] = {}
        self._allowed_pickup_names: Set[str] = set()
        # Tracks which TAG_PROVIDER names have already been promoted to
        # progression. Only the first copy of each provider needs to be
        # progression — `any(state.has(p))` is satisfied by one copy.
        self._provider_progression_marked: Set[str] = set()
        # Game biome number (1-4) the runs start in; 0 while biome_lock is off.
        self.start_biome: int = 0

    def generate_early(self):
        # A tracker rebuilding this slot passes the random choices of the real
        # seed back in (see interpret_slot_data); use them instead of rolling.
        regen = getattr(self.multiworld, "re_gen_passthrough", {}).get(self.game)

        # Clamp max_rank >= required_rank
        if self.options.max_rank.value < self.options.required_rank.value:
            self.options.max_rank.value = self.options.required_rank.value

        # Force melee/ability pool to 0 when completion is 0
        if self.options.melee_for_completion.value == 0:
            self.options.melee_in_pool.value = 0
        if self.options.ability_for_completion.value == 0:
            self.options.abilities_in_pool.value = 0

        # Clamp pool sizes >= completion counts
        if self.options.weapons_in_pool.value < self.options.weapons_for_completion.value:
            self.options.weapons_in_pool.value = self.options.weapons_for_completion.value
        if self.options.melee_in_pool.value < self.options.melee_for_completion.value:
            self.options.melee_in_pool.value = self.options.melee_for_completion.value
        if self.options.abilities_in_pool.value < self.options.ability_for_completion.value:
            self.options.abilities_in_pool.value = self.options.ability_for_completion.value

        # Clamp pool sizes to the full equipment count.  A full pool leaves
        # nothing unlocked at the start, so one random pool item of that
        # category is precollected below to keep the player able to play.
        max_weapons_pool = len(weapon_item_names)   # 20
        max_melee_pool = len(melee_item_names)       # 5
        max_ability_pool = len(ability_item_names)    # 7
        if self.options.weapons_in_pool.value > max_weapons_pool:
            self.options.weapons_in_pool.value = max_weapons_pool
        if self.options.melee_in_pool.value > max_melee_pool:
            self.options.melee_in_pool.value = max_melee_pool
        if self.options.abilities_in_pool.value > max_ability_pool:
            self.options.abilities_in_pool.value = max_ability_pool

        # Guard: when equipment_check_mode is disabled, non-pool equipment has
        # no locations, so completion cannot exceed the pool size.  With the
        # pool caps at the full equipment count this can no longer trigger
        # (in_pool was already raised to >= for_completion above), but it is
        # kept so the invariant survives any future range change.
        equip_mode = self.options.equipment_check_mode.value
        if equip_mode == 2:  # disabled
            if self.options.weapons_for_completion.value > self.options.weapons_in_pool.value:
                self.options.weapons_for_completion.value = self.options.weapons_in_pool.value
            if self.options.melee_for_completion.value > self.options.melee_in_pool.value:
                self.options.melee_for_completion.value = self.options.melee_in_pool.value
            if self.options.ability_for_completion.value > self.options.abilities_in_pool.value:
                self.options.ability_for_completion.value = self.options.abilities_in_pool.value

        # Randomly select which equipment is in the AP pool
        self.pool_weapons = sorted(
            self.random.sample(weapon_item_names, self.options.weapons_in_pool.value)
        )
        self.pool_melee = sorted(
            self.random.sample(melee_item_names, self.options.melee_in_pool.value)
        ) if self.options.melee_in_pool.value > 0 else []
        self.pool_abilities = sorted(
            self.random.sample(ability_item_names, self.options.abilities_in_pool.value)
        ) if self.options.abilities_in_pool.value > 0 else []
        if regen:
            self.pool_weapons = list(regen["pool_weapons"])
            self.pool_melee = list(regen["pool_melee"])
            self.pool_abilities = list(regen["pool_abilities"])

        self.pool_weapon_set = frozenset(self.pool_weapons)
        self.pool_melee_set = frozenset(self.pool_melee)
        self.pool_ability_set = frozenset(self.pool_abilities)
        self.non_pool_weapons = [w for w in weapon_item_names if w not in self.pool_weapon_set]
        self.non_pool_melee = [m for m in melee_item_names if m not in self.pool_melee_set]
        self.non_pool_abilities = [a for a in ability_item_names if a not in self.pool_ability_set]

        equip_mode = self.options.equipment_check_mode.value  # 0=regular, 1=filler_only, 2=disabled
        minimize = bool(self.options.minimize_run_checks.value)
        # Equipment runs exist when EITHER non-pool equipment is enabled
        # (equip_mode != disabled) OR any pool has at least one item.  Pool
        # equipment ALWAYS gets WEAPON_RUN/RANKED_WEAPON_RUN locations
        # regardless of equip_mode, so `minimize` should drop the redundant
        # ISLAND/RANK checks even when equip_mode is disabled.
        have_equipment = (
            equip_mode != 2
            or len(self.pool_weapons) > 0
            or len(self.pool_melee) > 0
            or len(self.pool_abilities) > 0
        )
        drop_redundant = minimize and have_equipment
        self._drop_redundant = drop_redundant

        # Clamp starting_weapons < weapons_in_pool (must find at least one)
        max_starting = max(0, self.options.weapons_in_pool.value - 1)
        if self.options.starting_weapons.value > max_starting:
            self.options.starting_weapons.value = max_starting

        # A full weapon pool leaves no weapon available at the start, so at
        # least one pool weapon must be precollected.
        if (self.options.weapons_in_pool.value == len(weapon_item_names)
                and self.options.starting_weapons.value < 1):
            self.options.starting_weapons.value = 1

        # A free check is one that needs no item.  Without the unranked island
        # checks (dropped by minimize when extra ranks are on) almost every
        # check needs a pool weapon, so a seed that starts with none can have
        # nowhere to put its first one.
        if (self.options.extra_rank_checks.value != 0 and drop_redundant
                and self.options.starting_weapons.value < 1):
            self.options.starting_weapons.value = 1

        # Select and precollect starting weapons from the pool
        self.starting_weapon_names = []
        if self.options.starting_weapons.value > 0:
            self.starting_weapon_names = self.random.sample(
                self.pool_weapons, self.options.starting_weapons.value
            )
            if regen:
                self.starting_weapon_names = list(regen["starting_weapon_names"])
            for weapon_name in self.starting_weapon_names:
                self.multiworld.push_precollected(self.create_item(weapon_name))

        # Melee/abilities have no starting-count option, so a full pool gets
        # exactly one random precollected item for the same reason.
        self.starting_melee = []
        self.starting_abilities = []
        if self.options.melee_in_pool.value == len(melee_item_names):
            self.starting_melee = self.random.sample(self.pool_melee, 1)
            if regen:
                self.starting_melee = list(regen["starting_melee"])
            for melee_name in self.starting_melee:
                self.multiworld.push_precollected(self.create_item(melee_name))
        if self.options.abilities_in_pool.value == len(ability_item_names):
            self.starting_abilities = self.random.sample(self.pool_abilities, 1)
            if regen:
                self.starting_abilities = list(regen["starting_abilities"])
            for ability_name in self.starting_abilities:
                self.multiworld.push_precollected(self.create_item(ability_name))

        # Biome lock: the player starts with the Access item of the starting biome.
        self.start_biome = 0
        if self.options.biome_lock.value:
            self.start_biome = regen["start_biome"] if regen else self.options.starting_biome.value
            self.multiworld.push_precollected(
                self.create_item(biome_access_item_names[self.start_biome - 1]))

        # Always-on categories
        self.enabled_location_categories.add(CrabChampsLocationCategory.ISLAND)
        self.enabled_location_categories.add(CrabChampsLocationCategory.RANK_RUN)

        # Pickup categories (perks/relics/mods) — only when pickup_checks is enabled
        if self.options.pickup_checks.value:
            self.enabled_location_categories.add(CrabChampsLocationCategory.PERK)
            self.enabled_location_categories.add(CrabChampsLocationCategory.RELIC)
            self.enabled_location_categories.add(CrabChampsLocationCategory.WEAPON_MOD)
            self.enabled_location_categories.add(CrabChampsLocationCategory.MELEE_MOD)
            self.enabled_location_categories.add(CrabChampsLocationCategory.ABILITY_MOD)

        # Ranked island locations always exist (at least for required_rank),
        # unless minimize drops them in favor of ranked equipment-run checks.
        if not drop_redundant:
            self.enabled_location_categories.add(CrabChampsLocationCategory.RANKED_ISLAND)

        # Weapon run locations: pool weapons always exist, non-pool depends on equip_mode.
        # Always enable the category; _should_include_location filters per-weapon.
        # The unranked equipment runs double as the Bronze tier, so they stay
        # whenever Bronze is covered; minimize only drops them for higher ranks.
        self.enabled_location_categories.add(CrabChampsLocationCategory.WEAPON_RUN)
        self.enabled_location_categories.add(CrabChampsLocationCategory.RANKED_WEAPON_RUN)

        # Melee/ability run locations: only when melee/ability completion is active
        if self.options.melee_for_completion.value > 0:
            self.enabled_location_categories.add(CrabChampsLocationCategory.MELEE_RUN)
            self.enabled_location_categories.add(CrabChampsLocationCategory.RANKED_MELEE_RUN)
        if self.options.ability_for_completion.value > 0:
            self.enabled_location_categories.add(CrabChampsLocationCategory.ABILITY_RUN)
            self.enabled_location_categories.add(CrabChampsLocationCategory.RANKED_ABILITY_RUN)

        # Biome layout: the island checks switch to their biome twins, and the goal gets run-level equipment
        # checks (the biome layout has no single final-island check to count).
        if self.options.check_layout.value == 1:
            self.enabled_location_categories = {
                ISLAND_TO_BIOME_CATEGORY.get(c, c) for c in self.enabled_location_categories
            }
            self.enabled_location_categories.add(CrabChampsLocationCategory.RUN_WEAPON)
            if self.options.melee_for_completion.value > 0:
                self.enabled_location_categories.add(CrabChampsLocationCategory.RUN_MELEE)
            if self.options.ability_for_completion.value > 0:
                self.enabled_location_categories.add(CrabChampsLocationCategory.RUN_ABILITY)

        # Pickup subsets: select once when either limit option is enabled.
        # Both options share the same chosen subset.
        if (self.options.limit_pickup_pool.value
                or self.options.limit_pickup_locations.value):
            exclude = (GREED_ITEM_NAMES
                       if self.options.greed_item_mode.value == 2
                       else frozenset())
            self.pickup_subsets = select_pickup_subsets(self.random, exclude_names=exclude)
            if regen:
                self.pickup_subsets = {k: list(v) for k, v in regen["pickup_subsets"].items()}
            self._allowed_pickup_names = {
                n for names in self.pickup_subsets.values() for n in names
            }

    def create_regions(self):
        regions: Dict[str, Region] = {}
        regions["Menu"] = self.create_region("Menu", [])

        region_names = [
            "Island Completion",
            "Ranked Island Completion",
            "Perk Pickups",
            "Relic Pickups",
            "Rank Runs",
            "Weapon Runs",
            "Ranked Weapon Runs",
            "Melee Runs",
            "Ranked Melee Runs",
            "Ability Runs",
            "Ranked Ability Runs",
            "Weapon Mod Pickups",
            "Melee Mod Pickups",
            "Ability Mod Pickups",
            "Biome Island Completion",
            "Ranked Biome Island Completion",
            "Biome Weapon Runs",
            "Ranked Biome Weapon Runs",
            "Biome Melee Runs",
            "Ranked Biome Melee Runs",
            "Biome Ability Runs",
            "Ranked Biome Ability Runs",
            "Run Weapon Completion",
            "Run Melee Completion",
            "Run Ability Completion",
        ]
        regions.update({
            name: self.create_region(name, location_tables[name])
            for name in region_names
        })

        # Connect all regions from Menu
        for region_name in region_names:
            connection = Entrance(self.player, f"Menu -> {region_name}", regions["Menu"])
            regions["Menu"].exits.append(connection)
            connection.connect(regions[region_name])

    def _extract_equip_name(self, location_name: str) -> str:
        """Extract equipment name from a location like 'Complete Island 5 with Auto Rifle on Gold'."""
        after_with = location_name.split(" with ", 1)[1]
        # Strip rank suffix if present
        if " on " in after_with:
            return after_with.rsplit(" on ", 1)[0]
        return after_with

    def _is_pool_equipment(self, equip_name: str, category) -> bool:
        """Check if an equipment name belongs to the randomized AP pool."""
        if category in (CrabChampsLocationCategory.WEAPON_RUN,
                        CrabChampsLocationCategory.RANKED_WEAPON_RUN,
                        CrabChampsLocationCategory.RUN_WEAPON):
            return equip_name in self.pool_weapon_set
        if category in (CrabChampsLocationCategory.MELEE_RUN,
                        CrabChampsLocationCategory.RANKED_MELEE_RUN,
                        CrabChampsLocationCategory.RUN_MELEE):
            return equip_name in self.pool_melee_set
        if category in (CrabChampsLocationCategory.ABILITY_RUN,
                        CrabChampsLocationCategory.RANKED_ABILITY_RUN,
                        CrabChampsLocationCategory.RUN_ABILITY):
            return equip_name in self.pool_ability_set
        return False

    @staticmethod
    def _extract_island_num(name: str) -> int:
        """Extract the island number from a location name.
        Handles both 'Complete Island X ...' and 'Reach Shop on Island X ...' patterns.
        A biome-layout name gives its position in the run (1..56) instead."""
        k = biome_index_from_name(name)
        if k >= 0:
            return k + 1
        idx = name.find("Island ")
        if idx == -1:
            return 0
        start = idx + 7
        end = start
        while end < len(name) and name[end].isdigit():
            end += 1
        return int(name[start:end]) if end > start else 0

    def _should_include_location(self, location) -> bool:
        """Check if a location should be included based on options."""
        if location.category not in self.enabled_location_categories:
            return False
        # Biome-layout checks are filtered like the island ones they mirror.
        category = BIOME_BASE_CATEGORY.get(location.category, location.category)

        # Exclude greed pickup locations when greed_item_mode == skip
        if self.options.greed_item_mode.value == 2:
            if category in (
                CrabChampsLocationCategory.PERK,
                CrabChampsLocationCategory.RELIC,
                CrabChampsLocationCategory.MELEE_MOD,
            ):
                # Extract the item name from location name: "Perk: Leap Of Faith" -> "Leap Of Faith"
                item_name = location.name.split(": ", 1)[-1] if ": " in location.name else ""
                if item_name in GREED_ITEM_NAMES:
                    return False

        # Limit pickup locations to the chosen subset when enabled.
        # Only restrict pickup categories — equipment runs are handled separately.
        if self.options.limit_pickup_locations.value:
            if category in (
                CrabChampsLocationCategory.PERK,
                CrabChampsLocationCategory.RELIC,
                CrabChampsLocationCategory.WEAPON_MOD,
                CrabChampsLocationCategory.MELEE_MOD,
                CrabChampsLocationCategory.ABILITY_MOD,
            ):
                item_name = location.name.split(": ", 1)[-1] if ": " in location.name else ""
                if item_name not in self._allowed_pickup_names:
                    return False

        run_length = self.options.run_length.value
        max_rank = self.options.max_rank.value
        required_rank = self.options.required_rank.value
        extra_rank_mode = self.options.extra_rank_checks.value
        extra_ranked = extra_rank_mode != 0
        equip_mode = self.options.equipment_check_mode.value

        # Bronze has no checks of its own: the plain (unranked) check is the
        # Bronze check. Ranked locations start at Silver.
        # Determine which ranks are allowed for ranked locations:
        # Always include required_rank. When extra is on, include all up to max_rank.
        def _rank_allowed(rank: int) -> bool:
            if rank < 1:
                return False
            if rank == required_rank:
                return True
            if extra_ranked and rank <= max_rank:
                return True
            return False

        # Whether the Bronze tier counts: it is the required rank, or an extra rank.
        bronze_tier = required_rank == 0 or extra_ranked

        # Island locations: filter by run_length.
        # With extra ranks on, minimize leaves islands to the equipment checks.
        if category == CrabChampsLocationCategory.ISLAND:
            if extra_ranked and self._drop_redundant:
                return False
            island_num = self._extract_island_num(location.name)
            return island_num <= run_length

        # Ranked island locations: filter by run_length and allowed ranks
        if category == CrabChampsLocationCategory.RANKED_ISLAND:
            rank = rank_from_location_name(location.name)
            if not _rank_allowed(rank):
                return False
            island_num = self._extract_island_num(location.name)
            return island_num <= run_length

        # Rank runs: only required_rank when extra_ranked is off,
        # all ranks up to max_rank when extra_ranked is on.
        # There is no Bronze rank run; finishing the run is the goal itself.
        if category == CrabChampsLocationCategory.RANK_RUN:
            rank_name = location.name.replace("Complete Run on ", "")
            rank_index = RANK_NAMES.index(rank_name) if rank_name in RANK_NAMES else -1
            if rank_index < 1:
                return False
            if extra_ranked:
                return rank_index <= max_rank
            else:
                return rank_index == required_rank

        # Equipment runs (unranked): filter by run_length + pool membership.
        # They stand in for Bronze, so minimize only drops them when Bronze
        # is not covered (a higher required rank without extra rank checks).
        if category in (
            CrabChampsLocationCategory.WEAPON_RUN,
            CrabChampsLocationCategory.MELEE_RUN,
            CrabChampsLocationCategory.ABILITY_RUN,
        ):
            if self._drop_redundant and not bronze_tier:
                return False
            equip_name = self._extract_equip_name(location.name)
            is_pool = self._is_pool_equipment(equip_name, category)
            # Non-pool equipment: exclude when equip_mode is disabled
            if not is_pool and equip_mode == 2:
                return False
            island_num = self._extract_island_num(location.name)
            return island_num <= run_length

        # Equipment runs (ranked): filter by run_length, allowed ranks, pool membership
        # The run-level checks follow the ranked rules too, without a run length.
        if category in (
            CrabChampsLocationCategory.RANKED_WEAPON_RUN,
            CrabChampsLocationCategory.RANKED_MELEE_RUN,
            CrabChampsLocationCategory.RANKED_ABILITY_RUN,
            CrabChampsLocationCategory.RUN_WEAPON,
            CrabChampsLocationCategory.RUN_MELEE,
            CrabChampsLocationCategory.RUN_ABILITY,
        ):
            equip_name = self._extract_equip_name(location.name)
            is_pool = self._is_pool_equipment(equip_name, category)
            if not is_pool and equip_mode == 2:
                return False
            rank = rank_from_location_name(location.name)
            if not _rank_allowed(rank):
                return False
            island_num = self._extract_island_num(location.name)
            return island_num <= run_length

        # All other categories (pickups): always include if category is enabled
        return True

    def create_region(self, region_name, location_table) -> Region:
        new_region = Region(region_name, self.player, self.multiworld)

        for location in location_table:
            if location.category == CrabChampsLocationCategory.EVENT:
                # Victory event
                event_item = self.create_item(location.default_item)
                new_location = CrabChampsLocation(
                    self.player, location.name, location.category,
                    location.default_item, None, new_region
                )
                event_item.code = None
                new_location.place_locked_item(event_item)
                new_region.locations.append(new_location)

            elif self._should_include_location(location):
                new_location = CrabChampsLocation(
                    self.player, location.name, location.category,
                    location.default_item,
                    self.location_name_to_id[location.name],
                    new_region
                )
                new_region.locations.append(new_location)

        self.multiworld.regions.append(new_region)
        return new_region

    def _count_excluded_locations(self) -> int:
        """Pre-calculate how many locations will be marked EXCLUDED in set_rules.

        This must match the logic in set_rules so the item pool has enough
        filler items for the fill algorithm.
        """
        required_rank = self.options.required_rank.value
        max_rank = self.options.max_rank.value
        run_length = self.options.run_length.value
        equip_mode = self.options.equipment_check_mode.value
        extra_rank_mode = self.options.extra_rank_checks.value
        extra_ranked = extra_rank_mode != 0
        non_prog_above = extra_rank_mode == 2
        minimize = bool(self.options.minimize_run_checks.value)
        # Same definition as in generate_early — pool equipment always has
        # locations regardless of equip_mode, so minimize can drop redundant
        # checks whenever any pool is non-empty.
        have_equipment = (
            equip_mode != 2
            or len(self.pool_weapons) > 0
            or len(self.pool_melee) > 0
            or len(self.pool_abilities) > 0
        )
        drop_redundant = minimize and have_equipment
        excluded = 0
        biome_layout = self.options.check_layout.value == 1

        n_non_pool_weapons = len(self.non_pool_weapons)
        n_non_pool_melee = len(self.non_pool_melee) if self.options.melee_for_completion.value > 0 else 0
        n_non_pool_abilities = len(self.non_pool_abilities) if self.options.ability_for_completion.value > 0 else 0

        # Count how many ranked tiers have locations
        # (Bronze has no ranked checks; the unranked ones stand in for it.)
        if extra_ranked:
            ranked_tiers = list(range(1, max_rank + 1))
        else:
            ranked_tiers = [required_rank] if required_rank >= 1 else []
        bronze_tier = required_rank == 0 or extra_ranked

        # Equipment filler_only mode: only NON-POOL equipment run locations are excluded
        # (pool equipment locations are always regular)
        if equip_mode == 1:  # filler_only
            n_non_pool = n_non_pool_weapons + n_non_pool_melee + n_non_pool_abilities
            # Unranked non-pool equipment runs (they exist unless minimize
            # dropped them with Bronze not covered).
            if bronze_tier or not drop_redundant:
                excluded += run_length * n_non_pool
            # Ranked non-pool equipment runs (one set per included rank tier)
            excluded += len(ranked_tiers) * run_length * n_non_pool
            # Biome layout: one run-level check per item and rank tier.
            if biome_layout:
                excluded += len(ranked_tiers) * n_non_pool

        # Non-progression above required rank (only when extra_ranked adds higher ranks)
        if non_prog_above and extra_ranked:
            # Count all equipment (pool + non-pool) at ranks above required
            n_all_weapons = len(weapon_item_names)
            n_all_melee = len(melee_item_names) if self.options.melee_for_completion.value > 0 else 0
            n_all_abilities = len(ability_item_names) if self.options.ability_for_completion.value > 0 else 0
            n_all_equip = n_all_weapons + n_all_melee + n_all_abilities

            for r in range(required_rank + 1, max_rank + 1):
                # Ranked islands above required (skipped when minimize drops the category)
                if not drop_redundant:
                    excluded += run_length
                # Ranked equipment runs above required (only if not already counted by filler_only)
                if equip_mode != 1:
                    excluded += run_length * n_all_equip
                    if biome_layout:
                        excluded += n_all_equip
                else:
                    # filler_only already counted non-pool; only pool equipment above required is new
                    n_pool_weapons = len(self.pool_weapons)
                    n_pool_melee = len(self.pool_melee)
                    n_pool_abilities = len(self.pool_abilities)
                    excluded += run_length * (n_pool_weapons + n_pool_melee + n_pool_abilities)
                    if biome_layout:
                        excluded += n_pool_weapons + n_pool_melee + n_pool_abilities
                # Rank run location
                excluded += 1

        return excluded

    def create_items(self):
        itempool: List[CrabChampsItem] = []

        # Count non-event locations that need items
        location_count = sum(
            1 for location in self.multiworld.get_locations(self.player)
            if location.category != CrabChampsLocationCategory.EVENT
        )

        # Progressive slot items: added before BuildItemPool so pool size is adjusted
        slot_item_count = 0
        if self.options.progressive_slots.value:
            slot_defs = [
                ("Progressive Perk Slot", 24, self.options.starting_perk_slots.value),
                ("Progressive Weapon Mod Slot", 24, self.options.starting_weapon_mod_slots.value),
                ("Progressive Ability Mod Slot", 12, self.options.starting_ability_mod_slots.value),
                ("Progressive Melee Mod Slot", 12, self.options.starting_melee_mod_slots.value),
            ]
            for slot_name, max_slots, starting in slot_defs:
                count = max_slots - starting
                for _ in range(count):
                    itempool.append(self.create_item(slot_name))
                    slot_item_count += 1

        # Biome Access items for the biomes the player does not start in; the
        # starting biome's item is precollected.
        if self.options.biome_lock.value:
            for i, access_name in enumerate(biome_access_item_names):
                if i + 1 != self.start_biome:
                    itempool.append(self.create_item(access_name))
                    slot_item_count += 1

        # Exclude greed items from pool when greed_item_mode == skip (2)
        exclude = GREED_ITEM_NAMES if self.options.greed_item_mode.value == 2 else None
        # When limit_pickup_pool is on, only items in the chosen subset are
        # eligible for pool steps 4-6 (relics + stackables + extras).
        pickup_subsets = (
            self.pickup_subsets if self.options.limit_pickup_pool.value else None
        )
        # Precollected equipment is already in the player's inventory, so it
        # must not also occupy a slot in the item pool.
        precollected_equipment = frozenset(
            self.starting_weapon_names + self.starting_melee + self.starting_abilities
        )
        remaining = location_count - slot_item_count
        pool = BuildItemPool(self.multiworld, remaining, self.options,
                             self.pool_weapons, self.pool_melee, self.pool_abilities,
                             exclude_names=exclude,
                             pickup_subsets=pickup_subsets,
                             skip_equipment=precollected_equipment)
        for item_data in pool:
            itempool.append(self.create_item(item_data.name))

        # EXCLUDED locations can only receive filler items (not useful/progression).
        # Downgrade enough useful items to filler to cover excluded locations.
        excluded_needed = self._count_excluded_locations()
        # Locations the player excluded in their yaml need filler too. A name that
        # is also excluded by the world is counted twice, which only downgrades a
        # few more useful items than strictly needed.
        created = {loc.name for loc in self.multiworld.get_locations(self.player)
                   if loc.category != CrabChampsLocationCategory.EVENT}
        user_excluded = len(created & set(self.options.exclude_locations.value))
        excluded_needed += user_excluded
        if excluded_needed > 0:
            filler_count = sum(
                1 for it in itempool
                if it.classification in (ItemClassification.filler, ItemClassification.trap)
            )
            to_downgrade = excluded_needed - filler_count
            if to_downgrade > 0:
                for it in itempool:
                    if to_downgrade <= 0:
                        break
                    if it.classification == ItemClassification.useful:
                        it.classification = ItemClassification.filler
                        to_downgrade -= 1
            if to_downgrade > 0 and user_excluded:
                raise OptionError(
                    f"Crab Champions: {self.multiworld.player_name[self.player]} excludes more locations "
                    f"than the item pool has filler for ({to_downgrade} too many). "
                    "Exclude fewer locations, or turn on more filler (crystal_cache_percentage).")

        self.multiworld.itempool += itempool

    def create_item(self, name: str) -> Item:
        data = self.item_name_to_id[name]
        item_cat = item_dictionary[name].category

        # All weapons/melee/abilities are classified as progression so that
        # state.has() works correctly in rule evaluation (has() only counts
        # progression items).  Non-pool equipment is never placed in the item
        # pool, so this classification doesn't affect generation.
        if name in key_item_names:
            classification = ItemClassification.progression
        elif item_cat in (CrabChampsItemCategory.WEAPON,
                          CrabChampsItemCategory.ABILITY,
                          CrabChampsItemCategory.MELEE):
            classification = ItemClassification.progression
        elif item_cat in (
            CrabChampsItemCategory.PERK,
            CrabChampsItemCategory.RELIC,
            CrabChampsItemCategory.WEAPON_MOD,
            CrabChampsItemCategory.MELEE_MOD,
            CrabChampsItemCategory.ABILITY_MOD,
        ):
            # Items that provide pickup tags gate other locations, so they
            # must be progression for state.has() to count them. Only applies
            # when pickup_checks is on — otherwise no locations need tags.
            # Only the FIRST copy of each provider name needs to be progression;
            # `any(state.has(p))` is satisfied by one copy, so extra copies
            # would just consume progression-eligible locations unnecessarily.
            if (name in TAG_PROVIDER_NAMES
                    and self.options.pickup_checks.value
                    and name not in self._provider_progression_marked):
                self._provider_progression_marked.add(name)
                classification = ItemClassification.progression
            else:
                classification = ItemClassification.useful
        elif item_cat in (CrabChampsItemCategory.SLOT, CrabChampsItemCategory.BIOME):
            classification = ItemClassification.progression
        elif item_cat == CrabChampsItemCategory.TRAP:
            classification = ItemClassification.trap
        elif name == "Perk Boost":
            classification = ItemClassification.useful
        elif item_cat == CrabChampsItemCategory.FILLER:
            classification = ItemClassification.filler
        else:
            classification = ItemClassification.filler

        return CrabChampsItem(name, classification, data, self.player)

    def get_filler_item_name(self) -> str:
        return "Crystal Cache"

    def set_rules(self) -> None:
        required_rank = self.options.required_rank.value
        max_rank = self.options.max_rank.value
        extra_rank_mode = self.options.extra_rank_checks.value
        extra_ranked = extra_rank_mode != 0
        non_prog_above = extra_rank_mode == 2
        equip_mode = self.options.equipment_check_mode.value  # 0=regular, 1=filler_only, 2=disabled

        _equip_categories = EQUIPMENT_CATEGORIES

        for location in self.multiworld.get_locations(self.player):
            if not hasattr(location, 'category'):
                continue
            cat = BIOME_BASE_CATEGORY.get(location.category, location.category)

            # Non-pool equipment runs are filler-only in filler_only mode.
            if cat in _equip_categories:
                equip_name = self._extract_equip_name(location.name)
                if not self._is_pool_equipment(equip_name, cat) and equip_mode == 1:
                    location.progress_type = LocationProgressType.EXCLUDED

            # Non-progression above required rank
            if non_prog_above and extra_ranked:
                rank = rank_from_location_name(location.name)
                if rank > required_rank:
                    location.progress_type = LocationProgressType.EXCLUDED

        # Also exclude rank run locations above required
        if non_prog_above and extra_ranked:
            for r in range(required_rank + 1, max_rank + 1):
                try:
                    loc = self.multiworld.get_location(f"Complete Run on {RANK_NAMES[r]}", self.player)
                    loc.progress_type = LocationProgressType.EXCLUDED
                except KeyError:
                    pass

        set_all_rules(self)

    @staticmethod
    def interpret_slot_data(slot_data: Dict[str, object]) -> Dict[str, object]:
        """The random choices a rebuild needs to match this seed."""
        options = slot_data["options"]
        return {
            "pool_weapons": options["pool_weapons"],
            "pool_melee": options["pool_melee"],
            "pool_abilities": options["pool_abilities"],
            "starting_weapon_names": options["starting_weapon_names"],
            "starting_melee": options["starting_melee"],
            "starting_abilities": options["starting_abilities"],
            "pickup_subsets": options["pickup_subsets"],
            "start_biome": options["starting_biome"],
        }

    def fill_slot_data(self) -> Dict[str, object]:
        # NOTE: We intentionally do NOT include `locationsId`/`itemsId` arrays
        # in slot_data.  The Lua client gets the authoritative location list
        # from the AP protocol's Connected packet (`missing_locations` +
        # `checked_locations`), and item IDs from items_received events.
        # Bundling those into slot_data is non-idiomatic and was unused.
        return {
            "options": {
                "required_rank": self.options.required_rank.value,
                "required_rank_name": RANK_NAMES[self.options.required_rank.value],
                "max_rank": self.options.max_rank.value,
                "max_rank_name": RANK_NAMES[self.options.max_rank.value],
                # Canonical option (replaces extra_ranked_island_checks +
                # non_progression_above_required since v1.3.0).
                "extra_rank_checks": self.options.extra_rank_checks.value,
                # Derived booleans, kept in slot_data for client compatibility.
                "extra_ranked_island_checks": self.options.extra_rank_checks.value != 0,
                "non_progression_above_required": self.options.extra_rank_checks.value == 2,
                "cascade_ranked_checks": bool(self.options.cascade_ranked_checks.value),
                "minimize_run_checks": bool(self.options.minimize_run_checks.value),
                "run_length": self.options.run_length.value,
                # 0 = island_number, 1 = biome. Seeds without it use island numbers.
                "check_layout": self.options.check_layout.value,
                # False: there are no "on Bronze" checks, the plain checks count
                # as Bronze. Seeds without it still have them.
                "bronze_checks": False,
                # Only pool equipment counts toward completion.  Seeds made
                # before this field existed also counted non-pool runs, and
                # the client keeps that rule for them.
                "pool_only_completion": True,
                "weapons_for_completion": self.options.weapons_for_completion.value,
                "weapons_in_pool": self.options.weapons_in_pool.value,
                "starting_weapons": self.options.starting_weapons.value,
                "melee_for_completion": self.options.melee_for_completion.value,
                "melee_in_pool": self.options.melee_in_pool.value,
                "ability_for_completion": self.options.ability_for_completion.value,
                "abilities_in_pool": self.options.abilities_in_pool.value,
                "pool_weapons": self.pool_weapons,
                "pool_melee": self.pool_melee,
                "pool_abilities": self.pool_abilities,
                "starting_weapon_names": self.starting_weapon_names,
                "starting_melee": self.starting_melee,
                "starting_abilities": self.starting_abilities,
                "equipment_check_mode": self.options.equipment_check_mode.value,
                "guaranteed_items": self.options.guaranteed_items.value,
                "greed_item_mode": self.options.greed_item_mode.value,
                "pickup_checks": bool(self.options.pickup_checks.value),
                "limit_pickup_pool": bool(self.options.limit_pickup_pool.value),
                "limit_pickup_locations": bool(self.options.limit_pickup_locations.value),
                "granted_item_checks": bool(self.options.granted_item_checks.value),
                "pickup_subsets": self.pickup_subsets,
                "progressive_slots": bool(self.options.progressive_slots.value),
                "starting_perk_slots": self.options.starting_perk_slots.value,
                "starting_weapon_mod_slots": self.options.starting_weapon_mod_slots.value,
                "starting_ability_mod_slots": self.options.starting_ability_mod_slots.value,
                "starting_melee_mod_slots": self.options.starting_melee_mod_slots.value,
                "starting_item_percentage": self.options.starting_item_percentage.value,
                "biome_item_percentage": self.options.biome_item_percentage.value,
                "biome_lock": bool(self.options.biome_lock.value),
                # Game biome number (Tropical 1, Arctic 2, Desert 3, Volcanic 4)
                # the runs start in; 0 when biome_lock is off.
                "starting_biome": self.start_biome,
                "death_link": bool(self.options.death_link.value),
                "trap_percentage": self.options.trap_percentage.value,
                "trap_duration": self.options.trap_duration.value,
                "trap_grace_seconds": self.options.trap_grace_seconds.value,
                "crystal_tax_percent": self.options.crystal_tax_percent.value,
                "slowdown_percent": self.options.slowdown_percent.value,
                "weak_shots_percent": self.options.weak_shots_percent.value,
                "bruise_percent": self.options.bruise_percent.value,
                "perk_boost_max_per_run": self.options.perk_boost_max_per_run.value,
                "perk_boost_level_cap": self.options.perk_boost_level_cap.value,
            },
            "death_link": bool(self.options.death_link.value),
            "seed": self.multiworld.seed_name,
            "slot": self.multiworld.player_name[self.player],
            "base_id": self.base_id,
            "id_layout": ID_LAYOUT,
        }
