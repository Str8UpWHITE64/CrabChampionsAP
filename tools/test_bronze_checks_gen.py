"""Generation half of the Bronze check tests (run from test_biome_checks.py with CRAB_AP_DIR): a spread of option
sets must generate without any "on Bronze" location, with the item pool matching the location count.
"""
import itertools
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def run(ap_dir):
    problems = []
    sys.path.insert(0, ap_dir)
    os.chdir(ap_dir)
    from test.bases import WorldTestBase
    from BaseClasses import LocationProgressType

    class Crab(WorldTestBase):
        game = "Crab Champions"
        run_default_tests = False

    def build(**opts):
        t = Crab()
        t.options = opts
        t.world_setup()
        return t

    ranks = ["bronze", "silver", "gold", "prismatic"]
    grid = itertools.product(("island_number", "biome"), (28, 56), ranks, ranks, (0, 1, 2), (False, True),
                             (0, 1, 2))
    seen = 0
    for layout, run_length, req, mx, extra, minimize, equip in grid:
        # A sample of the grid keeps this quick; every option value appears in it.
        seen += 1
        if seen % 7:
            continue
        opts = dict(check_layout=layout, run_length=run_length, required_rank=req, max_rank=mx,
                    extra_rank_checks=extra, minimize_run_checks=minimize, equipment_check_mode=equip,
                    melee_for_completion=1, ability_for_completion=1, melee_in_pool=2, abilities_in_pool=2,
                    weapons_in_pool=3, weapons_for_completion=2)
        tag = str(opts)
        try:
            t = build(**opts)
        except Exception as e:  # FillError and friends
            problems.append(f"{tag}: {type(e).__name__}: {e}")
            continue
        locs = [l for l in t.multiworld.get_locations(1) if l.address is not None]
        bad = [l.name for l in locs if l.name.endswith(" on Bronze")]
        if bad:
            problems.append(f"{tag}: Bronze locations {bad[:3]}")
        if len(t.multiworld.itempool) != len(locs):
            problems.append(f"{tag}: {len(t.multiworld.itempool)} items for {len(locs)} locations")
        ex = sum(1 for l in t.multiworld.get_locations(1) if l.progress_type == LocationProgressType.EXCLUDED)
        if ex > t.world._count_excluded_locations():
            problems.append(f"{tag}: {ex} excluded, more than the count allows")
        names = {l.name for l in locs}
        # Every run still has a way to complete the goal: the plain final-island checks are there at Bronze.
        if req == "bronze" and layout == "island_number":
            last = f"Complete Island {run_length} with"
            if not any(n.startswith(last) for n in names):
                problems.append(f"{tag}: no plain equipment check on the final island")
        slot = t.world.fill_slot_data()["options"]
        if slot.get("bronze_checks") is not False:
            problems.append(f"{tag}: slot_data lacks bronze_checks=False")

    # A real generation for a few option sets.
    sets = [
        dict(required_rank="bronze", max_rank="bronze", extra_rank_checks="progression"),
        dict(required_rank="gold", max_rank="prismatic", extra_rank_checks="filler_only", run_length=56),
        dict(required_rank="bronze", max_rank="silver", extra_rank_checks="progression", check_layout="biome"),
        dict(required_rank="silver", minimize_run_checks=True, check_layout="biome", run_length=56),
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
                                "--outputpath", str(out), "--seed", "4242"],
                               cwd=ap_dir, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=600)
            if r.returncode != 0 or not list(out.glob("*.zip")):
                problems.append(f"generation failed for {opts}:\n{(r.stdout + r.stderr)[-800:]}")
    return problems
