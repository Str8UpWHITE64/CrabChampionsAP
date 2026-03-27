# Crab Champions Archipelago

An [Archipelago](https://archipelago.gg/) multiworld randomizer integration for [Crab Champions](https://store.steampowered.com/app/774801/Crab_Champions/).

## What Is This?

This mod lets you play Crab Champions as part of an Archipelago multiworld session. Your equipment (weapons, melee weapons, abilities) is randomized into a shared item pool across multiple games and players. Completing islands and collecting items sends checks to other players, and you receive your unlocks from them in return.

## Features

- **Equipment Randomization** — Weapons, melee weapons, and abilities are locked behind the multiworld item pool. You unlock them as other players find your items.
- **Location Checks** — Completing islands, finishing runs at specific ranks, and using specific equipment all count as checks that send items to other players.
- **Ranked Difficulty Tiers** — Supports all 8 difficulty ranks from Bronze through Prismatic, with configurable check ranges.
- **Cascade Mode** — Completing an island at a higher rank can automatically count for all lower ranks.
- **Death Link** — Optional synchronized death across all connected players.
- **Configurable Item Pool** — Control how many weapons/melee/abilities are in the pool, what filler items look like, and more.

## Requirements

- [Crab Champions](https://store.steampowered.com/app/774801/Crab_Champions/)
- [UE4SS v3.0.1](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v3.0.1)
- [lua-apclient](github.com/black-sliver/lua-apclientpp/releases/tag/v0.6.4)
- [Archipelago](https://archipelago.gg/) v0.6.4+

## Installation

### Archipelago World (apworld)

1. Download the crabchampions.apworld file from the latest release.
2. Place it in your Archipelago `custom_worlds/` directory.
3. Open Archipelago and select "Generate Template Options".  This will open your yaml templates folder.
4. Grab the "crabchampions.yaml" file from the templates folder, edit it to your liking, and place it in your "players" directory.

### Game Mod (Lua/UE4SS)

1. Download [UE4SS v3.0.1](https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v3.0.1/UE4SS_v3.0.1.zip) and unzip it.
2. Navigate to Steam Library > Right-click Crab Champions > Properties > Local Files > Browse, then go to `CrabChampions\Binaries\Win64` and copy the contents of the UE4SS zip into the game's `Win64` directory.
3. Edit `UE4SS-settings.ini` and set `ConsoleEnabled = 1` to enable the debug console.
4. Download **CrabChampionsAP.zip** from the [latest release](https://github.com/Str8UpWHITE64/CrabChampionsAP/releases) and unzip it. Copy all three items into the `Mods` directory:
   ```
   Mods/
   ├── CrabChampionsAP/    (Lua mod — AP client, overlay, game hooks)
   ├── CrabInvMngmt/       (C++ mod — inventory management)
   └── mods.txt             (enables both mods in the correct load order)
   ```
   > **Note:** The included `mods.txt` replaces the default one. It ensures `CrabInvMngmt` loads before `CrabChampionsAP` so the C++ inventory functions are available when the Lua mod starts. If you have other UE4SS mods installed, merge the entries manually.
5. Launch the game! Press **F4** to open the connection panel, enter your server details, and press **F3** to connect.
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

#### `run_length` (Default: short)
How many islands you must complete for a single run to count as finished. The game loops islands in cycles of 28.
- **short** = 28 islands (1 cycle)
- **full** = 56 islands (2 cycles)

> **Example:** With `run_length: short`, clearing all 28 islands in a single run counts as a completed run.

#### `weapons_for_completion` (Default: 5, Range: 1–20)
How many different weapons you must complete a run with for victory. Each weapon requires its own full run.

> **Example:** With `weapons_for_completion: 3`, you need to finish 3 separate runs, each with a different weapon equipped, before you can win.

#### `melee_for_completion` (Default: 3, Range: 0–5)
How many different melee weapons you must complete a run with for victory. Set to **0** to disable melee completion requirements entirely (no melee location checks are generated).

> **Example:** With `melee_for_completion: 2`, you need 2 completed runs using different melee weapons. Setting it to `0` removes all melee-related checks from the game.

#### `ability_for_completion` (Default: 3, Range: 0–7)
How many different abilities you must complete a run with for victory. Set to **0** to disable ability completion requirements entirely (no ability location checks are generated).

> **Example:** With `ability_for_completion: 2`, you need 2 completed runs using different abilities. Setting it to `0` removes all ability-related checks from the game.

---

### Item Pool & Equipment

These options control which equipment is randomized into the Archipelago item pool and how equipment-based location checks work.

#### `weapons_in_pool` (Default: 5, Range: 1–19)
How many weapons are randomly selected and locked behind the AP item pool. You must receive these weapons from other players (or yourself) before you can use them. **Each weapon in the pool creates its own run-completion location check**, even if `weapons_for_completion` is lower.

Capped at 19 so you always have at least one weapon available from the start.

> **Example:** With `weapons_in_pool: 5` and `weapons_for_completion: 3`, five specific weapons (e.g., Auto Rifle, Rocket Launcher, Arcane Wand, Blade Launcher, Railgun) are locked behind AP items. Each of those 5 weapons generates a "Complete a run with [Weapon]" location check — that's **5 location checks total**. However, you only need to complete runs with any **3** of them to satisfy the victory condition.

#### `melee_in_pool` (Default: 0, Range: 0–4)
How many melee weapons are locked behind the AP item pool. **Each melee weapon in the pool creates its own run-completion location check**, even if `melee_for_completion` is lower. Forced to 0 when `melee_for_completion` is 0. Capped at 4 so you always have at least one melee weapon available.

> **Example:** With `melee_in_pool: 3` and `melee_for_completion: 1`, three melee weapons (e.g., Katana, Hammer, Dagger) are locked. All 3 generate location checks ("Complete a run with Katana", "Complete a run with Hammer", "Complete a run with Dagger"), but you only need to complete a run with **1** of them to win.

#### `abilities_in_pool` (Default: 0, Range: 0–6)
How many abilities are locked behind the AP item pool. **Each ability in the pool creates its own run-completion location check**, even if `ability_for_completion` is lower. Forced to 0 when `ability_for_completion` is 0. Capped at 6 so you always have at least one ability available.

> **Example:** With `abilities_in_pool: 4` and `ability_for_completion: 2`, four abilities (e.g., Grenade, Black Hole, Ice Blast, Laser Beam) are locked. All 4 generate location checks, but only **2** must be completed for victory.

#### `starting_weapons` (Default: 0, Range: 0–19)
How many of your pool weapons you start with already unlocked. These are randomly selected from your pool and given to you immediately, so you can start working on equipment run checks right away. Must be less than `weapons_in_pool`.

> **Example:** With `weapons_in_pool: 5` and `starting_weapons: 2`, you begin the game with 2 of your 5 pool weapons already unlocked and need to find the other 3 through AP.

#### `equipment_check_mode` (Default: disabled)
Controls how **non-pool** equipment run locations behave. Equipment that is in the AP pool always generates normal location checks. This option only affects equipment that is **not** in the pool (i.e., equipment you have access to from the start):
- **regular** — Non-pool equipment creates normal location checks that can hold any item.
- **filler_only** — Non-pool equipment creates location checks, but they can only hold filler/useful items (never progression).
- **disabled** — Non-pool equipment does not create any location checks at all.

> **Example:** If you have 5 weapons in the pool and 15 not in the pool, with `equipment_check_mode: disabled`, only the 5 pool weapons generate run-completion checks. With `equipment_check_mode: regular`, all 20 weapons generate checks.

---

### Rank Modifiers

These options control how difficulty ranks interact with location checks. They are most impactful when you want checks at multiple rank tiers.

#### `max_rank` (Default: Sapphire)
The highest rank that generates location checks. Must be >= `required_rank`. Any rank above this produces no locations at all. The ranks between `required_rank` and `max_rank` provide optional extra checks when `extra_ranked_island_checks` is enabled.

> **Example:** With `required_rank: bronze` and `max_rank: gold`, locations can be generated for Bronze, Silver, and Gold. Anything done at Sapphire or above produces no additional checks.

#### `extra_ranked_island_checks` (Default: false)
When enabled, island completions and equipment runs generate **separate checks for each rank** up to `max_rank`, not just at the `required_rank`. This greatly increases the total number of locations.

When **disabled**, `max_rank` and `non_progression_above_required` have no meaningful effect, since all checks are generated only at the `required_rank` level.

> **Example:** With `required_rank: bronze`, `max_rank: gold`, and `extra_ranked_island_checks: true`, completing Island 10 generates three separate checks: "Complete Island 10 on Bronze", "Complete Island 10 on Silver", and "Complete Island 10 on Gold". Without this option, only "Complete Island 10 on Bronze" exists.

#### `non_progression_above_required` (Default: false)
When enabled, items placed at locations for ranks **above** the `required_rank` (but at or below `max_rank`) are classified as useful or filler only — never progression. This prevents critical items from being locked behind higher difficulty content.

**Only has an effect when `extra_ranked_island_checks` is enabled.** If extra ranked checks are off, there are no above-required-rank locations to restrict.

> **Example:** With `required_rank: bronze`, `max_rank: gold`, and both toggles enabled, the Bronze-rank checks can contain progression items (weapons, key unlocks, etc.), but the Silver and Gold checks will only contain helpful or filler items. You'll never be forced to play at Gold rank to find a required weapon.

#### `cascade_ranked_checks` (Default: false)
When enabled, completing a check at a higher rank automatically completes the equivalent check at all lower ranks.

> **Example:** With cascade enabled, completing "Island 5 on Gold" also marks "Island 5 on Silver" and "Island 5 on Bronze" as complete. Without cascade, you'd need to complete each rank separately.

---

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

- **Weapons** (20): Arcane Wand, Auto Rifle, Blade Launcher, Rocket Launcher, and more
- **Melee Weapons** (5): Claw, Dagger, Hammer, Katana, Pickaxe
- **Abilities** (7): Air Strike, Black Hole, Electro Globe, Grappling Hook, Grenade, Ice Blast, Laser Beam
- **Perks** (107): Stackable bonuses like Damage Combo, Speed Demon, Critical Strike
- **Relics** (53): Unique rings and amulets
- **Weapon Mods** (90): Modifications like Arc Shot, Big Shot, Fire Strike
- **Melee Mods** (12): Augmentations like Big Claws, Fire Claws
- **Ability Mods** (43): Augmentations like Aura Explosion, Beam Turret
- **Filler**: Crystal Cache, Crystal Hoard, Crystal Jackpot

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
With the maximum settings selected, there are about 15,100 possible checks. 
- **Island Completion**: Completing an island at a specific rank sends a check.
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

## Credits

- **Author**: Str8UpWHITE64
- Built with [Archipelago](https://archipelago.gg/) and [UE4SS](https://docs.ue4ss.com/)
