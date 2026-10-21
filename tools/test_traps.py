"""Offline tests for the trap and Perk Boost client (Traps.lua).

Runs Traps.lua against a fake game and a fake clock and checks that every
effect is undone cleanly, replays never fire twice, and the Perk Boost limits
hold.

    pip install lupa
    python tools/test_traps.py
"""
import io
import os
import sys
import tempfile
from pathlib import Path

from lupa import LuaRuntime

REPO = Path(__file__).resolve().parent.parent
STATE = os.path.join(tempfile.mkdtemp(), "trap_state.txt").replace("\\", "/")

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("""
print = function() end
LoopAsync = function() end
local real_require = require
package.loaded["AP/LocationData"] = {
    trap_duration = 30, trap_grace_seconds = 10, crystal_tax_percent = 25, slowdown_percent = 40,
    weak_shots_percent = 50, bruise_percent = 30, perk_boost_max_per_run = 2, perk_boost_level_cap = 3,
}
-- fake world
clock = 1792265000   -- a real-sized epoch value, so island-long effects are tested with the clocks the game uses
world = { dead = false, lobby = false, island = 1, paused = false, crystals = 200, health = 100,
          boost_calls = 0, boost_pool = 5 }
local function obj(addr, fields) fields.addr = addr; return fields end
function new_world_objects()
    world.ps = obj(1, { DamageMultiplier = 1.0, ScaleMultiplier = 1.0 })
    world.player = obj(2, { ActorScale = 1.0 })
    world.cmc = obj(3, { MaxWalkSpeed = 1000.0, GravityScale = 2.0 })
end
new_world_objects()
""")
Traps = lua.execute(io.open(REPO / "CrabChampionsAP/Scripts/AP/Traps.lua", encoding="utf-8").read()) \
    if (io := __import__("io")) else None
lua.execute("""
return function(Traps, state_path)
    Traps.STATE_PATH = state_path
    Traps.now = function() return clock end
    local g = Traps.game
    g.in_lobby = function() return world.lobby end
    g.island = function() return world.island end
    g.paused = function() return world.paused end
    g.eliminated = function() return world.dead end
    g.ps = function() return world.ps end
    g.player = function() return world.player end
    g.target = function(n)
        if n == "ps" then return world.ps elseif n == "player" then return world.player
        elseif n == "cmc" then return world.cmc end
    end
    g.addr = function(o) return o.addr end
    g.get = function(o, p) return o[p] end
    g.set = function(o, p, v) o[p] = v; return true end
    g.crystals = function() return world.crystals end
    g.set_crystals = function(n) world.crystals = n; return true end
    g.health = function() return world.health, 100 end
    g.set_health = function(v) world.health = v; return true end
    Traps.item_apply = function()
        return { boost_random_perk = function(cap)
            if world.boost_pool <= 0 then return nil end
            world.boost_pool = world.boost_pool - 1
            world.boost_calls = world.boost_calls + 1
            return "Perk", cap
        end }
    end
end
""")(Traps, STATE)
g = lua.globals()
world = g.world

problems = []


def expect(label, got, want, tol=1e-6):
    ok = abs(got - want) <= tol if isinstance(want, float) else got == want
    if not ok:
        problems.append(f"{label}: expected {want}, got {got}")


def info(name):
    return lua.table(name=name)


def start_island(island=1):
    world.lobby = False
    world.island = island
    Traps.tick()          # notice the island
    g.clock += 11         # past the grace period


def fresh():
    Traps._reset_for_test("seed/slot")
    g.clock = 1792265000
    world.lobby = False
    world.island = 1
    world.paused = False
    world.dead = False
    world.crystals = 200
    world.health = 100
    world.boost_calls = 0
    world.boost_pool = 5
    g.new_world_objects()
    Traps.tick()
    g.clock += 11


ID = "seed/slot"

# --- ownership
assert Traps.owns(info("Crystal Tax")) and Traps.owns(info("Perk Boost"))
assert not Traps.owns(info("Crystal Cache"))

# --- Crystal Tax takes a share, once
fresh()
Traps.on_item(info("Crystal Tax"), 0, ID)
Traps.tick()
expect("crystal tax", world.crystals, 150)

# --- a replay of the same index is ignored
Traps.on_item(info("Crystal Tax"), 0, ID)
g.clock += 5
Traps.tick()
expect("replay ignored", world.crystals, 150)
expect("watermark", Traps.watermark(), 0)

# --- Slowdown: applies, lasts through the island, undone on the next
fresh()
Traps.on_item(info("Slowdown Trap"), 0, ID)
Traps.tick()
expect("slow cmc", world.cmc.MaxWalkSpeed, 600.0)
g.clock += 500   # far beyond the timed traps: slowdown ignores the clock
Traps.tick()
expect("slow still on", world.cmc.MaxWalkSpeed, 600.0)
world.cmc.MaxWalkSpeed = 750.0       # the game resets the speed when the crab starts aiming
Traps.tick()
expect("slow re-applied to the game's new value", world.cmc.MaxWalkSpeed, 450.0)
world.island = 2
Traps.tick()
expect("slow undone to the game's last value", world.cmc.MaxWalkSpeed, 750.0)

# --- the game resetting the speed after the trap is over is left alone
fresh()
Traps.on_item(info("Slowdown Trap"), 0, ID)
Traps.tick()
world.cmc.MaxWalkSpeed = 1000.0      # game put it back before the island ended
world.lobby = True
Traps.tick()
expect("reset by the game is kept", world.cmc.MaxWalkSpeed, 1000.0)

# --- Weak Shots: timed, undone on time
fresh()
Traps.on_item(info("Weak Shots Trap"), 0, ID)
Traps.tick()
expect("weak on", world.ps.DamageMultiplier, 0.5)
g.clock += 29
Traps.tick()
expect("weak still on", world.ps.DamageMultiplier, 0.5)
g.clock += 2
Traps.tick()
expect("weak off", world.ps.DamageMultiplier, 1.0)

# --- a perk raising the damage multiplier mid-trap is kept
fresh()
Traps.on_item(info("Weak Shots Trap"), 0, ID)
Traps.tick()
world.ps.DamageMultiplier = 1.5      # game recomputes the value after a perk pickup
Traps.tick()
expect("bonus still cut while the trap runs", world.ps.DamageMultiplier, 0.75)
g.clock += 31
Traps.tick()
expect("bonus kept", world.ps.DamageMultiplier, 1.5)

# --- Grow then Shrink share one size slot and end at the original size
fresh()
Traps.on_item(info("Grow Trap"), 0, ID)
Traps.tick()
expect("grow", world.player.ActorScale, 1.6)
g.clock += 4
Traps.on_item(info("Shrink Trap"), 1, ID)
Traps.tick()
expect("shrink replaces grow", world.player.ActorScale, 0.5)
g.clock += 31
Traps.tick()
expect("size restored", world.player.ActorScale, 1.0)

# --- Gravity up then lobby return undoes it
fresh()
Traps.on_item(info("Heavy Gravity Trap"), 0, ID)
Traps.tick()
expect("heavy", world.cmc.GravityScale, 4.0)
world.lobby = True
Traps.tick()
expect("heavy undone in lobby", world.cmc.GravityScale, 2.0)

# --- Floaty gravity
fresh()
Traps.on_item(info("Floaty Gravity Trap"), 0, ID)
Traps.tick()
expect("floaty", world.cmc.GravityScale, 0.8)
Traps.on_run_over()
expect("floaty undone on death", world.cmc.GravityScale, 2.0)

# --- being eliminated ends the effects even before the game-over screen is dismissed
fresh()
Traps.on_item(info("Slowdown Trap"), 0, ID)
Traps.tick()
expect("slow before death", world.cmc.MaxWalkSpeed, 600.0)
world.dead = True
Traps.tick()
expect("slow ends on elimination", world.cmc.MaxWalkSpeed, 1000.0)
expect("no effect left", len(list(Traps.active_names())), 0)

# --- a replaced player object (new run) is not touched by the old undo
fresh()
Traps.on_item(info("Slowdown Trap"), 0, ID)
Traps.tick()
g.new_world_objects()               # new run: new objects, default values
world.cmc.MaxWalkSpeed = 1000.0
world.player.addr = 20
world.cmc.addr = 30
world.island = 2
Traps.tick()
expect("new object left alone", world.cmc.MaxWalkSpeed, 1000.0)

# --- Bruise takes a share and never the last point
fresh()
Traps.on_item(info("Bruise Trap"), 0, ID)
Traps.tick()
expect("bruise", world.health, 70)
fresh()
world.health = 1
Traps.on_item(info("Bruise Trap"), 0, ID)
Traps.tick()
expect("bruise floor", world.health, 1)

# --- grace period: a trap waits after an island starts
fresh()
world.island = 5
Traps.tick()                         # new island noticed at the current clock
Traps.on_item(info("Crystal Tax"), 0, ID)
g.clock += 5
Traps.tick()
expect("grace holds", world.crystals, 200)
g.clock += 6
Traps.tick()
expect("grace over", world.crystals, 150)

# --- in the lobby nothing hits; the trap waits for the run
fresh()
world.lobby = True
Traps.on_item(info("Crystal Tax"), 0, ID)
Traps.tick()
expect("lobby holds", world.crystals, 200)
expect("lobby pending", Traps.pending_traps(), 1)
start_island(1)
Traps.tick()
expect("hits in run", world.crystals, 150)

# --- the ledger file survives a restart and a reconnect replay
fresh()
world.lobby = True
Traps.on_item(info("Weak Shots Trap"), 3, ID)
Traps.on_item(info("Perk Boost"), 4, ID)
Traps._reset_for_test(None)          # restart: memory gone, file stays
Traps.on_item(info("Weak Shots Trap"), 3, ID)   # the server re-sends it
expect("replay after restart: watermark", Traps.watermark(), 4)
expect("replay after restart: trap not doubled", Traps.pending_traps(), 1)
expect("replay after restart: boost kept", Traps.pending_boosts(), 1)

# --- reset: forgetting the ledger lets the same indexes fire again
fresh()
Traps.on_item(info("Crystal Tax"), 0, ID)
Traps.tick()
expect("before reset", world.crystals, 150)
world.crystals = 200
Traps.on_item(info("Crystal Tax"), 0, ID)      # a replay: ignored
Traps.tick()
expect("replay before reset ignored", world.crystals, 200)
Traps.reset()
Traps.on_item(info("Crystal Tax"), 0, ID)      # after reset it is new again
Traps.tick()                                    # notices the island again
g.clock += 11
Traps.tick()
expect("fires again after reset", world.crystals, 150)

# --- Perk Boost limits: max per run, boosts wait for the next run
fresh()
for i in range(4):
    Traps.on_item(info("Perk Boost"), i, ID)
Traps.tick()
g.clock += 1
Traps.tick()
Traps.tick()
expect("boosts capped per run", world.boost_calls, 2)
expect("boosts waiting", Traps.pending_boosts(), 2)
world.lobby = True
Traps.tick()                         # new run resets the per-run count
world.lobby = False
Traps.tick()
Traps.tick()
expect("boosts resume next run", world.boost_calls, 4)
expect("boosts used up", Traps.pending_boosts(), 0)

# --- a boost with nothing to raise waits instead of being lost
fresh()
world.boost_pool = 0
Traps.on_item(info("Perk Boost"), 0, ID)
Traps.tick()
expect("boost waits", Traps.pending_boosts(), 1)
world.boost_pool = 1
Traps.tick()
expect("boost lands later", world.boost_calls, 1)

if problems:
    print("FAILED", file=sys.stderr)
    for p in problems:
        print("  " + p, file=sys.stderr)
    sys.exit(1)
print("Trap tests passed.")
