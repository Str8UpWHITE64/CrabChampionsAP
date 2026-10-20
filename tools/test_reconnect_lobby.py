"""Check what a slot (re)connect does to the inventory and the run state.

A reconnect to the same seed and slot no longer wipes the inventory. The
server re-sends every item, ItemApply keeps a ledger of what it already
delivered, and only the difference is applied. This also checks that the real
lobby/run state survives (a mid-run drop restores the run's items instead of
rolling a new draw), that crystals are neither zeroed nor doubled, that a
full inventory leaves items waiting rather than losing them, and that the
start draw lowers received items left over from before. Runs ItemApply.lua
against stubbed UE4SS globals and a fake inventory.

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
    while #loops > 0 and guard < 200 do
        local cur = loops
        loops = {}
        for _, fn in ipairs(cur) do fn() end
        guard = guard + 1
    end
end

-- Game state the client reads: lobby pickups present, CrabGS.CurrentIsland.
game = { lobby = true, island = 0 }
local gs = { IsValid = function() return true end }
ps = { Crystals = 0, IsValid = function() return true end }
function FindFirstOf(name)
    if name == "CrabGS" then gs.CurrentIsland = game.island; return gs end
end
function FindAllOf(name)
    if name == "BP_Pickup_Lobby_C" then
        if game.lobby then return { { IsValid = function() return true end } } end
        return {}
    end
    if name == "CrabPS" then return { ps } end
end

-- Fake C++ inventory mod: perk levels by DA address, with a slot limit.
inventory = {}
slots = 24
function AP_AddInventoryItem(addr, arr, field, count)
    if inventory[addr] then inventory[addr] = inventory[addr] + count; return true end
    local n = 0
    for _ in pairs(inventory) do n = n + 1 end
    if n >= slots then return false end
    inventory[addr] = count
    return true
end
function AP_RemoveInventoryItem(addr, arr, field, amount)
    if not inventory[addr] then return false end
    inventory[addr] = inventory[addr] - amount
    if inventory[addr] <= 0 then inventory[addr] = nil end
    return true
end
function AP_ClearInventoryArray() inventory = {} end
function AP_RefreshInventoryUI() end
function AP_SanitizeInventory() return 0 end

package.preload["AP/InventorySanitize"] = function()
    return { build_inventory_snapshot = function()
        local bucket = {}
        for addr, level in pairs(inventory) do bucket["Perk" .. addr] = { level = level } end
        return { perks = bucket }
    end }
end
package.preload["AP/ItemData"] = function()
    local D = { CATEGORY = { FILLER = 10, EVENT = 1, SLOT = 11, PERK = 2, RELIC = 3,
                             WEAPON = 4, ABILITY = 5, MELEE = 6, WEAPON_MOD = 7,
                             MELEE_MOD = 8, ABILITY_MOD = 9 } }
    function D.is_resolved() return true end
    function D.resolve_game_objects() end
    function D.from_ap_id(id)
        if id >= 5000 then return { cat = 10, name = "Crystal Cache" } end
        local da = { GetAddress = function() return id end }
        return { cat = 2, name = "Perk" .. id, full_name = "Perk" .. id, da = da }
    end
    return D
end
package.preload["AP/LocationData"] = function()
    return { starting_item_percentage = pct or 50, biome_item_percentage = 0 }
end
"""


def send_items(IA, n, start=0):
    """Server side: send items start..n-1 in order."""
    for i in range(start, n):
        IA.apply_item(1000 + i)


def fresh(pct=50):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(f"pct = {pct}")
    lua.execute(SETUP)
    return lua, lua.execute(SRC)


def inv(lua):
    """Sorted list of (address, level) in the fake inventory."""
    g = lua.globals()
    return sorted((int(k), int(v)) for k, v in g.inventory.items())


def levels(lua):
    return sum(v for _, v in inv(lua))


problems = []

# --- Lobby draw, then a mid-run drop: the inventory is kept, nothing doubles. ---
lua, IA = fresh()
g = lua.globals()
IA.reset()
if not IA.in_lobby:
    problems.append("lobby connect: in_lobby should be true")
send_items(IA, 20)
g.run_async()
run_inv = inv(lua)
if not 0 < len(run_inv) < 20:
    problems.append(f"lobby draw should pick a share of 20, got {len(run_inv)}")

# Portal out of the lobby: PickupWatch clears in_lobby and the game shows island 3.
IA.in_lobby = False
g.game.lobby = False
g.game.island = 3

# Reconnect mid-run (soft): the inventory is NOT cleared, the server re-sends
# 0..19 and two items found since.
IA.reset({"soft": True})
if IA.in_lobby:
    problems.append("mid-run reconnect: in_lobby was set to true")
if inv(lua) != run_inv:
    problems.append("mid-run reconnect changed the inventory before the replay")
send_items(IA, 22)
g.run_async()
want = sorted(run_inv + [(1020, 1), (1021, 1)])
if inv(lua) != want:
    problems.append(f"mid-run reconnect left {inv(lua)}, expected the run's items plus the 2 new ones")
if IA.in_lobby:
    problems.append("in_lobby changed during the replay")

# A second drop before the replay finished keeps the same snapshot.
IA.reset({"soft": True})
send_items(IA, 5)
IA.reset({"soft": True})
send_items(IA, 22)
g.run_async()
if inv(lua) != want:
    problems.append("double reconnect changed the run's items")

# A different seed or slot is a hard reset: the inventory starts empty.
IA.reset()
if inv(lua):
    problems.append("hard reset should empty the inventory")

# --- Reconnect in the lobby: kept, one new draw, no doubling. ---
lua, IA = fresh()
g = lua.globals()
IA.reset()
send_items(IA, 20)
g.run_async()
before = inv(lua)
IA.reset({"soft": True})
if not IA.in_lobby:
    problems.append("lobby reconnect: in_lobby should stay true")
if inv(lua) != before:
    problems.append("lobby reconnect wiped the inventory")
send_items(IA, 20)
g.run_async()
n = len(inv(lua))
if n != 10 or levels(lua) != 10:  # ceil(20 * 50%), one level each, nothing from the old draw left over
    problems.append(f"lobby reconnect holds {n} items / {levels(lua)} levels, expected exactly 10")

# --- Re-grant at lobby entry when the game did not clear: no doubling. ---
IA.reapply_run_items()
g.run_async()
if levels(lua) != 10:
    problems.append(f"lobby re-grant with items already held gave {levels(lua)} levels, expected 10")

# --- Everything granted (100%): a soft reconnect adds nothing twice. ---
lua, IA = fresh(100)
g = lua.globals()
IA.reset()
send_items(IA, 8)
send_items(IA, 3)  # duplicates of items 0..2 as a second copy
g.run_async()
full = inv(lua)
IA.reset({"soft": True})
send_items(IA, 8)
send_items(IA, 3)
g.run_async()
if inv(lua) != full:
    problems.append(f"100% reconnect changed the inventory: {inv(lua)} vs {full}")

# --- An item the server never sent (a natural find) survives a reconnect and the run-start sync. ---
lua, IA = fresh(100)
g = lua.globals()
IA.reset()
send_items(IA, 4)
g.run_async()
g.inventory[9999] = 2  # found in the run, not received
IA.in_lobby = False
g.game.lobby = False
g.game.island = 2
IA.reset({"soft": True})
send_items(IA, 4)
g.run_async()
if dict(inv(lua)).get(9999) != 2:
    problems.append("a natural find was lost across a soft reconnect")
g.game.lobby = True
g.game.island = 0
IA.reapply_run_items()
g.run_async()
if dict(inv(lua)).get(9999) != 2:
    problems.append("the run-start sync touched a natural find")

# --- Crystals: a reconnect neither zeroes them nor grants them twice. ---
lua, IA = fresh(100)
g = lua.globals()
IA.reset()
IA.apply_item(5000)
IA.apply_item(5000)
g.run_async()
if g.ps.Crystals != 100:
    problems.append(f"crystals after two caches: {g.ps.Crystals}, expected 100")
g.ps.Crystals = 777  # earned in the run
IA.reset({"soft": True})
IA.apply_item(5000)
IA.apply_item(5000)
g.run_async()
if g.ps.Crystals != 777:
    problems.append(f"crystals after a reconnect: {g.ps.Crystals}, expected 777 (kept, not doubled)")
IA.apply_item(5000)  # a new one arriving later still counts
g.run_async()
if g.ps.Crystals != 827:
    problems.append(f"crystals after one more cache: {g.ps.Crystals}, expected 827")

# --- Full inventory: items wait instead of being lost, and apply once freed. ---
lua, IA = fresh(100)
g = lua.globals()
g.slots = 5
IA.reset()
send_items(IA, 7)
g.run_async()
if len(inv(lua)) != 5:
    problems.append(f"5 slots should hold 5 perks, holds {len(inv(lua))}")
if IA.overflow_count() != 2:
    problems.append(f"2 perks should be waiting, overflow_count={IA.overflow_count()}")
IA.apply_item(1000)  # a copy of one already held stacks without a free slot
g.run_async()
held = dict(inv(lua))
if held.get(1000) != 2:
    problems.append("a copy of a held perk should stack in a full inventory")
IA.retry_overflow()
g.run_async()
if len(inv(lua)) != 5 or IA.overflow_count() != 2:
    problems.append("retrying with no free slot must change nothing")
g.AP_RemoveInventoryItem(1001, "Perks", "PerkDA", 1)  # the player drops one
IA.retry_overflow()
g.run_async()
if len(inv(lua)) != 5 or IA.overflow_count() != 1:
    problems.append(f"a freed slot should take one waiting perk, overflow_count={IA.overflow_count()}")
# Two flushes requested at once must not both add the same missing levels.
IA.retry_overflow()
IA.retry_overflow()
g.run_async()
if levels(lua) > 5 + 1:
    problems.append(f"concurrent retries over-added: {levels(lua)} levels")

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
