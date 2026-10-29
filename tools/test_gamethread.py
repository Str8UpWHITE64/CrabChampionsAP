"""Offline tests for AP/GameThread.lua, the scheduler that runs the mod's work on the game thread.

Models UE4SS: LoopAsync callbacks run on a background tick, ExecuteInGameThread queues a function for the next game
frame. Checks that there is only ever one LoopAsync (the driver), at most one queued pump, a free tick after every
pump, that timers, jobs and signals run inside the pump, and that the pump owns the garbage collector.
Frame mode models the dll's AP_SetFrameCallback (one call per engine frame): no LoopAsync and no ExecuteInGameThread,
the load delays, the collector rate, and the fallback to the driver when the dll is missing, refuses or errors.

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


# ---- frame mode: the dll calls the pump once per engine frame ----

FRAME_SETUP = """
frame_fn, frame_due, frame_no, frame_regs = nil, 0, 0, {}
steps = 0
local real_cg = collectgarbage
collectgarbage = function(opt, ...)
    if opt == "step" then steps = steps + 1 end
    return real_cg(opt, ...)
end
function AP_SetFrameCallback(fn, delay_ms)
    frame_fn = fn
    frame_due = clock * 1000 + delay_ms
    frame_regs[#frame_regs + 1] = delay_ms
    return true
end
-- one engine frame of dt seconds: the dll calls the callback when it is due
function engine_frame(dt)
    clock = clock + dt
    frame_no = frame_no + 1
    if frame_fn and clock * 1000 >= frame_due then
        on_game = true
        frame_fn(frame_no, dt)
        on_game = false
    end
end
function frames(n, dt)
    for _ = 1, n do engine_frame(dt or 0.016) end
end
"""


def fresh_frame(extra="", loaded=True):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(SETUP + FRAME_SETUP + extra)
    GT = lua.execute(SRC)
    GT.start()
    if loaded:
        GT.loaded()
        lua.globals().frames(130)        # past the 2 s grace
    return lua, GT


def test_frame_mode_uses_no_background_thread():
    lua, GT = fresh_frame()
    g = lua.globals()
    lua.execute("calls = 0")
    GT.loop(16, lua.eval("function() calls = calls + 1 end"))
    GT.run(lua.eval("function() end"))
    g.frames(200)
    assert GT.mode() == "frame"
    assert len(g.loops) == 0, "no LoopAsync in frame mode"
    assert len(g.game_queue) == 0, "no ExecuteInGameThread in frame mode"
    assert g.calls >= 150, g.calls


def test_frame_mode_grace_and_auto_arm_delays():
    lua, GT = fresh_frame(loaded=False)
    g = lua.globals()
    assert list(g.frame_regs.values()) == [20000]      # first use: arm after 20 s if loaded() never comes
    lua.execute("ran = 0")
    GT.run(lua.eval("function() ran = ran + 1 end"))
    g.frames(100)
    assert g.ran == 0, "nothing runs while the mod loads"
    GT.loaded()
    assert list(g.frame_regs.values()) == [20000, 2000]
    g.frames(120)                        # 1.9 s
    assert g.ran == 0
    g.frames(10)
    assert g.ran == 1


def test_frame_mode_runs_jobs_timers_signals_on_game_thread():
    lua, GT = fresh_frame()
    g = lua.globals()
    lua.execute("hits, job_where, sig_where, tm = 0, nil, nil, 0")
    trigger = GT.signal(lua.eval("function() hits = hits + 1; sig_where = on_game end"))
    GT.run(lua.eval("function() job_where = on_game end"))
    GT.after(100, lua.eval("function() tm = tm + 1 end"))
    trigger()
    trigger()
    g.engine_frame(0.016)
    assert g.job_where is True and g.sig_where is True and g.hits == 1
    g.frames(10)
    assert g.tm == 1 and g.hits == 1


def test_frame_mode_keeps_the_collector_rate():
    lua, GT = fresh_frame()
    g = lua.globals()
    lua.execute("steps = 0")
    g.frames(250, 0.004)                 # 1 s at 250 fps
    assert 20 <= g.steps <= 35, g.steps
    assert lua.eval('collectgarbage("isrunning")') is False


def test_frame_mode_counts_gaps():
    lua, GT = fresh_frame()
    g = lua.globals()
    before = GT.state()["frame_gaps"]
    g.frames(5)
    lua.execute("frame_no = frame_no + 3")   # three frames the dll skipped
    g.frames(5)
    st = GT.state()
    assert st["mode"] == "frame"
    assert st["frame_gaps"] == before + 1, (before, st["frame_gaps"])


def test_falls_back_when_the_dll_refuses():
    lua, GT = fresh_frame("function AP_SetFrameCallback() return false, 'unknown UE4SS.dll build' end")
    g = lua.globals()
    assert GT.mode() == "pump"
    assert len(g.loops) == 1, "the driver runs instead"
    for _ in range(130):                 # the driver's grace period after loaded()
        g.async_tick()
    lua.execute("calls = 0")
    GT.loop(16, lua.eval("function() calls = calls + 1 end"))
    g.run_for(500)
    assert g.calls >= 5, g.calls


def test_switches_to_frame_mode_when_the_engine_appears_later():
    lua, GT = fresh_frame("""
        local real = AP_SetFrameCallback
        local first = true
        function AP_SetFrameCallback(fn, ms)
            if first then first = false; return false, 'no GameEngine object yet' end
            return real(fn, ms)
        end
    """, loaded=False)
    g = lua.globals()
    assert GT.mode() == "pump" and len(g.loops) == 1
    GT.loaded()
    assert GT.mode() == "frame"
    g.async_tick()
    assert len(g.loops) == 0, "the driver stops once the frame callback took over"
    lua.execute("ran = 0")
    GT.run(lua.eval("function() ran = ran + 1 end"))
    g.frames(130)
    assert g.ran == 1
    assert len(g.game_queue) == 0


def test_falls_back_when_the_dll_errors():
    lua, GT = fresh_frame("function AP_SetFrameCallback() error('boom') end")
    assert GT.mode() == "pump"
    assert len(lua.globals().loops) == 1


def test_old_dll_without_frame_callback_keeps_the_driver():
    lua, GT = fresh()                    # no AP_SetFrameCallback at all
    assert GT.mode() == "pump"
    assert len(lua.globals().loops) == 1


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
    print("GameThread tests passed.")
