"""Offline tests for the trap and Perk Boost item pool (Items.BuildItemPool).

Loads Items.py standalone with a fake multiworld and options, so no
Archipelago install is needed.

    python tools/test_trap_pool.py
"""
import importlib.util
import random
import sys
import types
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

base = types.ModuleType("BaseClasses")
base.Item = type("Item", (), {})
sys.modules["BaseClasses"] = base
spec = importlib.util.spec_from_file_location("crab_items", REPO / "apworld/crabchampions/Items.py")
items = importlib.util.module_from_spec(spec)
spec.loader.exec_module(items)


class Opt:
    def __init__(self, value):
        self.value = value


def make_options(**kw):
    o = types.SimpleNamespace(guaranteed_items=Opt({}), crystal_cache_percentage=Opt(75))
    o.trap_weights = Opt({name: 10 for name in items.TRAP_NAMES})
    o.trap_percentage = Opt(0)
    o.perk_boost_count = Opt(0)
    for k, v in kw.items():
        setattr(o, k, Opt(v))
    return o


mw = types.SimpleNamespace(random=random.Random(7))
problems = []
TRAPS = {i.name for i in items._trap_items}
COUNT = 700


def build(**kw):
    return items.BuildItemPool(mw, COUNT, make_options(**kw), ["Auto Rifle"], [], [])


def names(pool):
    return [i.name for i in pool]


def check(label, cond):
    if not cond:
        problems.append(label)


# no traps by default
pool = build()
check("default has no traps", not (set(names(pool)) & TRAPS))
check("default has no boost", "Perk Boost" not in names(pool))
check("default size", len(pool) == COUNT)

# trap percentage is a share of the leftover filler slots, pool size unchanged
pool = build(trap_percentage=100)
n_trap = sum(1 for n in names(pool) if n in TRAPS)
check("100 percent fills all leftover slots", n_trap > 100)
check("pool size with traps", len(pool) == COUNT)
check("equipment kept", "Auto Rifle" in names(pool))

pool = build(trap_percentage=50)
half = sum(1 for n in names(pool) if n in TRAPS)
check("50 percent is about half of 100 percent", abs(half - n_trap / 2) <= 2)

# a zero weight removes that trap
pool = build(trap_percentage=100, trap_weights={n: (0 if n in ('Crystal Tax', 'Grow Trap') else 10) for n in items.TRAP_NAMES})
got = set(names(pool))
check("zero weight removes a trap", "Crystal Tax" not in got and "Grow Trap" not in got)
check("other traps remain", "Shrink Trap" in got)

# all weights zero means no traps at all
zero = {k: 0 for k in items.TRAP_NAMES}
pool = build(trap_percentage=100, trap_weights=zero)
check("all-zero weights give no traps", not (set(names(pool)) & TRAPS))
check("all-zero size", len(pool) == COUNT)

# one weight alone gives only that trap
pool = build(trap_percentage=100, trap_weights={"Bruise Trap": 5})
kinds = {n for n in names(pool) if n in TRAPS}
check("single weight gives a single trap", kinds == {"Bruise Trap"})

# traps left out of the option are not in the pool
pool = build(trap_percentage=100, trap_weights={"Grow Trap": 3, "Shrink Trap": 3})
check("unlisted traps are left out", {n for n in names(pool) if n in TRAPS} == {"Grow Trap", "Shrink Trap"})

# perk boost count
pool = build(perk_boost_count=12)
check("boost count", names(pool).count("Perk Boost") == 12)
check("boost size", len(pool) == COUNT)
pool = build(perk_boost_count=50, trap_percentage=100)
check("boost with traps keeps size", len(pool) == COUNT)

# ids are new and distinct, and existing ids did not move
ids = [i.cc_code for i in items._all_items if i.cc_code is not None]
check("ids are unique", len(ids) == len(set(ids)))
check("trap ids", {items.item_dictionary[n].cc_code for n in TRAPS} == set(range(960, 968)))
check("boost id", items.item_dictionary["Perk Boost"].cc_code == 970)
check("crystal cache id unchanged", items.item_dictionary["Crystal Cache"].cc_code == 900)
check("progressive slot id unchanged", items.item_dictionary["Progressive Perk Slot"].cc_code == 950)
check("trap category", all(items.item_dictionary[n].category == items.CrabChampsItemCategory.TRAP for n in TRAPS))

if problems:
    print("FAILED", file=sys.stderr)
    for p in problems:
        print("  " + p, file=sys.stderr)
    sys.exit(1)
print("Trap pool tests passed.")
