"""Offline test for ObjCache.lua: a lookup is remembered, and re-done when the object dies, the answer ages out,
or the cache is cleared."""
import pathlib
import sys

from lupa import LuaRuntime

REPO = pathlib.Path(__file__).resolve().parent.parent
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("""
scans = 0
clock = 0
os.clock = function() return clock end
function mk(name) local o = { name = name, alive = true }; o.IsValid = function(self) return self.alive end; return o end
current = { mk("a") }
FindAllOF = nil
FindAllOf = function(class) scans = scans + 1; if class == "None" then return nil end; return current end
""")
M = lua.execute((REPO / "CrabChampionsAP/Scripts/AP/ObjCache.lua").read_text(encoding="utf-8"))
g = lua.globals()
problems = []


def expect(label, got, want):
    if got != want:
        problems.append(f"{label}: expected {want!r}, got {got!r}")


first = M.first("CrabGS")
expect("found", first() is not None, True)
for _ in range(20):
    first()
expect("one scan for 21 asks", g.scans, 1)
lua.execute("clock = 2.5")
first()
expect("rescan after the ttl", g.scans, 2)
lua.execute("current[1].alive = false; current = { mk('b') }")
expect("dead object replaced at once", first().name, "b")
expect("scan for the replacement", g.scans, 3)
lua.execute("current = { mk('c') }")
M.clear(first)
expect("clear forces a scan", first().name, "c")
miss = M.first("None")
expect("nothing found", miss(), None)
n = g.scans
miss(); miss()
expect("a miss is remembered for a moment", g.scans, n)
lua.execute("clock = 4")
miss()
expect("a miss is retried later", g.scans, n + 1)
M.clear_all()
first()
expect("clear_all reaches every getter", g.scans, n + 2)
accepted = M.list("CrabPS", lua.eval("function(o) return o.name == 'zzz' end"))
expect("filter applied", len(list(accepted().values())), 0)

if problems:
    print("FAIL")
    for p in problems:
        print(" -", p)
    sys.exit(1)
print("ObjCache OK")
