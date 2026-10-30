-- AP/ClickWatch.lua
-- Mouse clicks on UMG buttons the mod creates.
--
-- UE4SS 3.0.1 cannot bind a Lua function to a button's OnClicked event, so each watched button is read once per
-- frame on the game thread (GameThread.loop(0, ...)): a click is a press that ends while the pointer is still over
-- the button, which is what UMG itself counts as a click. Buttons are only read while their `active` check says
-- so (panel open, menu up), and an error reading one never stops the others.

local GameThread = require("AP/GameThread")

local ClickWatch = {}

local function log(msg) print("[CrabAP-Click] " .. tostring(msg) .. "\n") end

local entries = {}     -- name -> { get = fn -> widget|nil, on_click = fn, active = fn|nil, was_pressed = bool }
local loop = nil
ClickWatch.counts = {} -- name -> clicks seen (pointer and test clicks alike)

--- True when this frame's reading ends a press over the button.
function ClickWatch.edge(was_pressed, pressed, hovered)
    return was_pressed == true and pressed ~= true and hovered == true
end

local function read(btn)
    local ok, valid = pcall(function() return btn:IsValid() end)
    if not ok or not valid then return nil, nil end
    local okp, pressed = pcall(function() return btn:IsPressed() end)
    local okh, hovered = pcall(function() return btn:IsHovered() end)
    return okp and pressed == true, okh and hovered == true
end

--- Run a button's click action now, the same way a pointer click does.
function ClickWatch.fire(name, source)
    local e = entries[name]
    if not e then return false end
    ClickWatch.counts[name] = (ClickWatch.counts[name] or 0) + 1
    log(name .. " clicked (" .. tostring(source or "pointer") .. ")")
    local ok, err = pcall(e.on_click, source or "pointer")
    if not ok then log(name .. " click failed: " .. tostring(err)) end
    return ok
end

--- One reading of every active button. Exposed for tests.
function ClickWatch.step()
    for name, e in pairs(entries) do
        local on = true
        if e.active then
            local ok, r = pcall(e.active)
            on = ok and r == true
        end
        local btn = nil
        if on then
            local ok, w = pcall(e.get)
            btn = ok and w or nil
        end
        local pressed, hovered = nil, nil
        if btn then pressed, hovered = read(btn) end
        if pressed == nil then
            e.was_pressed = false
        else
            local click = ClickWatch.edge(e.was_pressed, pressed, hovered)
            e.was_pressed = pressed
            if click then ClickWatch.fire(name, "pointer") end
        end
    end
end

local function ensure_loop()
    if loop then return end
    loop = GameThread.loop(0, function()
        if next(entries) == nil then loop = nil return true end
        ClickWatch.step()
        return false
    end)
end

--- Watch a button. `get` returns the live button widget (or nil), `active` (optional) says when to read it,
--- `on_click(source)` runs on the game thread. Watching the same name again replaces it.
function ClickWatch.watch(name, get, on_click, active)
    entries[name] = { get = get, on_click = on_click, active = active, was_pressed = false }
    ensure_loop()
end

function ClickWatch.unwatch(name)
    entries[name] = nil
end

function ClickWatch.watching(name)
    return entries[name] ~= nil
end

return ClickWatch
