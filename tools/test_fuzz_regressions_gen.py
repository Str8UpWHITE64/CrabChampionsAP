"""Generation half of the random-option regression tests (run from test_biome_checks.py with CRAB_AP_DIR): option
mixes that once failed to produce a seed must generate.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

CASES = [
    # No melee or ability completion: the goal rule must not ask for items from empty pools.
    dict(melee_for_completion=0, ability_for_completion=0, melee_in_pool=3, abilities_in_pool=3),
    dict(melee_for_completion=0, ability_for_completion=2, abilities_in_pool=4),
    # Nothing to find the first weapon with: no plain island checks and no starting weapon.
    dict(required_rank="bronze", max_rank="silver", extra_rank_checks="filler_only", minimize_run_checks=True,
         starting_weapons=0, weapons_in_pool=17, weapons_for_completion=17, equipment_check_mode="disabled"),
]


def run(ap_dir):
    problems = []
    for opts in CASES:
        for seed in (1, 2, 3):
            with tempfile.TemporaryDirectory() as tmp:
                players = Path(tmp) / "players"
                players.mkdir()
                out = Path(tmp) / "out"
                out.mkdir()
                lines = ["name: Crab", "game: Crab Champions", "Crab Champions:"]
                lines += [f"  {k}: {str(v).lower() if isinstance(v, bool) else v}" for k, v in opts.items()]
                (players / "Crab.yaml").write_text("\n".join(lines) + "\n", encoding="utf-8")
                r = subprocess.run([sys.executable, "Generate.py", "--player_files_path", str(players),
                                    "--outputpath", str(out), "--seed", str(seed)],
                                   cwd=ap_dir, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                   timeout=600)
                if r.returncode != 0 or not list(out.glob("*.zip")):
                    problems.append(f"generation failed for {opts} seed {seed}:\n{(r.stdout + r.stderr)[-600:]}")
    return problems
