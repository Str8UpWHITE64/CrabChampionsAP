"""Check that a slot (re)connect keeps the real lobby/run state.

ItemApply.reset() used to set in_lobby = true on every connect. Mid-run that
made DeathLinks get ignored until the next portal, and on seeds with a partial
starting_item_percentage the replay did a fresh lobby draw instead of
restoring the run's items. Runs ItemApply.lua against stubbed UE4SS globals.

    pip install lupa
    python tools/test_reconnect_lobby.py
"""
import io
import sys
from pathlib import Path

from lupa import LuaRuntime

REPO = Path(__file__).resolve().parent.parent
SRC = io.open(REPO / "CrabChampionsAP/Scripts/AP/ItemApply.lua", encoding="utf-8").read()

SETUP = """
print = function() end
loops = {}
function LoopAsync(ms, fn) loops[#loops + 1] = fn end
function run_async()
    local guard = 0
    while #loops > 0 and guard < 100 do
        local cur = loops
        loops = {}
        for _, fn in ipairs(cur) do fn() end
        guard = guard + 1
    end
end

-- Game state the client reads: lobby pickups present, CrabGS.CurrentIsland.
game = { lobby = true, island = 0 }
local gs = { IsValid = function() return true end }
function FindFirstOf(name)
    if name == "CrabGS" then gs.CurrentIsland = game.island; return gs end
end
function FindAllOf(name)
    if name == "BP_Pickup_Lobby_C" then
        if game.lobby then return { { IsValid = function() return true end } } end
        return {}
    end
end

-- C++ inventory mod: inventory is the list of DA addresses added since clear.
inventory = {}
function AP_AddInventoryItem(addr) inventory[#inventory + 1] = addr; return true end
function AP_ClearInventoryArray() end
function AP_RefreshInventoryUI() end
function AP_SanitizeInventory() return 0 end

package.preload["AP/ItemData"] = function()
    local D = { CATEGORY = { FILLER = 10, EVENT = 1, SLOT = 11, PERK = 2, RELIC = 3,
                             WEAPON = 4, ABILITY = 5, MELEE = 6, WEAPON_MOD = 7,
                             MELEE_MOD = 8, ABILITY_MOD = 9 } }
    function D.is_resolved() return true end
    function D.resolve_game_objects() end
    function D.from_ap_id(id)
        local da = { GetAddress = function() return id end }
        return { cat = 2, name = "Perk" .. id, full_name = "Perk" .. id, da = da }
    end
    return D
end
package.preload["AP/LocationData"] = function()
    return { starting_item_percentage = 50, biome_item_percentage = 0 }
end
"""


def send_items(IA, n):
    """Server side: send items 0..n-1 in order."""
    for i in range(n):
        IA.apply_item(1000 + i)


def fresh():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(SETUP)
    return lua, lua.execute(SRC)


def inv(lua):
    return sorted(int(v) for v in lua.globals().inventory.values())


problems = []

# --- Start a run from the lobby with a partial draw, then drop mid-run. ---
lua, IA = fresh()
g = lua.globals()
IA.reset()
if not IA.in_lobby:
    problems.append("lobby connect: in_lobby should be true")
send_items(IA, 20)
g.run_async()
run_items = inv(lua)
if not 0 < len(run_items) < 20:
    problems.append(f"lobby draw should pick a share of 20, got {len(run_items)}")

# Portal out of the lobby: PickupWatch clears in_lobby and the game shows island 3.
IA.in_lobby = False
g.game.lobby = False
g.game.island = 3

# Reconnect mid-run: the connect handler resets, the server re-sends 0..19 and
# two items found since.
g.inventory = lua.table()
IA.reset()
if IA.in_lobby:
    problems.append("mid-run reconnect: in_lobby was set to true")
send_items(IA, 22)
g.run_async()
want = sorted(run_items + [1020, 1021])
if inv(lua) != want:
    problems.append(f"mid-run reconnect restored {inv(lua)}, expected the run's {len(run_items)} items plus the 2 new ones")
if IA.in_lobby:
    problems.append("in_lobby changed during the replay")

# A second drop before the replay finished keeps the same snapshot.
g.inventory = lua.table()
IA.reset()
send_items(IA, 5)
IA.reset()
send_items(IA, 22)
g.run_async()
if inv(lua) != want:
    problems.append("double reconnect lost the run's items")

# --- Reconnect in the lobby behaves as before: in_lobby, one fresh draw. ---
lua, IA = fresh()
g = lua.globals()
IA.reset()
send_items(IA, 20)
g.run_async()
g.inventory = lua.table()
IA.reset()
if not IA.in_lobby:
    problems.append("lobby reconnect: in_lobby should stay true")
send_items(IA, 20)
if len(inv(lua)) != 0:
    problems.append("lobby reconnect granted items before the settle delay")
g.run_async()
n = len(inv(lua))
if n != 10:  # ceil(20 * 50%)
    problems.append(f"lobby reconnect draw gave {n} items, expected 10")

# Island 0 with no lobby pickups (unclear state) counts as the lobby.
lua, IA = fresh()
lua.globals().game.lobby = False
IA.reset()
if not IA.in_lobby:
    problems.append("unclear state should count as lobby")

if problems:
    print("\n".join(problems))
    sys.exit(1)
print("Reconnect lobby state OK")
