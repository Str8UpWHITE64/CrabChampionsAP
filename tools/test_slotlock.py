"""Check that SlotLock keeps received slots when the game resets slot counts.

Starting a run sets every slot count back to the game's default of 8, and the
lobby sets them to 24/12 before run items are re-added. Runs SlotLock.lua
against stubbed UE4SS globals and checks the AP-granted counts come back in
both cases, above and below the game's values.

    pip install lupa
    python tools/test_slotlock.py
"""
import io
import sys
from pathlib import Path

from lupa import LuaRuntime

REPO = Path(__file__).resolve().parent.parent

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("""
print = function() end
hooks, loops, set_calls = {}, {}, {}
ps = { NumPerkSlots = 24, NumWeaponModSlots = 24, NumAbilityModSlots = 12,
       NumMeleeModSlots = 12, Crystals = 0 }
function ps:IsValid() return true end
local PROPS = { Perks = "NumPerkSlots", WeaponMods = "NumWeaponModSlots",
                AbilityMods = "NumAbilityModSlots", MeleeMods = "NumMeleeModSlots" }
function RegisterHook(path, fn) hooks[path] = fn end
function LoopAsync(ms, fn) loops[#loops + 1] = { ms = ms, fn = fn } end
function FindAllOf(name) if name == "CrabPS" then return { ps } end end
function AP_SetSlotCount(t, n) ps[PROPS[t]] = n; set_calls[#set_calls + 1] = t end
function AP_RefreshInventoryUI() end
-- Run queued one-shot callbacks; keep repeating ones (they return false).
function run_async()
    local keep = {}
    for _, l in ipairs(loops) do
        if not l.fn() then keep[#keep + 1] = l end
    end
    loops = keep
end
function start_run() for _, p in pairs(PROPS) do ps[p] = 8 end end
""")
SlotLock = lua.execute(io.open(REPO / "CrabChampionsAP/Scripts/AP/SlotLock.lua", encoding="utf-8").read())
g = lua.globals()
ps = g.ps

problems = []


def expect(label, want):
    got = {k: ps[p] for k, p in (("Perks", "NumPerkSlots"), ("WeaponMods", "NumWeaponModSlots"),
                                 ("AbilityMods", "NumAbilityModSlots"), ("MeleeMods", "NumMeleeModSlots"))}
    if got != want:
        problems.append(f"{label}: expected {want}, got {got}")


SlotLock.install()
g.run_async()

# Before connecting nothing is locked, so a run start is left alone.
g.start_run()
g.run_async()
expect("inactive", {"Perks": 8, "WeaponMods": 8, "AbilityMods": 8, "MeleeMods": 8})

# Connect with 4 of each, then receive slots: perks end above the game's 8.
for t in ("Perks", "WeaponMods", "AbilityMods", "MeleeMods"):
    SlotLock.set_slots(t, 4)
for _ in range(9):
    SlotLock.add_slots("Perks", 1)
SlotLock.add_slots("WeaponMods", 1)
g.run_async()
want = {"Perks": 13, "WeaponMods": 5, "AbilityMods": 4, "MeleeMods": 4}
expect("after receiving", want)

# Lobby: the game sets the lobby's 24/12 and the re-apply must land before
# run items are re-added in the same tick, so no queued callback runs here.
lua.execute("ps.NumPerkSlots, ps.NumWeaponModSlots = 24, 24 "
            "ps.NumAbilityModSlots, ps.NumMeleeModSlots = 12, 12")
SlotLock.reapply()
expect("lobby reapply", want)

# New run: the game resets everything to 8 and the watchdog puts it back.
g.start_run()
expect("game reset (sanity)", {"Perks": 8, "WeaponMods": 8, "AbilityMods": 8, "MeleeMods": 8})
g.run_async()
expect("after run start", want)

# Nothing to correct means no extra C++ calls.
before = len(g.set_calls)
g.run_async()
if len(g.set_calls) != before:
    problems.append("watchdog called AP_SetSlotCount with nothing to fix")

# Disabling stops the watchdog fighting the game.
SlotLock.disable()
g.run_async()
g.start_run()
g.run_async()
expect("after disable", {"Perks": 8, "WeaponMods": 8, "AbilityMods": 8, "MeleeMods": 8})

if problems:
    print("\n".join(problems))
    sys.exit(1)
print("SlotLock OK")
