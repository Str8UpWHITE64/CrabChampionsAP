"""Check that a Perk Boost raises a perk the player really holds.

The boost picks from the perks in the game's inventory, not only the ones
ItemApply delivered itself: perks found in the run and kept, received perks the
start draw left out, and everything after a reconnect. Greed perks are skipped.
Runs ItemApply.lua against stubbed UE4SS globals and a fake inventory.

    pip install lupa
    python tools/test_perk_boost.py
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
names = {}
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
        for addr, level in pairs(inventory) do bucket[names[addr] or ("Perk" .. addr)] = { level = level, da = { GetAddress = function() return addr end } } end
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
        local fn = "Perk" .. id
        names[id] = fn
        return { cat = 2, name = fn, full_name = fn, da = da }
    end
    return D
end
package.preload["AP/LocationData"] = function()
    return { starting_item_percentage = pct or 50, biome_item_percentage = 0 }
end
"""



def fresh(pct=100):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("package.path = [[%s/?.lua;]] .. package.path" % (REPO / "CrabChampionsAP/Scripts").as_posix())
    lua.execute(f"pct = {pct}")
    lua.execute(SETUP)
    return lua, lua.execute(SRC)


def inv(lua):
    return {int(k): int(v) for k, v in lua.globals().inventory.items()}


problems = []

for pct in (100, 50):
    lua, IA = fresh(pct)
    g = lua.globals()
    IA.reset()
    for i in range(12):
        IA.apply_item(1000 + i)
    g.run_async()
    IA.in_lobby = False
    g.game.lobby = False
    g.game.island = 2
    # Perks found in the run and kept (never sent by the server), plus a greed one.
    g.AP_AddInventoryItem(7001, "Perks", "PerkDA", 2)
    g.AP_AddInventoryItem(7002, "Perks", "PerkDA", 1)
    g.names[7003] = "/Game/Greed/DA_Perk_Greedy"
    g.AP_AddInventoryItem(7003, "Perks", "PerkDA", 1)
    before = inv(lua)
    seen = set()
    for _ in range(150):
        g.inventory = lua.table_from(before)
        res = IA.boost_random_perk(3)
        g.run_async()
        if res is None:
            problems.append(f"pct={pct}: boost found nothing to raise")
            break
        after = inv(lua)
        raised = [k for k in after if after[k] != before.get(k, 0)]
        if len(raised) != 1 or after[raised[0]] - before.get(raised[0], 0) != 3:
            problems.append(f"pct={pct}: boost should add 3 levels to one perk, changed {raised} {after} vs {before}")
            break
        if raised[0] == 7003:
            problems.append(f"pct={pct}: boosted a greed perk")
            break
        seen.add(raised[0])
        IA.reset({"soft": True})
    if not {7001, 7002} <= seen:
        problems.append(f"pct={pct}: perks found in the run were never boosted (saw {sorted(seen)})")
    if not any(a >= 1000 for a in seen):
        problems.append(f"pct={pct}: server perks were never boosted (saw {sorted(seen)})")

# Nothing held: the boost waits.
lua, IA = fresh(100)
IA.reset()
IA.in_lobby = False
if IA.boost_random_perk(3) is not None:
    problems.append("an empty inventory should leave the boost waiting")

if problems:
    print("FAIL")
    for p in problems:
        print(" -", p)
    sys.exit(1)
print("ok: Perk Boost raises perks read from the inventory")
