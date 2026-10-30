"""Offline tests for the biome check layout (check_layout = biome).

Always run:
  * location IDs: the biome layout is appended after the old IDs, every ID is unique, and the old island-layout
    IDs are exactly what they were before the layout existed.
  * the client (LocationData.lua) maps (island, biome) to the same IDs the apworld gives each named check.
  * seeds without check_layout keep using island numbers.

Run only when CRAB_AP_DIR names an Archipelago source copy that has this apworld in its worlds folder
(Python 3.12 or newer with its requirements):
  * generation: location counts and rules for 28 and 56 islands, both layouts, rank and minimize options,
    biome lock on and off, and a full generation of a few option sets.

    pip install lupa
    python tools/test_biome_checks.py
"""
import importlib.util
import io
import itertools
import os
import sys
import types
from pathlib import Path

from lupa import LuaRuntime

REPO = Path(__file__).resolve().parent.parent
APWORLD = REPO / "apworld" / "crabchampions"

problems = []


def check(cond, msg):
    if not cond:
        problems.append(msg)


# --------------------------------------------------------------------------
# Locations.py, loaded standalone with BaseClasses stubbed
# --------------------------------------------------------------------------
def load_locations(src_dir, tag):
    base = types.ModuleType("BaseClasses")
    base.Item = type("Item", (), {})
    base.Location = type("Location", (), {"__init__": lambda self, *a, **k: None})
    base.Region = type("Region", (), {})
    sys.modules["BaseClasses"] = base
    pkg = types.ModuleType(tag)
    pkg.__path__ = [str(src_dir)]
    sys.modules[tag] = pkg
    for mod in ("Items", "Locations"):
        spec = importlib.util.spec_from_file_location(f"{tag}.{mod}", Path(src_dir) / f"{mod}.py")
        m = importlib.util.module_from_spec(spec)
        sys.modules[f"{tag}.{mod}"] = m
        spec.loader.exec_module(m)
    return sys.modules[f"{tag}.Locations"], sys.modules[f"{tag}.Items"]


locs, items = load_locations(APWORLD, "crab_new")
new_ids = locs.CrabChampsLocation.get_name_to_id()

check(len(set(new_ids.values())) == len(new_ids), "location IDs are not unique")

# The island layout's IDs, written out from the original formulas.
B, T = 1890000, 12000
SHOPS = {6, 13, 20, 27, 34, 41, 48, 55}
RANKS = ["Bronze", "Silver", "Gold", "Sapphire", "Emerald", "Ruby", "Diamond", "Prismatic"]
old = {}
for i in range(1, 57):
    p = ("Reach Shop on Island" if i in SHOPS else "Complete Island") + f" {i}"
    old[p] = B + i
    for r, rn in enumerate(RANKS):
        old[f"{p} on {rn}"] = B + 57 + r * 56 + (i - 1)
for r, rn in enumerate(RANKS):
    old[f"Complete Run on {rn}"] = B + T * 3 + r
for region, names in ((4, items.weapon_item_names), (5, items.melee_item_names), (6, items.ability_item_names)):
    n = len(names)
    for i in range(1, 57):
        p = ("Reach Shop on Island" if i in SHOPS else "Complete Island") + f" {i}"
        for ei, en in enumerate(names):
            old[f"{p} with {en}"] = B + T * region + (i - 1) * n + ei
            for r, rn in enumerate(RANKS):
                old[f"{p} with {en} on {rn}"] = B + T * region + n * 56 + r * n * 56 + (i - 1) * n + ei
for name, lid in old.items():
    if new_ids.get(name) != lid:
        problems.append(f"island-layout location {name!r}: expected {lid}, got {new_ids.get(name)}")
        break
pickups = [n for n in new_ids if n.split(":")[0] in ("Perk", "Relic", "Weapon Mod", "Melee Mod", "Ability Mod")]
check(all(new_ids[n] < B + T * 10 for n in pickups), "pickup IDs moved")
added = {n: i for n, i in new_ids.items() if n not in old and n not in pickups}
check(len(added) > 0 and min(added.values()) >= B + T * 10, "biome IDs are not appended after the old regions")
check(max(added.values()) < B + T * 17, "biome IDs overflow their regions")

# --------------------------------------------------------------------------
# Names
# --------------------------------------------------------------------------
BIOMES = ["Tropical", "Ice", "Desert", "Volcano"]


def expected_name(biome, slot, loop):
    """Written out independently of Locations.biome_check_prefix."""
    tail = " (Loop 2)" if loop else ""
    if slot == 6:
        return f"Reach {BIOMES[biome - 1]} Shop{tail}"
    return f"Complete {BIOMES[biome - 1]} Island {slot}{tail}"


for loop, biome, slot in itertools.product((0, 1), range(1, 5), range(1, 8)):
    k = loop * 28 + (biome - 1) * 7 + (slot - 1)
    check(locs.biome_check_prefix(k) == expected_name(biome, slot, loop), f"name for index {k}")
    check(locs.biome_index_from_name(expected_name(biome, slot, loop) + " on Gold") == k, f"parse index {k}")
    check(locs.biome_index_from_name(expected_name(biome, slot, loop) + " with Auto Rifle on Gold") == k, f"parse eq {k}")
    check(locs.biome_index_to_biome(k) == biome, f"biome of index {k}")
check(locs.biome_index_from_name("Complete Island 3") == -1, "island name parsed as a biome name")
check(locs.biome_index_from_name("Reach Shop on Island 6 on Gold") == -1, "island shop parsed as a biome name")
check("Complete Tropical Island 3" in new_ids and "Reach Ice Shop" in new_ids, "documented names missing")
check("Complete Tropical Island 3 (Loop 2)" in new_ids, "loop 2 name missing")
check("Complete Desert Island 4 with Auto Rifle on Gold" in new_ids, "equipment name missing")

# --------------------------------------------------------------------------
# Client mapping (LocationData.lua)
# --------------------------------------------------------------------------
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("print = function() end")
LD = lua.execute(io.open(REPO / "CrabChampionsAP/Scripts/AP/LocationData.lua", encoding="utf-8").read())
check(int(LD.ID_LAYOUT) == locs.ID_LAYOUT, "ID_LAYOUT differs")


def configure(layout=None, run_length=28):
    opts = lua.table_from({"run_length": run_length})
    if layout is not None:
        opts["check_layout"] = layout
    LD.configure(lua.table_from({"options": opts}))


def equip_names(lst):
    return [n.split(" (")[0] for n in lst]


weapons = equip_names(items.weapon_item_names)
melees = equip_names(items.melee_item_names)
abilities = equip_names(items.ability_item_names)

configure(1, 56)
for k in range(1, 57):
    check(LD.check_name(k) == locs.biome_check_prefix(k - 1), f"log name for index {k}: {LD.check_name(k)}")

# Seeds without check_layout, or with the island layout: island numbers, old IDs.
for layout in (None, 0):
    configure(layout)
    check(not LD.biome_layout, "island layout read as biome")
    for n in (1, 6, 13, 28):
        pfx = "Reach Shop on Island" if n in locs.SHOP_ISLANDS else "Complete Island"
        check(LD.check_index(n, 2) == n, "island layout check_index")
        check(LD.island_location_id(n) == new_ids[f"{pfx} {n}"], f"island id {n}")
        check(LD.island_location_id(n, 2) == new_ids[f"{pfx} {n} on Gold"], f"ranked island id {n}")
        check(LD.weapon_run_location_id_by_name(n, "Auto Rifle", 2) == new_ids[f"{pfx} {n} with Auto Rifle on Gold"],
              f"weapon id {n}")
    # The island layout's goal looks at the final island's own equipment check.
    seen = []
    LD.final_run_checked(LD.weapon_run_location_id_by_name, "Auto Rifle", 2, lambda i: seen.append(i) or False)
    check(seen == [new_ids["Complete Island 28 with Auto Rifle on Gold"]], f"island layout victory looked at {seen}")

# Biome layout: every (island, biome) pair, short and full.
for run_length in (28, 56):
    configure(1, run_length)
    check(LD.biome_layout, "biome layout not read")
    for n in range(1, run_length + 1):
        for biome in range(1, 5):
            slot = (n - 1) % 7 + 1
            loop = 1 if n > 28 else 0
            name = expected_name(biome, slot, loop)
            idx = LD.check_index(n, biome)
            check(LD.island_location_id(idx) == new_ids[name], f"biome id {name}")
            check(LD.island_location_id(idx, 2) == new_ids[name + " on Gold"], f"biome ranked id {name}")
            check(LD.island_location_id(idx, 7) == new_ids[name + " on Prismatic"], f"biome ranked id {name}")
            for fn, nm in ((LD.weapon_run_location_id_by_name, "Auto Rifle"),
                           (LD.weapon_run_location_id_by_name, weapons[-1]),
                           (LD.melee_run_location_id_by_name, melees[0]),
                           (LD.melee_run_location_id_by_name, melees[-1]),
                           (LD.ability_run_location_id_by_name, abilities[0]),
                           (LD.ability_run_location_id_by_name, abilities[-1])):
                check(fn(idx, nm) == new_ids[f"{name} with {nm}"], f"equip id {name} {nm}")
                check(fn(idx, nm, 3) == new_ids[f"{name} with {nm} on Sapphire"], f"ranked equip id {name} {nm}")
    check(LD.check_index(5, None) is None, "unknown biome gave an index")
    # Run-level equipment checks, which the goal counts.
    for kind, lst, fn in (("weapon", weapons, LD.weapon_run_location_id_by_name),
                          ("melee", melees, LD.melee_run_location_id_by_name),
                          ("ability", abilities, LD.ability_run_location_id_by_name)):
        for nm in (lst[0], lst[-1]):
            for rank in (0, 2, 7):
                lid = LD.run_equipment_location_id(kind, nm, rank)
                check(lid == new_ids[f"Complete Run with {nm} on {RANKS[rank]}"], f"run id {kind} {nm} {rank}")
                seen = []
                check(LD.final_run_checked(fn, nm, rank, lambda i: seen.append(i) or i == lid), f"final_run_checked {nm}")
                check(seen == [lid], f"biome victory looked at {seen}, not the run check")
    # The same biome and slot gives the same ID however many times the biome repeats.
    if run_length == 28:
        check(LD.check_index(3, 1) == LD.check_index(10, 1) == LD.check_index(17, 1), "biome repeat changed the index")
    else:
        check(LD.check_index(3, 1) != LD.check_index(31, 1), "loop 2 shares an index with loop 1")
# A short run never uses a Loop 2 index, even if the island counter runs past 28.
configure(1, 28)
check(LD.check_index(30, 1) == 2, "short run reached loop 2")

# --------------------------------------------------------------------------
# Island clears through PickupWatch.lua with a model of the game
# --------------------------------------------------------------------------
SCRIPTS = (REPO / "CrabChampionsAP/Scripts").as_posix()


def play(options, clears, difficulty=1):
    """Run `clears` -- a list of (island, biome, hook) -- through the real PickupWatch and return the location
    IDs it sent, in order. hook is 'clear' or 'portal'."""
    rt = LuaRuntime(unpack_returned_tuples=True)
    rt.execute("package.path = '%s/?.lua;' .. package.path; logged = {}; "
               "print = function(m) logged[#logged + 1] = m end" % SCRIPTS)
    rt.execute("""
        hooks = {}
        RegisterHook = function(path, fn) hooks[path:match(":(%w+)$")] = fn end
        LoopAsync = function() end
        NotifyOnNewObject = function() end
        StaticFindObject = function() return nil end
        gs = { CurrentIsland = 1, Biome = 1, Difficulty = 1, IsValid = function() return true end }
        FindFirstOf = function(c) if c == "CrabGS" then return gs end end
        ps = { IsValid = function() return true end,
               WeaponDA = { GetFullName = function() return "CrabWeaponDA /Game/DA/DA_Weapon_AutoRifle.DA_Weapon_AutoRifle" end } }
        FindAllOf = function(c) if c == "CrabPS" then return { ps } end end
        sent, checked, runs, victories = {}, {}, {}, 0
        client = { slot_data = {},
                   is_location_checked = function(_, id) return checked[id] == true end,
                   send_check = function(_, id) checked[id] = true; sent[#sent + 1] = id end,
                   send_victory = function() victories = victories + 1 end,
                   is_run_completed = function(_, k, n) return runs[k .. ":" .. n] == true end,
                   record_run_completed = function(_, k, n) runs[k .. ":" .. n] = true end }
    """)
    rt.execute("gs.Difficulty = %d" % difficulty)  # the game enum: 1 = Bronze, 3 = Gold
    rt.execute("BL = require('AP/BiomeLock'); BL.game.gs = function() return gs end")
    rt.execute("require('AP/LocationData').configure({ options = %s })" % options)
    rt.execute("require('AP/PickupWatch').install(client)")
    for island, biome, hook in clears:
        rt.execute(f"gs.CurrentIsland = {island}; gs.Biome = {biome}")
        rt.execute("hooks.ClientOnClearedIsland({})" if hook == "clear" else "hooks.ClientOnEnteredPortal({})")
    play.log = [str(l) for l in rt.eval("logged").values()]
    play.runs = sorted(str(k) for k in rt.eval("runs").keys())
    play.victories = int(rt.eval("victories"))
    return [int(i) for i in rt.eval("sent").values()]


B = 1890000 + 12000 * 10
walk = [(1, 1, "clear"), (2, 1, "clear"), (3, 1, "clear"), (4, 1, "clear"), (5, 1, "clear"),
        (6, 1, "portal"), (7, 2, "clear"), (8, 2, "clear")]
got = play("{ run_length = 28, check_layout = 1 }", walk)
want = [B + n for n in (1, 2, 3, 4, 5, 6, 7, 8)]
# Each clear sends its plain check, then its Bronze check (the model's rank is Bronze).
plain = [i for i in got if i < B + 57]
check(plain == want, f"biome walk sent {plain}, wanted {want}")
check(all(i >= B for i in got), "biome walk sent an island-number check")
# The log reads like the location names, not island numbers.
text = chr(10).join(play.log)
for want in ("Island check: Complete Tropical Island 1", "Reach Tropical Shop", "Weapon run: Complete Tropical Island 1 with Auto Rifle"):
    check(want in text, f"log lacks {want!r}")
check("Complete Island" not in text and ": Island " not in text and "Reach Shop on" not in text,
      "biome log has island-number names")
# Island 7 was cleared when the game already read the next biome (2): it still counts for Tropical.
check(B + 14 not in got, "slot 7 took the next biome")
# Without the shop seen (portal not hooked, or a reconnect), slot 7 still takes the biome of the earlier islands.
got = play("{ run_length = 28, check_layout = 1 }", [(5, 1, "clear"), (7, 2, "clear")])
check(B + 7 in got and B + 14 not in got, f"slot 7 without the shop sent {got}")
got = play("{ run_length = 28, check_layout = 1 }", [(7, 2, "clear")])
check(B + 14 in got, f"slot 7 with no record should use the current biome {got}")
# A repeat of Ice slot 1 on island 8 sends nothing new.
got = play("{ run_length = 28, check_layout = 1 }", [(1, 2, "clear"), (8, 2, "clear")])
check(got.count(B + 8) == 1 and len(got) == len(set(got)), f"biome repeat sent {got}")
# A full run's second pass.
got = play("{ run_length = 56, check_layout = 1 }", [(28, 4, "clear"), (29, 1, "clear")])
check(B + 28 in got and B + 29 in got and B + 1 not in got, f"loop 2 sent {got}")
# Run-level equipment checks fire on the final island only, in whatever biome it is, and slot 7 of an earlier
# biome sends none of them.
got = play("{ run_length = 28, check_layout = 1 }",
           [(7, 1, "clear"), (14, 2, "clear")])
check(not any(1890000 + 12000 * 14 <= i < 1890000 + 12000 * 17 for i in got), f"run check on a non-final island {got}")
ALL_BIOMES = [(1, 1, "clear"), (8, 2, "clear"), (15, 3, "clear"), (22, 4, "clear")]
RUN_IDS = lambda got: [i for i in got if 1890000 + 12000 * 14 <= i < 1890000 + 12000 * 17]
got = play("{ run_length = 28, check_layout = 1 }", ALL_BIOMES + [(28, 4, "clear")])
check(RUN_IDS(got), f"no run check at island 28: {got}")
# Island 28 without clearing islands in all four biomes (a locked biome repeated) is not a completed run.
for walk in ([(28, 4, "clear")], [(1, 1, "clear"), (8, 1, "clear"), (15, 1, "clear"), (22, 1, "clear"), (28, 1, "clear")],
             ALL_BIOMES[:3] + [(28, 3, "clear")]):
    got = play("{ run_length = 28, check_layout = 1 }", walk)
    check(not RUN_IDS(got), f"run check without all biomes {walk}: {got}")
    check("not a completed run" in chr(10).join(play.log), "no log line for an incomplete run")
# Bronze goal (no Bronze checks): the final island's plain checks are ordinary checks, sent either way; the goal
# counts only a run that cleared all four biomes, kept in the run record.
BRONZE = "{ run_length = 28, check_layout = 1, bronze_checks = false, weapons_for_completion = 1 }"
got = play(BRONZE, [(1, 1, "clear"), (28, 4, "clear")])
check(any(i == B + 28 for i in got), f"Volcano Island 7 not sent without all biomes {got}")
check(play.victories == 0 and play.runs == [],
      f"incomplete run reached the goal: victories={play.victories} runs={play.runs}")
got = play(BRONZE, ALL_BIOMES + [(28, 4, "clear")])
check(play.runs == ["weapon:Auto Rifle"] and play.victories == 1,
      f"complete run not recorded or goal not met: victories={play.victories} runs={play.runs}")
# Silver required: the run-level checks stand in, nothing is recorded.
got = play("{ run_length = 28, check_layout = 1, required_rank = 1, weapons_for_completion = 1 }",
           ALL_BIOMES + [(28, 4, "clear")], difficulty=2)
check(play.runs == [], f"separate rank recorded runs {play.runs}")

# The run record uses data storage, so the client wrapper must forward those calls to the native client.
wrapper = (REPO / "CrabChampionsAP/Scripts/AP/APClientWrapper.lua").read_text(encoding="utf-8")
for fn in ("Get", "Set", "SetNotify", "get_team_number", "set_retrieved_handler", "set_set_reply_handler"):
    check(f"function wrapped:{fn}(" in wrapper, f"APClientWrapper does not forward {fn}")

# Island layout: island 28 alone still completes the run, as before.
got = play("{ run_length = 28 }", [(28, 4, "clear")])
check(any(i == 1890028 for i in got), f"island layout lost its island 28 check {got}")
got = play("{ run_length = 56, check_layout = 1 }", [(28, 4, "clear")])
check(not any(1890000 + 12000 * 14 <= i < 1890000 + 12000 * 17 for i in got), f"run check at island 28 of a full run {got}")
got = play("{ run_length = 56, check_layout = 1 }", ALL_BIOMES + [(56, 2, "clear")])
check(any(1890000 + 12000 * 14 <= i < 1890000 + 12000 * 17 for i in got), f"no run check at island 56: {got}")
# Island layout and seeds without check_layout: the old IDs.
for opts in ("{ run_length = 28 }", "{ run_length = 28, check_layout = 0 }"):
    got = play(opts, [(1, 3, "clear"), (7, 3, "clear")])
    check(1890001 in got and 1890007 in got and not any(i >= B for i in got), f"island layout sent {got}")

# --------------------------------------------------------------------------
# No Bronze checks: the plain checks are the Bronze checks. The Bronze IDs stay computable for old seeds.
# --------------------------------------------------------------------------
BRONZE_IDS = {i for n, i in new_ids.items() if n.endswith(" on Bronze")}
check(len(BRONZE_IDS) > 1000, "Bronze IDs are gone from the ID table")
configure(None)
check(LD.bronze_checks is True, "seeds without bronze_checks must keep Bronze checks")
check(LD.island_location_id(5, 0) == new_ids["Complete Island 5 on Bronze"], "Bronze island ID not computable")
check(LD.weapon_run_location_id_by_name(5, "Auto Rifle", 0) == new_ids["Complete Island 5 with Auto Rifle on Bronze"],
      "Bronze equipment ID not computable")
check(LD.rank_run_location_id(0) == new_ids["Complete Run on Bronze"], "Bronze run ID not computable")
# An old seed (no flag) still sends its Bronze checks.
got = play("{ run_length = 28 }", [(1, 1, "clear")])
check(1890001 in got and (BRONZE_IDS & set(got)), f"old seed lost its Bronze checks: {got}")

NB = "bronze_checks = false, run_length = 28"
for layout in ("", ", check_layout = 1"):
    # Required Bronze, no extra ranks: only the plain checks.
    got = play("{ %s%s }" % (NB, layout), [(1, 1, "clear"), (6, 1, "portal"), (28, 4, "clear")])
    check(got and not (BRONZE_IDS & set(got)), f"Bronze ID sent for a new seed{layout}: {got}")
    # Extra ranks at Gold: Gold and the plain checks, never Bronze, with and without cascade.
    for cascade in ("false", "true"):
        opts = ("{ %s%s, required_rank = 2, max_rank = 3, extra_ranked_island_checks = true, "
                "cascade_ranked_checks = %s }" % (NB, layout, cascade))
        got = play(opts, [(1, 1, "clear"), (28, 4, "clear")], difficulty=3)
        check(not (BRONZE_IDS & set(got)), f"Bronze ID sent at Gold{layout} cascade={cascade}: {got}")
        check(len(got) == len(set(got)), f"duplicate sends at Gold{layout} cascade={cascade}")
        check(not any("on Bronze" in l for l in play.log), f"log labels a plain check as Bronze{layout} cascade={cascade}")
        plain_isl = 1890001 if not layout else B + 1
        check(plain_isl in got, f"plain island check missing at Gold{layout}: {got}")
    # Required Gold without extra ranks: plain plus Gold.
    got = play("{ %s%s, required_rank = 2, max_rank = 2 }" % (NB, layout), [(1, 1, "clear")], difficulty=3)
    check(not (BRONZE_IDS & set(got)) and len(got) >= 2, f"Gold goal sent {got}")

# The goal: Bronze with no Bronze checks looks at the plain final-island check (any biome in the biome layout).
configure(None, 28)
LD.configure(lua.table_from({"options": lua.table_from({"run_length": 28, "bronze_checks": False})}))
seen = []
LD.final_run_checked(LD.weapon_run_location_id_by_name, "Auto Rifle", 0, lambda i: seen.append(i) or False)
check(seen == [new_ids["Complete Island 28 with Auto Rifle"]], f"Bronze goal looked at {seen}")
LD.configure(lua.table_from({"options": lua.table_from({"run_length": 28, "bronze_checks": False, "check_layout": 1})}))
seen = []
LD.final_run_checked(LD.weapon_run_location_id_by_name, "Auto Rifle", 0, lambda i: seen.append(i) or False)
want = sorted(new_ids[f"{locs.biome_check_prefix(k)} with Auto Rifle"] for k in (6, 13, 20, 27))
check(sorted(seen) == want, f"biome Bronze goal looked at {seen}, wanted {want}")
# With Bronze checks (old seeds) the goal still looks at the Bronze check.
LD.configure(lua.table_from({"options": lua.table_from({"run_length": 28})}))
seen = []
LD.final_run_checked(LD.weapon_run_location_id_by_name, "Auto Rifle", 0, lambda i: seen.append(i) or False)
check(seen == [new_ids["Complete Island 28 with Auto Rifle on Bronze"]], f"old Bronze goal looked at {seen}")

# --------------------------------------------------------------------------
# Generation (needs an Archipelago copy)
# --------------------------------------------------------------------------
ap_dir = os.environ.get("CRAB_AP_DIR")
if ap_dir:
    # Drop the stubs used above; the real BaseClasses comes from the Archipelago copy.
    for mod in [m for m in sys.modules if m == "BaseClasses" or m.startswith("crab_")]:
        del sys.modules[mod]
    sys.path.insert(0, str(Path(__file__).parent))
    import test_biome_checks_gen
    problems += test_biome_checks_gen.run(ap_dir)
    import test_bronze_checks_gen
    problems += test_bronze_checks_gen.run(ap_dir)
    import test_fuzz_regressions_gen
    problems += test_fuzz_regressions_gen.run(ap_dir)
else:
    print("generation checks skipped (set CRAB_AP_DIR to run them)")

if problems:
    print("FAILED:")
    print("\n".join(f"  {p}" for p in problems[:40]))
    sys.exit(1)
print("biome check tests passed")
