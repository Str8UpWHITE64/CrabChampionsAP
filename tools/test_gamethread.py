"""Offline tests for AP/GameThread.lua, the scheduler that runs the mod's work on the game thread.

Models UE4SS: LoopAsync callbacks run on a background tick, ExecuteInGameThread queues a function for the next game
frame. Checks that there is only ever one LoopAsync (the driver), at most one queued pump, a free tick after every
pump, that timers, jobs and signals run inside the pump, and that the pump owns the garbage collector.

    python tools/test_gamethread.py

Needs lupa.
"""
from pathlib import Path

from lupa import LuaRuntime

REPO = Path(__file__).resolve().parent.parent
SRC = (REPO / "CrabChampionsAP/Scripts/AP/GameThread.lua").read_text(encoding="utf-8")

SETUP = """
loops, game_queue, on_game = {}, {}, false
clock = 0
os.clock = function() return clock end
function LoopAsync(ms, fn) loops[#loops + 1] = fn end
function ExecuteInGameThread(fn) game_queue[#game_queue + 1] = fn end
function print() end
-- one background tick: every live loop runs once
function async_tick()
    local keep = {}
    for _, fn in ipairs(loops) do
        if not fn() then keep[#keep + 1] = fn end
    end
    loops = keep
end
-- one game frame: run what was queued
function game_frame()
    local q = game_queue
    game_queue = {}
    on_game = true
    for _, fn in ipairs(q) do fn() end
    on_game = false
end
-- advance time by ms with a background tick and a game frame every 16 ms
function run_for(ms)
    local stop = clock + ms / 1000
    while clock < stop - 1e-9 do
        clock = clock + 0.016
        async_tick()
        game_frame()
    end
end
"""


def fresh(extra="", loaded=True):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(SETUP + extra)
    GT = lua.execute(SRC)
    if loaded:                           # the mod finished loading; let the grace period pass
        GT.loaded()
        for _ in range(130):
            lua.globals().async_tick()
    return lua, GT


def test_one_driver_for_all_timers():
    lua, GT = fresh()
    for _ in range(30):
        GT.loop(1, lua.eval("function() end"))
    GT.run(lua.eval("function() end"))
    assert len(lua.globals().loops) == 1, len(lua.globals().loops)


def test_loop_runs_on_game_thread_and_stops():
    lua, GT = fresh()
    lua.execute("calls, where = 0, {}")
    GT.loop(100, lua.eval("function() calls = calls + 1; where[#where + 1] = on_game; return calls >= 3 end"))
    lua.globals().run_for(2000)
    g = lua.globals()
    assert g.calls == 3, g.calls
    assert all(g.where[i] for i in range(1, 4))


def test_loop_period_is_respected():
    lua, GT = fresh()
    lua.execute("calls = 0")
    GT.loop(500, lua.eval("function() calls = calls + 1 end"))
    lua.globals().run_for(2100)
    assert 3 <= lua.globals().calls <= 4, lua.globals().calls


def test_one_pump_queued_and_a_free_tick_after_each():
    lua, GT = fresh()
    GT.loop(1, lua.eval("function() end"))
    g = lua.globals()
    for _ in range(5):
        g.async_tick()                   # game thread stalled: only one pump waits
    assert len(g.game_queue) == 1
    g.game_frame()
    g.async_tick()                       # the tick right after a pump never queues
    assert len(g.game_queue) == 0
    g.async_tick()
    assert len(g.game_queue) == 1


def test_a_waiting_pump_is_never_queued_twice():
    lua, GT = fresh()
    lua.execute("calls = 0")
    GT.after(0, lua.eval("function() calls = calls + 1 end"))
    g = lua.globals()
    for _ in range(2000):                # half a minute of ticks without a game frame (a long load)
        g.async_tick()
    assert len(g.game_queue) == 1, len(g.game_queue)
    g.game_frame()
    assert g.calls == 1
    lua.globals().run_for(500)
    assert g.calls == 1


def test_nothing_is_queued_while_the_mod_loads():
    lua, GT = fresh(loaded=False)
    lua.execute("calls = 0")
    GT.loop(16, lua.eval("function() calls = calls + 1 end"))
    g = lua.globals()
    for _ in range(300):                 # hooks are being registered: the driver must stay quiet
        g.async_tick()
    assert len(g.game_queue) == 0
    GT.loaded()
    for _ in range(100):                 # grace period after loading
        g.async_tick()
    assert len(g.game_queue) == 0
    for _ in range(40):
        g.async_tick()
    assert len(g.game_queue) == 1
    lua.execute("clock = clock + 1")     # the loop is due
    g.game_frame()
    assert g.calls >= 1


def test_arms_anyway_if_loaded_is_never_called():
    lua, GT = fresh(loaded=False)
    GT.loop(16, lua.eval("function() end"))
    g = lua.globals()
    for _ in range(1300):
        g.async_tick()
    assert len(g.game_queue) == 1


def test_error_stops_only_that_loop():
    lua, GT = fresh()
    lua.execute("good = 0")
    GT.loop(16, lua.eval("function() error('boom') end"))
    GT.loop(16, lua.eval("function() good = good + 1 end"))
    lua.globals().run_for(500)
    assert lua.globals().good >= 5
    assert GT.state()["timers"] == 1
    assert GT.state()["errors"] == 1


def test_wrap_keeps_order_and_args():
    lua, GT = fresh()
    lua.execute("got = {}")
    f = GT.wrap(lua.eval("function(a, b) got[#got + 1] = tostring(a) .. ':' .. tostring(b) end"))
    f(1, None)
    f(2, "x")
    assert len(lua.globals().got) == 0, "should wait for the game thread"
    lua.globals().run_for(64)
    assert [lua.globals().got[i] for i in (1, 2)] == ["1:nil", "2:x"]


def test_run_from_inside_a_pump_runs_in_the_same_pump():
    lua, GT = fresh()
    lua.globals().GT = GT
    lua.execute("order = {}")
    GT.run(lua.eval("""function()
        order[#order + 1] = 'a'
        GT.run(function() order[#order + 1] = 'b' end)
    end"""))
    g = lua.globals()
    g.async_tick()
    g.game_frame()
    assert [g.order[i] for i in (1, 2)] == ["a", "b"]
    assert len(g.game_queue) == 0, "nothing may call ExecuteInGameThread from the game thread"


def test_signal_runs_on_next_pump_once():
    lua, GT = fresh()
    lua.execute("hits, where = 0, nil")
    trigger = GT.signal(lua.eval("function() hits = hits + 1; where = on_game end"))
    trigger()
    trigger()                            # two presses before a pump count once
    g = lua.globals()
    assert g.hits == 0
    g.run_for(64)
    assert g.hits == 1 and g.where is True
    g.run_for(64)
    assert g.hits == 1
    trigger()
    g.run_for(64)
    assert g.hits == 2


def test_pump_owns_the_collector():
    lua, GT = fresh()
    GT.loop(16, lua.eval("function() end"))
    lua.globals().run_for(64)
    assert lua.eval('collectgarbage("isrunning")') is False


def test_without_execute_in_game_thread_runs_inline():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(SETUP + "ExecuteInGameThread = nil")
    GT = lua.execute(SRC)
    lua.execute("n = 0")
    GT.run(lua.eval("function() n = n + 1 end"))
    assert lua.globals().n == 1
    trigger = GT.signal(lua.eval("function() n = n + 10 end"))
    trigger()
    assert lua.globals().n == 11


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
    print("GameThread tests passed.")
