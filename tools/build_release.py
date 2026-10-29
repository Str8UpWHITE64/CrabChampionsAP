#!/usr/bin/env python3
"""Build the CrabChampionsAP release zip.

Everything comes from git at the given ref (default HEAD), so uncommitted
or untracked files never end up in a release. Writes to dist/:

    CrabChampionsAP_v<version>.zip   game side, drag CrabChampions/ onto the
                                     game folder
    crabchampions.apworld            copy of the committed apworld

Zip layout:

    INSTALL.txt
    CrabChampions/Binaries/Win64/
        dwmapi.dll, UE4SS.dll        UE4SS v3.0.1, unchanged
        UE4SS-settings.ini           upstream + HookLoadMap = 0, with ConsoleEnabled = 1
        LICENSE                      UE4SS MIT license
        Mods/
            <UE4SS built-in mods>
            shared/
            mods.txt                 the repo's mods.txt
            CrabInvMngmt/
            CrabChampionsAP/

    python tools/build_release.py
    python tools/build_release.py --ref v1.5.0 --version 1.5.0
"""

from __future__ import annotations

import argparse
import io
import json
import subprocess
import sys
import tarfile
import time
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_OUT = REPO / "dist"

UE4SS_DIR = "third_party/UE4SS/v3.0.1"
UE4SS_LICENSE = "third_party/UE4SS/LICENSE"
# Upstream docs, and the stock mods.txt the repo's own copy replaces.
UE4SS_SKIP = {"README.md", "Changelog.md", "Mods/mods.txt"}
SETTINGS = "UE4SS-settings.ini"

MOD_DIRS = ("CrabChampionsAP", "CrabInvMngmt")
MODS_TXT = "mods.txt"
APWORLD = "apworld/crabchampions.apworld"
ARCHIPELAGO_JSON = "apworld/crabchampions/archipelago.json"

GAME_ROOT = "CrabChampions"
WIN64 = f"{GAME_ROOT}/Binaries/Win64"

# Last line of defence against dev leftovers, should any get committed.
BANNED_SUFFIXES = (".pdb", ".dmp", ".log", ".usmap", ".csv")
BANNED_NAMES = {"imgui.ini", "pickup_tags.txt", "probe_log.txt"}
BANNED_PARTS = {"CrabPickupProbe", "watches", "__pycache__", "dumps"}


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def git_files(ref: str, paths: list[str]) -> dict[str, bytes]:
    """Read files at ref through git archive, so .gitattributes applies the
    same way a checkout would."""
    try:
        data = subprocess.run(
            ["git", "-C", str(REPO), "archive", "--format=tar", ref, "--", *paths],
            check=True, capture_output=True,
        ).stdout
    except subprocess.CalledProcessError as e:
        fail(f"git archive {ref} failed: {e.stderr.decode(errors='replace').strip()}")
    files = {}
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        for m in tar.getmembers():
            if m.isfile():
                files[m.name] = tar.extractfile(m).read()
    return files


def sub(files: dict[str, bytes], prefix: str) -> dict[str, bytes]:
    p = prefix.rstrip("/") + "/"
    return {k[len(p):]: v for k, v in files.items() if k.startswith(p)}


def enable_console(ini: bytes) -> bytes:
    old, new = b"ConsoleEnabled = 0", b"ConsoleEnabled = 1"
    if ini.count(old) != 1:
        fail(f"expected one '{old.decode()}' line in {SETTINGS}")
    return ini.replace(old, new)


def check_mods_txt(text: str, builtin: set[str]) -> None:
    entries = []
    for line in text.splitlines():
        line = line.strip().lstrip("\ufeff")
        if not line or line.startswith(";"):
            continue
        name, _, state = line.partition(":")
        entries.append((name.strip(), state.strip()))
    names = [n for n, _ in entries]
    missing = builtin - set(names)
    if missing:
        fail(f"mods.txt doesn't list built-in mod(s): {', '.join(sorted(missing))}")
    unknown = set(names) - builtin - set(MOD_DIRS)
    if unknown:
        fail(f"mods.txt lists mod(s) the zip doesn't ship: {', '.join(sorted(unknown))}")
    if not names or names[-1] != "Keybinds":
        fail("Keybinds must be the last entry in mods.txt")
    state = dict(entries)
    for mod in MOD_DIRS:
        if state.get(mod) != "1":
            fail(f"mods.txt must enable {mod}")
    if names.index("CrabInvMngmt") > names.index("CrabChampionsAP"):
        fail("CrabInvMngmt must load before CrabChampionsAP")


def install_txt(version: str) -> str:
    return (
        f"CrabChampionsAP v{version}\r\n"
        "========================\r\n"
        "\r\n"
        "This zip includes UE4SS v3.0.1, so you don't need to install it separately.\r\n"
        "\r\n"
        "1. Open the game folder: Steam > right-click Crab Champions > Properties >\r\n"
        "   Installed Files > Browse. It's usually\r\n"
        "     C:\\Program Files (x86)\\Steam\\steamapps\\common\\Crab Champions\\\r\n"
        "2. Drag the CrabChampions folder from this zip into it and let Windows\r\n"
        "   merge folders and replace files.\r\n"
        "3. Launch the game. Press F4 to open the connection panel and F3 to connect.\r\n"
        "\r\n"
        "This replaces Mods\\mods.txt and UE4SS-settings.ini. If you run other UE4SS\r\n"
        "mods, add their lines back to mods.txt above the Keybinds line.\r\n"
        "\r\n"
        "The apworld (crabchampions.apworld) is a separate download. Put it in\r\n"
        "Archipelago's custom_worlds folder.\r\n"
        "\r\n"
        "UE4SS is MIT licensed, copyright (c) 2022 Narknon. See\r\n"
        "CrabChampions\\Binaries\\Win64\\LICENSE.\r\n"
    )


def banned(path: str) -> bool:
    parts = path.split("/")
    return (path.lower().endswith(BANNED_SUFFIXES) or parts[-1] in BANNED_NAMES
            or bool(BANNED_PARTS & set(parts)))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ref", default="HEAD", help="git ref to build from (default HEAD)")
    ap.add_argument("--version", help="version string (default: world_version at ref)")
    ap.add_argument("--output-dir", type=Path, default=DEFAULT_OUT)
    args = ap.parse_args()

    files = git_files(args.ref, [UE4SS_DIR, UE4SS_LICENSE, *MOD_DIRS, MODS_TXT,
                                 APWORLD, ARCHIPELAGO_JSON])
    for required in (UE4SS_LICENSE, MODS_TXT, APWORLD, ARCHIPELAGO_JSON,
                     f"{UE4SS_DIR}/UE4SS.dll", f"{UE4SS_DIR}/{SETTINGS}"):
        if required not in files:
            fail(f"{required} is not in git at {args.ref}")

    version = args.version or json.loads(files[ARCHIPELAGO_JSON])["world_version"]
    ue4ss = sub(files, UE4SS_DIR)
    builtin = {p.split("/")[1] for p in ue4ss
               if p.startswith("Mods/") and p.count("/") >= 2 and p.split("/")[1] != "shared"}
    check_mods_txt(files[MODS_TXT].decode("utf-8"), builtin)

    out_files: dict[str, bytes] = {"INSTALL.txt": install_txt(version).encode()}
    for rel, data in sorted(ue4ss.items()):
        if rel in UE4SS_SKIP:
            continue
        out_files[f"{WIN64}/{rel}"] = enable_console(data) if rel == SETTINGS else data
    out_files[f"{WIN64}/LICENSE"] = files[UE4SS_LICENSE]
    out_files[f"{WIN64}/Mods/mods.txt"] = files[MODS_TXT]
    for mod in MOD_DIRS:
        tree = sub(files, mod)
        if not tree:
            fail(f"{mod}/ is empty at {args.ref}")
        for rel, data in sorted(tree.items()):
            out_files[f"{WIN64}/Mods/{mod}/{rel}"] = data

    bad = [p for p in out_files if banned(p)]
    if bad:
        fail("refusing to package: " + ", ".join(bad))

    args.output_dir.mkdir(parents=True, exist_ok=True)
    zip_path = args.output_dir / f"CrabChampionsAP_v{version}.zip"
    # Stamp entries with the commit time so the same ref builds the same zip.
    stamp = time.gmtime(int(subprocess.run(
        ["git", "-C", str(REPO), "log", "-1", "--format=%ct", args.ref],
        check=True, capture_output=True, text=True).stdout))[:6]
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for path, data in out_files.items():
            info = zipfile.ZipInfo(path, stamp)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            zf.writestr(info, data)
    apworld_path = args.output_dir / "crabchampions.apworld"
    apworld_path.write_bytes(files[APWORLD])

    print(f"Built v{version} from {args.ref}:")
    print(f"  {zip_path} ({zip_path.stat().st_size:,} bytes, {len(out_files)} files)")
    print(f"  {apworld_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
