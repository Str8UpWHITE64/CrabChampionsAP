"""Offline test for Biome Lock (BiomeLock.lua).

Runs the module against a small model of the game's biome handling: data assets that carry a biome number, a game
state with a biome order, and a Biome portal that reads the next biome from that order the way the game does
(the entry after the current biome, the first entry if the current biome is missing, a failure past the end).
Checks the starting-biome renumbering, the next-biome steering for every combination of owned biomes, the loop that
rebuilds the order, the HUD name and the Access items.

    pip install lupa
    python tools/test_biome_lock.py
"""
import itertools
from pathlib import Path

from lupa import LuaRuntime

REPO = Path(__file__).resolve().parent.parent

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().OBJCACHE_SRC = (REPO / "CrabChampionsAP/Scripts/AP/ObjCache.lua").read_text(encoding="utf-8")
lua.execute('package.preload["AP/ObjCache"] = load(OBJCACHE_SRC, "@AP/ObjCache.lua")')
lua.execute("""
print = function() end
function mkarr(t)
    local data = { table.unpack(t) }
    return setmetatable({}, { __index = function(_, k)
            if k == "GetArrayNum" then return function() return #data end end
            return data[k]
        end, __newindex = function(_, k, v) data[k] = v end })
end
function arr_list(a) local out = {} for i = 1, a:GetArrayNum() do out[i] = a[i] end return out end

NAMES = { "Tropical", "Arctic", "Desert", "Volcanic" }   -- the game's own asset names
function mkworld()
    local w = { das = {}, texts = {} }
    for real, n in ipairs(NAMES) do
        w.das[real] = { Biome = real, IsValid = function() return true end,
                        GetFullName = function() return "CrabBiomeDA /Game/Blueprint/DataAsset/DA_Biome_" .. n .. ".DA_Biome_" .. n end }
    end
    w.gs = { Biome = 1, CurrentIsland = 0, BiomeOrder = mkarr({}), IsValid = function() return true end }
    w.block = { IsValid = function() return true end, text = "Tropical" }
    w.ui = { IsValid = function() return true end, BiomeText = w.block }
    return w
end

function install(M, w)
    M.game.gs = function() return w.gs end
    M.game.biome_assets = function()
        local out = {}
        for real, da in ipairs(w.das) do out[#out + 1] = { real = real, da = da } end
        return out
    end
    M.game.hud_widgets = function() return { w.ui } end
    M.game.get_text = function(b) return b.text end
    M.game.set_text = function(b, t) b.text = t return true end
end

-- Real biome shown by the asset that carries `label`.
function real_of(w, label)
    for real, da in ipairs(w.das) do if da.Biome == label then return real end end
end

-- The game's new-run setup: order [1,2,3,4], biome 1, island 1.
function new_run(w)
    w.gs.BiomeOrder = mkarr({ 1, 2, 3, 4 })
    w.gs.Biome = 1
    w.gs.CurrentIsland = 1
end

-- The Biome portal: next biome from the order. Returns the real biome entered, or nil and a reason.
function biome_portal(w)
    local order = arr_list(w.gs.BiomeOrder)
    local idx
    for i, v in ipairs(order) do if v == w.gs.Biome then idx = i break end end
    local nxt = idx and order[idx + 1] or (not idx) and order[1] or nil
    if nxt == nil then return nil, "read past the end of the order" end
    w.gs.Biome = nxt
    return real_of(w, nxt)
end
function portal(w)
    local real, why = biome_portal(w)
    return { real = real, why = why }
end
""")

src = (REPO / "CrabChampionsAP/Scripts/AP/BiomeLock.lua").read_text(encoding="utf-8")
problems = []


def expect(label, got, want):
    if got != want:
        problems.append(f"{label}: expected {want!r}, got {got!r}")


def fresh():
    mod = lua.execute(src)
    w = lua.eval("mkworld()")
    lua.globals().install(mod, w)
    return mod, w


def order(w):
    return list(lua.globals().arr_list(w.gs.BiomeOrder).values())


def labels(w):
    return [w.das[i].Biome for i in range(1, 5)]


# --- renumbering -------------------------------------------------------------------------------------------------
for start, want in {1: [1, 2, 3, 4], 2: [2, 1, 3, 4], 3: [3, 2, 1, 4], 4: [4, 2, 3, 1]}.items():
    mod, w = fresh()
    mod.configure(lua.table(biome_lock=True, starting_biome=start), False)
    expect(f"labels for start {start}", labels(w), want)
    expect(f"start {start} answers to 1", lua.globals().real_of(w, 1), start)
    expect(f"start {start} owned", mod.is_owned(start), True)

mod, w = fresh()
mod.configure(lua.table(biome_lock=False, starting_biome=2), False)
expect("lock off leaves labels", labels(w), [1, 2, 3, 4])
expect("lock off is inactive", mod.is_active(), False)
mod.configure(lua.table(biome_lock=True, starting_biome=0), False)
expect("bad start biome is inactive", mod.is_active(), False)
mod.configure(lua.table(), False)
expect("missing options are inactive", mod.is_active(), False)

mod, w = fresh()
mod.configure(lua.table(biome_lock=True, starting_biome=3), False)
mod.deactivate()
expect("deactivate restores labels", labels(w), [1, 2, 3, 4])
expect("deactivate turns the lock off", mod.is_active(), False)

# mid-run: the numbers are left alone until the lobby
mod, w = fresh()
w.gs.CurrentIsland = 5
mod.configure(lua.table(biome_lock=True, starting_biome=2), False)
expect("mid-run configure leaves labels", labels(w), [1, 2, 3, 4])
w.gs.CurrentIsland = 0
mod.tick()
expect("lobby tick applies labels", labels(w), [2, 1, 3, 4])
w.das[3].Biome = 2
w.das[2].Biome = 3
for _ in range(4):
    mod.tick()
expect("lobby tick repairs wrong labels", labels(w), [2, 1, 3, 4])

# disconnect mid-run keeps the numbers (a reconnect continues the run); the lobby puts them back
mod, w = fresh()
mod.configure(lua.table(biome_lock=True, starting_biome=2), False)
lua.globals().new_run(w)
mod.deactivate()
expect("mid-run disconnect keeps labels", labels(w), [2, 1, 3, 4])
mod.tick()
expect("still in the run: labels kept", labels(w), [2, 1, 3, 4])
mod.configure(lua.table(biome_lock=True, starting_biome=2), True)
expect("reconnect in the run keeps labels", labels(w), [2, 1, 3, 4])
mod.deactivate()
w.gs.CurrentIsland = 0
mod.tick()
expect("lobby restores labels after a disconnect", labels(w), [1, 2, 3, 4])
mod.configure(lua.table(biome_lock=True, starting_biome=2), False)
expect("lobby connect renumbers again", labels(w), [2, 1, 3, 4])

# --- Access items ------------------------------------------------------------------------------------------------
mod, w = fresh()
mod.configure(lua.table(biome_lock=True, starting_biome=2), False)
expect("only the start is owned", [mod.is_owned(i) for i in range(1, 5)], [False, True, False, False])
expect("access item handled", mod.on_item(lua.table(name="Desert Access")), True)
expect("desert owned", mod.is_owned(3), True)
expect("other items not handled", mod.on_item(lua.table(name="Crystal Cache")), False)
expect("nil info not handled", mod.on_item(None), False)
mod.configure(lua.table(biome_lock=True, starting_biome=2), True)
expect("reconnect keeps items", mod.is_owned(3), True)
mod.configure(lua.table(biome_lock=True, starting_biome=2), False)
expect("new session forgets items", mod.is_owned(3), False)

# the client's item table resolves the four Access items, and the module takes them
itemdata = lua.execute((REPO / "CrabChampionsAP/Scripts/AP/ItemData.lua").read_text(encoding="utf-8"))
mod, w = fresh()
mod.configure(lua.table(biome_lock=True, starting_biome=1), False)
for i, name in enumerate(["Tropical", "Ice", "Desert", "Volcano"]):
    info = itemdata.from_ap_id(1890980 + i)
    expect(f"{name} Access resolves", info.name if info else None, f"{name} Access")
    expect(f"{name} Access category", info.cat if info else None, itemdata.CATEGORY.BIOME)
    expect(f"{name} Access taken by the module", mod.on_item(info), True)
    expect(f"{name} owned", mod.is_owned(i + 1), True)

# --- the asset lookup, with the game's real asset names ----------------------------------------------------------------
# No test double for biome_assets here: the module finds the assets through FindAllOf by the name DA_Biome_<game name>.
lua.execute("""
function FindAllOf(class)
    if class ~= "CrabBiomeDA" then return nil end
    local out = {}
    for real, n in ipairs({ "Volcanic", "Desert", "Arctic", "Tropical", "Default__" }) do
        out[#out + 1] = { IsValid = function() return true end,
                          GetFullName = function() return "CrabBiomeDA /Game/Blueprint/DataAsset/DA_Biome_" .. n .. ".DA_Biome_" .. n end }
    end
    return out
end
""")
mod = lua.execute(src)
found = mod.game.biome_assets()
expect("four biome assets found by their game names", len(found), 4)
expect("assets map to biome numbers", sorted(found[i].real for i in range(1, len(found) + 1)), [1, 2, 3, 4])
lua.execute("FindAllOf = nil")

# --- steering, hand-picked cases ---------------------------------------------------------------------------------
# Only Ice (start): labels Ice 1, Tropical 2, Desert 3, Volcano 4. Next biome is Ice again.
mod, w = fresh()
mod.configure(lua.table(biome_lock=True, starting_biome=2), False)
lua.globals().new_run(w)
expect("steer rewrites a locked successor", mod.steer(), True)
expect("single biome repeats", order(w), [1, 1, 2, 3])
expect("steer is stable", mod.steer(), False)
r = lua.globals().portal(w)
real, why = r.real, r.why
expect("portal enters Ice again", real, 2)

# An Access item received mid-biome replaces the repeat.
mod.on_item(lua.table(name="Desert Access"))
w.gs.Biome = 1
expect("new access replaces a repeat", mod.steer(), True)
expect("repeat gives way to Desert", order(w)[:2], [1, 3])
expect("then it is stable", mod.steer(), False)

# Ice + Volcano: from Ice go to Volcano, from Volcano back to Ice.
mod, w = fresh()
mod.configure(lua.table(biome_lock=True, starting_biome=2), False)
mod.on_item(lua.table(name="Volcano Access"))
lua.globals().new_run(w)
mod.steer()
expect("skips locked biomes", order(w), [1, 4, 2, 3])
r = lua.globals().portal(w)
real, why = r.real, r.why
expect("portal enters Volcano", real, 4)
expect("current biome is last: rewritten", mod.steer(), True)
expect("back to the start biome", order(w)[:2], [4, 1])
r = lua.globals().portal(w)
real, why = r.real, r.why
expect("portal enters Ice", real, 2)

# Everything owned: the game's own order is left alone, except when the current biome is last.
mod, w = fresh()
mod.configure(lua.table(biome_lock=True, starting_biome=1), False)
for n in ("Ice", "Desert", "Volcano"):
    mod.on_item(lua.table(name=n + " Access"))
lua.globals().new_run(w)
expect("all owned: no rewrite", mod.steer(), False)
expect("all owned: order untouched", order(w), [1, 2, 3, 4])
w.gs.Biome = 4
expect("last entry is rewritten", mod.steer(), True)
expect("last entry is not last any more", order(w)[-1] != 4, True)
r = lua.globals().portal(w)
real, why = r.real, r.why
expect("portal after the last entry works", real, 1)

# The current biome missing from the order: the game takes the first entry, which must be owned.
mod, w = fresh()
mod.configure(lua.table(biome_lock=True, starting_biome=1), False)
lua.globals().new_run(w)
w.gs.BiomeOrder = lua.eval("mkarr({ 3, 2, 4, 2 })")
expect("missing current biome is rewritten", mod.steer(), True)
expect("current biome first", order(w)[:2], [1, 1])

# Arrays of other lengths and a failing write do not raise.
mod, w = fresh()
mod.configure(lua.table(biome_lock=True, starting_biome=1), False)
w.gs.CurrentIsland = 1
w.gs.BiomeOrder = lua.eval("mkarr({ 1 })")
expect("one-entry order is left alone", mod.steer(), False)
w.gs.BiomeOrder = lua.eval("mkarr({})")
expect("empty order is left alone", mod.steer(), False)

# --- HUD ---------------------------------------------------------------------------------------------------------
mod, w = fresh()
mod.configure(lua.table(biome_lock=True, starting_biome=2), False)
lua.globals().new_run(w)
w.block.text = "Tropical"          # what the game shows for number 1
expect("hud changes", mod.update_hud(), 1)
expect("hud shows the real biome", w.block.text, "Arctic")
expect("hud second pass changes nothing", mod.update_hud(), 0)
w.block.text = "ARCTIC"
expect("hud ignores case", mod.update_hud(), 0)
w.gs.Biome = 2                     # number 2 is Tropical now
mod.update_hud()
expect("hud follows the biome", w.block.text, "Tropical")

# --- tick ---------------------------------------------------------------------------------------------------------
mod, w = fresh()
mod.configure(lua.table(biome_lock=True, starting_biome=4), False)
lua.globals().new_run(w)
w.block.text = "Tropical"
mod.tick()
expect("tick steers", order(w), [1, 1, 2, 3])
expect("tick sets the hud", w.block.text, "Volcanic")
mod.deactivate()
w.gs.BiomeOrder = lua.eval("mkarr({ 1, 2, 3, 4 })")
mod.tick()
expect("inactive tick does nothing", order(w), [1, 2, 3, 4])

# --- every combination: a run never enters a locked biome and never reads past the order -----------------------
checked = 0
for start in range(1, 5):
    others = [b for b in range(1, 5) if b != start]
    for k in range(len(others) + 1):
        for extra in itertools.combinations(others, k):
            mod, w = fresh()
            mod.configure(lua.table(biome_lock=True, starting_biome=start), False)
            for b in extra:
                mod.on_item(lua.table(name=lua.globals().NAMES[b] + " Access"))
            owned = {start, *extra}
            lua.globals().new_run(w)
            entered = [lua.globals().real_of(w, 1)]
            expect(f"start {start}/{extra}: run begins in the start biome", entered[0], start)
            # 3 loops of 4 biome changes; the game rebuilds the order at the loop and the new-run setup.
            for step in range(12):
                mod.tick()
                r = lua.globals().portal(w)
                real, why = r.real, r.why
                if real is None:
                    problems.append(f"start {start}/{extra} step {step}: {why}")
                    break
                entered.append(real)
                if step % 4 == 3:
                    lua.globals().new_run(w)       # island 29: the game builds the run's order again
                    entered[-1] = lua.globals().real_of(w, 1)
            for biome in entered:
                if biome not in owned:
                    problems.append(f"start {start}/{extra}: entered locked biome {biome}: {entered}")
                    break
            checked += 1
expect("combinations checked", checked, 32)

if problems:
    print("FAILED:")
    for p in problems:
        print("  " + p)
    raise SystemExit(1)
print("biome lock tests passed")
