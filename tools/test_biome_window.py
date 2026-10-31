"""Check the Archipelago window's biome lines: biomes unlocked and biomes cleared per weapon, melee and ability.

Runs APOverlay.lua against stubbed UE4SS and UMG globals with the real LocationData.lua and BiomeLock.lua, and
reads the text back through APOverlay.get_shown().

    pip install lupa
    python tools/test_biome_window.py
"""
import sys
from pathlib import Path

from lupa import LuaRuntime

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = (REPO / "CrabChampionsAP/Scripts").as_posix()

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(f"""
package.path = "{SCRIPTS}/?.lua;" .. package.path
print = function() end
loops = {{}}
function LoopAsync(ms, fn) loops[#loops + 1] = fn end
local proxy
proxy = setmetatable({{}}, {{
    __index = function() return proxy end,
    __call = function() return proxy end,
    __newindex = function() end,
}})
StaticFindObject = function() return proxy end
StaticConstructObject = function() return proxy end
FindFirstOf = function(c) if c == "GameInstance" then return proxy end return nil end
FindAllOf = function() return nil end
FName = function(s) return s end
FText = function(s) return s end
ExecuteInGameThread = function(fn) fn() end
""")

problems = []


def check(label, cond, detail=""):
    if not cond:
        problems.append(f"{label} {detail}".strip())


lua.execute("require('AP/GameThread').loaded(); for _ = 1, 130 do for _, f in ipairs(loops) do f() end end")
LD = lua.execute("return (require('AP/LocationData'))")
BL = lua.execute("return (require('AP/BiomeLock'))")
O = lua.execute("return (require('AP/APOverlay'))")
O.create({"server": "127.0.0.1:1", "slot": "Crab", "password": ""})

lua.execute("""
checked = {}
client = { is_location_checked = function(self, id) return checked[id] == true end }
item_apply = { unlocked = {} }
item_data = { CATEGORY = { WEAPON = 1, MELEE = 2, ABILITY = 3 }, get_da = function() return nil end }
function refresh() require('AP/APOverlay').update_equipment_progress(
    require('AP/LocationData'), item_apply, item_data, client) end
function mark_biome(biome, name, rank)
    local LD = require('AP/LocationData')
    local idx = LD.check_index(biome * 7, biome)
    checked[LD.weapon_run_location_id_by_name(idx, name, LD.tier_rank(rank))] = true
end
""")
g = lua.globals()


def configure(options, pool=("Auto Rifle", "Seagle")):
    lua.execute("require('AP/LocationData').configure({ options = %s })" % options)
    lua.execute("local LD = require('AP/LocationData'); LD.pool_weapons = {%s}" %
                ", ".join(f'["{n}"] = true' for n in pool))
    lua.execute("checked = {}")


# Biome layout, Bronze checks off: the plain last-island check counts.
configure("{ check_layout = 1, bronze_checks = false, required_rank = 0, weapons_for_completion = 2,"
          " biome_lock = true, starting_biome = 2 }")
BL.configure(lua.eval("{ biome_lock = true, starting_biome = 2 }"), False)
g.refresh()
s = O.get_shown()
check("start biome unlocked", s["biome_access_text"] == "Biomes unlocked (1/4): Ice", s["biome_access_text"])
check("nothing cleared", "Auto Rifle - 0/4 biomes" in s["equip_weapons_text"], s["equip_weapons_text"])

lua.execute("require('AP/BiomeLock').on_item({ name = 'Volcano Access' })")
g.refresh()
check("access item shows", O.get_shown()["biome_access_text"] == "Biomes unlocked (2/4): Ice, Volcano",
      O.get_shown()["biome_access_text"])

g.mark_biome(1, "Auto Rifle", 0)
g.mark_biome(4, "Auto Rifle", 0)
g.mark_biome(2, "Seagle", 0)
g.refresh()
t = O.get_shown()["equip_weapons_text"]
check("two biomes", "Auto Rifle - 2/4 biomes (Tropical, Volcano)" in t, t)
check("one biome", "Seagle - 1/4 biomes (Ice)" in t, t)

# A rank-1 check does not count when the goal asks for Bronze, and an island-6 (shop) check is not a biome clear.
configure("{ check_layout = 1, bronze_checks = false, required_rank = 0 }")
g.mark_biome(3, "Auto Rifle", 1)
g.refresh()
check("other rank ignored", "Auto Rifle - 0/4 biomes" in O.get_shown()["equip_weapons_text"],
      O.get_shown()["equip_weapons_text"])

# Required rank Gold with Bronze checks: the Gold check for the biome's last island counts.
configure("{ check_layout = 1, bronze_checks = true, required_rank = 2 }")
g.mark_biome(3, "Auto Rifle", 2)
g.mark_biome(1, "Auto Rifle", 0)
g.refresh()
check("required rank counts", "Auto Rifle - 1/4 biomes (Desert)" in O.get_shown()["equip_weapons_text"],
      O.get_shown()["equip_weapons_text"])

# Lock off: no unlock line.
BL.configure(lua.eval("{ biome_lock = false }"), False)
g.refresh()
check("no lock, no line", O.get_shown()["biome_access_text"] == "", O.get_shown()["biome_access_text"])

# Island layout: no biome progress on the lines.
configure("{ check_layout = 0 }")
g.refresh()
check("island layout plain", "biomes" not in O.get_shown()["equip_weapons_text"],
      O.get_shown()["equip_weapons_text"])

# Disconnect wipes the unlock line.
BL.configure(lua.eval("{ biome_lock = true, starting_biome = 1 }"), False)
g.refresh()
check("shows again", O.get_shown()["biome_access_text"].startswith("Biomes unlocked"))
O.clear_progress()
check("cleared", O.get_shown()["biome_access_text"] == "")

if problems:
    print("FAILED:")
    for p in problems:
        print(" -", p)
    sys.exit(1)
print("OK")
