"""Check the clickable Connect button and the pause menu's Archipelago button.

Runs ClickWatch.lua, APOverlay.lua and PauseButton.lua against small stand-in
widgets (fake UObjects with parents, children, press and hover state), so the
click detection, the connect path and the menu layout handling can be checked
without the game.

    pip install lupa
    python tools/test_click.py
"""
import sys
from pathlib import Path

from lupa import LuaRuntime

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = (REPO / "CrabChampionsAP/Scripts").as_posix()

LUA_SETUP = r"""
package.path = "@SCRIPTS@/?.lua;" .. package.path
print = function() end
clock = 0
os.clock = function() return clock end
loops = {}
function LoopAsync(ms, fn) loops[#loops + 1] = fn end
function run_loops(n)
    for _ = 1, (n or 2) do
        local keep = {}
        for _, fn in ipairs(loops) do
            if not fn() then keep[#keep + 1] = fn end
        end
        loops = keep
    end
end

-- A field or method we do not model: callable (no-op), and its own fields exist too, like a struct's.
function placeholder()
    local mt = {}
    mt.__call = function() return nil end
    mt.__index = function(t, k)
        if type(k) == "string" and k:match("^%u") then
            local c = placeholder()
            rawset(t, k, c)
            return c
        end
        return nil
    end
    return setmetatable({}, mt)
end

-- Make a nested plain table behave like an engine struct (fields not given still exist).
function struct(t)
    for k, v in pairs(t) do
        if type(v) == "table" and getmetatable(v) == nil and not v.ToString then struct(v) end
    end
    return setmetatable(t, getmetatable(placeholder()))
end

-- Stand-in UObjects. Unknown methods are no-ops that return nil.
local next_addr = 1000
local Fake = {}
local methods = {}
Fake.__index = function(self, k)
    if methods[k] then return methods[k] end
    local p = rawget(self, "_props")[k]
    if p ~= nil then return p end
    if type(k) == "string" and k:match("^Set%u") then
        return function(self2, v) rawget(self2, "_props")[k:sub(4)] = v end
    end
    if type(k) == "string" and k:match("^%u") then
        -- a property or method we do not model: callable (no-op) and can hold fields
        local t = placeholder()
        rawget(self, "_props")[k] = t
        return t
    end
    return function() return nil end
end
Fake.__newindex = function(self, k, v) rawget(self, "_props")[k] = v end

function new_obj(cls, name, props)
    next_addr = next_addr + 1
    local o = setmetatable({ _cls = cls, _name = name, _addr = next_addr, _children = {}, _props = props or {},
                             _valid = true, _pressed = false, _hovered = false, _calls = {} }, Fake)
    return o
end
local function name_obj(s) return { ToString = function() return s end } end
function methods:IsValid() return rawget(self, "_valid") end
function methods:GetClass() local c = rawget(self, "_cls"); return { GetFName = function() return name_obj(c) end } end
function methods:GetFName() return name_obj(rawget(self, "_name")) end
function methods:GetAddress() return rawget(self, "_addr") end
function methods:GetParent() return rawget(self, "_parent") end
function methods:GetChildrenCount() return #rawget(self, "_children") end
function methods:GetChildAt(i) return rawget(self, "_children")[i + 1] end
function methods:GetContent() return rawget(self, "_children")[1] end
function methods:IsPressed() return rawget(self, "_pressed") end
function methods:IsHovered() return rawget(self, "_hovered") end
local function attach(parent, child)
    rawset(child, "_parent", parent)
    table.insert(rawget(parent, "_children"), child)
    local slot = new_obj("Slot", "slot", { Padding = { Left = 0, Top = 0, Right = 0, Bottom = 0 },
                                           HorizontalAlignment = 0 })
    rawget(child, "_props").Slot = slot
    return slot
end
function add_child(parent, child) return attach(parent, child) end
function methods:AddChild(c)
    if rawget(self, "_no_add") then error("AddChild not available") end
    return attach(self, c)
end
function methods:AddChildToVerticalBox(c) return attach(self, c) end
function methods:AddChildToHorizontalBox(c) return attach(self, c) end
function methods:AddChildToCanvas(c) attach(self, c); return { LayoutData = { Anchors = {}, Offsets = {} } } end
function methods:SetContent(c) rawset(self, "_children", {}); return attach(self, c) end
function methods:RemoveFromParent()
    local p = rawget(self, "_parent")
    if not p then return end
    local kids = rawget(p, "_children")
    for i, c in ipairs(kids) do if c == self then table.remove(kids, i) break end end
    rawset(self, "_parent", nil)
end
function methods:SetText(t) rawget(self, "_props").Text = t end
function methods:GetFullName() return rawget(self, "_cls") .. " /Game/" .. rawget(self, "_name") end
function methods:GetText() local t = rawget(self, "_props").Text; return { ToString = function() return t end } end
function methods:OnPressedResumeButton() rawget(self, "_calls").resume = (rawget(self, "_calls").resume or 0) + 1 end

StaticFindObject = function(path) return { _path = path, IsValid = function() return true end } end
constructed = {}
StaticConstructObject = function(cls, outer, name)
    local short = tostring(cls._path):match("%.([%w_]+)$") or "Object"
    local o = new_obj(short, name)
    constructed[#constructed + 1] = o
    return o
end
FName = function(s) return s end
FText = function(s) return s end
ExecuteInGameThread = function(fn) fn() end
test_pc = nil
FindFirstOf = function(c)
    if c == "GameInstance" then return new_obj("GameInstance", "gi") end
    if c == "CrabPC" then return test_pc end
    return nil
end

-- A pause menu shaped like the game's: buttons (with a TextBlock inside) in a VerticalBox.
game_font = new_obj("Font", "MenuFont")
function make_menu(opts)
    opts = opts or {}
    local menu = new_obj("WBP_InGameMenu_C", "InGameMenu")
    menu.WidgetTree = new_obj("WidgetTree", "WidgetTree")
    local box = new_obj(opts.box or "VerticalBox", "ButtonsBox")
    menu._box = box
    for _, f in ipairs({ "ResumeButton", "SettingsButton", "QuitToLobbyButton" }) do
        local clear = function() return { SpecifiedColor = { R = 1, G = 1, B = 1, A = 0 }, ColorUseRule = 0 } end
        local brush = function(a)
            return { TintColor = { SpecifiedColor = { R = 1, G = 0.8, B = 0.2, A = a }, ColorUseRule = 0 },
                     DrawAs = 0, ResourceName = { ToString = function() return "None" end },
                     Margin = { Left = 0, Top = 0, Right = 0, Bottom = 0 } }
        end
        local b = new_obj("Button", f, struct {
            WidgetStyle = { Normal = brush(0), Hovered = brush(0.3), Pressed = brush(0.5), Disabled = brush(0),
                            NormalForeground = clear(), NormalPadding = { Left = 12, Top = 2, Right = 12, Bottom = 2 } },
            ColorAndOpacity = { R = 1, G = 1, B = 1, A = 1 }, BackgroundColor = { R = 1, G = 1, B = 1, A = 1 },
        })
        local tb = new_obj("TextBlock", f .. "Text", struct {
            Font = { FontObject = game_font, TypefaceFontName = { ToString = function() return "Bold" end }, Size = 30,
                     LetterSpacing = 50, OutlineSettings = { OutlineSize = 2, OutlineColor = { R = 0, G = 0, B = 0, A = 1 } } },
            ColorAndOpacity = { SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 0 },
            Justification = 1,
        })
        tb:SetText(opts.lower and f:gsub("Button", "") or f:gsub("Button", ""):upper())
        b:SetContent(tb)
        if opts.wrap then
            local sb = new_obj("SizeBox", f .. "Size", { bOverride_WidthOverride = true, WidthOverride = 320 })
            sb:SetContent(b)
            add_child(box, sb)
        else
            local slot = add_child(box, b)
            slot.Padding = { Left = 0, Top = 8, Right = 0, Bottom = 8 }
            slot.HorizontalAlignment = 2
        end
        menu[f] = b
    end
    return menu
end
"""

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(LUA_SETUP.replace("@SCRIPTS@", SCRIPTS))
g = lua.globals()
lua.execute("require('AP/GameThread').loaded(); for _ = 1, 130 do run_loops() end")

problems = []


def check(label, cond, detail=""):
    if not cond:
        problems.append(f"{label} {detail}".strip())


CW = lua.execute("return (require('AP/ClickWatch'))")

# --- click edge -------------------------------------------------------------
check("release over button is a click", CW.edge(True, False, True) is True)
check("release off the button is not", CW.edge(True, False, False) is False)
check("still held is not", CW.edge(True, True, True) is False)
check("hover alone is not", CW.edge(False, False, True) is False)

# --- watch / step -------------------------------------------------------------
lua.execute("""
wbtn = new_obj("Button", "W")
wclicks = 0
wactive = true
require('AP/ClickWatch').watch("w", function() return wbtn end, function(src) wclicks = wclicks + 1; wsrc = src end,
    function() return wactive end)
""")


def press(btn, pressed, hovered=True):
    lua.execute(f"rawset({btn}, '_pressed', {str(pressed).lower()}); rawset({btn}, '_hovered', {str(hovered).lower()})")
    CW.step()


press("wbtn", True)
press("wbtn", True)
check("no click while held", g.wclicks == 0)
press("wbtn", False)
check("click on release", g.wclicks == 1 and g.wsrc == "pointer", str(g.wclicks))
press("wbtn", False)
check("one click per press", g.wclicks == 1)
press("wbtn", True)
press("wbtn", False, hovered=False)
check("dragged off: no click", g.wclicks == 1)
lua.execute("wactive = false")
press("wbtn", True)
lua.execute("wactive = true")
press("wbtn", False)
check("press while inactive does not count", g.wclicks == 1)
lua.execute("rawset(wbtn, '_valid', false)")
press("wbtn", True)
press("wbtn", False)
check("dead widget is ignored", g.wclicks == 1)
lua.execute("rawset(wbtn, '_valid', true)")
lua.execute("wbtn2 = wbtn; wbtn = nil")
CW.step()
check("missing widget is ignored", g.wclicks == 1)
CW.unwatch("w")
check("unwatch", not CW.watching("w"))

# --- the Connect button in the panel -------------------------------------------
O = lua.execute("return (require('AP/APOverlay'))")
O.create({"server": "127.0.0.1:1", "slot": "Crab", "password": ""})
check("overlay created", O.is_initialized())
s = O.get_shown()
check("connect button made", s["connect_button"] is True)
check("idle label", "Connect" in s["connect_btn_text"] and "Disconnect" not in s["connect_btn_text"],
      s["connect_btn_text"])
lua.execute("""
connect_calls = {}
require('AP/APOverlay').set_connect_handler(function(src) connect_calls[#connect_calls + 1] = src end)
cbtn = nil
for _, o in ipairs(constructed) do
    if rawget(o, "_name") == "APConnectButton" then cbtn = o end
end
""")
check("connect button found", g.cbtn is not None)
check("connect button not focusable", lua.eval("cbtn and rawget(cbtn, '_props').IsFocusable") is False)

# Panel closed: pressing the (hidden) button does nothing.
press("cbtn", True)
press("cbtn", False)
check("no click while panel closed", lua.eval("#connect_calls") == 0)

O.show_panel()
press("cbtn", True)
press("cbtn", False)
check("pointer click connects", lua.eval("#connect_calls") == 1 and lua.eval("connect_calls[1]") == "pointer")
s = O.get_shown()
check("readback names the source", s["connect_source"] == "pointer" and s["connect_requests"] == 1, str(dict(s)))
check("click counted", s["connect_clicks"] == 1)

# F3 goes through the same entry point.
O.request_connect("F3")
check("F3 same handler", lua.eval("#connect_calls") == 2 and lua.eval("connect_calls[2]") == "F3")

# The test/debug click runs the same action as the pointer.
O.click("connect")
check("test click same handler", lua.eval("#connect_calls") == 3 and lua.eval("connect_calls[3]") == "test")

# A failing handler does not break the watcher.
lua.execute("require('AP/APOverlay').set_connect_handler(function() error('boom') end)")
press("cbtn", True)
press("cbtn", False)
lua.execute("""require('AP/APOverlay').set_connect_handler(function(src)
    connect_calls[#connect_calls + 1] = src end)""")
press("cbtn", True)
press("cbtn", False)
check("watcher survives a failing handler", lua.eval("#connect_calls") == 4)

# Labels follow the state.
O.set_connecting("127.0.0.1:1")
check("connecting label", "try again" in O.get_shown()["connect_btn_text"])
O.set_connected("Crab")
check("connected label", "Disconnect" in O.get_shown()["connect_btn_text"])
O.hide_panel()
press("cbtn", True)
press("cbtn", False)
check("no click after closing", lua.eval("#connect_calls") == 4)

# --- pause menu button -----------------------------------------------------------
PB = lua.execute("return (require('AP/PauseButton'))")
lua.execute("opened = 0")
PB.install(lua.eval("function() opened = opened + 1 end"))


def menu_case(opts_lua):
    lua.execute(f"menu = make_menu({opts_lua}); test_pc = new_obj('CrabPC', 'pc', {{InGameMenuUI = menu}})")


def box_names():
    return lua.eval("""(function()
        local out = {}
        for i, c in ipairs(rawget(menu._box, '_children')) do out[i] = rawget(c, '_name') end
        return table.concat(out, ',') end)()""")


# No controller / no menu: nothing happens.
lua.execute("test_pc = nil")
PB.tick()
check("no pc: no button", PB.state()["button"] is False)

menu_case("{}")
PB.tick()
st = PB.state()
check("button added", st["button"] is True and st["box_class"] == "VerticalBox", str(dict(st)))
names = box_names()
check("appended to the box", names.split(",")[-1].startswith("APArchipelagoButton") and names.count("AP") == 1,
      names)
check("upper-case label like the menu",
      lua.eval("rawget(rawget(menu._box, '_children')[4], '_children')[1]:GetText():ToString()") == "ARCHIPELAGO")
diff = lua.eval("(function() local d = require('AP/PauseButton').compare(); return d and table.concat(d, ',') end)()")
check("looks like Resume (style, font, text and row slot)", diff == "", str(diff))
check("font copied field by field",
      lua.eval("rawget(rawget(menu._box, '_children')[4], '_children')[1].Font.Size") == 30)
check("see-through brush copied",
      lua.eval("rawget(rawget(menu._box, '_children')[4], '_props').WidgetStyle.Normal.TintColor.SpecifiedColor.A") == 0)
check("row spacing copied", lua.eval("rawget(rawget(menu._box, '_children')[4], '_props').Slot.Padding.Top") == 8)
lua.execute("rawget(rawget(menu._box, '_children')[4], '_props').WidgetStyle.Hovered.TintColor.SpecifiedColor.A = 0.9")
diff = lua.eval("(function() local d = require('AP/PauseButton').compare(); return d and table.concat(d, ',') end)()")
check("compare notices a difference", "button.WidgetStyle.Hovered.TintColor.SpecifiedColor.A" in str(diff), str(diff))
lua.execute("rawget(rawget(menu._box, '_children')[4], '_props').WidgetStyle.Hovered.TintColor.SpecifiedColor.A = 0.3")
PB.tick()
PB.tick()
check("added once", box_names().count("APArchipelago") == 1, box_names())

# Clicking it: game's Resume, then the window opens. Only read while the menu is on screen.
lua.execute("pbtn = rawget(menu._box, '_children')[4]")
lua.execute("rawget(menu, '_props').IsInViewport = function() return false end")
PB.tick()
press("pbtn", True)
press("pbtn", False)
check("menu closed: no click", lua.eval("rawget(menu, '_calls').resume") is None)
lua.execute("rawget(menu, '_props').IsInViewport = function() return true end")
PB.tick()
check("menu up", PB.state()["menu_up"] is True)
press("pbtn", True)
press("pbtn", False)
check("resume pressed", lua.eval("rawget(menu, '_calls').resume") == 1)
lua.execute("clock = clock + 1; run_loops()")
check("window opened", g.opened == 1, str(g.opened))
check("pause click counted", PB.state()["clicks"] == 1)

# Remove, then the next check puts it back.
check("remove", PB.remove() is True and "APArchipelago" not in box_names(), box_names())
PB.tick()
check("re-added after remove", box_names().count("APArchipelago") == 1, box_names())

# A new menu instance (new level) gets its own button.
menu_case("{lower = true}")
PB.tick()
check("new menu gets a button", box_names().count("APArchipelago") == 1, box_names())
check("label case follows the menu",
      lua.eval("rawget(rawget(menu._box, '_children')[4], '_children')[1]:GetText():ToString()") == "Archipelago")

# Left over from an earlier load of the mod: reused, not doubled.
lua.execute("menu = make_menu({}); add_child(menu._box, new_obj('Button', 'APArchipelagoButton_9_9'))"
            "; test_pc = new_obj('CrabPC', 'pc', {InGameMenuUI = menu})")
PB.tick()
st = PB.state()
check("existing button reused", st["adopted"] is True and box_names().count("APArchipelago") == 1,
      f"{dict(st)} {box_names()}")

# Buttons inside SizeBoxes: the copy gets a SizeBox too.
menu_case("{wrap = true}")
PB.tick()
last = lua.eval("rawget(rawget(menu._box, '_children')[4], '_cls')")
check("wrapped like the others", last == "SizeBox", str(last))
check("wrapper keeps the width", lua.eval("rawget(rawget(menu._box, '_children')[4], '_props').WidthOverride") == 320)

# Unexpected layouts: nothing added, no error, and it gives up for that menu.
menu_case("{box = 'CanvasPanel'}")
PB.tick()
st = PB.state()
check("canvas layout: not added", st["button"] is False and st["gave_up"] is not None, str(dict(st)))
check("canvas layout: box untouched", "APArchipelago" not in box_names(), box_names())
PB.tick()
check("gives up once", PB.state()["tries"] == 1, str(PB.state()["tries"]))

lua.execute("menu = new_obj('WBP_InGameMenu_C', 'Empty'); test_pc = new_obj('CrabPC', 'pc', {InGameMenuUI = menu})")
for _ in range(3):
    PB.tick()
st = PB.state()
check("menu without buttons: retries, nothing added", st["button"] is False and st["tries"] == 3
      and st["gave_up"] is None, str(dict(st)))
for _ in range(10):
    PB.tick()
check("menu without buttons: stops retrying", PB.state()["gave_up"] is not None)

lua.execute("menu = make_menu({}); rawset(menu._box, '_no_add', true)"
            "; test_pc = new_obj('CrabPC', 'pc', {InGameMenuUI = menu})")
PB.tick()
check("add failure is caught", PB.state()["button"] is False and PB.state()["gave_up"] is not None)

# Uninstall takes it out.
menu_case("{}")
PB.tick()
check("present before uninstall", "APArchipelago" in box_names())
PB.uninstall()
check("uninstall removes it", "APArchipelago" not in box_names(), box_names())
PB.tick()
check("stays out after uninstall", "APArchipelago" not in box_names(), box_names())

if problems:
    print("FAILED:")
    for p in problems:
        print("  -", p)
    sys.exit(1)
print("Click paths OK")
