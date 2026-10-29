"""Offline test: the AP client is created and polled on the game thread, always in the same Lua thread.

lua-apclientpp refuses calls from a Lua thread other than the one that created the client ("Lua state changed"),
and UE4SS functions (print among them) fail inside a coroutine UE4SS didn't create. The fake native client below
records the running coroutine on every call and fails like the real one; print fails inside a foreign coroutine.

    python tools/test_poll_thread.py

Needs lupa.
"""
from pathlib import Path

from lupa import LuaRuntime

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = (REPO / "CrabChampionsAP/Scripts").as_posix()

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(f"""
package.path = "{SCRIPTS}/?.lua;" .. package.path
clock = 0
os.clock = function() return clock end
loops, game_queue, on_game = {{}}, {{}}, false
function LoopAsync(ms, fn) loops[#loops + 1] = fn end
function ExecuteInGameThread(fn) game_queue[#game_queue + 1] = fn end
printed, print_errors = {{}}, 0
-- UE4SS's print: fails in a coroutine UE4SS didn't create
print = function(s)
    local co, main = coroutine.running()
    if not main then print_errors = print_errors + 1; error("no lua_instances entry") end
    printed[#printed + 1] = tostring(s)
end
function run_for(ms)
    local stop = clock + ms / 1000
    while clock < stop - 1e-9 do
        clock = clock + 0.016
        local keep = {{}}
        for _, fn in ipairs(loops) do if not fn() then keep[#keep + 1] = fn end end
        loops = keep
        local q = game_queue
        game_queue = {{}}
        on_game = true
        for _, fn in ipairs(q) do fn() end
        on_game = false
    end
end
calls, bad = 0, 0
package.preload["AP/APConfig"] = function() return {{ load = function() return {{ slot = "Crab" }} end }} end
package.preload["AP/APClientWrapper"] = function()
    return {{ new = function()
        local owner = coroutine.running()
        local c = {{}}
        local function check()
            calls = calls + 1
            if coroutine.running() ~= owner or not on_game then bad = bad + 1; error("Lua state changed") end
        end
        setmetatable(c, {{ __index = function(_, k) return function() check() end end }})
        return c
    end }}
end
""")
g = lua.globals()
Client = lua.execute("return (require('AP/APClient'))")
Client.init(Client)
lua.execute("require('AP/GameThread').loaded()")
Client.queue_command(Client, "connect")
g.run_for(3000)

problems = []
if Client._client is None:
    problems.append("client was not created")
if g.calls < 5:
    problems.append(f"native client barely used ({g.calls} calls)")
if g.bad:
    problems.append(f"{g.bad} native call(s) from another Lua thread or off the game thread")
if g.print_errors:
    problems.append(f"print was called inside the poll coroutine {g.print_errors} time(s)")
if not any("Creating AP client" in str(g.printed[i]) for i in range(1, len(g.printed) + 1)):
    problems.append("log lines from inside the poll were lost")
if len(g.loops) != 1:
    problems.append(f"expected only the GameThread driver on LoopAsync, found {len(g.loops)}")

if problems:
    print("FAILED:\n  - " + "\n  - ".join(problems))
    raise SystemExit(1)
print("Poll thread OK")
