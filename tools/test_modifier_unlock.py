"""Offline test for the difficulty modifier unlock (ModifierUnlock.lua).

Checks that, while on, a locked live modifier button gets its Locked overlay collapsed and its button enabled, that
templates and default objects and an unlocked button are left alone, that nothing runs while off, that the account
rank and level are never written, and that a broken widget does not stop the sweep.

    pip install lupa
    python tools/test_modifier_unlock.py
"""
from pathlib import Path

from lupa import LuaRuntime

REPO = Path(__file__).resolve().parent.parent

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().OBJCACHE_SRC = (REPO / "CrabChampionsAP/Scripts/AP/ObjCache.lua").read_text(encoding="utf-8")
lua.execute('package.preload["AP/ObjCache"] = load(OBJCACHE_SRC, "@AP/ObjCache.lua")')
lua.execute("""
print = function() end
function mkwidget(name, vis, enabled, broken)
    local w = { name = name, calls = {} }
    w.LockedDifficultyModifierOverlay = { Visibility = vis,
        IsValid = function() return true end,
        SetVisibility = function(self, v)
            if broken then error("boom") end
            self.Visibility = v
        end }
    w.DifficultyModifierButton = { bIsEnabled = enabled,
        IsValid = function() return true end,
        SetIsEnabled = function(self, v) self.bIsEnabled = v end }
    w.IsValid = function() return true end
    w.GetFullName = function() return name end
    return w
end
LIVE = "UI_DifficultyModifier_Green_C /Engine/Transient.GameEngine_1:BP_GI_C_1.UI_DifficultyMenu_OLD_C_1.WidgetTree.X"
TEMPLATE = "UI_DifficultyModifier_Green_C /Game/UI/Menu/UI_DifficultyMenu_OLD.UI_DifficultyMenu_OLD_C:WidgetTree.UI_DifficultyModifier_Green"
CDO = "CrabDifficultyModifierUI /Script/CrabChampions.Default__CrabDifficultyModifierUI"
""")
mod = lua.execute((REPO / "CrabChampionsAP/Scripts/AP/ModifierUnlock.lua").read_text(encoding="utf-8"))
g = lua.globals()
problems = []


def expect(label, got, want):
    if got != want:
        problems.append(f"{label}: expected {want!r}, got {got!r}")


def setup(widgets):
    lua.execute("widgets = {" + ",".join(widgets) + "}")
    lua.execute("FindAllOf = function(c) if c == 'CrabDifficultyModifierUI' then return widgets end end")


setup(['mkwidget(LIVE, 0, false)', 'mkwidget(TEMPLATE, 0, false)', 'mkwidget(CDO, 0, false)',
       'mkwidget(LIVE, 2, true)'])
lua.execute("locked, template, cdo, open = table.unpack(widgets)")
lua.execute("menu_is_open = true")
mod.menu_open = lua.eval("function() return menu_is_open end")
mod.set_active(False)
expect("off does nothing", mod.tick(), 0)
expect("off leaves overlay", g.locked.LockedDifficultyModifierOverlay.Visibility, 0)

mod.set_active(True)
expect("on changes only the locked live button", mod.tick(), 1)
expect("overlay collapsed", g.locked.LockedDifficultyModifierOverlay.Visibility, 1)
expect("button enabled", g.locked.DifficultyModifierButton.bIsEnabled, True)
expect("template untouched", g.template.LockedDifficultyModifierOverlay.Visibility, 0)
expect("default object untouched", g.cdo.LockedDifficultyModifierOverlay.Visibility, 0)
expect("already open button untouched", g.open.LockedDifficultyModifierOverlay.Visibility, 2)
expect("second sweep finds nothing", mod.tick(), 0)
expect("stats", mod.stats().fixed, 1)

# nothing is touched while the difficulty menu is closed, or while a level change is in progress
lua.execute("locked.LockedDifficultyModifierOverlay.Visibility = 0; locked.DifficultyModifierButton.bIsEnabled = false")
lua.execute("menu_is_open = false")
expect("menu closed: no sweep", mod.tick(), 0)
expect("menu closed: overlay untouched", g.locked.LockedDifficultyModifierOverlay.Visibility, 0)
lua.execute("menu_is_open = true")
mod.pause(60)
expect("paused: no sweep", mod.tick(), 0)
mod.pause(-1)
expect("pause over: sweeps again", mod.tick(), 1)
lua.execute("locked.LockedDifficultyModifierOverlay.Visibility = 0; locked.DifficultyModifierButton.bIsEnabled = false")

# the default menu check: true only for a live difficulty menu in focus
lua.execute("""
function mkpc(menu) return { IsValid = function() return true end, ActiveFocusMenuUI = menu } end
function mkmenu(name) return { IsValid = function() return true end, GetFullName = function() return name end } end
""")
mod2 = lua.execute((REPO / "CrabChampionsAP/Scripts/AP/ModifierUnlock.lua").read_text(encoding="utf-8"))
lua.execute("FindAllOf_real = FindAllOf; FindAllOf = function(c) if c == 'CrabPC' then return {pc} end return FindAllOf_real(c) end")
lua.execute("pc = mkpc(mkmenu('UI_DifficultyMenu_OLD_C /Engine/Transient.X'))")
expect("focused difficulty menu is open", mod2.menu_open(), True)
lua.execute("require('AP/ObjCache').clear_all(); pc = mkpc(mkmenu('UI_InGameMenu_C /Engine/Transient.X'))")
expect("another menu is not", mod2.menu_open(), False)
lua.execute("require('AP/ObjCache').clear_all(); pc = mkpc(nil)")
expect("no menu is not", mod2.menu_open(), False)

# the sweep runs in the lobby only
lua.execute("pc = mkpc(mkmenu('UI_DifficultyMenu_OLD_C /Engine/Transient.X')); require('AP/ObjCache').clear_all()")
mod2.in_lobby = lambda: False
expect("not swept outside the lobby", mod2.tick(), 0)
mod2.in_lobby = lambda: True

# a menu that redraws the lock is unlocked again on the next poll
lua.execute("locked.LockedDifficultyModifierOverlay.Visibility = 0; locked.DifficultyModifierButton.bIsEnabled = false")
expect("re-locked button unlocked again", mod.tick(), 1)

# a widget that errors does not stop the others
setup(['mkwidget(LIVE, 0, false, true)', 'mkwidget(LIVE, 0, false)'])
expect("broken widget skipped, next one done", mod.tick(), 1)
expect("error recorded", mod.stats().last_error is not None, True)

# no widgets / no FindAllOf result
lua.execute("FindAllOf = function() return nil end")
expect("no widgets", mod.tick(), 0)

# the module never touches the player state
src = (REPO / "CrabChampionsAP/Scripts/AP/ModifierUnlock.lua").read_text(encoding="utf-8")
code = "\n".join(l for l in src.splitlines() if not l.strip().startswith("--"))
expect("no AccountRank in code", "AccountRank" in code, False)
expect("no AccountLevel in code", "AccountLevel" in code, False)
expect("no CrabPS in code", "CrabPS" in code, False)

if problems:
    print("FAIL")
    for p in problems:
        print(" -", p)
    raise SystemExit(1)
print("modifier unlock tests passed")
