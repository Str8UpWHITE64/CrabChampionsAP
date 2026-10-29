-- GameThread: one scheduler that runs all of the mod's timed and deferred work on the game thread.
--
-- Why it is built this way (UE4SS 3.0.1):
-- * LoopAsync callbacks run on a background thread, but on the SAME Lua state as the game-thread code (hooks and
--   ExecuteInGameThread callbacks). Lua is not thread safe and UE4SS takes no lock around it.
-- * Every ExecuteInGameThread call creates a Lua thread and two registry references on the calling thread, outside
--   the lock that guards the queue, while the game thread is running queued callbacks and freeing their references.
--   Called from LoopAsync, that corrupts the registry: a queued callback's reference ends up pointing at something
--   that is not a function, UE4SS throws "[Lua::Registry::get_function_ref] Ref was not function" from inside the
--   game's ProcessEvent, and the game crashes (0xe06d7363 in UE4SS.dll). Corrupted tables can also loop forever,
--   which freezes the whole game.
-- * Lua's garbage collector runs on whichever thread happens to allocate, so a collection step on the background
--   thread walks objects the game thread is changing.
-- * ExecuteInGameThread called while the queue is being run (from a queued callback, or from a hook that fires
--   inside one) is either dropped or reads freed memory, because UE4SS clears the whole queue afterwards.
-- * ExecuteInGameThread, RegisterHook and NotifyOnNewObject all create their Lua thread on the mod's main Lua
--   stack and then anchor it with luaL_ref, which takes whatever is on top of that stack. RegisterHook does that
--   under the queue lock, but ExecuteInGameThread does it before taking the lock. So an ExecuteInGameThread on the
--   background thread while the mod is still registering its hooks can swap the anchors: a hook's Lua thread ends
--   up anchored by the queued callback's reference, is freed after that callback runs, and the game crashes the
--   next time the hook fires (access violation in UE4SS writing to a freed lua_State).
--
-- So the background thread does almost nothing: a single LoopAsync driver that queues nothing until the mod has
-- finished loading (M.loaded, plus a grace period), and then only counts ticks and, at most once
-- at a time, hands one function (the pump) to ExecuteInGameThread, and only one full tick after the previous pump
-- finished, so its registry writes never overlap UE4SS cleaning up after the pump. The pump runs on the game
-- thread and does everything else: queued jobs, timers, signals from other threads, and the garbage collector
-- (stopped for automatic collection, stepped here, so it never runs on the background thread).
--
-- Frame mode (preferred). When the CrabInvMngmt dll offers AP_SetFrameCallback and it accepts the callback, the
-- dll calls the pump once per frame at the start of the engine's frame (UGameEngine::Tick), on the game thread,
-- outside any ProcessEvent and under UE4SS's own Lua lock. Then there is no driver at all: no LoopAsync, no
-- ExecuteInGameThread, and no Lua on the background thread. The same load rule applies: the first call comes
-- 2 s after M.loaded() (20 s after the first use if M.loaded() never comes). The collector step keeps its old rate
-- (about 30 per second, from the frame times). If the dll is missing or refuses, the driver below is used.
--
-- Rules for the rest of the mod:
-- * Never call LoopAsync or ExecuteInGameThread directly. Use M.loop / M.after / M.run / M.wrap.
-- * Register hooks (RegisterHook, NotifyOnNewObject, ...) only at load time or from game-thread work run by the
--   pump (the driver never queues while a pump is pending or running). Call M.loaded() when loading is done.
-- * Code that may run on another thread (RegisterKeyBind callbacks) must only call a trigger from M.signal.
--
-- Without ExecuteInGameThread (offline tests), everything runs inline or on LoopAsync as before.

local M = {}

local DRIVER_MS = 16            -- LoopAsync period of the driver
local GRACE_TICKS = 125         -- about 2 s after M.loaded() before the first pump is queued
local AUTO_ARM_TICKS = 1250     -- about 20 s: arm anyway if M.loaded() is never called
local MAX_JOBS = 5000           -- per pump, so a job that keeps queueing itself can't hang the game
local GC_STEP_KB = 256          -- collector work per pump (as if this many KB had been allocated)
local FRAME_GRACE_MS = 2000     -- frame mode: first call this long after M.loaded()
local FRAME_AUTO_ARM_MS = 20000 -- frame mode: first call this long after the first use if M.loaded() never comes
local FRAME_GC_S = 0.032        -- frame mode: at most one collector step per this much game time

local function log(msg) print("[CrabAP-GameThread] " .. tostring(msg)) end

local function available()
    return type(ExecuteInGameThread) == "function" and type(LoopAsync) == "function"
end

local function now_ms() return os.clock() * 1000 end

-- State used only on the game thread.
local jobs, jobs_head, jobs_tail = {}, 1, 0
local timers = {}               -- { due = ms, ms = period, fn = f, once = bool }
local signals = {}              -- checkers, registered at load time
local in_pump = false
local gc_stopped = false
M.stats = { pumps = 0, jobs = 0, errors = 0, frames = 0, frame_gaps = 0 }

local mode = nil                -- "frame" (dll frame callback) or "pump" (driver + ExecuteInGameThread)
local last_frame = nil
local gc_wait = 0

-- Shared with the driver (plain numbers and booleans in upvalues: no allocation, no table access there).
local started = false
local tick_n, done_at, pending = 0, -1, false
local armed_at = AUTO_ARM_TICKS  -- the driver queues nothing before this tick

local function run_job(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        M.stats.errors = M.stats.errors + 1
        log("error: " .. tostring(err))
    end
    return ok, err
end

local function push_job(fn)
    jobs_tail = jobs_tail + 1
    jobs[jobs_tail] = fn
end

local function drain_jobs()
    local n = 0
    while jobs_head <= jobs_tail and n < MAX_JOBS do
        local fn = jobs[jobs_head]
        jobs[jobs_head] = nil
        jobs_head = jobs_head + 1
        n = n + 1
        run_job(fn)
    end
    if jobs_head > jobs_tail then jobs, jobs_head, jobs_tail = {}, 1, 0 end
    M.stats.jobs = M.stats.jobs + n
end

local function run_timers()
    local t = now_ms()
    local count = #timers
    local keep = {}
    for i = 1, count do
        local tm = timers[i]
        if tm.dead then
            -- dropped
        elseif tm.due <= t then
            local ok, stop = run_job(tm.fn)
            if not ok then
                log("timer stopped on error")
            elseif tm.once or stop == true then
                -- finished
            else
                -- keep the average period: the next call is due one period after this one was due
                local nxt = tm.due + tm.ms
                tm.due = (nxt > t) and nxt or (t + 1)
                keep[#keep + 1] = tm
            end
        else
            keep[#keep + 1] = tm
        end
    end
    for i = count + 1, #timers do keep[#keep + 1] = timers[i] end   -- added while running
    timers = keep
end

local function gc_step()
    if not gc_stopped or collectgarbage("isrunning") then
        collectgarbage("stop")
        gc_stopped = true
    end
    collectgarbage("step", GC_STEP_KB)
end

-- The pump: runs on the game thread as an ExecuteInGameThread callback.
local function pump()
    if in_pump then return end
    in_pump = true
    M.stats.pumps = M.stats.pumps + 1
    for i = 1, #signals do signals[i]() end
    drain_jobs()
    run_timers()
    drain_jobs()
    run_job(gc_step)
    in_pump = false
    done_at = tick_n
    pending = false
end
M._pump = pump

-- Frame mode: called by the dll once per engine frame, on the game thread, at the start of the frame.
local function on_frame(frame_no, dt)
    if in_pump then return end
    in_pump = true
    M.stats.pumps = M.stats.pumps + 1
    M.stats.frames = M.stats.frames + 1
    if last_frame and frame_no ~= last_frame + 1 then M.stats.frame_gaps = M.stats.frame_gaps + 1 end
    last_frame = frame_no
    for i = 1, #signals do signals[i]() end
    drain_jobs()
    run_timers()
    drain_jobs()
    gc_wait = gc_wait + (tonumber(dt) or 0)
    if gc_wait >= FRAME_GC_S then
        gc_wait = 0
        run_job(gc_step)
    end
    in_pump = false
end
M._on_frame = on_frame

local start_driver

-- Hand on_frame to the dll. False (and the reason) when the dll can't run it.
local function set_frame_callback(delay_ms)
    if type(AP_SetFrameCallback) ~= "function" then return false, "no AP_SetFrameCallback in the dll" end
    local ok, res, why = pcall(AP_SetFrameCallback, on_frame, delay_ms)
    if not ok then return false, tostring(res) end
    if res ~= true then return false, tostring(why or "refused") end
    return true
end

local function start()
    if started then return end
    started = true
    local ok, why = set_frame_callback(FRAME_AUTO_ARM_MS)
    if ok then
        mode = "frame"
        log("frame callback active")
        return
    end
    log("frame callback unavailable: " .. tostring(why) .. "; using ExecuteInGameThread")
    start_driver()
end

start_driver = function()
    mode = "pump"
    local execute = ExecuteInGameThread
    LoopAsync(DRIVER_MS, function()
        if mode ~= "pump" then return true end     -- the dll's frame callback took over
        tick_n = tick_n + 1
        if tick_n < armed_at then return false end   -- still loading: hooks are being registered
        if pending then return false end              -- one pump at a time; it waits for the next ProcessEvent
        if tick_n <= done_at + 1 then
            return false               -- leave one full tick after the last pump before queueing the next
        end
        pending = true
        execute(pump)
        return false
    end)
end

--- Driver numbers for diagnostics (read on the game thread).
function M.state()
    return { mode = mode, ticks = tick_n, done_at = done_at, pending = pending, armed_at = armed_at, timers = #timers,
             jobs = jobs_tail - jobs_head + 1, pumps = M.stats.pumps, errors = M.stats.errors,
             frames = M.stats.frames, frame_gaps = M.stats.frame_gaps, last_frame = last_frame }
end

--- Run fn on the game thread: in the current pump if one is running, else in the next one.
--- Call it from game-thread code only (hooks, timers, jobs, AP callbacks).
function M.run(fn)
    if not available() then return fn() end
    start()
    push_job(fn)
end

--- Wrap a callback so every call runs on the game thread, in call order. Return values are dropped.
function M.wrap(fn)
    return function(...)
        local args = table.pack(...)
        M.run(function() return fn(table.unpack(args, 1, args.n)) end)
    end
end

--- Call fn on the game thread every ms (first call after ms). Return true from fn to stop; an error also stops it.
--- Returns a handle with :cancel().
function M.loop(ms, fn)
    if not available() then
        local h = { dead = false }
        LoopAsync(ms, function()
            if h.dead then return true end
            return fn()
        end)
        function h:cancel() self.dead = true end
        return h
    end
    start()
    local tm = { due = now_ms() + math.max(ms, 0), ms = math.max(ms, 0), fn = fn, once = false }
    function tm:cancel() self.dead = true end
    timers[#timers + 1] = tm
    return tm
end

--- Run fn once on the game thread after ms.
function M.after(ms, fn)
    if not available() then
        return M.loop(ms, function() fn(); return true end)
    end
    local tm = M.loop(ms, fn)
    tm.once = true
    return tm
end

--- For code that runs on another thread (RegisterKeyBind callbacks): returns a trigger that only sets a flag;
--- the next pump sees it and runs fn on the game thread. Register at load time, not from another thread.
function M.signal(fn)
    if not available() then return fn end
    start()
    local hit = false
    signals[#signals + 1] = function()
        if hit then
            hit = false
            run_job(fn)
        end
    end
    return function() hit = true end
end

--- Start the driver now (otherwise it starts with the first timer or job). It queues nothing before M.loaded().
function M.start()
    if available() then start() end
end

--- The mod has finished registering its hooks: the first pump may be queued after a short grace period.
--- Calling it again (a later loader) pushes the first pump back again.
function M.loaded()
    if not available() then return end
    start()
    -- Also retried here when it failed at the first use (too early in start-up for the dll to find the engine).
    if mode == "frame" or type(AP_SetFrameCallback) == "function" then
        local was = mode
        local ok, why = set_frame_callback(FRAME_GRACE_MS)
        if ok then
            if was ~= "frame" then log("frame callback active") end
            mode = "frame"               -- a running driver stops at its next tick
            return
        end
        if was == "frame" then
            log("frame callback unavailable: " .. tostring(why) .. "; using ExecuteInGameThread")
            start_driver()
        end
    end
    armed_at = tick_n + GRACE_TICKS
end

--- "frame" when the dll calls the pump once per frame, "pump" for the ExecuteInGameThread driver, nil before start.
function M.mode()
    return mode
end

return M
