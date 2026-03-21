from typing import Dict, Set, List

from BaseClasses import MultiWorld, Region, Item, Entrance, Tutorial, ItemClassification, LocationProgressType

from worlds.AutoWorld import World, WebWorld
from worlds.generic.Rules import set_rule

from .Items import (
    CrabChampsItem, CrabChampsItemCategory, item_dictionary, key_item_names,
    item_descriptions, BuildItemPool, weapon_item_names, melee_item_names,
    ability_item_names,
)
from .Locations import (
    CrabChampsLocation, CrabChampsLocationCategory, location_tables,
    location_dictionary, RANK_NAMES, MAX_ISLANDS, NUM_RANKS,
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

        pool_weapon_set = set(self.pool_weapons)
        pool_melee_set = set(self.pool_melee)
        pool_ability_set = set(self.pool_abilities)
        self.non_pool_weapons = [w for w in weapon_item_names if w not in pool_weapon_set]
        self.non_pool_melee = [m for m in melee_item_names if m not in pool_melee_set]
        self.non_pool_abilities = [a for a in ability_item_names if a not in pool_ability_set]

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

        # Always-on categories
        self.enabled_location_categories.add(CrabChampsLocationCategory.ISLAND)
        self.enabled_location_categories.add(CrabChampsLocationCategory.PERK)
        self.enabled_location_categories.add(CrabChampsLocationCategory.RELIC)
        self.enabled_location_categories.add(CrabChampsLocationCategory.RANK_RUN)
        self.enabled_location_categories.add(CrabChampsLocationCategory.WEAPON_MOD)
        self.enabled_location_categories.add(CrabChampsLocationCategory.MELEE_MOD)
        self.enabled_location_categories.add(CrabChampsLocationCategory.ABILITY_MOD)

        # Ranked island locations always exist (at least for required_rank).
        self.enabled_location_categories.add(CrabChampsLocationCategory.RANKED_ISLAND)

        # Weapon run locations: pool weapons always exist, non-pool depends on equip_mode.
        # Always enable the category; _should_include_location filters per-weapon.
        self.enabled_location_categories.add(CrabChampsLocationCategory.WEAPON_RUN)
        self.enabled_location_categories.add(CrabChampsLocationCategory.RANKED_WEAPON_RUN)

        # Melee/ability run locations: only when melee/ability completion is active
        if self.options.melee_for_completion.value > 0:
            self.enabled_location_categories.add(CrabChampsLocationCategory.MELEE_RUN)
            self.enabled_location_categories.add(CrabChampsLocationCategory.RANKED_MELEE_RUN)
        if self.options.ability_for_completion.value > 0:
            self.enabled_location_categories.add(CrabChampsLocationCategory.ABILITY_RUN)
            self.enabled_location_categories.add(CrabChampsLocationCategory.RANKED_ABILITY_RUN)

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
        pool_weapon_set = set(self.pool_weapons)
        pool_melee_set = set(self.pool_melee)
        pool_ability_set = set(self.pool_abilities)
        if category in (CrabChampsLocationCategory.WEAPON_RUN,
                        CrabChampsLocationCategory.RANKED_WEAPON_RUN):
            return equip_name in pool_weapon_set
        if category in (CrabChampsLocationCategory.MELEE_RUN,
                        CrabChampsLocationCategory.RANKED_MELEE_RUN):
            return equip_name in pool_melee_set
        if category in (CrabChampsLocationCategory.ABILITY_RUN,
                        CrabChampsLocationCategory.RANKED_ABILITY_RUN):
            return equip_name in pool_ability_set
        return False

    @staticmethod
    def _extract_island_num(name: str) -> int:
        """Extract the island number from a location name.
        Handles both 'Complete Island X ...' and 'Reach Shop on Island X ...' patterns."""
        import re
        m = re.search(r'Island\s+(\d+)', name)
        return int(m.group(1)) if m else 0

    def _should_include_location(self, location) -> bool:
        """Check if a location should be included based on options."""
        if location.category not in self.enabled_location_categories:
            return False

        run_length = self.options.run_length.value
        max_rank = self.options.max_rank.value
        required_rank = self.options.required_rank.value
        extra_ranked = bool(self.options.extra_ranked_island_checks.value)
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
        extra_ranked = bool(self.options.extra_ranked_island_checks.value)
        non_prog_above = bool(self.options.non_progression_above_required.value)
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
            # Unranked non-pool equipment runs (only exist when extra_ranked is off)
            if not extra_ranked:
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
                # Ranked islands above required
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

        pool = BuildItemPool(self.multiworld, location_count, self.options,
                             self.pool_weapons, self.pool_melee, self.pool_abilities)
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
        run_length = self.options.run_length.value
        weapons_needed = self.options.weapons_for_completion.value
        melee_needed = self.options.melee_for_completion.value
        abilities_needed = self.options.ability_for_completion.value
        extra_ranked = bool(self.options.extra_ranked_island_checks.value)
        cascade = bool(self.options.cascade_ranked_checks.value)
        non_prog_above = bool(self.options.non_progression_above_required.value)
        equip_mode = self.options.equipment_check_mode.value  # 0=regular, 1=filler_only, 2=disabled
        def _il(i, equip=None, rank=None):
            """Build the correct location name for an island, handling shop islands."""
            pfx = _island_prefix(i)
            name = f"{pfx} {i}"
            if equip:
                name += f" with {equip}"
            if rank is not None:
                name += f" on {rank}"
            return name

        final_island = _il(run_length)
        required_rank_name = RANK_NAMES[required_rank]

        pool_weapon_set = set(self.pool_weapons)
        pool_melee_set = set(self.pool_melee)
        pool_ability_set = set(self.pool_abilities)

        # Determine which ranked tiers have locations
        if extra_ranked:
            ranked_tiers = list(range(max_rank + 1))
        else:
            ranked_tiers = [required_rank]

        # --- Unranked island chain: Island N requires Island N-1 ---
        # (Only when unranked islands exist, i.e. extra_ranked is off)
        if not extra_ranked:
            for island in range(2, run_length + 1):
                current = _il(island)
                previous = _il(island - 1)
                set_rule(
                    self.multiworld.get_location(current, self.player),
                    lambda state, prev=previous: state.can_reach_location(prev, self.player)
                )

        # --- Ranked island chains (for all included rank tiers) ---
        for r in ranked_tiers:
            rname = RANK_NAMES[r]
            for island in range(1, run_length + 1):
                loc_name = _il(island, rank=rname)
                try:
                    location = self.multiworld.get_location(loc_name, self.player)
                except KeyError:
                    continue

                if island == 1:
                    pass
                elif cascade and not extra_ranked:
                    # Cascade + unranked exists: depend on unranked previous island
                    prev_name = _il(island - 1)
                    set_rule(
                        location,
                        lambda state, prev=prev_name: state.can_reach_location(prev, self.player)
                    )
                else:
                    # No cascade, or cascade without unranked: chain within same rank
                    prev_name = _il(island - 1, rank=rname)
                    set_rule(
                        location,
                        lambda state, prev=prev_name: state.can_reach_location(prev, self.player)
                    )

        # --- Rank runs ---
        if extra_ranked:
            # Sequential chain: Bronze requires final ranked island, each rank requires previous
            final_island_dep = _il(run_length, rank=RANK_NAMES[0])
            try:
                set_rule(
                    self.multiworld.get_location("Complete Run on Bronze", self.player),
                    lambda state, fi=final_island_dep: state.can_reach_location(fi, self.player)
                )
            except KeyError:
                pass

            for i in range(1, max_rank + 1):
                current_rank = RANK_NAMES[i]
                previous_rank = RANK_NAMES[i - 1]
                try:
                    set_rule(
                        self.multiworld.get_location(f"Complete Run on {current_rank}", self.player),
                        lambda state, prev=previous_rank: state.can_reach_location(
                            f"Complete Run on {prev}", self.player
                        )
                    )
                except KeyError:
                    pass
        else:
            # Only required_rank exists: depends on final ranked island at required_rank
            final_ranked_dep = _il(run_length, rank=required_rank_name)
            try:
                set_rule(
                    self.multiworld.get_location(f"Complete Run on {required_rank_name}", self.player),
                    lambda state, fi=final_ranked_dep: state.can_reach_location(fi, self.player)
                )
            except KeyError:
                pass

        # --- Equipment run rules ---
        # Pool equipment: always set rules (require AP item, locations always exist).
        # Non-pool equipment: set rules only when equip_mode != disabled.
        def _set_equipment_rules(equipment_names, category, ranked_category,
                                 require_item, pool_set):
            """Set rules for equipment-island locations (unranked and ranked)."""
            for island in range(1, run_length + 1):
                island_loc = _il(island)
                for equip_name in equipment_names:
                    is_pool = equip_name in pool_set
                    need_item = require_item and is_pool

                    # Unranked (only when extra_ranked is off)
                    if not extra_ranked:
                        loc_name = _il(island, equip=equip_name)
                        try:
                            location = self.multiworld.get_location(loc_name, self.player)
                            if need_item:
                                set_rule(
                                    location,
                                    lambda state, il=island_loc, en=equip_name: (
                                        state.can_reach_location(il, self.player)
                                        and state.has(en, self.player)
                                    )
                                )
                            else:
                                set_rule(
                                    location,
                                    lambda state, il=island_loc: state.can_reach_location(il, self.player)
                                )
                        except KeyError:
                            pass

                    # Ranked (for each included rank tier)
                    for r in ranked_tiers:
                        rname = RANK_NAMES[r]
                        ranked_loc = _il(island, equip=equip_name, rank=rname)
                        if cascade and not extra_ranked:
                            # Cascade + unranked exists: depend on unranked island
                            ranked_island_dep = island_loc
                        else:
                            # No cascade, or no unranked islands: depend on ranked island
                            ranked_island_dep = _il(island, rank=rname)
                        try:
                            location = self.multiworld.get_location(ranked_loc, self.player)
                            if need_item:
                                set_rule(
                                    location,
                                    lambda state, il=ranked_island_dep, en=equip_name: (
                                        state.can_reach_location(il, self.player)
                                        and state.has(en, self.player)
                                    )
                                )
                            else:
                                set_rule(
                                    location,
                                    lambda state, il=ranked_island_dep: (
                                        state.can_reach_location(il, self.player)
                                    )
                                )
                        except KeyError:
                            pass

        # All weapons that have locations (pool always, non-pool when not disabled)
        all_active_weapons = list(self.pool_weapons)
        if equip_mode != 2:
            all_active_weapons += self.non_pool_weapons
        _set_equipment_rules(
            all_active_weapons,
            CrabChampsLocationCategory.WEAPON_RUN,
            CrabChampsLocationCategory.RANKED_WEAPON_RUN,
            require_item=True,
            pool_set=pool_weapon_set,
        )

        if melee_needed > 0:
            all_active_melee = list(self.pool_melee)
            if equip_mode != 2:
                all_active_melee += self.non_pool_melee
            _set_equipment_rules(
                all_active_melee,
                CrabChampsLocationCategory.MELEE_RUN,
                CrabChampsLocationCategory.RANKED_MELEE_RUN,
                require_item=True,
                pool_set=pool_melee_set,
            )

        if abilities_needed > 0:
            all_active_abilities = list(self.pool_abilities)
            if equip_mode != 2:
                all_active_abilities += self.non_pool_abilities
            _set_equipment_rules(
                all_active_abilities,
                CrabChampsLocationCategory.ABILITY_RUN,
                CrabChampsLocationCategory.RANKED_ABILITY_RUN,
                require_item=True,
                pool_set=pool_ability_set,
            )

        # Mark NON-POOL equipment run locations as EXCLUDED when filler_only
        if equip_mode == 1:
            _equip_categories = {
                CrabChampsLocationCategory.WEAPON_RUN,
                CrabChampsLocationCategory.MELEE_RUN,
                CrabChampsLocationCategory.ABILITY_RUN,
                CrabChampsLocationCategory.RANKED_WEAPON_RUN,
                CrabChampsLocationCategory.RANKED_MELEE_RUN,
                CrabChampsLocationCategory.RANKED_ABILITY_RUN,
            }
            for location in self.multiworld.get_locations(self.player):
                if not hasattr(location, 'category') or location.category not in _equip_categories:
                    continue
                equip_name = self._extract_equip_name(location.name)
                if not self._is_pool_equipment(equip_name, location.category):
                    location.progress_type = LocationProgressType.EXCLUDED

        # --- Non-progression above required rank ---
        if non_prog_above and extra_ranked:
            for location in self.multiworld.get_locations(self.player):
                if not hasattr(location, 'category'):
                    continue
                rank = rank_from_location_name(location.name)
                if rank > required_rank:
                    location.progress_type = LocationProgressType.EXCLUDED

            # Also exclude rank run locations above required
            for r in range(required_rank + 1, max_rank + 1):
                try:
                    loc = self.multiworld.get_location(f"Complete Run on {RANK_NAMES[r]}", self.player)
                    loc.progress_type = LocationProgressType.EXCLUDED
                except KeyError:
                    pass

        # --- Victory rule ---
        # Goal: complete final island with required pool equipment at required rank.
        # Always check pool equipment (pool locations always exist).
        # Capture pool lists for victory closure
        victory_pool_weapons = list(self.pool_weapons)
        victory_pool_melee = list(self.pool_melee)
        victory_pool_abilities = list(self.pool_abilities)

        # Pre-build victory location names using _il helper
        equip_rank = required_rank_name  # e.g. "Bronze"
        victory_weapon_locs = {w: _il(run_length, equip=w, rank=equip_rank)
                               for w in victory_pool_weapons}
        victory_melee_locs = {m: _il(run_length, equip=m, rank=equip_rank)
                              for m in victory_pool_melee}
        victory_ability_locs = {a: _il(run_length, equip=a, rank=equip_rank)
                                for a in victory_pool_abilities}

        def victory_rule(state, rank_name=required_rank_name, wn=weapons_needed,
                         mn=melee_needed, an=abilities_needed,
                         wl=victory_weapon_locs, ml=victory_melee_locs,
                         al=victory_ability_locs):
            # Must complete the required rank
            if not state.can_reach_location(f"Complete Run on {rank_name}", self.player):
                return False
            # Must reach final island with enough different pool weapons at required rank
            weapon_count = sum(
                1 for w, loc in wl.items()
                if state.can_reach_location(loc, self.player)
            )
            if weapon_count < wn:
                return False
            # Melee (if enabled)
            if mn > 0:
                melee_count = sum(
                    1 for m, loc in ml.items()
                    if state.can_reach_location(loc, self.player)
                )
                if melee_count < mn:
                    return False
            # Abilities (if enabled)
            if an > 0:
                ability_count = sum(
                    1 for a, loc in al.items()
                    if state.can_reach_location(loc, self.player)
                )
                if ability_count < an:
                    return False
            return True

        set_rule(self.multiworld.get_location("Victory", self.player), victory_rule)

        self.multiworld.completion_condition[self.player] = lambda state: (
            state.can_reach_location("Victory", self.player)
        )

    def fill_slot_data(self) -> Dict[str, object]:
        name_to_cc_code = {item.name: item.cc_code for item in item_dictionary.values()}

        items_id = []
        items_address = []
        locations_id = []
        locations_address = []
        locations_target = []

        for location in self.multiworld.get_filled_locations():
            if location.item.player == self.player and location.item.name in name_to_cc_code:
                items_id.append(location.item.code)
                items_address.append(name_to_cc_code[location.item.name])

            if location.player == self.player and location.name in location_dictionary:
                loc_data = location_dictionary[location.name]
                locations_address.append(name_to_cc_code.get(loc_data.default_item, 0))
                locations_id.append(location.address)
                if location.item.player == self.player and location.item.name in name_to_cc_code:
                    locations_target.append(name_to_cc_code[location.item.name])
                else:
                    locations_target.append(0)

        return {
            "options": {
                "required_rank": self.options.required_rank.value,
                "required_rank_name": RANK_NAMES[self.options.required_rank.value],
                "max_rank": self.options.max_rank.value,
                "max_rank_name": RANK_NAMES[self.options.max_rank.value],
                "extra_ranked_island_checks": bool(self.options.extra_ranked_island_checks.value),
                "cascade_ranked_checks": bool(self.options.cascade_ranked_checks.value),
                "non_progression_above_required": bool(self.options.non_progression_above_required.value),
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
                "death_link": bool(self.options.death_link.value),
            },
            "death_link": bool(self.options.death_link.value),
            "seed": self.multiworld.seed_name,
            "slot": self.multiworld.player_name[self.player],
            "base_id": self.base_id,
            "locationsId": locations_id,
            "locationsAddress": locations_address,
            "locationsTarget": locations_target,
            "itemsId": items_id,
            "itemsAddress": items_address,
        }
