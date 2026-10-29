"""Offline tests for the full-inventory pickup path (PickupWatch.lua).

Runs PickupWatch against a fake game, a fake dll gate and a fake AP client,
and checks which pickups are marked as open checks and what happens to a
pickup that was let through a full inventory.

    pip install lupa
    python tools/test_pickup_gate.py
"""
from pathlib import Path

from lupa import LuaRuntime

REPO = Path(__file__).resolve().parent.parent
AP = REPO / "CrabChampionsAP/Scripts/AP"

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("""
print = function() end
hooks = {}
RegisterHook = function(path, fn) hooks[path] = fn end
loops = {}
package.loaded["AP/GameThread"] = { loop = function(ms, fn) loops[#loops + 1] = fn end }
function run_loops()
    local pending = loops
    loops = {}
    for _, fn in ipairs(pending) do fn() end
end

-- fake dll gate
gate = { installed = nil, open = nil, lifts = {}, set_calls = 0 }
function AP_InstallPickupGate(addr) gate.installed = addr; return true end
function AP_SetOpenPickupChecks(keys)
    gate.open = {}
    for _, k in ipairs(keys) do gate.open[k] = true end
    gate.set_calls = gate.set_calls + 1
end
function AP_ConsumePickupLift(key)
    if gate.lifts[key] then gate.lifts[key] = nil; return true end
    return false
end
function AP_PickupGateStatus() return "installed slot 202" end

cdo = { IsValid = function() return true end, GetAddress = function() return 4242 end }
StaticFindObject = function(path)
    if path:find("Default__CrabInteractPickup") then return cdo end
    return { IsValid = function() return false end }
end

-- fake world: a pickup actor and a PS that records removals
removed = {}
ps = { IsValid = function() return true end }
for _, rpc in ipairs({ "ServerRemovePerk", "ServerRemoveRelic", "ServerRemoveWeaponMod",
                       "ServerRemoveMeleeMod", "ServerRemoveAbilityMod" }) do
    ps[rpc] = function(self, token) removed[#removed + 1] = rpc .. ":" .. token end
end
FindAllOf = function(name) if name == "CrabPS" then return { ps } end end
FindFirstOf = function() return nil end

function da(class, leaf)
    return { GetFullName = function() return class .. " /Game/Data/" .. leaf .. "." .. leaf end,
             PerkType = 42, RelicType = 42, WeaponModType = 42 }
end
function ref(v) return { get = function() return v end } end

-- fake AP client
sent = {}
checked = {}
client = {
    slot_data = {},
    is_location_checked = function(self, id) return checked[id] == true end,
    send_check = function(self, id) sent[#sent + 1] = id; checked[id] = true end,
}

package.loaded["AP/ItemApply"] = {
    unlocked = {}, overflow_count = function() return 0 end, retry_overflow = function() end,
}
""")


# Both modules are plain chunks that return their table.
lua.execute("""
local real = require
function load_module(name, src)
    package.loaded[name] = assert(load(src, name))()
    return package.loaded[name]
end
""")
load_module = lua.globals().load_module
LocationData = load_module("AP/LocationData", (AP / "LocationData.lua").read_text(encoding="utf-8"))
PickupWatch = load_module("AP/PickupWatch", (AP / "PickupWatch.lua").read_text(encoding="utf-8"))

problems = []


def reset():
    lua.execute("checked = {}")


def expect(label, got, want):
    if got != want:
        problems.append(f"{label}: got {got!r}, want {want!r}")


L = lua.globals()
LocationData.pickup_checks = True
PickupWatch.install(L.client)

# --- gate key matches the form the dll builds -----------------------------
expect("perk key", LocationData.gate_key("CrabPerkDA /Game/Data/DA_Perk_Charger.DA_Perk_Charger"),
       "CrabPerkDA:charger")
expect("relic key", LocationData.gate_key("CrabRelicDA /Game/Data/DA_Relic_RingOfArmor.DA_Relic_RingOfArmor"),
       "CrabRelicDA:ringofarmor")
expect("non-pickup key", LocationData.gate_key("CrabWeaponDA /Game/Data/DA_Weapon_Minigun.DA_Weapon_Minigun"), None)

# --- install + open set ----------------------------------------------------
L.run_loops()
expect("gate installed on the default object", L.gate.installed, 4242)
open_keys = L.gate.open
expect("perk open", open_keys["CrabPerkDA:charger"], True)
expect("relic open", open_keys["CrabRelicDA:ringofarmor"], True)
expect("weapon mod open", open_keys["CrabWeaponModDA:accelerating" + "shot"], True)
expect("melee mod open", open_keys["CrabMeleeModDA:potentclaws"], True)
expect("ability mod open", open_keys["CrabAbilityModDA:bigability"], True)

charger_id, kind, _ = LocationData.from_da("CrabPerkDA /Game/Data/DA_Perk_Charger.DA_Perk_Charger")
expect("charger kind", kind, "perk")

# a sent check leaves the set on the next refresh
L.checked[charger_id] = True
PickupWatch.refresh_open_checks()
expect("checked perk is closed", L.gate.open["CrabPerkDA:charger"], None)
expect("other perks stay open", L.gate.open["CrabPerkDA:giantslayer"], True)
L.checked[charger_id] = None
PickupWatch.refresh_open_checks()
expect("reopened after a reset", L.gate.open["CrabPerkDA:charger"], True)

# an unchanged set is not pushed again
calls = L.gate.set_calls
PickupWatch.refresh_open_checks()
expect("no repeat push", L.gate.set_calls, calls)

# excluded pickups never open
LocationData.pickup_checks = False
PickupWatch.refresh_open_checks()
expect("pickup checks off closes all", sum(1 for _ in L.gate.open), 0)
LocationData.pickup_checks = True
PickupWatch.refresh_open_checks()

# --- the pickup events -----------------------------------------------------
hook_interact = L.hooks["/Script/CrabChampions.CrabPlayerC:ServerInteract"]
hook_pickup = L.hooks["/Script/CrabChampions.CrabPC:ClientOnPickedUpPickup"]


def pick(class_name, leaf, lifted, received=False):
    """One pickup: a find by the player, optionally let through by the dll."""
    lua.execute("removed = {}; sent = {}")
    full = f"{class_name} /Game/Data/{leaf}.{leaf}"
    key = LocationData.gate_key(full)
    lua.execute(f"gate.lifts = {{}}")
    if lifted:
        L.gate.lifts[key] = True
    lua.execute(f"package.loaded['AP/ItemApply'].unlocked = {{ [{full!r}] = {str(received).lower()} }}")
    lua.execute(f"""
        local player_ps = {{ GetFullName = function() return "CrabPS /Game/PS" end }}
        local actor = {{
            IsValid = function() return true end,
            IsA = function() return true end,
            GetFullName = function() return "CrabInteractPickup /Game/Level.Pickup" end,
            PickupInfo = {{ PickupDA = da({class_name!r}, {leaf!r}), OwningPS = player_ps, Cost = 0 }},
        }}
        local ctx = ref({{ PlayerState = player_ps }})
        hooks["/Script/CrabChampions.CrabPlayerC:ServerInteract"](ctx, ref(actor))
        hooks["/Script/CrabChampions.CrabPC:ClientOnPickedUpPickup"](ctx, ref(da({class_name!r}, {leaf!r})))
    """)
    L.run_loops()
    return len(L.sent), len(L.removed)


# Interact needs the actor's class check to pass: PickupWatch falls back to the name.
lua.execute("""
StaticFindObject = function(path)
    return { IsValid = function() return true end }
end
""")

# normal pickup into a free slot: sent and stripped, as before
expect("normal pickup", pick("CrabPerkDA", "DA_Perk_GiantSlayer", False), (1, 1))
reset()
# normal pickup of a received item: sent, kept
expect("received item, free slot", pick("CrabPerkDA", "DA_Perk_GiantSlayer", False, received=True), (1, 0))
reset()
# full inventory, open check: sent and stripped, even for a received item
expect("full perk", pick("CrabPerkDA", "DA_Perk_GiantSlayer", True), (1, 1))
reset()
expect("full perk, received", pick("CrabPerkDA", "DA_Perk_GiantSlayer", True, received=True), (1, 1))
reset()
expect("full weapon mod", pick("CrabWeaponModDA", "DA_WeaponMod_AcceleratingShot", True), (1, 1))
reset()
expect("full relic", pick("CrabRelicDA", "DA_Relic_RingOfArmor", True), (1, 1))
reset()
expect("removal rpc used", str(L.removed[1]).split(":")[0], "ServerRemoveRelic")
# the RPC gets the enum the DA carries, not a token cut from its name
expect("removal param is the DA enum", str(L.removed[1]), "ServerRemoveRelic:42")
# a check that was already sent, picked up with room: nothing sent, nothing removed
first = pick("CrabPerkDA", "DA_Perk_GiantSlayer", False)
expect("first pickup sends", first, (1, 1))
expect("already checked, free slot", pick("CrabPerkDA", "DA_Perk_GiantSlayer", False), (0, 0))
# the same pickup if the dll lifted it by mistake: still stripped, nothing sent
expect("already checked but lifted", pick("CrabPerkDA", "DA_Perk_GiantSlayer", True), (0, 1))

if problems:
    print("FAILED")
    for p in problems:
        print(" -", p)
    raise SystemExit(1)
print("pickup gate: all checks passed")
