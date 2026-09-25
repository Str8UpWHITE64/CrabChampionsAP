"""Check that the Lua client's item tables match the apworld's.

The client derives item IDs (ItemData.lua) and location IDs (LocationData.lua)
from its own copies of the name lists in Items.py, by list position.  If the
copies drift, players get the wrong items and send the wrong checks with no
error anywhere.  Run this after touching any item list.

    pip install lupa
    python tools/check_sync.py
"""
import importlib.util
import io
import sys
import types
from pathlib import Path

from lupa import LuaRuntime

REPO = Path(__file__).resolve().parent.parent

# Items.py only needs BaseClasses.Item, so load it standalone rather than
# through the world package, which needs the full Archipelago runtime.
base = types.ModuleType("BaseClasses")
base.Item = type("Item", (), {})
sys.modules["BaseClasses"] = base
spec = importlib.util.spec_from_file_location("crab_items", REPO / "apworld/crabchampions/Items.py")
items = importlib.util.module_from_spec(spec)
spec.loader.exec_module(items)

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("print = function() end")


def load_lua(rel_path):
    return lua.execute(io.open(REPO / rel_path, encoding="utf-8").read())


itemdata = load_lua("CrabChampionsAP/Scripts/AP/ItemData.lua")
locdata = load_lua("CrabChampionsAP/Scripts/AP/LocationData.lua")


def strip_suffix(name):
    # Items.py disambiguates "Spike Strike (Ability)"; the client stores the
    # bare name and strips the suffix when matching, so compare that form.
    return name.split(" (")[0]


problems = []

# Item IDs, compared by code since two client entries share a display name.
py_codes = {d.cc_code: strip_suffix(d.name) for d in items.item_dictionary.values()
            if d.cc_code is not None}
lua_codes = {int(code): entry["name"] for code, entry in itemdata.BY_CC_CODE.items()}
for code in sorted(set(py_codes) | set(lua_codes)):
    if py_codes.get(code) != lua_codes.get(code):
        problems.append(f"item cc {code}: Items.py={py_codes.get(code)!r} "
                        f"ItemData.lua={lua_codes.get(code)!r}")

# Location name lists: list order is the location ID.
for lua_name, py_list in (
    ("perk_names", items.perk_item_names),
    ("relic_names", items.relic_item_names),
    ("weapon_mod_names", items.weapon_mod_item_names),
    ("melee_mod_names", items.melee_mod_item_names),
    ("ability_mod_names", items.ability_mod_item_names),
    ("weapon_names", items.weapon_item_names),
    ("melee_names", items.melee_item_names),
    ("ability_names", items.ability_item_names),
):
    lua_t = locdata[lua_name]
    lua_list = [lua_t[i] for i in range(1, len(lua_t) + 1)]
    py = [strip_suffix(n) for n in py_list]
    if lua_list != py:
        first = next((i for i, (a, b) in enumerate(zip(py, lua_list)) if a != b),
                     min(len(py), len(lua_list)))
        problems.append(f"LocationData.{lua_name} differs from index {first} "
                        f"(Items.py has {len(py)}, LocationData.lua has {len(lua_list)})")

# Greed lists drive what the client pre-allows in skip mode.
lua_greed = set(locdata.GREED_ITEM_NAMES.keys())
py_greed = set(items.GREED_ITEM_NAMES)
if lua_greed != py_greed:
    problems.append(f"greed lists differ: only in Items.py {sorted(py_greed - lua_greed)}, "
                    f"only in LocationData.lua {sorted(lua_greed - py_greed)}")

# The client refuses seeds whose layout differs from its own, so both sides
# must agree on the current one.
loc_src = open(REPO / "apworld/crabchampions/Locations.py", encoding="utf-8").read()
py_layout = int(loc_src.split("ID_LAYOUT = ", 1)[1].split()[0])
if py_layout != int(locdata.ID_LAYOUT):
    problems.append(f"ID_LAYOUT differs: Locations.py={py_layout} LocationData.lua={locdata.ID_LAYOUT}")

# Tag rules must name real items.
for req, providers in items.PICKUP_TAG_REQUIREMENTS.items():
    for name in (req, *providers):
        if name not in items.item_dictionary:
            problems.append(f"PICKUP_TAG_REQUIREMENTS names unknown item {name!r}")

if problems:
    print("OUT OF SYNC:")
    print("\n".join(f"  {p}" for p in problems))
    sys.exit(1)
print(f"In sync: {len(py_codes)} items, all location lists and greed lists match.")
