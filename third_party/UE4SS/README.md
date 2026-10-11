# UE4SS (bundled third-party dependency)

`v3.0.1/` is an unmodified copy of the official UE4SS v3.0.1 release, the
version this mod is built and tested against. `tools/build_release.py`
packs it into the release zip so players don't need a separate download.

## Bundled version

- **Release**: [v3.0.1](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v3.0.1)
- **Asset**: `UE4SS_v3.0.1.zip` (5,523,402 bytes,
  SHA-256 `4b47d4bceddd2f561a4e395bfa00924ccfc945af576a2d0c613e6537846c57ec`)
- **Upstream repo**: <https://github.com/UE4SS-RE/RE-UE4SS>

`v3.0.1/` holds the zip's contents exactly as extracted. `.gitattributes`
keeps git from touching their line endings.

## License

UE4SS is MIT licensed, copyright (c) 2022 Narknon. The release zip doesn't
include the license text, so `LICENSE` here is the upstream `LICENSE` file
at tag `v3.0.1`. The build ships it next to `UE4SS.dll`.

## What the release zip takes from here

- `UE4SS.dll`, `dwmapi.dll` and the built-in `Mods/` folders, unchanged.
- `UE4SS-settings.ini` with `ConsoleEnabled = 1`, the one setting the mod
  needs changed. The build patches that line and leaves the rest alone.
- Not `Mods/mods.txt`: the repo's own `mods.txt` replaces it.
- Not `README.md` or `Changelog.md`.

## Updating

1. Extract the new official release zip over a clean `v<version>/` folder.
2. Update `UE4SS_DIR` in `tools/build_release.py` and the version and hash
   above.
3. Check the repo's `mods.txt` still lists every built-in mod in `Mods/`.
4. Test the mod against the new build before committing.
