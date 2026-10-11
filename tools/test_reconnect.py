"""Check that a reconnect after a socket drop applies every item again.

The slot connect handler in main.lua clears the inventory, and the server
re-sends all items after Connected. When the socket drops mid-run the native
client reconnects by itself, so APClient has to replay from index 0 there too,
not only on the F3 connect command. Runs APClient.lua against a stub client.

    pip install lupa
    python tools/test_reconnect.py
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
loops = {}
function LoopAsync(ms, fn) loops[#loops + 1] = fn end
-- Run queued one-shot callbacks (apply chunks return true).
function run_async()
    local guard = 0
    while #loops > 0 and guard < 100 do
        local cur = loops
        loops = {}
        for _, fn in ipairs(cur) do fn() end
        guard = guard + 1
    end
end
package.preload["AP/APClientWrapper"] = function() return {} end
package.preload["AP/APConfig"] = function() return { load = function() return {} end } end
package.preload["AP/LocationData"] = function()
    return { ID_LAYOUT = 1, set_location_allowlist = function() end,
             is_valid_location_id = function() return true end }
end
handlers = {}
fake = setmetatable({}, { __index = function(_, k)
    if k:match("^set_.*_handler$") then
        local name = k:gsub("^set_", ""):gsub("_handler$", "")
        return function(_, fn) handlers[name] = fn end
    end
    return function() end
end })
function make_items(n)
    local t = {}
    for i = 0, n - 1 do t[#t + 1] = { index = i, item = 1000 + i, player = 1, flags = 0 } end
    return t
end
""")
Client = lua.execute(SRC)
g = lua.globals()
h = g.handlers

applied = []
resets = []
Client.on_item = lambda it: applied.append(int(it.index))
Client.on_slot_connected = lambda sd: (resets.append(1), applied.clear())
Client._client = g.fake
Client._register_handlers(Client)

problems = []


def connect(n):
    h.room_info()
    h.slot_connected(lua.table_from({"seed": "s1"}))
    h.items_received(g.make_items(n))
    Client._apply_pending_items(Client)
    g.run_async()


# First connect: 60 items, more than one apply chunk.
connect(60)
if applied != list(range(60)):
    problems.append(f"first connect applied {len(applied)} items")

# Socket drops and the native client reconnects by itself. The connect
# handler wiped the inventory, so all 61 items must come back.
h.socket_disconnected()
connect(61)
if applied != list(range(61)):
    problems.append(f"auto reconnect applied {applied[:3]}... ({len(applied)} items), expected all 61")

# A new item after that applies once, an old re-send is ignored.
h.items_received(lua.table_from([lua.table_from({"index": 61, "item": 2000, "player": 1, "flags": 0}),
                                 lua.table_from({"index": 3, "item": 1003, "player": 1, "flags": 0})]))
Client._apply_pending_items(Client)
g.run_async()
if applied != list(range(62)):
    problems.append(f"follow-up items wrong: {applied[-3:]}")

# Reconnect while a multi-chunk batch is still applying: the old batch stops
# and the replay starts from 0 without duplicates.
h.socket_disconnected()
h.room_info()
h.slot_connected(lua.table_from({"seed": "s1"}))
h.items_received(g.make_items(60))
Client._apply_pending_items(Client)       # applies the first chunk, queues the rest
h.socket_disconnected()
connect(60)
if applied != list(range(60)):
    problems.append(f"reconnect mid-apply gave {len(applied)} items, dupes={len(applied) - len(set(applied))}")

if problems:
    print("\n".join(problems))
    sys.exit(1)
print("Reconnect OK")
