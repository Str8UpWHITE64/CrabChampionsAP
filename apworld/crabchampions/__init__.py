from typing import Dict, Set, List

from BaseClasses import MultiWorld, Region, Item, Entrance, Tutorial, ItemClassification, LocationProgressType

from worlds.AutoWorld import World, WebWorld
from worlds.generic.Rules import set_rule

from .Items import (
    CrabChampsItem, CrabChampsItemCategory, item_dictionary, key_item_names,
    item_descriptions, BuildItemPool, weapon_item_names, melee_item_names,
    ability_item_names, GREED_ITEM_NAMES, PICKUP_TAG_REQUIREMENTS, TAG_PROVIDER_NAMES,
    select_pickup_subsets, PICKUP_INVENTORY_CAPS,
)
from .Locations import (
    CrabChampsLocation, CrabChampsLocationCategory, location_tables,
    RANK_NAMES, MAX_ISLANDS, NUM_RANKS,
    rank_from_location_name, SHOP_ISLANDS, _island_prefix,
)
from .Options import CrabChampsOption


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
    data_version = 2
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
        # Pickup-subset selections — populated when limit_pickup_pool or
        # limit_pickup_locations is enabled.  Maps category key
        # (perk/weapon_mod/ability_mod/melee_mod/relic) -> list of names.
        self.pickup_subsets: Dict[str, List[str]] = {}
        self._allowed_pickup_names: Set[str] = set()
        # Tracks which TAG_PROVIDER names have already been promoted to
        # progression. Only the first copy of each provider needs to be
        # progression — `any(state.has(p))` is satisfied by one copy.
        self._provider_progression_marked: Set[str] = set()

    def generate_early(self):
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

        # Clamp pool sizes to total-1 so the player always has at least one
        # available from the start (not locked behind AP progression)
        max_weapons_pool = len(weapon_item_names) - 1   # 19
        max_melee_pool = len(melee_item_names) - 1       # 4
        max_ability_pool = len(ability_item_names) - 1    # 6
        if self.options.weapons_in_pool.value > max_weapons_pool:
            self.options.weapons_in_pool.value = max_weapons_pool
        if self.options.melee_in_pool.value > max_melee_pool:
            self.options.melee_in_pool.value = max_melee_pool
        if self.options.abilities_in_pool.value > max_ability_pool:
            self.options.abilities_in_pool.value = max_ability_pool

        # When equipment_check_mode is disabled, non-pool equipment has no locations,
        # so completion is limited to pool size. Otherwise the player can use all
        # equipment (pool + non-pool) toward completion.
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

        self.pool_weapon_set = frozenset(self.pool_weapons)
        self.pool_melee_set = frozenset(self.pool_melee)
        self.pool_ability_set = frozenset(self.pool_abilities)
        self.non_pool_weapons = [w for w in weapon_item_names if w not in self.pool_weapon_set]
        self.non_pool_melee = [m for m in melee_item_names if m not in self.pool_melee_set]
        self.non_pool_abilities = [a for a in ability_item_names if a not in self.pool_ability_set]

        # Clamp starting_weapons < weapons_in_pool (must find at least one)
        max_starting = max(0, self.options.weapons_in_pool.value - 1)
        if self.options.starting_weapons.value > max_starting:
            self.options.starting_weapons.value = max_starting

        # Select and precollect starting weapons from the pool
        if self.options.starting_weapons.value > 0:
            starting = self.random.sample(self.pool_weapons, self.options.starting_weapons.value)
            for weapon_name in starting:
                self.multiworld.push_precollected(self.create_item(weapon_name))

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
        # Unranked weapon-run drops when minimize covers them with the ranked variant.
        if not drop_redundant:
            self.enabled_location_categories.add(CrabChampsLocationCategory.WEAPON_RUN)
        self.enabled_location_categories.add(CrabChampsLocationCategory.RANKED_WEAPON_RUN)

        # Melee/ability run locations: only when melee/ability completion is active
        if self.options.melee_for_completion.value > 0:
            if not drop_redundant:
                self.enabled_location_categories.add(CrabChampsLocationCategory.MELEE_RUN)
            self.enabled_location_categories.add(CrabChampsLocationCategory.RANKED_MELEE_RUN)
        if self.options.ability_for_completion.value > 0:
            if not drop_redundant:
                self.enabled_location_categories.add(CrabChampsLocationCategory.ABILITY_RUN)
            self.enabled_location_categories.add(CrabChampsLocationCategory.RANKED_ABILITY_RUN)

        # Pickup subsets: select once when either limit option is enabled.
        # Both options share the same chosen subset.
        if (self.options.limit_pickup_pool.value
                or self.options.limit_pickup_locations.value):
            exclude = (GREED_ITEM_NAMES
                       if self.options.greed_item_mode.value == 2
                       else frozenset())
            self.pickup_subsets = select_pickup_subsets(self.random, exclude_names=exclude)
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
                        CrabChampsLocationCategory.RANKED_WEAPON_RUN):
            return equip_name in self.pool_weapon_set
        if category in (CrabChampsLocationCategory.MELEE_RUN,
                        CrabChampsLocationCategory.RANKED_MELEE_RUN):
            return equip_name in self.pool_melee_set
        if category in (CrabChampsLocationCategory.ABILITY_RUN,
                        CrabChampsLocationCategory.RANKED_ABILITY_RUN):
            return equip_name in self.pool_ability_set
        return False

    @staticmethod
    def _extract_island_num(name: str) -> int:
        """Extract the island number from a location name.
        Handles both 'Complete Island X ...' and 'Reach Shop on Island X ...' patterns."""
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

        # Exclude greed pickup locations when greed_item_mode == skip
        if self.options.greed_item_mode.value == 2:
            if location.category in (
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
            if location.category in (
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

        # Determine which ranks are allowed for ranked locations:
        # Always include required_rank. When extra is on, include all up to max_rank.
        def _rank_allowed(rank: int) -> bool:
            if rank == required_rank:
                return True
            if extra_ranked and 0 <= rank <= max_rank:
                return True
            return False

        # Island locations: filter by run_length.
        # When extra_ranked is on, skip unranked island completions (ranked versions cover them).
        if location.category == CrabChampsLocationCategory.ISLAND:
            if extra_ranked:
                return False
            island_num = self._extract_island_num(location.name)
            return island_num <= run_length

        # Ranked island locations: filter by run_length and allowed ranks
        if location.category == CrabChampsLocationCategory.RANKED_ISLAND:
            rank = rank_from_location_name(location.name)
            if not _rank_allowed(rank):
                return False
            island_num = self._extract_island_num(location.name)
            return island_num <= run_length

        # Rank runs: only required_rank when extra_ranked is off,
        # all ranks up to max_rank when extra_ranked is on
        if location.category == CrabChampsLocationCategory.RANK_RUN:
            rank_name = location.name.replace("Complete Run on ", "")
            rank_index = RANK_NAMES.index(rank_name) if rank_name in RANK_NAMES else -1
            if extra_ranked:
                return rank_index <= max_rank
            else:
                return rank_index == required_rank

        # Equipment runs (unranked): filter by run_length + pool membership.
        # When extra_ranked is on, skip unranked equipment runs (ranked versions cover them).
        if location.category in (
            CrabChampsLocationCategory.WEAPON_RUN,
            CrabChampsLocationCategory.MELEE_RUN,
            CrabChampsLocationCategory.ABILITY_RUN,
        ):
            if extra_ranked:
                return False
            equip_name = self._extract_equip_name(location.name)
            is_pool = self._is_pool_equipment(equip_name, location.category)
            # Non-pool equipment: exclude when equip_mode is disabled
            if not is_pool and equip_mode == 2:
                return False
            island_num = self._extract_island_num(location.name)
            return island_num <= run_length

        # Equipment runs (ranked): filter by run_length, allowed ranks, pool membership
        if location.category in (
            CrabChampsLocationCategory.RANKED_WEAPON_RUN,
            CrabChampsLocationCategory.RANKED_MELEE_RUN,
            CrabChampsLocationCategory.RANKED_ABILITY_RUN,
        ):
            equip_name = self._extract_equip_name(location.name)
            is_pool = self._is_pool_equipment(equip_name, location.category)
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

        n_non_pool_weapons = len(self.non_pool_weapons)
        n_non_pool_melee = len(self.non_pool_melee) if self.options.melee_for_completion.value > 0 else 0
        n_non_pool_abilities = len(self.non_pool_abilities) if self.options.ability_for_completion.value > 0 else 0

        # Count how many ranked tiers have locations
        if extra_ranked:
            ranked_tiers = list(range(max_rank + 1))
        else:
            ranked_tiers = [required_rank]

        # Equipment filler_only mode: only NON-POOL equipment run locations are excluded
        # (pool equipment locations are always regular)
        if equip_mode == 1:  # filler_only
            n_non_pool = n_non_pool_weapons + n_non_pool_melee + n_non_pool_abilities
            # Unranked non-pool equipment runs (only exist when extra_ranked is off
            # AND minimize did not drop them).
            if not extra_ranked and not drop_redundant:
                excluded += run_length * n_non_pool
            # Ranked non-pool equipment runs (one set per included rank tier)
            excluded += len(ranked_tiers) * run_length * n_non_pool

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
                else:
                    # filler_only already counted non-pool; only pool equipment above required is new
                    n_pool_weapons = len(self.pool_weapons)
                    n_pool_melee = len(self.pool_melee)
                    n_pool_abilities = len(self.pool_abilities)
                    excluded += run_length * (n_pool_weapons + n_pool_melee + n_pool_abilities)
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

        # Exclude greed items from pool when greed_item_mode == skip (2)
        exclude = GREED_ITEM_NAMES if self.options.greed_item_mode.value == 2 else None
        # When limit_pickup_pool is on, only items in the chosen subset are
        # eligible for pool steps 4-6 (relics + stackables + extras).
        pickup_subsets = (
            self.pickup_subsets if self.options.limit_pickup_pool.value else None
        )
        remaining = location_count - slot_item_count
        pool = BuildItemPool(self.multiworld, remaining, self.options,
                             self.pool_weapons, self.pool_melee, self.pool_abilities,
                             exclude_names=exclude,
                             pickup_subsets=pickup_subsets)
        for item_data in pool:
            itempool.append(self.create_item(item_data.name))

        # EXCLUDED locations can only receive filler items (not useful/progression).
        # Downgrade enough useful items to filler to cover excluded locations.
        excluded_needed = self._count_excluded_locations()
        if excluded_needed > 0:
            filler_count = sum(
                1 for it in itempool
                if it.classification == ItemClassification.filler
            )
            to_downgrade = excluded_needed - filler_count
            if to_downgrade > 0:
                for it in itempool:
                    if to_downgrade <= 0:
                        break
                    if it.classification == ItemClassification.useful:
                        it.classification = ItemClassification.filler
                        to_downgrade -= 1

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
        elif item_cat == CrabChampsItemCategory.SLOT:
            classification = ItemClassification.progression
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
        weapons_needed = self.options.weapons_for_completion.value
        melee_needed = self.options.melee_for_completion.value
        abilities_needed = self.options.ability_for_completion.value
        extra_rank_mode = self.options.extra_rank_checks.value
        extra_ranked = extra_rank_mode != 0
        non_prog_above = extra_rank_mode == 2
        equip_mode = self.options.equipment_check_mode.value  # 0=regular, 1=filler_only, 2=disabled

        _equip_categories = {
            CrabChampsLocationCategory.WEAPON_RUN,
            CrabChampsLocationCategory.MELEE_RUN,
            CrabChampsLocationCategory.ABILITY_RUN,
            CrabChampsLocationCategory.RANKED_WEAPON_RUN,
            CrabChampsLocationCategory.RANKED_MELEE_RUN,
            CrabChampsLocationCategory.RANKED_ABILITY_RUN,
        }
        pickup_cats = (
            CrabChampsLocationCategory.PERK,
            CrabChampsLocationCategory.RELIC,
            CrabChampsLocationCategory.WEAPON_MOD,
            CrabChampsLocationCategory.MELEE_MOD,
            CrabChampsLocationCategory.ABILITY_MOD,
        )

        # --- Single pass over all locations ---
        # Island completion locations have no AP-item prerequisites (the player
        # can always reach any island through normal gameplay), so no access
        # rules are needed for them.  Equipment-island locations only require
        # the player to have the weapon/melee/ability if it is in the AP pool.
        for location in self.multiworld.get_locations(self.player):
            if not hasattr(location, 'category'):
                continue
            cat = location.category

            # Equipment run: pool items need state.has() rule
            if cat in _equip_categories:
                equip_name = self._extract_equip_name(location.name)
                is_pool = self._is_pool_equipment(equip_name, cat)
                if is_pool:
                    set_rule(location, lambda state, en=equip_name: state.has(en, self.player))
                elif equip_mode == 1:  # filler_only for non-pool
                    location.progress_type = LocationProgressType.EXCLUDED

            # Pickup tag prerequisites
            elif cat in pickup_cats:
                item_name = location.name.split(": ", 1)[-1] if ": " in location.name else ""
                providers = PICKUP_TAG_REQUIREMENTS.get(item_name)
                if providers:
                    # When limit_pickup_pool is on, only providers actually
                    # in the chosen subset can satisfy state.has() — others
                    # are never sent as AP items.  Filter the rule's
                    # provider list to the in-pool ones.
                    if self.options.limit_pickup_pool.value:
                        providers = [p for p in providers
                                     if p in self._allowed_pickup_names]
                    if providers:
                        set_rule(
                            location,
                            lambda state, p=providers: any(
                                state.has(item, self.player) for item in p
                            )
                        )

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

        # --- Victory rule ---
        # The player must complete enough different equipment runs.
        # Pool equipment requires the AP item (state.has); non-pool equipment
        # is always available.  Island reachability requires no AP items
        # (the player progresses through islands via normal gameplay).
        n_non_pool_w = len(self.non_pool_weapons) if equip_mode != 2 else 0
        n_non_pool_m = (len(self.non_pool_melee) if equip_mode != 2 else 0) if melee_needed > 0 else 0
        n_non_pool_a = (len(self.non_pool_abilities) if equip_mode != 2 else 0) if abilities_needed > 0 else 0

        # Snapshot pool lists for the closure
        pw = list(self.pool_weapons)
        pm = list(self.pool_melee)
        pa = list(self.pool_abilities)

        def victory_rule(state, wn=weapons_needed, mn=melee_needed, an=abilities_needed,
                         npw=n_non_pool_w, npm=n_non_pool_m, npa=n_non_pool_a,
                         _pw=pw, _pm=pm, _pa=pa):
            if sum(1 for w in _pw if state.has(w, self.player)) + npw < wn:
                return False
            if mn > 0 and sum(1 for m in _pm if state.has(m, self.player)) + npm < mn:
                return False
            if an > 0 and sum(1 for a in _pa if state.has(a, self.player)) + npa < an:
                return False
            return True

        set_rule(self.multiworld.get_location("Victory", self.player), victory_rule)

        self.multiworld.completion_condition[self.player] = lambda state: (
            state.can_reach_location("Victory", self.player)
        )

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
                "equipment_check_mode": self.options.equipment_check_mode.value,
                "guaranteed_items": self.options.guaranteed_items.value,
                "greed_item_mode": self.options.greed_item_mode.value,
                "pickup_checks": bool(self.options.pickup_checks.value),
                "limit_pickup_pool": bool(self.options.limit_pickup_pool.value),
                "limit_pickup_locations": bool(self.options.limit_pickup_locations.value),
                "pickup_subsets": self.pickup_subsets,
                "progressive_slots": bool(self.options.progressive_slots.value),
                "starting_perk_slots": self.options.starting_perk_slots.value,
                "starting_weapon_mod_slots": self.options.starting_weapon_mod_slots.value,
                "starting_ability_mod_slots": self.options.starting_ability_mod_slots.value,
                "starting_melee_mod_slots": self.options.starting_melee_mod_slots.value,
                "death_link": bool(self.options.death_link.value),
            },
            "death_link": bool(self.options.death_link.value),
            "seed": self.multiworld.seed_name,
            "slot": self.multiworld.player_name[self.player],
            "base_id": self.base_id,
        }
