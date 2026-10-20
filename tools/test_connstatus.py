"""Check the connection panel's messages, connect timeout and stale-data clearing.

Runs ConnStatus.lua on its own, then APOverlay.lua against stubbed UE4SS and
UMG globals (every widget is a do-nothing proxy), and checks what the panel says
through APOverlay.get_shown().

    pip install lupa
    python tools/test_connstatus.py
"""
import sys
from pathlib import Path

from lupa import LuaRuntime

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = (REPO / "CrabChampionsAP/Scripts").as_posix()

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(f"""
package.path = "{SCRIPTS}/?.lua;" .. package.path
print = function() end
clock = 0
os.clock = function() return clock end
loops = {{}}
function LoopAsync(ms, fn) loops[#loops + 1] = fn end
function run_loops()
    local keep = {{}}
    for _, fn in ipairs(loops) do
        if not fn() then keep[#keep + 1] = fn end
    end
    loops = keep
end
local proxy
proxy = setmetatable({{}}, {{
    __index = function() return proxy end,
    __call = function() return proxy end,
    __newindex = function() end,
}})
StaticFindObject = function() return proxy end
StaticConstructObject = function() return proxy end
FindFirstOf = function(c) if c == "GameInstance" then return proxy end return nil end
FName = function(s) return s end
FText = function(s) return s end
ExecuteInGameThread = function(fn) fn() end
""")
g = lua.globals()
CS = lua.execute("return (require('AP/ConnStatus'))")

problems = []


def check(label, cond, detail=""):
    if not cond:
        problems.append(f"{label} {detail}".strip())


# --- messages -------------------------------------------------------------
check("invalid slot", "Slot name not found" in CS.friendly("Refused: InvalidSlot"), CS.friendly("Refused: InvalidSlot"))
check("invalid password", CS.friendly("InvalidPassword").startswith("Wrong password"))
check("invalid game", "different game" in CS.friendly("Refused: InvalidGame"))
check("first known code wins", "Wrong password" in CS.friendly("Refused: InvalidPassword, InvalidSlot") or
      "Slot name" in CS.friendly("Refused: InvalidPassword, InvalidSlot"))
check("unknown code", CS.friendly("Refused: SomethingNew") == "The server refused the connection (SomethingNew).",
      CS.friendly("Refused: SomethingNew"))
layout = "seed needs ID layout 2, this mod has 1 - install the mod version that matches the seed"
check("sentence passes through", CS.friendly(layout) == layout)
check("empty", CS.friendly(None) == "" and CS.friendly("") == "")
check("short slot", CS.short("Refused: InvalidSlot") == "slot not found")
check("short layout", CS.short(layout) == "mod version mismatch", CS.short(layout))
check("short timeout", CS.short(CS.timeout_message("1.2.3.4:5", 10)) == "server unreachable")
check("timeout text names server", "1.2.3.4:5" in CS.timeout_message("1.2.3.4:5", 10))

# --- timeout --------------------------------------------------------------
check("not yet", CS.timed_out(0, 9.9, 10) is False)
check("at limit", CS.timed_out(0, 10, 10) is True)
check("no start", CS.timed_out(None, 50, 10) is False)

# --- overlay --------------------------------------------------------------
O = lua.execute("return (require('AP/APOverlay'))")
O.create({"server": "127.0.0.1:1", "slot": "Crab", "password": ""})
check("created", O.is_initialized())
O.set_info_provider(lua.eval("function() return {server='127.0.0.1:1', slot='Crab', seed='123', items=4, checked=7} end"))


def shown():
    return O.get_shown()


# Connected: status, hint, info lines.
O.set_connected("Crab")
s = shown()
check("connected status", "AP: Crab" in s["status_text"], s["status_text"])
check("connected hint", "Disconnect" in s["connect_btn_text"])
check("info slot", "Slot: Crab" in s["info_text"] and "Seed: 123" in s["info_text"], s["info_text"])
check("info counts", "Items received: 4" in s["info_text"] and "Locations checked: 7" in s["info_text"])

# Stale data: log lines and checklist text are wiped on disconnect.
O.add_item_log("Crab received a Banana")
check("log shows", "Banana" in shown()["item_log_text"])
lua.execute("clock = 0")
O.set_disconnected("Refused: InvalidSlot")
s = shown()
check("refusal sentence", "Slot name not found" in s["error_text"], s["error_text"])
check("refusal short label", "slot not found" in s["status_text"], s["status_text"])
check("hint resets", "Connect" in s["connect_btn_text"] and "Disconnect" not in s["connect_btn_text"])
check("log cleared", s["item_log_text"] == "(none)", s["item_log_text"])
check("equipment cleared", s["equip_weapons_text"] == "(connect to see weapons)", s["equip_weapons_text"])
check("info cleared", s["info_text"] == "")

# Timeout with a handler: fires after 10 s only while still connecting, and only once.
calls = []
O.set_timeout_handler(lua.eval("function(m) calls_made = (calls_made or 0) + 1; last_msg = m end"))
O.set_connecting("10.0.0.9:38281")
s = shown()
check("connecting status", "Connecting" in s["status_text"], s["status_text"])
check("connecting clears error", s["error_text"] == "")
lua.execute("clock = 9.5; run_loops()")
check("no early timeout", g.calls_made is None)
lua.execute("clock = 10.5; run_loops()")
check("timeout handler called", g.calls_made == 1 and "10.0.0.9:38281" in str(g.last_msg), str(g.last_msg))
lua.execute("clock = 30; run_loops()")
check("timeout fires once", g.calls_made == 1)

# Without a handler the overlay shows the unreachable message itself.
O.set_timeout_handler(None)
lua.execute("clock = 100")
O.set_connecting("10.0.0.9:38281")
lua.execute("clock = 105; run_loops()")
check("still connecting at 5 s", shown()["state"] == "connecting")
lua.execute("clock = 111; run_loops()")
s = shown()
check("unreachable message", "Could not reach the server" in s["error_text"], s["error_text"])
check("unreachable label", "server unreachable" in s["status_text"], s["status_text"])
check("state idle", s["state"] == "idle")

# Connecting that succeeds never times out.
lua.execute("calls_made = nil")
O.set_timeout_handler(lua.eval("function(m) calls_made = (calls_made or 0) + 1 end"))
lua.execute("clock = 200")
O.set_connecting("x:1")
lua.execute("clock = 205; run_loops()")
O.set_connected("Crab")
lua.execute("clock = 300; run_loops()")
check("no timeout after connect", g.calls_made is None)

if problems:
    print("FAILED:")
    for p in problems:
        print("  -", p)
    sys.exit(1)
print("Connection panel OK")
