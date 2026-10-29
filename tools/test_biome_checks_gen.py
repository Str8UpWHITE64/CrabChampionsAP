"""Generation half of test_biome_checks.py: builds worlds with an Archipelago source copy (CRAB_AP_DIR) that has
this apworld in its worlds folder, and checks location counts, rules and a full generation.
"""
import itertools
import os
import subprocess
import sys
import tempfile
from pathlib import Path

BIOMES = ["Tropical", "Arctic", "Desert", "Volcanic"]


def run(ap_dir):
    problems = []
    sys.path.insert(0, ap_dir)
    os.chdir(ap_dir)
    from test.bases import WorldTestBase
    from BaseClasses import CollectionState, LocationProgressType

    class Crab(WorldTestBase):
        game = "Crab Champions"
        run_default_tests = False

    def build(**opts):
        t = Crab()
        t.options = opts
        t.world_setup()
        return t

    def real_locations(t):
        return [l for l in t.multiworld.get_locations(1) if l.address is not None]

    def names(t):
        return [l.name for l in real_locations(t)]

    def is_biome(n):
        return any(f"{b} " in n for b in BIOMES) and (" Island " in n or " Shop" in n)

    def cats(t):
        c = {}
        for l in real_locations(t):
            key = l.category.name.replace("BIOME_", "")
            c[key] = c.get(key, 0) + 1
        return c

    # The biome layout has the same number of checks as the island layout, no Loop 2 in a short run, and
    # the item pool matches the location count.
    grid = itertools.product((28, 56), (0, 1, 2), (False, True), (False, True))
    for run_length, extra, minimize, lock in grid:
        common = dict(run_length=run_length, extra_rank_checks=extra, minimize_run_checks=minimize,
                      biome_lock=lock, starting_biome=2, melee_for_completion=1, ability_for_completion=1,
                      melee_in_pool=2, abilities_in_pool=2, weapons_in_pool=3, weapons_for_completion=2)
        tag = f"len={run_length} extra={extra} min={minimize} lock={lock}"
        a = build(check_layout=0, **common)
        b = build(check_layout=1, **common)
        na, nb = names(a), names(b)
        n_run = len([n for n in nb if n.startswith("Complete Run with ")])
        if len(na) + n_run != len(nb):
            problems.append(f"{tag}: island layout {len(na)} checks, biome layout {len(nb)} ({n_run} run-level)")
        if any(" (Loop 2)" in n for n in nb) != (run_length == 56):
            problems.append(f"{tag}: Loop 2 checks {'missing' if run_length == 56 else 'present'}")
        if len(set(nb)) != len(nb):
            problems.append(f"{tag}: duplicate biome check names")
        if any(n.startswith(("Complete Island", "Reach Shop on Island")) for n in nb):
            problems.append(f"{tag}: island-number checks in a biome seed")
        if any(is_biome(n) for n in na):
            problems.append(f"{tag}: biome checks in an island seed")
        # The biome layout adds only the run-level equipment checks.
        cb = {k: v for k, v in cats(b).items() if not k.startswith("RUN_")}
        if cats(a) != cb:
            problems.append(f"{tag}: category counts differ {cats(a)} vs {cb}")
        runs = [n for n in nb if n.startswith("Complete Run with ")]
        if not runs or any(n in na for n in runs):
            problems.append(f"{tag}: run-level equipment checks missing or in the island layout")
        excluded = {}
        for t, tg in ((a, "island"), (b, "biome")):
            pool, locs = len(t.multiworld.itempool), len(real_locations(t))
            if pool != locs:
                problems.append(f"{tag} {tg}: {pool} items for {locs} locations")
            ex = sum(1 for l in t.multiworld.get_locations(1) if l.progress_type == LocationProgressType.EXCLUDED)
            want = t.world._count_excluded_locations()
            # The padding count may overshoot (it never undershoots), and must not depend on the layout.
            if ex > want:
                problems.append(f"{tag} {tg}: {ex} excluded, count says only {want}")
            excluded[tg] = (ex, want)

    # Exact sizes of the plain island checks.
    d = dict(biome_lock=False, pickup_checks=False, minimize_run_checks=False, extra_rank_checks=0)
    s = build(check_layout=1, run_length=28, **d)
    f = build(check_layout=1, run_length=56, **d)

    def plain(t):
        return [n for n in names(t) if is_biome(n) and " with " not in n and " on " not in n]

    if len(plain(s)) != 28 or len(plain(f)) != 56:
        problems.append(f"plain island checks: short {len(plain(s))} (want 28), full {len(plain(f))} (want 56)")
    for want in ("Complete Tropical Island 3", "Reach Arctic Shop", "Complete Volcanic Island 7"):
        if want not in names(s):
            problems.append(f"short run is missing {want}")
    for want in ("Complete Tropical Island 3 (Loop 2)", "Reach Arctic Shop (Loop 2)"):
        if want not in names(f):
            problems.append(f"full run is missing {want}")
        if want in names(s):
            problems.append(f"short run has {want}")

    # Rules: with biome lock a biome's checks need its Access item; the starting biome is open.
    for lock in (True, False):
        t = build(check_layout=1, run_length=56, biome_lock=lock, starting_biome=3, pickup_checks=False,
                  minimize_run_checks=False, extra_rank_checks=0)
        w = t.world
        state = CollectionState(t.multiworld)
        for l in real_locations(t):
            if not is_biome(l.name) or " with " in l.name:
                continue
            biome = next(b for b in BIOMES if b in l.name)
            open_now = l.access_rule(state)
            should = (not lock) or biome == "Desert"
            if open_now != should:
                problems.append(f"lock={lock}: {l.name} open={open_now}, expected {should}")
                break
        if lock:
            state.collect(w.create_item("Arctic Access"))
            if not t.multiworld.get_location("Complete Arctic Island 2 (Loop 2)", 1).access_rule(state):
                problems.append("Arctic Access did not open an Arctic Loop 2 check")
            if t.multiworld.get_location("Complete Volcanic Island 2", 1).access_rule(state):
                problems.append("a Volcanic check opened without Volcanic Access")
            eq = next(l for l in real_locations(t) if " with " in l.name and "Volcanic" in l.name)
            st = CollectionState(t.multiworld)
            st.collect(w.create_item("Volcanic Access"))
            if eq.access_rule(st):
                problems.append(f"{eq.name} opened without its equipment")

    # A real generation for a few option sets.
    sets = [
        dict(check_layout="biome", run_length=28),
        dict(check_layout="biome", run_length=56, extra_rank_checks="progression", max_rank=3),
        dict(check_layout="biome", run_length=56, minimize_run_checks=True, biome_lock=False),
        dict(check_layout="island_number", run_length=56),
    ]
    for opts in sets:
        with tempfile.TemporaryDirectory() as tmp:
            players = Path(tmp) / "players"
            players.mkdir()
            out = Path(tmp) / "out"
            out.mkdir()
            lines = ["name: Crab", "game: Crab Champions", "Crab Champions:"]
            lines += [f"  {k}: {str(v).lower() if isinstance(v, bool) else v}" for k, v in opts.items()]
            (players / "Crab.yaml").write_text("\n".join(lines) + "\n", encoding="utf-8")
            r = subprocess.run([sys.executable, "Generate.py", "--player_files_path", str(players),
                                "--outputpath", str(out), "--seed", "12345"],
                               cwd=ap_dir, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=600)
            if r.returncode != 0 or not list(out.glob("*.zip")):
                problems.append(f"generation failed for {opts}:\n{(r.stdout + r.stderr)[-800:]}")
    return problems
