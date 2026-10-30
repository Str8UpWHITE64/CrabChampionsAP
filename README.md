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
- [Archipelago](https://archipelago.gg/) v0.6.6+

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

### Worlds made with older versions

Multiworlds made with apworld 1.4.0 or earlier still play with this mod, with the same checks and items as before. The game's 2.0 update changed a few of their items:

- **All You Can Eat** is a relic now. The seed's All You Can Eat gives the relic, and picking up the relic sends the seed's All You Can Eat check.
- **Aura Explosion** is gone from the game. Receiving it gives nothing, and its pickup check is sent as soon as you connect, since it can no longer be found.
- Items the update added are not part of an older seed. They are ordinary pickups there: they have no check and you keep them, and the new weapons, melee and abilities are unlocked like non-pool equipment.

## Configuration Options

These options are set in your Archipelago YAML configuration file, or on the options page on the website, where the Presets ("Short and easy", "Standard", "Long grind") fill in a set for you. They are grouped below in the same order and under the same headings as in the YAML template. Options you leave out keep the defaults shown here.

When an option would clash with another (for example a pool smaller than the number needed to win), generation changes it for you and prints a warning saying what it changed.

### Goal

What you need to do to win.

#### `required_rank` (Default: Bronze)
The rank you must reach to win. A run counts when you finish it at this rank or higher, so a Gold run also counts for Silver. Rank comes from how many difficulty modifier points you have active:

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
How many islands a run must complete to count as finished. The game loops islands in cycles of 28.
- **short** = 28 islands (1 cycle)
- **full** = 56 islands (2 cycles)

Island and equipment checks scale with this, so a full run has about twice as many of them. Pickup checks and the per-rank "Complete Run" checks do not change.

#### `weapons_for_completion` (Default: 5, Range: 1–21)
How many different weapons you must complete a run with for victory. Each weapon requires its own full run.

**Only weapons in the AP pool count.** Weapons you have available from the start never advance the goal, even when `equipment_check_mode` gives them their own location checks. `weapons_in_pool` is automatically raised to match this value when it is lower, so the goal is always satisfiable from pool weapons alone. A pool weapon you start with already counts. The same rules apply to `melee_for_completion` and `ability_for_completion`.

> **Example:** With `weapons_for_completion: 3`, you need to finish 3 separate runs, each with a different **pool** weapon equipped, before you can win.

#### `melee_for_completion` (Default: 3, Range: 0–6)
How many different melee weapons you must complete a run with for victory. Set to **0** to disable melee completion requirements entirely (no melee items in the pool and no melee location checks).

#### `ability_for_completion` (Default: 3, Range: 0–9)
How many different abilities you must complete a run with for victory. Set to **0** to disable ability completion requirements entirely (no ability items in the pool and no ability location checks).

---

### Equipment

These options control which equipment is locked behind Archipelago items and how equipment-based checks work.

#### `weapons_in_pool` (Default: 5, Range: 1–21)
How many weapons are randomly selected and locked behind the AP item pool. You must receive these weapons before you can use them. **Each weapon in the pool gets its own per-island run checks**, even if `weapons_for_completion` is lower. Weapons not in the pool are available from the start.

Set to 21 to put every weapon in the pool. In that case `starting_weapons` is forced to at least 1, so you always begin with something usable.

> **Example:** With `weapons_in_pool: 5` and `weapons_for_completion: 3`, five weapons are locked behind AP items and each has its own checks, but you only need to complete runs with any **3** of them to win.

#### `melee_in_pool` (Default: 3, Range: 0–6)
How many melee weapons are locked behind the AP item pool, with their own checks. Raised to `melee_for_completion` when lower, and set to 0 when `melee_for_completion` is 0. At 6, `starting_melee` is forced to at least 1.

#### `abilities_in_pool` (Default: 3, Range: 0–9)
How many abilities are locked behind the AP item pool, with their own checks. Raised to `ability_for_completion` when lower, and set to 0 when `ability_for_completion` is 0. At 9, `starting_abilities` is forced to at least 1.

#### `starting_weapons` (Default: 0, Range: 0–20)
How many of your pool weapons you start with already unlocked, picked at random from your pool. Must be less than `weapons_in_pool` (it is reduced if not). Forced to at least 1 when `weapons_in_pool` is 21.

A weapon you start with is removed from the item pool rather than duplicated; its slot goes to filler.

> **Example:** With `weapons_in_pool: 5` and `starting_weapons: 2`, you begin with 2 of your 5 pool weapons and need to find the other 3 through AP.

#### `starting_melee` (Default: 0, Range: 0–5)
The same as `starting_weapons`, for pool melee weapons. Must be less than `melee_in_pool`; forced to at least 1 when `melee_in_pool` is 6.

#### `starting_abilities` (Default: 0, Range: 0–8)
The same as `starting_weapons`, for pool abilities. Must be less than `abilities_in_pool`; forced to at least 1 when `abilities_in_pool` is 9.

#### `equipment_check_mode` (Default: disabled)
Controls how checks for **non-pool** equipment (equipment you have from the start) behave. Equipment in the AP pool always has normal checks.
- **regular** — Non-pool equipment has normal checks that can hold any item.
- **filler_only** — Non-pool equipment has checks, but they only hold filler.
- **disabled** — Non-pool equipment has no checks.

> **Example:** With 5 weapons in the pool and 16 not, `disabled` gives run checks for the 5 pool weapons only; `regular` gives them for all 21.

> **Note:** These are bonus checks. Non-pool equipment never counts toward `weapons_for_completion`, `melee_for_completion` or `ability_for_completion`. The option has no effect on a category whose pool holds everything.

---

### Run Checks

#### `check_layout` (Default: island_number)
How island checks are named and counted.
- **island_number** = one check per island number, "Complete Island 15". Shop islands are "Reach Shop on Island 13".
- **biome** = one check per biome and island slot, "Complete Ice Island 1", "Reach Desert Shop". Rank and equipment checks follow the same names ("Complete Ice Island 1 on Gold", "Complete Ice Island 1 with Auto Rifle"). The same biome and slot only counts once, so repeating a biome in a run sends nothing new.

A short run has exactly 28 biome checks of each kind. A full run adds a second set for its second pass through the biomes: "Complete Ice Island 1 (Loop 2)". The number of checks is the same in both layouts. With `biome_lock` on, a biome check needs that biome's Access item. The goal counts run-level checks instead, "Complete Run with Auto Rifle on Gold", which go out when you clear the run's final island, whichever biome it is in. They need the item but no biome access. With a Bronze goal the final island's plain equipment check, in whichever biome the run ends, counts instead.

Seeds made before this option existed use island numbers.

#### `extra_rank_checks` (Default: none)
Whether ranks besides `required_rank` get their own checks. A higher rank always counts for all lower ranks, so one Gold clear also covers the Silver and plain checks.

- **`none`** — Only `required_rank` has ranked checks, plus the plain checks that any clear sends.
- **`progression`** — Every rank from Silver up to `max_rank` gets ranked checks, and they can hold progression items. Greatly increases the number of checks.
- **`filler_only`** — The same checks, but those above `required_rank` only hold filler. Adds checks for variety without forcing high-rank grinding for important items.

Has no effect when `required_rank` and `max_rank` are both Bronze.

> **Example:** With `required_rank: bronze`, `max_rank: gold` and `extra_rank_checks: progression`, completing Island 10 can send three checks: "Complete Island 10", "Complete Island 10 on Silver" and "Complete Island 10 on Gold". With `filler_only` the same checks exist, but the Silver and Gold ones will not hold critical items.

#### `max_rank` (Default: Sapphire)
The highest rank that gets its own checks. Raised to `required_rank` when lower. A run above `max_rank` still counts for every rank up to `max_rank`. Only used when `extra_rank_checks` is not `none`. Bronze here means only the plain checks.

> **Example:** With `required_rank: bronze` and `max_rank: gold`, checks exist for Bronze (the plain checks), Silver and Gold. A Sapphire run counts for all three and adds nothing else.

#### `minimize_run_checks` (Default: false)
Leaves out checks that a more specific check already covers, for a smaller world:

- "Complete Island X on Rank" (the per-rank island checks) are removed; the plain "Complete Island X" stays.
- "Complete Island X with Weapon" (the plain equipment checks) are removed when the goal is above Bronze, since "with Weapon on Rank" covers them. With a Bronze goal or `extra_rank_checks` on they stay, because they are the Bronze checks.

"Complete Island X with Weapon on Rank" is always kept.

---

### Biomes

The game has four biomes (Tropical, Ice, Desert and Volcano), seven islands each. Normally a run walks through them in that order.

#### `biome_lock` (Default: on)
Your runs can only enter biomes you own the **Access** item for: Tropical Access, Ice Access, Desert Access and Volcano Access. You start with the Access item of your starting biome; the other three are in the multiworld. When the next biome of a run is one you do not own, the run goes to a biome you do own instead, and repeats the same biome if it is the only one. The island numbers keep counting up, so island-number checks stay reachable with a single biome; with the biome `check_layout`, each biome's checks need its Access item. The game's loop at island 29 starts again in your starting biome.

Turn it off to play the game's normal biome order, with no Access items.

#### `starting_biome` (Default: random)
Which biome your runs start in when `biome_lock` is on: tropical, ice, desert, volcano or random. You own its Access item from the start. The biome name on the screen shows the biome you are really in.

---

### Pickup Checks

#### `pickup_checks` (Default: on)
Picking up a perk, relic, weapon mod, melee mod or ability mod for the first time sends a check, e.g. "Perk: Driller". There are up to 341 of these (318 with `greed_item_mode: skip`). When off they do not exist, and the world is only island, equipment and rank checks. Perks, mods and relics are still received as items, but a small world only holds a random part of them.

#### `granted_item_checks` (Default: true)
When on, receiving a perk, mod or relic from the multiworld also completes that item's pickup check. For example, being sent Driller checks "Perk: Driller".

When off, pickup checks only come from finding items in a run: loot, chests, totems and shop purchases. Items you drop and pick back up, and the lobby's free item, never count either way.

#### `limit_pickups` (Default: off)
Limits pickups to a random set that matches your per-run inventory caps (24 perks, 24 weapon mods, 12 ability mods, 12 melee mods, 10 relics), so the pool is not far bigger than what you can carry.
- **off** — Every pickup can be an item and has a check.
- **pool_and_checks** — Only the chosen set is sent as items and has checks.
- **pool_only** — Only the chosen set is sent as items; every pickup keeps its check.
- **checks_only** — Every pickup can be an item, but only the chosen set has checks.

Pickups outside the set can still be found in a run; they just are not sent or received, and where checks are limited they send no check. The set always includes a provider for every pickup that needs another one, so no check becomes unreachable. This replaces the old `limit_pickup_pool` and `limit_pickup_locations` options (pool_and_checks is both on).

#### `greed_item_mode` (Default: skip)
Controls how Greed items are handled. Greed items (certain perks, relics, and melee mods) cannot be dropped once picked up, making them a permanent commitment.
- **auto** — Greed items are added directly to your inventory when received from AP, just like any other item.
- **drop** — Greed items are spawned on the floor in the lobby for you to pick up manually, so you can choose whether to pick them up or not.
- **skip** — Greed items are removed from the item and location pools entirely. You can still find them naturally in-game.

> **Example:** With `greed_item_mode: drop`, when you receive a Greed perk like "Glass Cannon" from AP, it appears on the ground near you instead of being auto-added. You can pick it up if you want it, or leave it.

---

### Inventory Slots

#### `progressive_slots` (Default: off)
You start with fewer inventory slots than the game allows and receive more as items. The in-game crystal purchase for slots is blocked. When off you have all slots from the start.

#### `starting_perk_slots` (Default: 6, Range: 1–24)
#### `starting_weapon_mod_slots` (Default: 6, Range: 1–24)
#### `starting_ability_mod_slots` (Default: 4, Range: 1–12)
#### `starting_melee_mod_slots` (Default: 4, Range: 1–12)
With `progressive_slots` on, how many slots of each kind you start with. The rest are items in the pool ("Progressive Perk Slot" and so on). No effect when `progressive_slots` is off.

---

### Received Items

Perks, mods and relics only last one run, so the mod gives you your received ones again at the start of every run. These options control how many.

#### `starting_item_percentage` (Default: 5, Range: 0–100)
The percentage of your received perks, mods and relics you start each run with, picked at random and rounded up. Items received during a run are applied right away, and crystals always come in full. Set to **100** to start every run with everything.

> **Example:** With 200 received items and `starting_item_percentage: 5`, each run starts with 10 of them.

#### `biome_item_percentage` (Default: 5, Range: 0–100)
When you clear the last island of a biome, this percentage of the received items you don't have yet this run is granted, picked at random and rounded up. Set to **0** to turn it off.

> **Example:** Continuing the example above, clearing the first biome grants 5% of the remaining 190 items, so 10 more.

#### `crystal_cache_percentage` (Default: 75, Range: 0–100)
The share of the spare item slots that become crystals rather than extra copies of perks and mods. Spare slots are what is left after equipment, one of each pickup, Biome Access, slot items, traps and Perk Boosts. Crystals come in three sizes: Cache (50 crystals, 60% of them), Hoard (100, 35%) and Jackpot (500, 5%).

> **Example:** At `75`, three-quarters of the spare slots are crystals and one-quarter are extra perk/mod copies. At `0`, all are perks/mods. At `100`, all are crystals.

#### `guaranteed_items` (Default: empty)
Extra copies of specific items, as a mapping of exact item names to copy counts:

```yaml
  guaranteed_items:
    Time Bolt: 2
    Driller: 3
```

Every perk, mod and relic is already in the pool once, so this is for more copies, or to include an item despite `limit_pickups`. Only perks and mods take extra copies; relics and equipment get one. Greed items are ignored with `greed_item_mode: skip`. Asking for more than the world can hold stops generation with a message.

---

### Traps

Traps are received items that make a run harder for a short time. None of them is permanent, removes your equipment, perks or progress, or can kill you. They are off by default. A trap that arrives in the lobby, or in the first seconds of an island, waits (see `trap_grace_seconds`). A reconnect or a game restart never fires the same trap twice.

#### `trap_percentage` (Default: 0, Range: 0-100)
The percentage of the spare item slots that become traps. Spare slots are what is left after equipment, one of each pickup, Biome Access and slot items. Traps are placed before Perk Boosts, so 100 leaves none for them.

#### `trap_weights` (Default: Crystal Tax 20, Slowdown Trap 20, Weak Shots Trap 20, Bruise Trap 20, Grow Trap 10, Shrink Trap 10, Heavy Gravity Trap 10, Floaty Gravity Trap 10)
How likely each kind of trap is, relative to the others, as a list of trap names with a whole number from 0 to 100. Only the traps you list can appear: leave one out, or give it 0, to remove it. If you list only some, the others are not in the pool. This replaces the eight `trap_weight_*` options.

```yaml
  trap_weights:
    Crystal Tax: 30
    Bruise Trap: 10
```

| Trap | Effect |
|------|--------|
| Crystal Tax | Takes `crystal_tax_percent` (default 25) of your current crystals. |
| Slowdown Trap | Walk speed drops by `slowdown_percent` (default 35) until the island you were on is over. |
| Weak Shots Trap | Your outgoing damage is cut to `weak_shots_percent` (default 50) for `trap_duration` seconds. |
| Bruise Trap | Takes `bruise_percent` (default 30) of your current health. It never takes the last point. |
| Grow Trap / Shrink Trap | A bigger / smaller crab for `trap_duration` seconds. |
| Heavy Gravity Trap / Floaty Gravity Trap | Stronger / weaker gravity for `trap_duration` seconds. |

Other trap options: `trap_duration` (default 30, 5-120 seconds), `trap_grace_seconds` (default 10, 0-60), `crystal_tax_percent` (5-100), `slowdown_percent` (10-80), `weak_shots_percent` (10-90), `bruise_percent` (5-90). Effects end when the timer runs out, when the island is over (Slowdown), or when you die or return to the lobby.

---

### Perk Boost

A **Perk Boost** adds levels to one random perk you are holding in the current run. Greed perks are skipped, and a boost with no perk to raise waits until you hold one.

- `perk_boost_count` (Default: 0, Range: 0-50): how many Perk Boosts are in the pool (they take spare slots, after traps). A Perk Boost raises a random perk you are holding in the current run by `perk_boost_levels` levels, as if you had picked that perk up again.
- `perk_boost_levels` (Default: 3, Range: 1-10): how many levels each Perk Boost adds.

---

### Multiplayer

#### `death_link` (Default: false)
When enabled, dying in Crab Champions sends a death to all connected Death Link players, and deaths from other players kill you. Deaths are only sent and received during runs — not in the lobby.

### Options that were removed or changed

- `cascade_ranked_checks` is gone. A run at a higher rank always counts for the lower ranks now. Worlds made before keep the setting they were made with.
- `limit_pickup_pool` and `limit_pickup_locations` became `limit_pickups`.
- The eight `trap_weight_*` options became one `trap_weights` list.
- `perk_boost_max_per_run` and `perk_boost_level_cap` are gone; a Perk Boost now adds `perk_boost_levels` levels (new, default 3) with no per-run limit.
- `melee_in_pool` and `abilities_in_pool` now default to 3, which is what the old defaults ended up as anyway.
- `starting_melee` and `starting_abilities` are new.
- Archipelago ignores an option name it does not know, with a warning, so an old YAML still generates; the removed options just stop doing anything.

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
- **Biome Access** (4): Tropical Access, Ice Access, Desert Access, Volcano Access (only with `biome_lock`)
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
