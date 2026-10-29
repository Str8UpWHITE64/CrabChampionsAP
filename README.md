# Crab Champions Archipelago

An [Archipelago](https://archipelago.gg/) multiworld randomizer integration for [Crab Champions](https://store.steampowered.com/app/774801/Crab_Champions/).

## What Is This?

This mod lets you play Crab Champions as part of an Archipelago multiworld session. Your equipment (weapons, melee weapons, abilities) is randomized into a shared item pool across multiple games and players. Completing islands and collecting items sends checks to other players, and you receive your unlocks from them in return.

## Features

- **Equipment Randomization** — Weapons, melee weapons, and abilities are locked behind the multiworld item pool. You unlock them as other players find your items.
- **Location Checks** — Completing islands, finishing runs at specific ranks, and using specific equipment all count as checks that send items to other players.
- **Ranked Difficulty Tiers** — Supports all 8 difficulty ranks from Bronze through Prismatic, with configurable check ranges. Bronze has no checks of its own, since every clear is at least Bronze: the plain checks are the Bronze checks.
- **Cascade Mode** — Completing an island at a higher rank can automatically count for all lower ranks.
- **Biome Lock** — Runs can only enter biomes you own the Access item for, and start in the biome you choose.
- **Death Link** — Optional synchronized death across all connected players.
- **Configurable Item Pool** — Control how many weapons/melee/abilities are in the pool, what filler items look like, and more.

## Requirements

- [Crab Champions](https://store.steampowered.com/app/774801/Crab_Champions/)
- [Archipelago](https://archipelago.gg/) v0.6.4+

## Installation

### Archipelago World (apworld)

1. Download the crabchampions.apworld file from the latest release.
2. Place it in your Archipelago `custom_worlds/` directory.
3. Open Archipelago and select "Generate Template Options".  This will open your yaml templates folder.
4. Grab the "crabchampions.yaml" file from the templates folder, edit it to your liking, and place it in your "players" directory.

### Game Mod (Lua/UE4SS)

The release zip includes [UE4SS v3.0.1](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v3.0.1), already set up, so there is nothing else to install.

1. Download **`CrabChampionsAP_v<version>.zip`** from the [latest release](https://github.com/Str8UpWHITE64/CrabChampionsAP/releases) and unzip it somewhere temporary. You'll see a `CrabChampions` folder and an `INSTALL.txt`.
2. Open the game folder: Steam Library > right-click Crab Champions > Properties > Installed Files > Browse. It's usually `C:\Program Files (x86)\Steam\steamapps\common\Crab Champions\`.
3. Drag the `CrabChampions` folder from the zip into the game folder, and let Windows merge the folders and replace files. Everything lands in `CrabChampions\Binaries\Win64`:
   ```
   Win64/
   ├── dwmapi.dll, UE4SS.dll   (UE4SS)
   ├── UE4SS-settings.ini       (UE4SS settings, debug console on)
   ├── LICENSE                  (UE4SS license)
   └── Mods/
       ├── CrabChampionsAP/     (Lua mod — AP client, overlay, game hooks)
       ├── CrabInvMngmt/        (C++ mod — inventory management)
       ├── mods.txt             (enables both mods in the correct load order)
       └── ...                  (UE4SS's built-in mods)
   ```
   > **Note:** This replaces `Mods\mods.txt` and `UE4SS-settings.ini`. `mods.txt` makes `CrabInvMngmt` load before `CrabChampionsAP` so the C++ inventory functions are available when the Lua mod starts. If you have other UE4SS mods installed, add their lines back to `mods.txt` above the `Keybinds` line.
4. Launch the game! Press **F4** to open the connection panel, enter your server details, and press **F3** to connect.
   - Your connection details are saved automatically after a successful connection, so you only need to enter them once.

## Configuration Options

These options are set in your Archipelago YAML configuration file. They are grouped below in the same order they appear in the YAML template.

### Victory Conditions

These options define what you need to accomplish to complete the game.

#### `required_rank` (Default: Bronze)
The minimum difficulty rank you must complete a run at for it to count toward victory. Ranks are determined by how many difficulty modifier points you have active:

| Rank | Modifier Points |
|------|----------------|
| Bronze | 0 |
| Silver | 1 |
| Gold | 2–3 |
| Sapphire | 4–5 |
| Emerald | 6–7 |
| Ruby | 8–9 |
| Diamond | 10–15 |
| Prismatic | 16+ |

> **Example:** With `required_rank: gold`, you need at least 2 difficulty modifier points active when you finish a run for it to count.

> **Note:** There are no "on Bronze" checks. Every clear is at least Bronze, so with `required_rank: bronze` the goal uses the plain checks ("Complete Island 15", "Complete Island 15 with Auto Rifle").

#### `run_length` (Default: short)
How many islands you must complete for a single run to count as finished. The game loops islands in cycles of 28.
- **short** = 28 islands (1 cycle)
- **full** = 56 islands (2 cycles)

> **Example:** With `run_length: short`, clearing all 28 islands in a single run counts as a completed run.

#### `check_layout` (Default: island_number)
How island checks are named and counted.
- **island_number** = one check per island number, "Complete Island 15". Shop islands are "Reach Shop on Island 13".
- **biome** = one check per biome and island slot, "Complete Arctic Island 1", "Reach Desert Shop". Rank and equipment checks follow the same names ("Complete Arctic Island 1 on Gold", "Complete Arctic Island 1 with Auto Rifle"). The same biome and slot only counts once, so repeating a biome in a run sends nothing new.

A short run has exactly 28 biome checks of each kind. A full run adds a second set for its second pass through the biomes: "Complete Arctic Island 1 (Loop 2)". The number of checks is the same in both layouts. With `biome_lock` on, a biome check needs that biome's Access item. The goal counts run-level checks instead, "Complete Run with Auto Rifle on Gold", which go out when you clear the run's final island, whichever biome it is in. They need the item but no biome access. With a Bronze goal the final island's plain equipment check, in whichever biome the run ends, counts instead.

Seeds made before this option existed use island numbers.

#### `weapons_for_completion` (Default: 5, Range: 1–21)
How many different weapons you must complete a run with for victory. Each weapon requires its own full run.

**Only weapons in the AP pool count.** Weapons you have available from the start never advance the goal, even when `equipment_check_mode` gives them their own location checks. `weapons_in_pool` is automatically raised to match this value when it is lower, so the goal is always satisfiable from pool weapons alone. The same rule applies to `melee_for_completion` and `ability_for_completion`.

> **Example:** With `weapons_for_completion: 3`, you need to finish 3 separate runs, each with a different **pool** weapon equipped, before you can win.

#### `melee_for_completion` (Default: 3, Range: 0–6)
How many different melee weapons you must complete a run with for victory. Set to **0** to disable melee completion requirements entirely (no melee location checks are generated).

> **Example:** With `melee_for_completion: 2`, you need 2 completed runs using different melee weapons. Setting it to `0` removes all melee-related checks from the game.

#### `ability_for_completion` (Default: 3, Range: 0–9)
How many different abilities you must complete a run with for victory. Set to **0** to disable ability completion requirements entirely (no ability location checks are generated).

> **Example:** With `ability_for_completion: 2`, you need 2 completed runs using different abilities. Setting it to `0` removes all ability-related checks from the game.

---

### Item Pool & Equipment

These options control which equipment is randomized into the Archipelago item pool and how equipment-based location checks work.

#### `weapons_in_pool` (Default: 5, Range: 1–21)
How many weapons are randomly selected and locked behind the AP item pool. You must receive these weapons from other players (or yourself) before you can use them. **Each weapon in the pool creates its own run-completion location check**, even if `weapons_for_completion` is lower.

Set to 21 to put every weapon in the pool. In that case `starting_weapons` is forced to at least 1, so one random pool weapon is added to your starting inventory and you always begin with something usable.

> **Example:** With `weapons_in_pool: 5` and `weapons_for_completion: 3`, five specific weapons (e.g., Auto Rifle, Rocket Launcher, Arcane Wand, Blade Launcher, Sniper) are locked behind AP items. Each of those 5 weapons generates a "Complete a run with [Weapon]" location check — that's **5 location checks total**. However, you only need to complete runs with any **3** of them to satisfy the victory condition.

#### `melee_in_pool` (Default: 0, Range: 0–6)
How many melee weapons are locked behind the AP item pool. **Each melee weapon in the pool creates its own run-completion location check**, even if `melee_for_completion` is lower. Forced to 0 when `melee_for_completion` is 0. Set to 6 to put every melee weapon in the pool — one random pool melee is then added to your starting inventory so you always begin with something usable.

> **Example:** With `melee_in_pool: 3` and `melee_for_completion: 1`, three melee weapons (e.g., Katana, Hammer, Dagger) are locked. All 3 generate location checks ("Complete a run with Katana", "Complete a run with Hammer", "Complete a run with Dagger"), but you only need to complete a run with **1** of them to win.

#### `abilities_in_pool` (Default: 0, Range: 0–9)
How many abilities are locked behind the AP item pool. **Each ability in the pool creates its own run-completion location check**, even if `ability_for_completion` is lower. Forced to 0 when `ability_for_completion` is 0. Set to 9 to put every ability in the pool — one random pool ability is then added to your starting inventory so you always begin with something usable.

> **Example:** With `abilities_in_pool: 4` and `ability_for_completion: 2`, four abilities (e.g., Grenade, Black Hole, Ice Blast, Laser Beam) are locked. All 4 generate location checks, but only **2** must be completed for victory.

#### `starting_weapons` (Default: 0, Range: 0–20)
How many of your pool weapons you start with already unlocked. These are randomly selected from your pool and given to you immediately, so you can start working on equipment run checks right away. Must be less than `weapons_in_pool`. Forced to at least 1 when `weapons_in_pool` is 21, since no weapon would otherwise be available at the start.

A weapon you start with is removed from the item pool rather than duplicated — its slot goes to filler instead of a second copy of something you already hold.

> **Example:** With `weapons_in_pool: 5` and `starting_weapons: 2`, you begin the game with 2 of your 5 pool weapons already unlocked and need to find the other 3 through AP.

#### `equipment_check_mode` (Default: disabled)
Controls how **non-pool** equipment run locations behave. Equipment that is in the AP pool always generates normal location checks. This option only affects equipment that is **not** in the pool (i.e., equipment you have access to from the start):
- **regular** — Non-pool equipment creates normal location checks that can hold any item.
- **filler_only** — Non-pool equipment creates location checks, but they can only hold filler/useful items (never progression).
- **disabled** — Non-pool equipment does not create any location checks at all.

> **Example:** If you have 5 weapons in the pool and 16 not in the pool, with `equipment_check_mode: disabled`, only the 5 pool weapons generate run-completion checks. With `equipment_check_mode: regular`, all 21 weapons generate checks.

> **Note:** These are bonus locations only — non-pool equipment runs never count toward `weapons_for_completion`, `melee_for_completion`, or `ability_for_completion`.

> **Note:** This option has no effect on a category whose pool holds every item (`weapons_in_pool: 21`, `melee_in_pool: 6`, `abilities_in_pool: 9`) — there is no non-pool equipment left for it to act on.

---

### Rank Modifiers

These options control how difficulty ranks interact with location checks. They are most impactful when you want checks at multiple rank tiers.

#### `max_rank` (Default: Sapphire)
The highest rank that generates location checks. Must be >= `required_rank`. Any rank above this produces no locations at all. The ranks between `required_rank` and `max_rank` provide optional extra checks when `extra_rank_checks` is set to anything other than `none`.

> **Example:** With `required_rank: bronze` and `max_rank: gold`, locations can be generated for Bronze (the plain checks), Silver, and Gold. Anything done at Sapphire or above produces no additional checks.

#### `extra_rank_checks` (Default: none)
Controls whether ranks **above** `required_rank` generate additional location checks. Replaces the legacy `extra_ranked_island_checks` + `non_progression_above_required` pair with a single option:

- **`none`** — Only `required_rank` produces ranked checks. Higher ranks are ignored.
- **`progression`** — Ranks above required (up to `max_rank`) add new ranked checks, and those locations can hold progression items. Greatly increases location count.
- **`filler_only`** — Ranks above required add new ranked checks, but those locations are excluded from progression — they only ever hold filler items. Adds checks for variety without forcing high-rank grinding for critical items.

Has no effect when `required_rank == max_rank` (no extra ranks exist).

> **Example:** With `required_rank: bronze`, `max_rank: gold`, and `extra_rank_checks: progression`, completing Island 10 generates three separate checks: "Complete Island 10", "Complete Island 10 on Silver", and "Complete Island 10 on Gold". With `filler_only` instead, the same checks exist but the Silver/Gold ones won't hold critical items.

#### `cascade_ranked_checks` (Default: false)
When enabled, completing a check at a higher rank automatically completes the equivalent check at all lower ranks.

> **Example:** With cascade enabled, completing "Island 5 on Gold" also marks "Island 5 on Silver" and the plain "Complete Island 5" as complete. Without cascade, you'd need to complete each rank separately.

#### `minimize_run_checks` (Default: false)
When enabled, drops generalized run-completion checks that are made redundant by more-specific equipment-and-rank checks. When equipment runs are enabled (`equipment_check_mode != disabled`):

- "Complete Island X on Rank" checks are removed
- "Complete Island X with Weapon" checks are removed (unless they are the Bronze checks, see below)

The most specific "Complete Island X with Weapon on Rank" check is always kept.

> **Example:** With minimize on and equipment runs enabled, completing "Island 5 with Auto Rifle on Gold" is the only ranked check generated for that combination — the standalone "Island 5 on Gold" check is dropped since it would fire automatically from the same gameplay. The plain "Island 5 with Auto Rifle" check is the Bronze check, so it stays when Bronze is part of the goal or `extra_rank_checks` is on.

---

### Biomes

The game has four biomes (Tropical, Arctic, Desert and Volcanic), seven islands each. Normally a run walks through them in that order.

#### `biome_lock` (Default: on)
Your runs can only enter biomes you own the **Access** item for: Tropical Access, Arctic Access, Desert Access and Volcanic Access. You start with the Access item of your starting biome; the other three are in the multiworld. When the next biome of a run is one you do not own, the run goes to a biome you do own instead, and repeats the same biome if it is the only one. The island numbers keep counting up, so island-number checks stay reachable with a single biome; with the biome `check_layout`, each biome's checks need its Access item. The game's loop at island 29 starts again in your starting biome.

Turn it off to play the game's normal biome order, with no Access items.

#### `starting_biome` (Default: random)
Which biome your runs start in when `biome_lock` is on: tropical, arctic, desert, volcanic or random. You own its Access item from the start. The biome name on the screen shows the biome you are really in.

---

### Pickup Checks

#### `granted_item_checks` (Default: true)
When on, receiving a perk, mod or relic from the multiworld also completes that item's pickup check. For example, being sent Driller checks "Perk: Driller".

When off, pickup checks only come from finding items in a run: loot, chests, totems and shop purchases. Items you drop and pick back up, and the lobby's free item, never count either way.

### Pickup Subset Limits

These options scale the pickup pool down to per-run inventory caps so the AP pool doesn't grossly exceed what the player can actually carry. Both options share the same randomly-chosen subset (24 perks, 24 weapon mods, 12 ability mods, 12 melee mods, 10 relics) and can be enabled independently.

#### `limit_pickup_pool` (Default: false)
When enabled, the AP item pool is limited to the chosen subset. Items not in the subset stay in-game and can be picked up normally during runs but are never sent or received via AP. Tag-group coverage is enforced so tag-gated locations like "Relic: Time Ring" remain reachable.

#### `limit_pickup_locations` (Default: false)
When enabled, pickup location checks are only generated for items in the chosen subset. Items not in the subset still appear in-game but produce no location check when picked up.

---

### Received Items Per Run

Perks, mods and relics only last one run, so the mod gives you your received ones again at the start of every run. These options control how many.

#### `starting_item_percentage` (Default: 5, Range: 0–100)
The percentage of your received perks, mods and relics you start each run with, picked at random and rounded up. Items received during a run are applied right away, and crystals always come in full. Set to **100** to start every run with everything.

> **Example:** With 200 received items and `starting_item_percentage: 5`, each run starts with 10 of them.

#### `biome_item_percentage` (Default: 5, Range: 0–100)
When you clear the last island of a biome, this percentage of the received items you don't have yet this run is granted, picked at random and rounded up. Set to **0** to turn it off.

> **Example:** Continuing the example above, clearing the first biome grants 5% of the remaining 190 items, so 10 more.

### Traps

Traps are received items that make a run harder for a short time. None of them is permanent, removes your equipment, perks or progress, or can kill you. They are off by default. A trap that arrives in the lobby, or in the first seconds of an island, waits (see `trap_grace_seconds`). A reconnect or a game restart never fires the same trap twice.

#### `trap_percentage` (Default: 0, Range: 0-100)
The percentage of the filler slots that become traps. Filler slots are what is left after equipment, one of each pickup and any Perk Boosts.

#### Trap weights (each Default: see below, Range: 0-100)
`trap_weight_crystal_tax` (20), `trap_weight_slowdown` (20), `trap_weight_weak_shots` (20), `trap_weight_bruise` (20), `trap_weight_grow` (10), `trap_weight_shrink` (10), `trap_weight_heavy_gravity` (10), `trap_weight_floaty_gravity` (10). The relative chance of each trap kind; 0 removes that trap.

| Trap | Effect |
|------|--------|
| Crystal Tax | Takes `crystal_tax_percent` (default 25) of your current crystals. |
| Slowdown Trap | Walk speed drops by `slowdown_percent` (default 35) until the island you were on is over. |
| Weak Shots Trap | Your outgoing damage is cut to `weak_shots_percent` (default 50) for `trap_duration` seconds. |
| Bruise Trap | Takes `bruise_percent` (default 30) of your current health. It never takes the last point. |
| Grow Trap / Shrink Trap | A bigger / smaller crab for `trap_duration` seconds. |
| Heavy Gravity Trap / Floaty Gravity Trap | Stronger / weaker gravity for `trap_duration` seconds. |

Other trap options: `trap_duration` (default 30, 5-120 seconds), `trap_grace_seconds` (default 10, 0-60), `crystal_tax_percent` (5-100), `slowdown_percent` (10-80), `weak_shots_percent` (10-90), `bruise_percent` (5-90). Effects end when the timer runs out, when the island is over (Slowdown), or when you die or return to the lobby.

### Perk Boost

A **Perk Boost** adds one level to a random perk you are holding in the current run. It is strong, so it is limited three ways:

- `perk_boost_count` (Default: 0, Range: 0-50): how many Perk Boosts are in the pool (they take filler slots).
- `perk_boost_max_per_run` (Default: 3, Range: 1-20): the most that take effect in one run; the rest wait for the next run.
- `perk_boost_level_cap` (Default: 5, Range: 2-10): a boost never raises a perk above this level. Greed perks are skipped, and a boost with nothing to raise waits until you hold a perk it can.

### Filler & Miscellaneous

#### `crystal_cache_percentage` (Default: 75, Range: 0–100)
Controls what percentage of extra item pool slots are filled with Crystal Cache rewards (which grant crystals in-game) versus additional copies of perks and mods.

> **Example:** At `75`, three-quarters of the filler slots are crystal rewards and one-quarter are extra perk/mod stacks. At `0`, all filler is perks/mods. At `100`, all filler is crystals.

#### `greed_item_mode` (Default: auto)
Controls how Greed items are handled. Greed items (certain perks, relics, and melee mods) cannot be dropped once picked up, making them a permanent commitment.
- **auto** — Greed items are added directly to your inventory when received from AP, just like any other item.
- **drop** — Greed items are spawned on the floor in the lobby for you to pick up manually, so you can choose whether to pick them up or not.
- **skip** — Greed items are removed from the item and location pools entirely. You can still find them naturally in-game.

> **Example:** With `greed_item_mode: drop`, when you receive a Greed perk like "Glass Cannon" from AP, it appears on the ground near you instead of being auto-added. You can pick it up if you want it, or leave it.

#### `guaranteed_items` (Default: empty)
A dictionary of specific items guaranteed to appear in the item pool.

#### `death_link` (Default: false)
When enabled, dying in Crab Champions sends a death to all connected Death Link players, and deaths from other players kill you. Deaths are only sent and received during runs — not in the lobby.

## Item Categories

- **Weapons** (21): Arcane Wand, Auto Rifle, Blade Launcher, Popcorn Shotgun, Rocket Launcher, and more
- **Melee Weapons** (6): Baseball Bat, Claw, Dagger, Hammer, Katana, Pickaxe
- **Abilities** (9): Air Strike, Black Hole, Boomerang, Electro Globe, Grappling Hook, Grenade, Ice Blast, Laser Beam, Tornado
- **Perks** (116): Stackable bonuses like Damage Combo, Speed Demon, Critical Strike
- **Relics** (70): Unique rings and amulets
- **Weapon Mods** (93): Modifications like Arc Shot, Big Shot, Fire Strike
- **Melee Mods** (17): Augmentations like Big Claws, Fire Claws
- **Ability Mods** (45): Augmentations like Beam Turret, Homing Ability
- **Filler**: Crystal Cache, Crystal Hoard, Crystal Jackpot, Perk Boost
- **Biome Access** (4): Tropical Access, Arctic Access, Desert Access, Volcanic Access (only with `biome_lock`)
- **Traps** (8): Crystal Tax, Slowdown, Weak Shots, Bruise, Grow, Shrink, Heavy Gravity, Floaty Gravity

## Difficulty Ranks

| Rank      | Modifier Level |
|-----------|----------------|
| Bronze    | 0              |
| Silver    | 1              |
| Gold      | 2–3            |
| Sapphire  | 4–5            |
| Emerald   | 6–7            |
| Ruby      | 8–9            |
| Diamond   | 10–15          |
| Prismatic | 16+            |

## Locations
With the maximum settings selected, there are about 16,900 possible checks. 
- **Island Completion**: Completing an island sends a check, and so does completing it at a specific rank above Bronze.
- **Equipment**: Completing islands with specific weapons, melee weapons, or abilities equipped can send checks based on the `equipment_check_mode` setting.
- **Run Completion**: Finishing a run at or above the required rank sends a check.
- **Perk/Mod Pickup**: Grabbing a perk or mod that is in the item pool sends a check.


## Items
- **Weapons/Melee/Abilities**: Each of these is configurable.  You can add all to the pool, or just a few. 
- **Perks/Relics/Mods**: These are not required for completion but can be added to the pool as extra items.  If you pick up a perk or mod that you haven't received yet, it will send the check for it and remove it from your inventory.
- **Crystals**: The pool is mostly filled with crystal bundles.  You can change the percentage of crystal rewards vs. stackable items with the `crystal_cache_percentage` setting.  See the `Bugs` section for related details.

## How It Works

1. **Generate** a multiworld with Crab Champions included via Archipelago.
2. **Connect** the Lua mod to the Archipelago server.
3. **Play** Crab Champions — you start with limited equipment based on your pool settings.  Items will be spawned in front of you and automatically grabbed, aside from Greed perks.  
4. **Complete islands** and collect items to send checks to other players.
5. **Receive equipment** unlocks and items as other players find your checks.
6. **Win** by collecting enough weapons, melee weapons, and abilities to meet the completion requirements, then finishing a run at the required rank.


## Bugs
- None so far!  Report any issues you find in the Discord thread or on GitHub.

## Building a release

`python tools/build_release.py` builds `dist/CrabChampionsAP_v<version>.zip` from the committed files at `HEAD` (`--ref` picks another commit or tag), with the bundled UE4SS from `third_party/UE4SS/`.

## Credits

- **Author**: Str8UpWHITE64
- Built with [Archipelago](https://archipelago.gg/) and [UE4SS](https://docs.ue4ss.com/) (bundled under the MIT License, copyright (c) 2022 Narknon)
