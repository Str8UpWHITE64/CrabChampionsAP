"""Check that seeds made with 1.4.0 and earlier (ID layout 1) play as before.

Loads the 1.4.0 client from the git tag next to the current client and
compares what each one does for the same in-game events:

  * every item ID of layout 1 gives the same item (All You Can Eat, now a
    relic in the game, gives the relic; Aura Explosion, no longer in the
    game, gives nothing),
  * every pickup, island, shop, equipment run and rank run sends the same
    location ID, including the full-inventory gate keys,
  * receiving an item completes the same pickup check,
  * the goal is reached at the same point,
  * slot_data fields read the same, and fields added after 1.4.0 default
    to 1.4.0's behaviour.

Every release up to 1.4.0 shares the same ID table, so layout 1 covers all
of them.

Seeds: pass .archipelago files made with the 1.4.0 apworld (or set
CRAB_OLD_SEEDS to a folder of them), with CRAB_AP_DIR pointing at an
Archipelago checkout to read them. Each seed's options are played through
simulated runs on both clients, and every location in the seed must be one
the current client can send. Without seeds the tables are compared with
a few built-in option sets.

    pip install lupa
    python tools/test_old_worlds.py [seed.archipelago ...]
"""
import os
import random
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

from lupa import LuaRuntime

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = REPO / "CrabChampionsAP/Scripts"
OLD_TAG = "1.4.0"
OLD_FILES = ["AP/LocationData.lua", "AP/ItemData.lua", "AP/PickupWatch.lua"]

failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)
        if len(failures) <= 40:
            print("FAIL:", msg)


# ---------------------------------------------------------------
# The two clients
# ---------------------------------------------------------------

def old_scripts_dir():
    out = Path(tempfile.mkdtemp(prefix="crab_old_client_"))
    for rel in OLD_FILES:
        src = subprocess.run(
            ["git", "-C", str(REPO), "show", f"{OLD_TAG}:CrabChampionsAP/Scripts/{rel}"],
            check=True, capture_output=True).stdout
        dest = out / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(src)
    return out


FAKE_GAME = r"""
print = function() end
hooks = {}
RegisterHook = function(path, fn) hooks[path] = fn end
NotifyOnNewObject = function() end
LoopAsync = function() end
StaticFindObject = function() return nil end
gs = { CurrentIsland = 0, Difficulty = 1 }
function gs:IsValid() return true end
ps = setmetatable({}, { __index = function(_, k)
    if k == "IsValid" then return function() return true end end
    if type(k) == "string" and k:find("^ServerRemove") then return function() end end
end })
FindFirstOf = function(name) if name == "CrabGS" then return gs end end
FindAllOf = function(name) if name == "CrabPS" then return { ps } end end
function da(full)
    if not full then return nil end
    return { GetFullName = function() return full end, IsValid = function() return true end }
end
function ref(v) return { get = function() return v end } end

package.preload["AP/ItemApply"] = function()
    return { unlocked = {}, overflow_count = function() return 0 end, retry_overflow = function() end }
end
package.preload["AP/GameThread"] = function()
    return { loop = function() end, after = function() end, run = function() end }
end

LD = require("AP/LocationData")
ID = require("AP/ItemData")
PW = require("AP/PickupWatch")

-- AP client: drops checks the server doesn't have, as APClient:send_check does
sent = {}
checked = {}
victories = 0
client = { slot_data = {} }
function client:is_location_checked(id) return checked[id] == true end
function client:send_check(id)
    id = tonumber(id)
    if not id or checked[id] then return end
    if not LD.is_valid_location_id(id) then return end
    checked[id] = true
    sent[#sent + 1] = id
end
function client:send_victory() victories = victories + 1 end
PW.install(client)

function reset_checks() sent = {}; checked = {}; victories = 0 end

function connect(slot_data, ids)
    if LD.set_layout then
        assert(LD.set_layout(slot_data.id_layout))
        assert(ID.set_layout(slot_data.id_layout))
    end
    client.slot_data = slot_data
    LD.configure(slot_data)
    LD.set_location_allowlist(ids, {})
end

-- What main.lua does on connect for checks that can't be found any more.
function send_unfindable()
    if not LD.unfindable_location_ids or not LD.pickup_checks then return end
    for _, id in ipairs(LD.unfindable_location_ids()) do
        if LD.is_valid_location_id(id) and not client:is_location_checked(id) then
            client:send_check(id)
        end
    end
end

function pick_up(full) hooks["/Script/CrabChampions.CrabPC:ClientOnPickedUpPickup"](nil, ref(da(full))) end
function clear_island(n) gs.CurrentIsland = n; hooks["/Script/CrabChampions.CrabPC:ClientOnClearedIsland"](nil) end
function enter_portal() hooks["/Script/CrabChampions.CrabPC:ClientOnEnteredPortal"](nil) end
function equip(w, m, a) ps.WeaponDA = da(w); ps.MeleeDA = da(m); ps.AbilityDA = da(a) end
function start_run() PW.reset_island_counter() end
"""


def make_runtime(scripts_dir):
    rt = LuaRuntime(unpack_returned_tuples=True)
    rt.execute("package.path = %r .. '/?.lua;' .. package.path" % str(scripts_dir).replace("\\", "/"))
    rt.execute(FAKE_GAME)
    return rt


def to_lua(rt, obj):
    if isinstance(obj, dict):
        return rt.table_from({k: to_lua(rt, v) for k, v in obj.items()})
    if isinstance(obj, (list, tuple, set, frozenset)):
        return rt.table_from([to_lua(rt, v) for v in obj])
    return obj


def lua_list(t):
    return [t[i] for i in range(1, len(t) + 1)] if t is not None else []


old = make_runtime(old_scripts_dir())
new = make_runtime(SCRIPTS)
OLD, NEW = old.globals(), new.globals()

IdLayouts = new.execute("return (require('AP/IdLayouts'))")
L1 = IdLayouts[1]

# ---------------------------------------------------------------
# Game data assets, by kind
# ---------------------------------------------------------------
KIND_DA = {
    "perk": ("CrabPerkDA", "Perk"), "relic": ("CrabRelicDA", "Relic"),
    "weapon_mod": ("CrabWeaponModDA", "WeaponMod"), "melee_mod": ("CrabMeleeModDA", "MeleeMod"),
    "ability_mod": ("CrabAbilityModDA", "AbilityMod"),
    "weapon": ("CrabWeaponDA", "Weapon"), "melee": ("CrabMeleeDA", "Melee"),
    "ability": ("CrabAbilityDA", "Ability"),
}
PICKUP_KINDS = ["perk", "relic", "weapon_mod", "melee_mod", "ability_mod"]
EQUIP_KINDS = ["weapon", "melee", "ability"]


def da_full(kind, name):
    cls, prefix = KIND_DA[kind]
    leaf = "DA_%s_%s" % (prefix, name.split(" (")[0].replace("'", "").replace(" ", ""))
    return "%s /Game/Blueprint/Pickup/%s/%s.%s" % (cls, prefix, leaf, leaf)


def old_names(kind):
    return lua_list(L1[kind])


def moved_kind(kind, name):
    m = L1.moved[kind] if L1.moved else None
    return (m[name] if m else None) or kind


def is_removed(kind, name):
    r = L1.removed[kind] if L1.removed else None
    return bool(r and r[name])


def new_game_da(kind, name):
    """The same item's data asset in the current game, or None if it's gone."""
    if is_removed(kind, name):
        return None
    return da_full(moved_kind(kind, name), name)


# ---------------------------------------------------------------
# Items
# ---------------------------------------------------------------

def compare_items():
    check(NEW.ID.set_layout(1), "ItemData can't read layout 1")
    old_tab, new_tab = OLD.ID.BY_CC_CODE, NEW.ID.BY_CC_CODE
    old_codes = sorted(int(k) for k in old_tab.keys())
    new_codes = sorted(int(k) for k in new_tab.keys())
    check(old_codes == new_codes, "layout 1 item codes differ: only old %s, only new %s" % (
        sorted(set(old_codes) - set(new_codes)), sorted(set(new_codes) - set(old_codes))))
    CAT = NEW.ID.CATEGORY
    kind_cat = {"perk": CAT.PERK, "relic": CAT.RELIC, "weapon_mod": CAT.WEAPON_MOD,
                "melee_mod": CAT.MELEE_MOD, "ability_mod": CAT.ABILITY_MOD}
    cat_kind = {v: k for k, v in kind_cat.items()}
    special = 0
    for code in old_codes:
        o, n = old_tab[code], new_tab[code]
        if n is None:
            continue  # reported with the code lists above
        check(o.name == n.name, "item %d: 1.4.0 gives %s, now %s" % (code, o.name, n.name))
        kind = cat_kind.get(o.cat)
        if kind and is_removed(kind, o.name):
            check(n.cat == CAT.SKIP, "item %d (%s) is gone from the game but isn't skipped" % (code, o.name))
            special += 1
        elif kind and moved_kind(kind, o.name) != kind:
            check(n.cat == kind_cat[moved_kind(kind, o.name)],
                  "item %d (%s) should give the game's %s" % (code, o.name, moved_kind(kind, o.name)))
            special += 1
        else:
            check(o.cat == n.cat, "item %d (%s): category %s, was %s" % (code, o.name, n.cat, o.cat))
        info_o = OLD.ID.from_ap_id(1890000 + code)
        info_n = NEW.ID.from_ap_id(1890000 + code)
        check(info_o.name == info_n.name, "from_ap_id(%d) name differs" % code)
    check(special == 2, "expected the All You Can Eat and Aura Explosion cases, saw %d" % special)
    # The current layout is unchanged by switching back.
    check(NEW.ID.set_layout(4) and new.eval("ID.BY_CC_CODE == ID.CURRENT_BY_CC_CODE"), "layout 4 table not restored")
    check(not NEW.ID.set_layout(2) and not NEW.ID.set_layout(3), "layouts 2 and 3 must be refused")
    NEW.ID.set_layout(1)


# ---------------------------------------------------------------
# Location IDs, event by event
# ---------------------------------------------------------------

def pickup_id(LD, full):
    got = LD.from_da(full)
    return got[0] if isinstance(got, tuple) else got


def all_event_ids(rt_globals, game):
    """Every location ID the client computes, keyed by in-game event."""
    LD = rt_globals.LD
    ev = {}
    for kind in PICKUP_KINDS:
        for name in old_names(kind):
            full = da_full(kind, name) if game == "old" else new_game_da(kind, name)
            if full is None:
                continue
            ev[("pickup", kind, name)] = pickup_id(LD, full)
    for island in range(0, 58):
        ev[("island", island, None)] = LD.island_location_id(island)
        for r in range(-1, 9):
            ev[("island", island, r)] = LD.island_location_id(island, r)
        for kind in EQUIP_KINDS:
            fn = getattr(LD, "%s_run_location_id" % kind)
            fn_name = getattr(LD, "%s_run_location_id_by_name" % kind)
            for name in old_names(kind):
                ev[(kind, island, name, None)] = fn(island, da_full(kind, name))
                ev[(kind + "_by_name", island, name, None)] = fn_name(island, name)
                for r in range(-1, 9):
                    ev[(kind, island, name, r)] = fn(island, da_full(kind, name), r)
                    ev[(kind + "_by_name", island, name, r)] = fn_name(island, name, r)
    for r in range(-1, 9):
        ev[("rank_run", r)] = LD.rank_run_location_id(r)
    ev[("victory",)] = LD.victory_location_id()
    return ev


def compare_location_ids():
    check(NEW.LD.set_layout(1), "LocationData can't read layout 1")
    o, n = all_event_ids(OLD, "old"), all_event_ids(NEW, "new")
    for key, oid in o.items():
        if key[0] == "pickup" and is_removed(key[1], key[2]):
            continue
        check(n.get(key) == oid, "%s: 1.4.0 sends %s, now %s" % (key, oid, n.get(key)))
    # Items the game added after layout 1 have no check in an old seed.
    for kind in PICKUP_KINDS:
        known = set(old_names(kind)) | {nm for k in PICKUP_KINDS for nm in old_names(k) if moved_kind(k, nm) == kind}
        for name in lua_list(NEW.LD.PICKUP_NAMES_BY_KIND[kind]):
            lid = pickup_id(NEW.LD, da_full(kind, name))
            if name in known:
                check(lid is not None, "%s %s has no check in layout 1" % (kind, name))
            else:
                check(lid is None, "%s %s is new in the game but sends %s" % (kind, name, lid))
                check(name in lua_list(NEW.LD.untracked_pickup_names(kind)),
                      "%s %s should be pre-allowed for an old seed" % (kind, name))
    for kind in EQUIP_KINDS:
        olds = set(old_names(kind))
        for name in lua_list(getattr(NEW.LD, kind + "_names")):
            if name not in olds:
                fn = getattr(NEW.LD, "%s_run_location_id_by_name" % kind)
                check(fn(28, name) is None and fn(28, name, 0) is None,
                      "%s %s is new in the game but has a run check in layout 1" % (kind, name))
    # Aura Explosion's pickup check is the one that can't be found.
    aura = 1890000 + 12000 * 9
    check(lua_list(NEW.LD.unfindable_location_ids()) == [aura], "unfindable checks: %s" % lua_list(NEW.LD.unfindable_location_ids()))
    # The current layout keeps its own IDs.
    NEW.LD.set_layout(4)
    check(pickup_id(NEW.LD, da_full("relic", "All You Can Eat")) == 1890000 + 12000 * 2 + 60,
          "layout 4 relic All You Can Eat moved")
    check(lua_list(NEW.LD.unfindable_location_ids()) == [], "layout 4 has no unfindable checks")
    check(lua_list(NEW.LD.untracked_pickup_names("perk")) == [], "layout 4 has no untracked pickups")
    NEW.LD.set_layout(1)


# ---------------------------------------------------------------
# A seed, played on both clients
# ---------------------------------------------------------------

CONFIG_FIELDS = [
    "extra_ranked_island_checks", "cascade_ranked_checks", "max_rank", "required_rank", "run_length",
    "equipment_check_mode", "greed_item_mode", "pickup_checks", "death_link", "progressive_slots",
    "starting_perk_slots", "starting_weapon_mod_slots", "starting_ability_mod_slots",
    "starting_melee_mod_slots", "weapons_for_completion", "pool_only_completion",
    "melee_for_completion", "ability_for_completion", "limit_pickup_pool", "limit_pickup_locations",
    "_has_pickup_subsets",
]
# Fields added after 1.4.0, and the value that keeps 1.4.0's behaviour.
NEW_FIELD_DEFAULTS = {
    "check_layout": 0, "biome_layout": False, "granted_item_checks": True,
    "starting_item_percentage": 100, "biome_item_percentage": 0,
}


def lua_set(t):
    return {k for k, v in t.items() if v} if t is not None else set()


def connect_both(slot_data, ids):
    for rt in (old, new):
        g = rt.globals()
        g.reset_checks()
        g.connect(to_lua(rt, slot_data), to_lua(rt, sorted(ids)))
    for f in CONFIG_FIELDS:
        check(OLD.LD[f] == NEW.LD[f], "configure: %s is %s, 1.4.0 had %s" % (f, NEW.LD[f], OLD.LD[f]))
    for f in ("pool_weapons", "pool_melee", "pool_abilities"):
        check(lua_set(OLD.LD[f]) == lua_set(NEW.LD[f]), "configure: %s differs" % f)
    for kind in PICKUP_KINDS:
        check(lua_set(OLD.LD.pickup_subsets[kind]) == lua_set(NEW.LD.pickup_subsets[kind]),
              "configure: pickup subset %s differs" % kind)
    for f, v in NEW_FIELD_DEFAULTS.items():
        check(NEW.LD[f] == v, "configure: %s is %s without the field, 1.4.0 behaviour is %s" % (f, NEW.LD[f], v))


def sent_ids(g):
    return lua_list(g.sent)


def compare_exclusions():
    for kind in PICKUP_KINDS:
        for name in old_names(kind):
            if is_removed(kind, name):
                continue
            o = OLD.LD.is_pickup_location_excluded(kind, name)
            n = NEW.LD.is_pickup_location_excluded(moved_kind(kind, name), name)
            check(o == n, "excluded(%s %s): 1.4.0 %s, now %s" % (kind, name, o, n))


def compare_gate_keys(seed_ids):
    """Open full-inventory keys map to the seed's open pickup checks."""
    expected = set()
    for kind in PICKUP_KINDS:
        for name in old_names(kind):
            full = new_game_da(kind, name)
            lid = pickup_id(OLD.LD, da_full(kind, name))
            if full and lid in seed_ids and not OLD.LD.is_pickup_location_excluded(kind, name) \
                    and OLD.LD.pickup_checks:
                expected.add(NEW.LD.gate_key(full))
    got = set(lua_list(NEW.LD.open_pickup_keys(lambda _id: False)))
    check(got == expected, "gate keys: missing %s, extra %s" % (sorted(expected - got)[:5], sorted(got - expected)[:5]))


def compare_granted_checks():
    """Receiving an item completes the same pickup check (granted_item_checks)."""
    OLD.reset_checks()
    NEW.reset_checks()
    for kind in PICKUP_KINDS:
        for name in old_names(kind):
            full = new_game_da(kind, name)
            if full is None:
                continue  # can't be given
            OLD.PW.send_pickup_check(da_full(kind, name))
            NEW.PW.send_pickup_check(full)
    check(sent_ids(OLD) == sent_ids(NEW), "granted checks differ: %d vs %d" % (len(sent_ids(OLD)), len(sent_ids(NEW))))


def play(slot_data, ids, runs, rng_seed):
    """Simulated runs with the same events on both clients."""
    opts = slot_data["options"]
    rng = random.Random(rng_seed)
    OLD.reset_checks()
    NEW.reset_checks()
    # The player finds Aura Explosion with 1.4.0; the current client sends it on connect.
    if opts.get("pickup_checks", True):
        OLD.pick_up(da_full("ability_mod", "Aura Explosion"))
    NEW.send_unfindable()
    pickups = [(k, n) for k in PICKUP_KINDS for n in old_names(k) if not is_removed(k, n)]
    pools = {"weapon": opts.get("pool_weapons", []), "melee": opts.get("pool_melee", []),
             "ability": opts.get("pool_abilities", [])}
    run_length = int(opts.get("run_length", 28))
    for _ in range(runs):
        rank = rng.randrange(8) if rng.random() < 0.5 else int(opts.get("required_rank", 0))
        gear = []
        for kind in EQUIP_KINDS:
            names = pools[kind] if pools[kind] and rng.random() < 0.7 else old_names(kind)
            gear.append(da_full(kind, rng.choice(names)))
        last = run_length if rng.random() < 0.7 else rng.randrange(1, run_length + 1)
        for g in (OLD, NEW):
            g.gs.Difficulty = rank + 1
            g.equip(*gear)
            g.start_run()
        for island in range(1, last + 1):
            for kind, name in rng.sample(pickups, rng.randrange(0, 3)):
                OLD.pick_up(da_full(kind, name))
                NEW.pick_up(new_game_da(kind, name))
            for g in (OLD, NEW):
                if island in (6, 13, 20, 27, 34, 41, 48, 55):
                    g.enter_portal()
                else:
                    g.clear_island(island)
        o, n = sent_ids(OLD), sent_ids(NEW)
        if o != n:
            first = next((i for i, (a, b) in enumerate(zip(o, n)) if a != b), min(len(o), len(n)))
            check(False, "run checks differ at #%d: 1.4.0 %s, now %s" % (first, o[first:first + 3], n[first:first + 3]))
            return
        check(OLD.victories == NEW.victories, "goal: 1.4.0 sent %d, now %d" % (OLD.victories, NEW.victories))
    return len(sent_ids(NEW)), NEW.victories


def coverage(ids):
    """Every location of the seed is one the current client can send."""
    n = all_event_ids(NEW, "new")
    sendable = {v for v in n.values() if v is not None} | set(lua_list(NEW.LD.unfindable_location_ids()))
    missing = sorted(set(ids) - sendable)
    check(not missing, "seed locations the client can't send: %d, e.g. %s" % (len(missing), missing[:5]))


def run_seed(label, slot_data, ids, item_ids):
    connect_both(slot_data, ids)
    compare_exclusions()
    compare_gate_keys(set(ids))
    compare_granted_checks()
    coverage(ids)
    for item_id in item_ids:
        o, n = OLD.ID.from_ap_id(item_id), NEW.ID.from_ap_id(item_id)
        check(o is not None and n is not None and o.name == n.name,
              "%s: item %s doesn't resolve the same" % (label, item_id))
    result = play(slot_data, ids, runs=40, rng_seed=zlib.crc32(label.encode()))
    print("  %s: %d locations, %d items, %s checks sent / goal %s" % (
        label, len(ids), len(item_ids), *(result or ("?", "?"))))


# ---------------------------------------------------------------
# Seeds
# ---------------------------------------------------------------

def load_seed(path):
    ap_dir = os.environ.get("CRAB_AP_DIR")
    if not ap_dir:
        raise SystemExit("set CRAB_AP_DIR to an Archipelago checkout to read .archipelago files")
    if ap_dir not in sys.path:
        sys.path.insert(0, ap_dir)
    import Utils  # noqa: E402  (Archipelago)
    data = Utils.restricted_loads(zlib.decompress(Path(path).read_bytes()[1:]))
    for slot, info in data["slot_info"].items():
        if info.game == "Crab Champions":
            ids = sorted(data["locations"][slot].keys())
            items = sorted({it[0] for locs in data["locations"].values() for it in locs.values() if it[1] == slot}
                           | {it for it in data["precollected_items"].get(slot, [])})
            yield "%s/%s" % (Path(path).stem, info.name), data["slot_data"][slot], ids, items


def builtin_seeds():
    """Option sets without a seed: every location the 1.4.0 client can compute is in play."""
    o = all_event_ids(OLD, "old")
    ids = sorted({v for v in o.values() if v is not None} - {1890000})
    base = {"required_rank": 0, "max_rank": 3, "extra_rank_checks": 0, "extra_ranked_island_checks": False,
            "non_progression_above_required": False, "cascade_ranked_checks": False, "run_length": 28,
            "pool_only_completion": True, "weapons_for_completion": 2, "melee_for_completion": 0,
            "ability_for_completion": 0, "pool_weapons": ["Auto Rifle", "Sniper", "Crossbow"],
            "pool_melee": [], "pool_abilities": [], "equipment_check_mode": 0, "greed_item_mode": 2,
            "pickup_checks": True, "limit_pickup_pool": False, "limit_pickup_locations": False,
            "pickup_subsets": {}, "progressive_slots": False}
    yield "builtin-default", {"options": base, "id_layout": 1}, ids, []
    full = dict(base, run_length=56, extra_rank_checks=1, extra_ranked_island_checks=True,
                cascade_ranked_checks=True, max_rank=7, required_rank=2, greed_item_mode=0,
                pool_melee=["Hammer"], melee_for_completion=1)
    yield "builtin-full-ranked", {"options": full, "id_layout": 1}, ids, []
    # Before 1.4.0: no id_layout, no pool_only_completion
    pre = {k: v for k, v in base.items() if k != "pool_only_completion"}
    yield "builtin-pre-1.4", {"options": pre}, ids, []
    subset = dict(base, limit_pickup_locations=True,
                  pickup_subsets={"perk": ["All You Can Eat", "Banana"], "relic": ["Twin Ring"],
                                  "weapon_mod": [], "melee_mod": [], "ability_mod": ["Aura Explosion"]})
    yield "builtin-subset", {"options": subset, "id_layout": 1}, ids, []


def main():
    compare_items()
    compare_location_ids()
    paths = [a for a in sys.argv[1:] if a.endswith(".archipelago")]
    seed_dir = os.environ.get("CRAB_OLD_SEEDS")
    if seed_dir:
        paths += [str(p) for p in Path(seed_dir).rglob("*.archipelago")]
    print("Built-in option sets:")
    for seed in builtin_seeds():
        run_seed(*seed)
    if paths:
        print("Seeds:")
        for path in paths:
            for seed in load_seed(path):
                check((seed[1].get("id_layout") or 1) == 1, "%s is not an ID layout 1 seed" % seed[0])
                run_seed(*seed)
    if failures:
        print("%d failure(s)" % len(failures))
        sys.exit(1)
    print("old world tests passed")


main()
