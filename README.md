# Crab Champions Archipelago

An [Archipelago](https://archipelago.gg/) multiworld randomizer integration for [Crab Champions](https://store.steampowered.com/app/774801/Crab_Champions/).

## What Is This?

This mod lets you play Crab Champions as part of an Archipelago multiworld session. Your equipment (weapons, melee weapons, abilities) is randomized into a shared item pool across multiple games and players. Completing islands and collecting items sends checks to other players, and you receive your unlocks from them in return.

## Features

- **Equipment Randomization** — Weapons, melee weapons, and abilities are locked behind the multiworld item pool. You unlock them as other players find your items.
- **Location Checks** — Completing islands, finishing runs at specific ranks, and using specific equipment all count as checks that send items to other players.
- **Ranked Difficulty Tiers** — Supports all 8 difficulty ranks from Bronze through Prismatic, with configurable check ranges.
- **Cascade Mode** — Completing an island at a higher rank can automatically count for all lower ranks.
- ~~**Death Link** — Optional synchronized death across all connected players.~~ Currently not implemented.
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

1. Download [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v3.0.1/UE4SS_v3.0.1.zip) and unzip it.
2. Navigate to Steam Library > Right-click Crab Champions > Properties > Local Files > Browse, then go to ``CrabChampions\Binaries\Win64`` and copy the contents of the UE4SS zip folder into the game's Win64 directory.
3. Edit `UE4SS-settings.ini` and set `ConsoleEnabled = 1` to enable the game's console, which will show you Archipelago connection status and checks received.
4. Download the CrabChampionsAP.zip from the latest release and unzip it. Copy the `CrabChampionsAP` folder into the `Mods` directory from the previous step.
5. Edit `Scripts/ap_config.json` with your Archipelago server address, slot name, and password:
   ```json
   {
     "address": "localhost:38281",
     "slot": "YourSlotName",
     "password": ""
   }
   ```
6. Under the `Mods` directory, open `mods.txt` and add `CrabChampionsAP` to the list of mods to load like this:
   ```
   CrabChampionsAP : 1
   ```
7. ~~Download the lau-apclient 7z from [here](https://github.com/black-sliver/lua-apclientpp/releases/download/v0.6.4/lua54.7z), extract it, and copy the lua-apclientpp.dll file from the `lua54\lua54-clang64-static` folder and place it in the AP folder under `CrabChampionsAP\Scripts\AP`.~~ No longer needed, included with the zip.

8. Launch the game!  You will automatically connect to the server after a few seconds at the lobby.  You will see output in the console window that opens along with the game.

## Configuration Options

These options are set in your Archipelago YAML configuration file:

| Option                     | Default  | Description                                                                       |
|----------------------------|----------|-----------------------------------------------------------------------------------|
| `required_rank`            | Bronze   | Minimum difficulty rank required for completion                                   |
| `max_rank`                 | Sapphire | Highest rank that generates location checks                                       |
| `weapons_for_completion`   | 5        | Number of different weapons needed to win                                         |
| `run_length`               | short    | Number of islands to complete to consider a "run" complete. Short = 28, long = 56 |
| `weapons_in_pool`          | 5        | Number of weapons randomized into the pool                                        |
| `melee_for_completion`     | 3        | Number of melee weapons needed to win                                             |
| `melee_in_pool`            | 0        | Number of melee weapons in the pool                                               |
| `abilities_for_completion` | 3        | Number of abilities needed to win                                                 |
| `abilities_in_pool`        | 0        | Number of abilities in the pool                                                   |
| `extra_ranked_checks`      | false    | Generate checks for all rank tiers, not just required                             |
| `cascade_ranked_checks`    | true     | Completing at rank R counts for all lower ranks                                   |
| `equipment_check_mode`     | Regular  | How non-pool equipment run locations work                                         |
| `crystal_cache_percentage` | 75       | Percentage of filler that is crystal rewards vs. stackable items                  |
| `death_link`               | false    | ~~Enable synchronized deaths across players~~                                     |

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
- The game may occasionally crash when receiving multiple perks or mods at once.  This is a known issue with the way the mod spawns items and is being worked on.
- You cannot continue a previous run in game.  If you leave to the lobby or crash, you need to start a new run.  This is due to how island tracking is done, and I will be working on finding other solutions.
- Due to the crashing, the default item pool is currently set to be 75% crystals.  This is to reduce the number of items received at once and mitigate the crashes. Lower this at your own risk.
- Deathlink currently doesn't do anything.  It doesn't send or receive deaths.  

## Credits

- **Author**: Str8UpWHITE64
- Built with [Archipelago](https://archipelago.gg/) and [UE4SS](https://docs.ue4ss.com/)
