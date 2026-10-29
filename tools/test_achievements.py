"""Offline test for the achievement block (Achievements.lua).

Runs the module against a fake RegisterHook and checks that a write is turned
into zero progress while the block is on, left alone while it is off, and that
a call that cannot be changed is reported rather than counted as blocked.

    pip install lupa
    python tools/test_achievements.py
"""
from pathlib import Path

from lupa import LuaRuntime

REPO = Path(__file__).resolve().parent.parent

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("package.path = [[%s/?.lua;]] .. package.path" % (REPO / "CrabChampionsAP/Scripts").as_posix())  # finds AP/GameThread
lua.execute("""
print = function() end
hooks = {}
-- the first path is missing in this game build, like a module that is not there
RegisterHook = function(path, fn)
    if path:find("Engine.AchievementWriteCallbackProxy", 1, true) then error("no such function") end
    hooks[path] = fn
end
function param(v, can_set)
    local p = { value = v }
    function p:get() return self.value end
    function p:set(x)
        if not can_set then error("read only") end
        self.value = x
    end
    return p
end
function name_param(s)
    return { get = function() return { ToString = function() return s end } end }
end
""")
mod = lua.execute((REPO / "CrabChampionsAP/Scripts/AP/Achievements.lua").read_text(encoding="utf-8"))
g = lua.globals()
problems = []


def expect(label, got, want):
    if got != want:
        problems.append(f"{label}: expected {want!r}, got {got!r}")


PATH = "/Script/OnlineSubsystemUtils.AchievementWriteCallbackProxy:WriteAchievementProgress"
mod.install()
expect("hooked paths", list(mod.installed().values()), [PATH])


def call(progress, can_set=True):
    p = g.param(progress, can_set)
    g.hooks[PATH](None, None, None, g.name_param("SILVER"), p, g.param(0, True))
    return p.value


# off: untouched, counted as passed
expect("off leaves progress", call(100.0), 100.0)
expect("passed count", mod.stats()["passed"], 1)

# on through the flag
mod.set_active(True)
expect("on zeroes progress", call(100.0), 0.0)
expect("blocked count", mod.stats()["blocked"], 1)

# a call that cannot be changed is a failure, not a block
expect("unchangeable keeps value", call(100.0, False), 100.0)
expect("failed count", mod.stats()["failed"], 1)
expect("blocked count unchanged", mod.stats()["blocked"], 1)

# off again after the rank is put back
mod.set_active(False)
expect("off again", call(100.0), 100.0)

# on through the connection test alone
state = {"connected": True}
mod.also_active = lambda: state["connected"]
expect("connected zeroes progress", call(100.0), 0.0)
state["connected"] = False
expect("disconnected passes", call(100.0), 100.0)

# an erroring connection test must not block or crash
def boom():
    raise RuntimeError("x")


mod.also_active = boom
expect("broken test passes", call(100.0), 100.0)

log = "\n".join(str(m) for m in mod.recent_log().values())
for needle in ("BLOCKED: SILVER", "NOT blocked", "block ON", "block OFF"):
    if needle not in log:
        problems.append(f"log is missing {needle!r}")

if problems:
    print("FAILED")
    for p in problems:
        print(" -", p)
    raise SystemExit(1)
print("achievement block: all checks passed")
