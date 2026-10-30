"""Check the completed-run record kept in the server's data storage (APClient.lua), against a stub client.

    pip install lupa
    python tools/test_run_record.py
"""
import io
import sys
from pathlib import Path

from lupa import LuaRuntime

REPO = Path(__file__).resolve().parent.parent
SRC = io.open(REPO / "CrabChampionsAP/Scripts/AP/APClient.lua", encoding="utf-8").read()

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("""
print = function() end
function LoopAsync() end
package.preload["AP/APClientWrapper"] = function() return {} end
package.preload["AP/APConfig"] = function() return { load = function() return {} end } end
package.preload["AP/LocationData"] = function()
    return { ID_LAYOUT = 1, set_location_allowlist = function() end,
             set_layout = function() return true end,
             is_valid_location_id = function() return true end }
end
package.preload["AP/ItemData"] = function() return { set_layout = function() return true end } end
handlers, calls = {}, {}
fake = setmetatable({}, { __index = function(_, k)
    if k:match("^set_.*_handler$") then
        local name = k:gsub("^set_", ""):gsub("_handler$", "")
        return function(_, fn) handlers[name] = fn end
    end
    if k == "get_player_number" then return function() return 1 end end
    if k == "get_team_number" then return function() return 0 end end
    return function(_, ...) calls[#calls + 1] = { k, ... } end
end })
""")
Client = lua.execute(SRC)
g = lua.globals()
h = g.handlers
Client._client = g.fake
Client._register_handlers(Client)

problems = []
loaded = []
Client.on_runs_loaded = lambda: loaded.append(1)
KEY = "crabchampions_runs_0_1"


def calls_named(name):
    return [c for c in g.calls.values() if c[1] == name]


h.room_info()
h.slot_connected(lua.table_from({"seed": "s1"}))
if len(calls_named("Get")) != 1 or len(calls_named("SetNotify")) != 1:
    problems.append("slot connect did not request the run record")

# Recording: local at once, one Set with an update of a dict keyed by kind:name.
Client.record_run_completed(Client, "weapon", "Auto Rifle")
Client.record_run_completed(Client, "weapon", "Auto Rifle")
Client.record_run_completed(Client, "melee", "Claw")
if not Client.is_run_completed(Client, "weapon", "Auto Rifle") or Client.is_run_completed(Client, "weapon", "Claw"):
    problems.append("local record wrong")
Client._process_outgoing(Client)
sets = calls_named("Set")
if len(sets) != 1:
    problems.append(f"expected one Set, got {len(sets)}")
else:
    c = sets[0]
    key, default, want_reply, ops = c[2], c[3], c[4], c[5]
    op = ops[1]
    entries = dict(op[2].items())
    if key != KEY or len(default) != 0 or op[1] != "update":
        problems.append(f"Set shaped wrong: {key} {op[1]}")
    if entries != {"weapon:Auto Rifle": True, "melee:Claw": True}:
        problems.append(f"update entries wrong: {entries}")

# Reading back: a dict value, a legacy list, null and a missing value.
Client._completed_runs = lua.table_from({})
h.retrieved(lua.table_from({KEY: lua.table_from({"weapon:Crossbow": True, "ability:Grenade": True})}))
if not Client.is_run_completed(Client, "weapon", "Crossbow") or not Client.is_run_completed(Client, "ability", "Grenade"):
    problems.append("dict value not read")
if len(loaded) != 1:
    problems.append("on_runs_loaded not called once")
h.retrieved(lua.table_from({KEY: lua.table_from({"weapon:Crossbow": True})}))
if len(loaded) != 1:
    problems.append("a repeat of known entries called on_runs_loaded again")
h.retrieved(lua.table_from({}))                      # key missing / null
h.set_reply(KEY, lua.table_from(["melee:Katana"]))   # list form
if not Client.is_run_completed(Client, "melee", "Katana"):
    problems.append("list value not read")
h.set_reply("other_key", lua.table_from({"weapon:Sniper": True}))
if Client.is_run_completed(Client, "weapon", "Sniper"):
    problems.append("another key's reply was read")

if problems:
    print("\n".join(problems))
    sys.exit(1)
print("Run record OK")
