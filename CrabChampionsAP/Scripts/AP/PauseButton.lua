-- AP/PauseButton.lua
-- An "Archipelago" button in the game's pause menu (CrabInGameMenuUI) that opens the connection window.
--
-- The menu is the game's own widget, so this module only reads it, with one exception: it adds a single Button
-- (made here, styled like the menu's Resume button) to the panel that holds Resume. Nothing else in the menu is
-- changed, and the button is never added to the menu's gamepad/keyboard navigation list, so it is a mouse-only
-- control. When the layout is not the expected one (Resume missing, or not in a vertical, horizontal, wrap or
-- scroll box), nothing is added and one line is logged.
--
-- Clicking it presses the menu's own Resume (the game closes the menu and gives the input back) and then opens
-- the connection window, which turns the pointer on for itself.

local GameThread = require("AP/GameThread")
local ClickWatch = require("AP/ClickWatch")

local M = {}

local function log(msg) print("[CrabAP-PauseButton] " .. tostring(msg) .. "\n") end

local BUTTON_PREFIX = "APArchipelagoButton"
local LABEL = "Archipelago"
local WATCH_MS = 250
local MAX_TRIES = 8             -- per menu instance, while its widgets are still being built

-- The pause menu's buttons, in the order to try one as the style template.
M.TEMPLATE_FIELDS = { "ResumeButton", "SettingsButton", "QuitToLobbyButton", "QuitToDesktopButton" }
-- Panels a child can be appended to and land in a sensible place.
M.BOX_CLASSES = { VerticalBox = true, HorizontalBox = true, WrapBox = true, ScrollBox = true }
-- Single-child wrappers between a button and its box that are copied along with it.
M.WRAPPER_CLASSES = { SizeBox = true }

local state = {
    menu = nil, menu_addr = nil, -- the menu instance the button belongs to
    button = nil, row = nil,     -- our Button, and what was added to the box (the Button or a SizeBox around it)
    tries = 0, gave_up = nil,    -- reason, when this menu's layout was not usable
    box_class = nil, template = nil, added = 0, adopted = false,
}
local opener = nil              -- function(): opens the connection window
local find_pc = function() return FindFirstOf("CrabPC") end
local name_counter = 0
local loop = nil
local enabled = false

local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

local function try(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function class_name(o)
    return try(function() return o:GetClass():GetFName():ToString() end)
end

local function obj_name(o)
    return try(function() return o:GetFName():ToString() end)
end

local function addr(o)
    return try(function() return o:GetAddress() end)
end

--- Walk up from the template button to the box that lists the menu's buttons.
--- Returns box, row (the box's direct child holding the button), wrapper (row when it is a copyable wrapper) or nil
--- and a reason.
function M.find_box(button)
    local row = button
    for _ = 1, 4 do
        local parent = try(function() return row:GetParent() end)
        if not valid(parent) then return nil, "no parent above " .. tostring(class_name(row)) end
        local cls = class_name(parent)
        if cls and M.BOX_CLASSES[cls] then
            local wrapper = nil
            if addr(row) ~= addr(button) then wrapper = row end
            return parent, row, wrapper
        end
        row = parent
    end
    return nil, "no box within 4 levels"
end

--- The first TextBlock inside a widget (depth first, a few levels), or nil.
function M.find_text(w, depth)
    depth = depth or 0
    if not valid(w) or depth > 4 then return nil end
    if class_name(w) == "TextBlock" then return w end
    local n = tonumber(try(function() return w:GetChildrenCount() end)) or 0
    for i = 0, math.min(n, 8) - 1 do
        local found = M.find_text(try(function() return w:GetChildAt(i) end), depth + 1)
        if found then return found end
    end
    return nil
end

--- The label in the same case the menu uses ("ARCHIPELAGO" when Resume reads "RESUME").
function M.label_like(template_text)
    if type(template_text) == "string" and template_text:find("%a")
        and template_text == template_text:upper() then
        return LABEL:upper()
    end
    return LABEL
end

local function make(class_path, outer, name)
    local cls = StaticFindObject(class_path)
    if not valid(cls) then return nil end
    return StaticConstructObject(cls, outer, FName(name))
end

-- ----------------------------------------------------------------------------------------------------------------
-- Copying the look. UE4SS 3.0.1 does not copy a whole struct read from one widget into another (SetStyle(other's
-- WidgetStyle), SetFont(other's Font) and SetPadding(other's Padding) leave the defaults), so every field is copied
-- one by one, following these layouts. A field the engine version does not have is skipped.
-- ----------------------------------------------------------------------------------------------------------------
local COLOR = { "R", "G", "B", "A" }
local VEC2 = { "X", "Y" }
local MARGIN = { "Left", "Top", "Right", "Bottom" }
local SLATE_COLOR = { SpecifiedColor = COLOR, ColorUseRule = true }
local BRUSH = {
    ImageSize = VEC2, Margin = MARGIN, TintColor = SLATE_COLOR, ResourceObject = true, ResourceName = true,
    UVRegion = { Min = VEC2, Max = VEC2, bIsValid = true }, DrawAs = true, Tiling = true, Mirroring = true,
    ImageType = true, bIsDynamicallyLoaded = true,
    OutlineSettings = { CornerRadii = { "X", "Y", "Z", "W" }, Color = SLATE_COLOR, Width = true, RoundingType = true,
                        bUseBrushTransparency = true },
}
local SOUND = { Resource = true }
M.BUTTON_LOOK = {
    WidgetStyle = {
        Normal = BRUSH, Hovered = BRUSH, Pressed = BRUSH, Disabled = BRUSH,
        NormalForeground = SLATE_COLOR, HoveredForeground = SLATE_COLOR, PressedForeground = SLATE_COLOR,
        DisabledForeground = SLATE_COLOR, NormalPadding = MARGIN, PressedPadding = MARGIN,
        PressedSlateSound = SOUND, HoveredSlateSound = SOUND,
    },
    ColorAndOpacity = COLOR, BackgroundColor = COLOR,
    ClickMethod = true, TouchMethod = true, PressMethod = true,
}
M.TEXT_LOOK = {
    Font = {
        FontObject = true, FontMaterial = true, TypefaceFontName = true, Size = true, LetterSpacing = true,
        SkewAmount = true, bForceMonospaced = true, bMaterialIsStencil = true, MonospacedWidth = true,
        OutlineSettings = { OutlineSize = true, bSeparateFillAlpha = true, bApplyOutlineToDropShadows = true,
                            OutlineMaterial = true, OutlineColor = COLOR },
    },
    ColorAndOpacity = SLATE_COLOR, ShadowOffset = VEC2, ShadowColorAndOpacity = COLOR,
    Justification = true, TextTransformPolicy = true, MinDesiredWidth = true, AutoWrapText = true,
    LineHeightPercentage = true, Margin = MARGIN,
}
M.SLOT_LOOK = {
    Padding = MARGIN, Size = { SizeRule = true, Value = true }, HorizontalAlignment = true, VerticalAlignment = true,
}

local OBJECT_FIELDS = { ResourceObject = true, FontObject = true, FontMaterial = true, OutlineMaterial = true,
                        Resource = true }

local function is_leaf_list(schema) return schema[1] ~= nil end

local function is_struct(v) return v ~= nil and type(v) ~= "number" and type(v) ~= "boolean" and type(v) ~= "string" end

--- Copy every field in `schema` from src to dst (widgets or struct references), one leaf at a time.
--- Returns how many leaves were written.
function M.copy_fields(src, dst, schema)
    local n = 0
    local function leaf(s, d, k)
        local ok, v = pcall(function() return s[k] end)
        if not ok then return end
        -- an empty object reference (no texture, no material) is copied as empty, not left at our default
        if v == nil and not OBJECT_FIELDS[k] then return end
        if pcall(function() d[k] = v end) then n = n + 1 end
    end
    local function walk(s, d, sch)
        if is_leaf_list(sch) then
            for _, k in ipairs(sch) do leaf(s, d, k) end
            return
        end
        for k, sub in pairs(sch) do
            if sub == true then
                leaf(s, d, k)
            else
                local s2 = try(function() return s[k] end)
                local d2 = try(function() return d[k] end)
                if is_struct(s2) and is_struct(d2) then walk(s2, d2, sub) end
            end
        end
    end
    walk(src, dst, schema)
    return n
end

--- The same fields as a plain table (slot setters only take tables).
function M.read_fields(src, schema)
    local function walk(s, sch)
        local out = {}
        if is_leaf_list(sch) then
            for _, k in ipairs(sch) do out[k] = try(function() return s[k] end) end
            return out
        end
        for k, sub in pairs(sch) do
            if sub == true then
                out[k] = try(function() return s[k] end)
            else
                local s2 = try(function() return s[k] end)
                if is_struct(s2) then out[k] = walk(s2, sub) end
            end
        end
        return out
    end
    return walk(src, schema)
end

local function show(v)
    if type(v) == "number" then return string.format("%.3f", v) end
    if type(v) == "boolean" or type(v) == "string" then return tostring(v) end
    if v == nil then return "nil" end
    local s = try(function() return v:GetFullName() end)
    if type(s) == "string" then return s end
    s = try(function() return v:ToString() end)
    if type(s) == "string" then return s end
    return "?"
end

--- Flat path -> printable value for every field in the schema (UObjects by full name, names as text).
function M.describe(src, schema, prefix, out)
    out = out or {}
    prefix = prefix or ""
    if src == nil then return out end
    if is_leaf_list(schema) then
        for _, k in ipairs(schema) do out[prefix .. k] = show(try(function() return src[k] end)) end
        return out
    end
    for k, sub in pairs(schema) do
        if sub == true then
            out[prefix .. k] = show(try(function() return src[k] end))
        else
            local s2 = try(function() return src[k] end)
            if is_struct(s2) then M.describe(s2, sub, prefix .. k .. ".", out) end
        end
    end
    return out
end

--- Paths where two descriptions differ, sorted.
function M.differences(a, b)
    local diff = {}
    for k, v in pairs(a) do if b[k] ~= v then diff[#diff + 1] = k end end
    for k in pairs(b) do if a[k] == nil then diff[#diff + 1] = k end end
    table.sort(diff)
    return diff
end

local function copy_slot(from_slot, to_slot)
    if not (from_slot and to_slot) then return end
    local f = M.read_fields(from_slot, M.SLOT_LOOK)
    if f.Padding then pcall(function() to_slot:SetPadding(f.Padding) end) end
    if f.HorizontalAlignment ~= nil then pcall(function() to_slot:SetHorizontalAlignment(f.HorizontalAlignment) end) end
    if f.VerticalAlignment ~= nil then pcall(function() to_slot:SetVerticalAlignment(f.VerticalAlignment) end) end
    if f.Size then pcall(function() to_slot:SetSize(f.Size) end) end
    -- and the fields themselves, for a slot whose widget is not built yet
    M.copy_fields(from_slot, to_slot, M.SLOT_LOOK)
end

--- Give our button and its text the template's look. Writes only to our own widgets.
local function apply_look(btn, tb, template, src)
    M.copy_fields(template, btn, M.BUTTON_LOOK)
    pcall(function() btn.IsFocusable = false end)
    if valid(tb) then
        if src then
            M.copy_fields(src, tb, M.TEXT_LOOK)
            copy_slot(try(function() return src.Slot end), try(function() return tb.Slot end))
        else
            pcall(function() tb.Font.Size = 24 end)
        end
    end
end

-- An Archipelago button already in the box (left by an earlier load of the mod): reuse it instead of adding another.
local function find_existing(box)
    local n = tonumber(try(function() return box:GetChildrenCount() end)) or 0
    for i = 0, n - 1 do
        local c = try(function() return box:GetChildAt(i) end)
        local nm = valid(c) and obj_name(c) or nil
        if nm and nm:sub(1, #BUTTON_PREFIX) == BUTTON_PREFIX then
            if class_name(c) == "Button" then return c, c end
            local inner = try(function() return c:GetContent() end)
            if valid(inner) and class_name(inner) == "Button" then return inner, c end
        end
    end
    return nil
end

local function build(menu)
    local template, tfield = nil, nil
    for _, f in ipairs(M.TEMPLATE_FIELDS) do
        local b = try(function() return menu[f] end)
        if valid(b) then template, tfield = b, f break end
    end
    if not template then return nil, "no menu buttons yet", true end

    local box, row, wrapper = M.find_box(template)
    if not box then return nil, row end
    state.box_class = class_name(box)
    state.template = tfield

    state.template_widget = template
    local existing, existing_row = find_existing(box)
    if existing then
        state.adopted = true
        apply_look(existing, M.find_text(existing), template, M.find_text(template))
        pcall(function() existing:SynchronizeProperties() end)
        copy_slot(try(function() return row.Slot end), try(function() return existing_row.Slot end))
        return existing, existing_row
    end

    local tree = try(function() return menu.WidgetTree end)
    local outer = valid(tree) and tree or menu
    name_counter = name_counter + 1
    local name = BUTTON_PREFIX .. "_" .. tostring(os.time()) .. "_" .. name_counter

    local btn = make("/Script/UMG.Button", outer, name)
    if not valid(btn) then return nil, "could not make a Button" end

    local src = M.find_text(template)
    local tb = make("/Script/UMG.TextBlock", outer, name .. "_Text")
    if valid(tb) then
        local src_text = src and try(function() return src:GetText():ToString() end) or nil
        pcall(function() tb:SetText(FText(M.label_like(src_text))) end)
        pcall(function() btn:SetContent(tb) end)
    end
    -- Styled before it goes into the menu, so its Slate widget is built with the copied look.
    apply_look(btn, tb, template, src)

    local new_row = btn
    if wrapper and M.WRAPPER_CLASSES[class_name(wrapper) or ""] then
        local sb = make("/Script/UMG.SizeBox", outer, name .. "_Size")
        if valid(sb) then
            for _, p in ipairs({ "WidthOverride", "HeightOverride", "MinDesiredWidth", "MinDesiredHeight",
                                 "MaxDesiredWidth", "MaxDesiredHeight" }) do
                if try(function() return wrapper["bOverride_" .. p] end) == true then
                    local v = try(function() return wrapper[p] end)
                    if v then pcall(function() sb["Set" .. p](sb, v) end) end
                end
            end
            pcall(function() sb:SetContent(btn) end)
            new_row = sb
        end
    end

    local slot = try(function() return box:AddChild(new_row) end)
    if not slot then return nil, "could not add to the " .. tostring(state.box_class) end
    copy_slot(try(function() return row.Slot end), slot)
    state.added = state.added + 1
    return btn, new_row
end

local function forget()
    state.menu, state.menu_addr, state.button, state.row, state.menu_up = nil, nil, nil, nil, false
    state.tries, state.gave_up, state.adopted, state.template_widget = 0, nil, false, nil
end

--- One check: add the button to the current pause menu when it has none. Exposed for tests.
function M.tick()
    if not enabled then return end
    local pc = try(find_pc)
    if not valid(pc) then return end
    local menu = try(function() return pc.InGameMenuUI end)
    if not valid(menu) then return end
    local a = addr(menu)
    if a ~= state.menu_addr then
        forget()
        state.menu, state.menu_addr = menu, a
    end
    -- Whether the menu is on screen; the button is only read for clicks while it is (checked here, not per frame).
    local inv = try(function() return menu:IsInViewport() end)
    local vis = try(function() return menu:IsVisible() end)
    state.menu_up = inv ~= false and vis ~= false
    if state.button and valid(state.button) then return end
    if state.gave_up then return end
    state.tries = state.tries + 1
    local ok, btn, row, retry = pcall(build, menu)
    if ok and btn then
        state.button, state.row = btn, row
        log((state.adopted and "Reusing" or "Added") .. " the Archipelago button (" .. tostring(state.box_class)
            .. ", styled like " .. tostring(state.template) .. ")")
    elseif not ok then
        state.gave_up = "error: " .. tostring(btn)
        log("Not adding the Archipelago button: " .. state.gave_up)
    elseif not retry or state.tries >= MAX_TRIES then
        state.gave_up = tostring(row)
        log("Not adding the Archipelago button: " .. state.gave_up)
    end
end

--- What a click does: let the game close its menu (its own Resume), then open the connection window.
function M.on_click(source)
    local menu = state.menu
    if valid(menu) then
        local ok, err = pcall(function() menu:OnPressedResumeButton() end)
        if not ok then log("Resume failed: " .. tostring(err)) end
    end
    GameThread.after(100, function()
        if opener then
            local ok, err = pcall(opener, source)
            if not ok then log("Opening the connection window failed: " .. tostring(err)) end
        end
    end)
end

--- Take the button out of the menu again (it is added back on the next check unless disabled).
function M.remove()
    local row = state.row
    if valid(row) then pcall(function() row:RemoveFromParent() end) end
    local had = row ~= nil
    state.button, state.row = nil, nil
    return had
end

--- Start watching for the pause menu. `open_panel` opens the connection window.
function M.install(open_panel, opts)
    opener = open_panel
    if opts and opts.find_pc then find_pc = opts.find_pc end
    enabled = true
    ClickWatch.watch("pause_archipelago",
        function() return state.button end,
        M.on_click,
        function() return enabled and state.button ~= nil and state.menu_up == true end)
    if not loop then
        loop = GameThread.loop(WATCH_MS, function()
            if not enabled then loop = nil return true end
            M.tick()
            return false
        end)
    end
end

--- Stop adding the button and take it out of the current menu.
function M.uninstall()
    enabled = false
    ClickWatch.unwatch("pause_archipelago")
    M.remove()
    forget()
end

--- Our button widget in the current menu, or nil.
function M.button()
    if valid(state.button) then return state.button end
    return nil
end

--- Our button against the template: the style, text and slot fields that differ (empty when they look the same).
function M.compare()
    local ours, tpl = state.button, state.template_widget
    if not (valid(ours) and valid(tpl)) then return nil, "no button or template" end
    local diff = {}
    local function add(part, a, b)
        for _, k in ipairs(M.differences(a, b)) do diff[#diff + 1] = part .. k end
    end
    add("button.", M.describe(ours, M.BUTTON_LOOK), M.describe(tpl, M.BUTTON_LOOK))
    local ot, tt = M.find_text(ours), M.find_text(tpl)
    if ot and tt then
        add("text.", M.describe(ot, M.TEXT_LOOK), M.describe(tt, M.TEXT_LOOK))
        add("text_slot.", M.describe(try(function() return ot.Slot end), M.SLOT_LOOK),
            M.describe(try(function() return tt.Slot end), M.SLOT_LOOK))
    elseif ot or tt then
        diff[#diff + 1] = "text.missing"
    end
    local orow = state.row
    add("slot.", M.describe(try(function() return orow.Slot end), M.SLOT_LOOK),
        M.describe(try(function() return tpl.Slot end), M.SLOT_LOOK))
    return diff
end

--- What the module knows, for tests and debug tools.
function M.state()
    return {
        enabled = enabled,
        menu = state.menu ~= nil,
        menu_up = state.menu_up == true,
        button = state.button ~= nil and valid(state.button),
        adopted = state.adopted,
        added = state.added,
        tries = state.tries,
        gave_up = state.gave_up,
        box_class = state.box_class,
        template = state.template,
        clicks = ClickWatch.counts.pause_archipelago or 0,
    }
end

return M
