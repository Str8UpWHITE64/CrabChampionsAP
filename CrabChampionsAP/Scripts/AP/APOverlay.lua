-- AP/APOverlay.lua
-- In-game UMG overlay for Archipelago connection and status display.
-- Uses UE4SS StaticConstructObject to create UMG widgets from Lua.
-- Based on the GroundedAP overlay pattern.

local APOverlay = {}

local ConnStatus = require("AP/ConnStatus")
local GameThread = require("AP/GameThread")
local ClickWatch = require("AP/ClickWatch")

local UEHelpers = nil
pcall(function() UEHelpers = require("UEHelpers") end)

-- ============================================================================
-- Constants
-- ============================================================================

local VIS_VISIBLE = 0
local VIS_COLLAPSED = 1
local VIS_HIDDEN = 2
local VIS_HIT_INVIS = 3       -- visible but not interactable
local VIS_SELF_HIT_INVIS = 4  -- visible, children interactable, self not

-- Connect button labels
local HINT_IDLE = "Connect"
local HINT_CONNECTED = "Disconnect"
local HINT_CONNECTING = "Connecting...   (click to try again)"
local CLOSE_LABEL = "Close"

-- ============================================================================
-- Helpers
-- ============================================================================

local function FLinearColor(R, G, B, A)
    return { R = R, G = G, B = B, A = A }
end

-- A brush colour from ordinary 0-255 screen colours (brushes take linear values).
local function SRGB(r, g, b, a)
    local function lin(c) return (c / 255) ^ 2.2 end
    return FLinearColor(lin(r), lin(g), lin(b), a or 1)
end

local function FSlateColor(R, G, B, A)
    return { SpecifiedColor = FLinearColor(R, G, B, A), ColorUseRule = 0 }
end

local function log(msg)
    print("[APOverlay] " .. msg .. "\n")
end

-- ============================================================================
-- Widget refs
-- ============================================================================

local overlay = {
    root = nil,          -- UserWidget
    canvas = nil,        -- CanvasPanel (root container)

    -- Status bar (always visible, top-right)
    status_border = nil,
    status_text = nil,

    -- Connection panel (toggled)
    conn_panel = nil,    -- Border (connection panel background)
    conn_vbox = nil,     -- VerticalBox (connection panel layout)

    -- Input fields
    server_input = nil,
    slot_input = nil,
    password_input = nil,

    -- Buttons
    connect_btn = nil,   -- Button (click = connect)
    connect_btn_text = nil,
    close_btn = nil,     -- Button (click = hide the window)
    error_text = nil,    -- plain-words reason the last connect failed
    info_text = nil,     -- slot, seed, counts while connected

    -- Biome access (biome lock seeds)
    biome_access_text = nil,

    -- Equipment progress
    equip_weapons_text = nil,
    equip_melee_text = nil,
    equip_abilities_text = nil,
    victory_summary_text = nil,

    -- Item log (connection panel)
    item_log_text = nil,

    -- Item feed (top-right, below status)
    feed_vbox = nil,

    -- State
    visible = false,
    state = "idle",      -- idle | connecting | connected
    connecting_since = nil,
    connect_server = nil,
    connected = false,
    initialized = false,
}

-- Recent item log lines (for connection panel)
local item_log_lines = {}
local MAX_LOG_LINES = 4

-- Item feed entries (timed, auto-remove)
local feed_entries = {}
local FEED_DURATION = 7
local MAX_FEED = 10
local feed_counter = 0

-- AP item classification flags
local ITEM_FLAG_PROGRESSION = 1
local ITEM_FLAG_USEFUL      = 2
local ITEM_FLAG_TRAP        = 4

-- Track panel visibility in Lua (NEVER query widget visibility — native crash on stale refs)
local panel_shown = false

-- Queued state updates for when overlay isn't ready yet
local queued_status = nil
local queued_connected = nil

-- ============================================================================
-- Validity check
-- ============================================================================

local function is_alive()
    if not overlay.initialized or not overlay.root then return false end
    local ok, valid = pcall(function() return overlay.root:IsValid() end)
    if not ok or not valid then
        log("Overlay widgets invalidated — will recreate")
        overlay.initialized = false
        overlay.root = nil
        overlay.canvas = nil
        overlay.conn_panel = nil
        overlay.status_text = nil
        overlay.status_border = nil
        overlay.conn_vbox = nil
        overlay.server_input = nil
        overlay.slot_input = nil
        overlay.password_input = nil
        overlay.connect_btn = nil
        overlay.connect_btn_text = nil
        overlay.close_btn = nil
        overlay.error_text = nil
        overlay.biome_access_text = nil
        overlay.victory_summary_text = nil
        overlay.item_log_text = nil
        overlay.right_vbox = nil
        overlay.strip_states = nil
        overlay.strip_info = nil
        overlay.eq = nil
        overlay.biome_access_text_bar = nil
        overlay.victory_summary_text_bar = nil
        overlay.feed_vbox = nil
        feed_entries = {}
        return false
    end
    return true
end

-- ============================================================================
-- Widget creation helpers
-- ============================================================================

local function make(class_path, parent, name)
    local cls = StaticFindObject(class_path)
    if not cls then
        log("ERROR: Class not found: " .. class_path)
        return nil
    end
    return StaticConstructObject(cls, parent, FName(name))
end

-- Text colour. Writing the whole struct has left the text black in the game, so the fields are also written
-- one by one, the way Font.Size is.
local function set_text_color(tb, r, g, b, a)
    local c = FSlateColor(r, g, b, a)
    pcall(function() tb.ColorAndOpacity = c end)
    pcall(function() tb:SetColorAndOpacity(c) end)
    pcall(function()
        local sc = tb.ColorAndOpacity.SpecifiedColor
        sc.R = r; sc.G = g; sc.B = b; sc.A = a
    end)
    pcall(function() tb.ColorAndOpacity.ColorUseRule = 0 end)
end

local function make_text(parent, name, text, size, color)
    local tb = make("/Script/UMG.TextBlock", parent, name)
    if not tb then return nil end
    tb.Font.Size = size or 14
    pcall(function() tb:SetText(FText(text or "")) end)
    if color then set_text_color(tb, color[1], color[2], color[3], color[4] or 1) end
    pcall(function()
        tb:SetShadowOffset({ X = 1, Y = 1 })
        tb:SetShadowColorAndOpacity(FLinearColor(0, 0, 0, 0.75))
    end)
    return tb
end

local function set_text(widget, text)
    if widget then
        pcall(function() widget:SetText(FText(text or "")) end)
    end
end

-- What each text widget currently shows, by overlay field name. Kept in Lua so tests and
-- debug tools can read it back without touching widgets.
local shown = {}

-- A problem with the install (see APOverlay.set_settings_warning), shown under
-- whatever the error line says.
local settings_warning = nil
local error_raw = ""

local function with_warning(text)
    text = text or ""
    if not settings_warning then return text end
    if text == "" then return settings_warning end
    return text .. "\n" .. settings_warning
end

local function put(key, text)
    text = text or ""
    if key == "error_text" then
        error_raw = text
        text = with_warning(text)
    end
    shown[key] = text
    set_text(overlay[key], text)
    if key == "biome_access_text" and overlay.biome_access_text_bar then
        pcall(function() overlay.biome_access_text_bar:SetVisibility((text == "") and VIS_COLLAPSED or VIS_VISIBLE) end)
    end
    if key == "error_text" and overlay[key] then
        pcall(function() overlay[key]:SetVisibility((text == "") and VIS_COLLAPSED or VIS_VISIBLE) end)
    end
end

local function set_error_shown(text)
    error_raw = text or ""
    shown.error_text = with_warning(error_raw)
end

--- Keep a warning about the install on the panel's error line (nil clears it).
function APOverlay.set_settings_warning(msg)
    settings_warning = (msg ~= nil and msg ~= "") and tostring(msg) or nil
    put("error_text", error_raw)
end

-- Item lines the equipment panel can hold (it has a fixed height).
local EQUIP_LINE_BUDGET = 13
local MAX_LINE_CHARS = 46

--- Wrap a line to MAX_LINE_CHARS, breaking at word boundaries with indented continuation.
local function wrap_line(line)
    if not line or #line <= MAX_LINE_CHARS then return line end
    local result = {}
    local remaining = line
    local first = true
    while #remaining > 0 do
        local prefix = first and "" or "    "
        local max = MAX_LINE_CHARS - #prefix
        if #remaining <= max then
            table.insert(result, prefix .. remaining)
            break
        end
        -- Find last space within the limit to break at a word boundary
        local cut = max
        local space = remaining:sub(1, max):find("%s[^%s]*$")
        if space and space > 1 then
            cut = space
        end
        table.insert(result, prefix .. remaining:sub(1, cut))
        remaining = remaining:sub(cut + 1)
        first = false
    end
    return table.concat(result, "\n")
end

-- Sizes are in UMG units; the game scales the whole UI to the screen, so they are used as they are.
local function S(size) return size end

local function add_spacer(parent, name, height)
    local spacer = make("/Script/UMG.Spacer", parent, name)
    if spacer then
        spacer.Size = { X = 0, Y = height }
        parent:AddChildToVerticalBox(spacer)
    end
end

-- ============================================================================
-- Build the overlay UI
-- ============================================================================

function APOverlay.create(ap_config)
    if overlay.initialized then
        if is_alive() then
            log("Overlay already initialized and alive")
            return
        end
    end

    local gi = nil
    if UEHelpers then
        pcall(function() gi = UEHelpers.GetGameInstance() end)
    end
    if not gi then
        pcall(function() gi = FindFirstOf("GameInstance") end)
    end
    if not gi then
        log("ERROR: Cannot find GameInstance for overlay")
        return
    end

    log("Creating AP overlay...")

    -- Root UserWidget
    overlay.root = make("/Script/UMG.UserWidget", gi, "APOverlayWidget")
    if not overlay.root then
        log("ERROR: Failed to create UserWidget")
        return
    end

    overlay.root.WidgetTree = make("/Script/UMG.WidgetTree", overlay.root, "APOverlayTree")
    overlay.canvas = make("/Script/UMG.CanvasPanel", overlay.root.WidgetTree, "APRootCanvas")
    overlay.root.WidgetTree.RootWidget = overlay.canvas

    -- =================================================================
    -- Status bar (top-right corner, always visible)
    -- =================================================================
    overlay.status_border = make("/Script/UMG.Border", overlay.canvas, "APStatusBorder")
    pcall(function() overlay.status_border:SetBrushColor(FLinearColor(0.02, 0.02, 0.04, 0.92)) end)
    pcall(function() overlay.status_border:SetPadding({ Left = 12, Top = 6, Right = 12, Bottom = 6 }) end)

    overlay.status_text = make_text(overlay.status_border, "APStatusText",
        "AP: Disconnected", 20, { 1, 0.4, 0.4, 1 })
    if overlay.status_text then
        pcall(function() overlay.status_border:SetContent(overlay.status_text) end)
    end

    local status_slot = overlay.canvas:AddChildToCanvas(overlay.status_border)
    status_slot.bAutoSize = true
    status_slot.LayoutData.Anchors.Minimum = { X = 1, Y = 0 }
    status_slot.LayoutData.Anchors.Maximum = { X = 1, Y = 0 }
    status_slot.LayoutData.Alignment = { X = 1, Y = 0 }
    status_slot.LayoutData.Offsets.Left = -10
    status_slot.LayoutData.Offsets.Top = 110

    -- =================================================================
    -- Item feed (top-right, below status bar)
    -- =================================================================
    overlay.feed_vbox = make("/Script/UMG.VerticalBox", overlay.canvas, "APFeedVBox")
    if overlay.feed_vbox then
        local feed_slot = overlay.canvas:AddChildToCanvas(overlay.feed_vbox)
        feed_slot.bAutoSize = true
        feed_slot.LayoutData.Anchors.Minimum = { X = 1, Y = 0 }
        feed_slot.LayoutData.Anchors.Maximum = { X = 1, Y = 0 }
        feed_slot.LayoutData.Alignment = { X = 1, Y = 0 }
        feed_slot.LayoutData.Offsets.Left = -10
        feed_slot.LayoutData.Offsets.Top = 150
        overlay.feed_vbox.Visibility = VIS_SELF_HIT_INVIS
    end

    APOverlay._start_feed_timer()
    APOverlay._start_info_timer()

    -- =================================================================
    -- Connection panel (centered, toggled with key)
    -- =================================================================
    overlay.conn_panel = make("/Script/UMG.Border", overlay.canvas, "APConnPanel")
    overlay.conn_panel:SetBrushColor(FLinearColor(0, 0, 0, 0))

    -- Layout: a title strip across the top, then two panels of exactly the same fixed size side by side.
    local outer = make("/Script/UMG.VerticalBox", overlay.conn_panel, "APConnOuter")
    overlay.conn_panel:SetContent(outer)

    local PANEL_W, PANEL_H, GAP = 680, 640, 20
    local PANEL_BG = SRGB(10, 14, 28, 0.97)
    local LABEL = { 0.56, 0.83, 1, 1 }

    -- Title strip: name and connection state on the left, "server - N items - N checks" on the right.
    local strip = make("/Script/UMG.Border", outer, "APStrip")
    strip:SetBrushColor(PANEL_BG)
    strip:SetPadding({ Left = 32, Top = 14, Right = 32, Bottom = 14 })
    local strip_row = make("/Script/UMG.HorizontalBox", strip, "APStripRow")
    strip:SetContent(strip_row)
    local title = make_text(strip_row, "APTitle", "ARCHIPELAGO", S(34), { 1, 1, 1, 1 })
    if title then
        local sl = strip_row:AddChildToHorizontalBox(title)
        pcall(function() sl:SetVerticalAlignment(2) end)
        pcall(function() sl:SetPadding({ Left = 0, Top = 0, Right = 40, Bottom = 0 }) end)
    end
    -- The connection state: one text per colour (green / yellow / red), only the current one shown. A colour
    -- set when the widget is made is the one that works, so the colour is never changed afterwards.
    overlay.strip_states = {}
    for key, col in pairs({ ok = { 0.3, 1, 0.3, 1 }, busy = { 1, 1, 0.3, 1 }, off = { 1, 0.4, 0.4, 1 } }) do
        local w = make_text(strip_row, "APStripState_" .. key, "", S(22), col)
        if w then
            local sl = strip_row:AddChildToHorizontalBox(w)
            pcall(function() sl:SetVerticalAlignment(2) end)
            pcall(function() sl:SetSize({ SizeRule = 1, Value = 1 }) end)   -- Fill: pushes the counts to the right
            pcall(function() w:SetVisibility(VIS_COLLAPSED) end)
            overlay.strip_states[key] = w
        end
    end
    overlay.strip_info = make_text(strip_row, "APStripInfo", "", S(17), LABEL)
    if overlay.strip_info then
        local sl = strip_row:AddChildToHorizontalBox(overlay.strip_info)
        pcall(function() sl:SetVerticalAlignment(2) end)
    end
    outer:AddChildToVerticalBox(strip)

    -- Blue rule under the strip
    local rule_box = make("/Script/UMG.SizeBox", outer, "APRuleBox")
    local rule = make("/Script/UMG.Border", rule_box, "APRule")
    if rule_box and rule then
        rule:SetBrushColor(SRGB(26, 143, 208, 1))
        rule_box:SetHeightOverride(4)
        rule_box:SetContent(rule)
        outer:AddChildToVerticalBox(rule_box)
    end
    add_spacer(outer, "APSpacerStrip", 18)

    local cols = make("/Script/UMG.HorizontalBox", outer, "APConnCols")
    outer:AddChildToVerticalBox(cols)

    local function fixed_panel(name)
        local box = make("/Script/UMG.SizeBox", cols, name .. "Box")
        local border = make("/Script/UMG.Border", box, name .. "Border")
        local vbox = make("/Script/UMG.VerticalBox", border, name .. "VBox")
        box:SetWidthOverride(PANEL_W)
        box:SetHeightOverride(PANEL_H)
        border:SetBrushColor(PANEL_BG)
        border:SetPadding({ Left = 28, Top = 22, Right = 28, Bottom = 22 })
        border:SetContent(vbox)
        box:SetContent(border)
        return box, vbox
    end
    local left_box, left_vbox = fixed_panel("APLeft")
    local right_box, right_vbox = fixed_panel("APRight")
    overlay.conn_vbox, overlay.right_vbox = left_vbox, right_vbox
    cols:AddChildToHorizontalBox(left_box)
    local gap_slot = cols:AddChildToHorizontalBox(right_box)
    pcall(function() gap_slot:SetPadding({ Left = GAP, Top = 0, Right = 0, Bottom = 0 }) end)

    local lh = make_text(overlay.conn_vbox, "APConnHeading", "CONNECTION", S(17), LABEL)
    if lh then overlay.conn_vbox:AddChildToVerticalBox(lh) end

    add_spacer(overlay.conn_vbox, "APSpacer1", 8)

    -- A label in a fixed-width column so the input boxes line up
    local function label_cell(row, lbl)
        local box = make("/Script/UMG.SizeBox", row, "APLabelBox")
        if box then
            box:SetWidthOverride(170)
            box:SetContent(lbl)
            row:AddChildToHorizontalBox(box)
        else
            row:AddChildToHorizontalBox(lbl)
        end
    end

    -- Server row
    local server_row = make("/Script/UMG.HorizontalBox", overlay.conn_vbox, "APServerRow")
    if server_row then
        local lbl = make_text(server_row, "APServerLabel", "Server", S(21), { 1, 1, 1, 1 })
        if lbl then label_cell(server_row, lbl) end

        overlay.server_input = make("/Script/UMG.EditableTextBox", server_row, "APServerInput")
        if overlay.server_input then
            pcall(function()
                overlay.server_input:SetText(FText(ap_config and ap_config.server or "localhost:38281"))
                overlay.server_input.WidgetStyle.Font.Size = 21
                overlay.server_input.MinimumDesiredWidth = 440
            end)
            server_row:AddChildToHorizontalBox(overlay.server_input)
        end
        overlay.conn_vbox:AddChildToVerticalBox(server_row)
    end

    add_spacer(overlay.conn_vbox, "APSpacer2", 8)

    -- Slot row
    local slot_row = make("/Script/UMG.HorizontalBox", overlay.conn_vbox, "APSlotRow")
    if slot_row then
        local lbl = make_text(slot_row, "APSlotLabel", "Slot", S(21), { 1, 1, 1, 1 })
        if lbl then label_cell(slot_row, lbl) end

        overlay.slot_input = make("/Script/UMG.EditableTextBox", slot_row, "APSlotInput")
        if overlay.slot_input then
            pcall(function()
                overlay.slot_input:SetText(FText(ap_config and ap_config.slot or ""))
                overlay.slot_input.WidgetStyle.Font.Size = 21
                overlay.slot_input.MinimumDesiredWidth = 440
            end)
            slot_row:AddChildToHorizontalBox(overlay.slot_input)
        end
        overlay.conn_vbox:AddChildToVerticalBox(slot_row)
    end

    add_spacer(overlay.conn_vbox, "APSpacer3", 8)

    -- Password row
    local pw_row = make("/Script/UMG.HorizontalBox", overlay.conn_vbox, "APPwRow")
    if pw_row then
        local lbl = make_text(pw_row, "APPwLabel", "Password", S(21), { 1, 1, 1, 1 })
        if lbl then label_cell(pw_row, lbl) end

        overlay.password_input = make("/Script/UMG.EditableTextBox", pw_row, "APPwInput")
        if overlay.password_input then
            pcall(function()
                overlay.password_input:SetText(FText(ap_config and ap_config.password or ""))
                overlay.password_input.WidgetStyle.Font.Size = 21
                overlay.password_input.MinimumDesiredWidth = 440
                overlay.password_input.IsPassword = true
            end)
            pw_row:AddChildToHorizontalBox(overlay.password_input)
        end
        overlay.conn_vbox:AddChildToVerticalBox(pw_row)
    end

    add_spacer(overlay.conn_vbox, "APSpacer4", 14)

    -- Connect button (a click connects, disconnects or retries). Not focusable, so Space or Enter while playing never presses it.
    overlay.connect_btn = make("/Script/UMG.Button", overlay.conn_vbox, "APConnectButton")
    if overlay.connect_btn then
        pcall(function() overlay.connect_btn.IsFocusable = false end)
        pcall(function() overlay.connect_btn:SetBackgroundColor(FLinearColor(0.25, 0.55, 0.85, 1)) end)
        overlay.connect_btn_text = make_text(overlay.connect_btn, "APConnectButtonText", HINT_IDLE, S(22), { 1, 1, 1, 1 })
        if overlay.connect_btn_text then
            pcall(function()
                local s = overlay.connect_btn:SetContent(overlay.connect_btn_text)
                if s then s:SetPadding({ Left = 15, Top = 8, Right = 15, Bottom = 8 }) end
            end)
        end
        overlay.conn_vbox:AddChildToVerticalBox(overlay.connect_btn)
    end
    shown.connect_btn_text = HINT_IDLE

    -- Close button (a click hides the window). Not focusable, for the same reason.
    overlay.close_btn = make("/Script/UMG.Button", overlay.conn_vbox, "APCloseButton")
    if overlay.close_btn then
        pcall(function() overlay.close_btn.IsFocusable = false end)
        pcall(function() overlay.close_btn:SetBackgroundColor(FLinearColor(0.45, 0.45, 0.5, 1)) end)
        local ct = make_text(overlay.close_btn, "APCloseButtonText", CLOSE_LABEL, S(22), { 1, 1, 1, 1 })
        if ct then
            pcall(function()
                local s = overlay.close_btn:SetContent(ct)
                if s then s:SetPadding({ Left = 15, Top = 8, Right = 15, Bottom = 8 }) end
            end)
        end
        add_spacer(overlay.conn_vbox, "APSpacerClose", 6)
        overlay.conn_vbox:AddChildToVerticalBox(overlay.close_btn)
    end


    overlay.error_text = make_text(overlay.conn_vbox, "APErrorText", "", S(18), { 1, 0.55, 0.45, 1 })
    if overlay.error_text then
        overlay.conn_vbox:AddChildToVerticalBox(overlay.error_text)
        if settings_warning then put("error_text", error_raw) end
    end


    -- =================================================================
    -- Equipment Progress section
    -- =================================================================
    local equip_heading = make_text(overlay.right_vbox, "APEquipHeading", "EQUIPMENT", S(17), LABEL)
    if equip_heading then overlay.right_vbox:AddChildToVerticalBox(equip_heading) end

    -- Each kind of equipment is a light-blue heading, the finished items (green), the received ones (white)
    -- and a grey "+N" line.
    overlay.eq = {}
    local function equip_section(key, heading, empty_text)
        local sec = {}
        sec.head = make_text(overlay.right_vbox, "APEq" .. key .. "Head", heading, S(17), LABEL)
        sec.done = make_text(overlay.right_vbox, "APEq" .. key .. "Done", "", S(20), { 0.37, 0.88, 0.54, 1 })
        sec.rec = make_text(overlay.right_vbox, "APEq" .. key .. "Rec", empty_text or "", S(20), { 1, 1, 1, 1 })
        sec.extra = make_text(overlay.right_vbox, "APEq" .. key .. "Extra", "", S(20), { 0.54, 0.58, 0.64, 1 })
        for i, w in ipairs({ sec.head, sec.done, sec.rec, sec.extra }) do
            if w then
                local slot = overlay.right_vbox:AddChildToVerticalBox(w)
                if i == 1 then pcall(function() slot:SetPadding({ Left = 0, Top = 14, Right = 0, Bottom = 2 }) end) end
            end
        end
        overlay.eq[key] = sec
    end
    equip_section("w", "WEAPONS", "(connect to see weapons)")
    equip_section("m", "")
    equip_section("a", "")

    -- A text line on a tinted bar with a coloured edge (goal: yellow, biomes: blue).
    local function bar(name, key, text_color, edge, bg)
        local row = make("/Script/UMG.HorizontalBox", overlay.conn_vbox, name .. "Row")
        local edge_box = make("/Script/UMG.SizeBox", row, name .. "EdgeBox")
        local edge_b = make("/Script/UMG.Border", edge_box, name .. "Edge")
        local body = make("/Script/UMG.Border", row, name .. "Body")
        local txt = make_text(body, name .. "Text", "", S(20), text_color)
        if not (row and edge_box and edge_b and body and txt) then return nil end
        edge_b:SetBrushColor(SRGB(edge[1], edge[2], edge[3], 1))
        edge_box:SetWidthOverride(8)
        edge_box:SetContent(edge_b)
        body:SetBrushColor(SRGB(bg[1], bg[2], bg[3], 1))
        body:SetPadding({ Left = 18, Top = 10, Right = 18, Bottom = 10 })
        body:SetContent(txt)
        row:AddChildToHorizontalBox(edge_box)
        local bs = row:AddChildToHorizontalBox(body)
        pcall(function() bs:SetSize({ SizeRule = 1, Value = 1 }) end)
        overlay[key] = txt
        overlay[key .. "_bar"] = row
        local slot = overlay.conn_vbox:AddChildToVerticalBox(row)
        pcall(function() slot:SetPadding({ Left = 0, Top = 12, Right = 0, Bottom = 0 }) end)
        return row
    end
    bar("APGoal", "victory_summary_text", { 1, 0.9, 0.4, 1 }, { 255, 210, 74 }, { 42, 36, 16 })
    bar("APBiomes", "biome_access_text", { 0.75, 0.92, 1, 1 }, { 26, 143, 208 }, { 15, 42, 58 })
    pcall(function() overlay.biome_access_text_bar:SetVisibility(VIS_COLLAPSED) end)

    -- =================================================================
    -- Recent items (what the server sent you)
    -- =================================================================
    local log_label = make_text(overlay.conn_vbox, "APLogLabel", "RECENT ITEMS", S(17), LABEL)
    if log_label then
        local slot = overlay.conn_vbox:AddChildToVerticalBox(log_label)
        pcall(function() slot:SetPadding({ Left = 0, Top = 16, Right = 0, Bottom = 2 }) end)
    end

    overlay.item_log_text = make_text(overlay.conn_vbox, "APLogText",
        "(none)", S(20), { 0.62, 0.66, 0.72, 1 })
    if overlay.item_log_text then
        overlay.conn_vbox:AddChildToVerticalBox(overlay.item_log_text)
    end

    -- Position connection panel at center
    local conn_slot = overlay.canvas:AddChildToCanvas(overlay.conn_panel)
    conn_slot.bAutoSize = true
    conn_slot.LayoutData.Anchors.Minimum = { X = 0.5, Y = 0.5 }
    conn_slot.LayoutData.Anchors.Maximum = { X = 0.5, Y = 0.5 }
    conn_slot.LayoutData.Alignment = { X = 0.5, Y = 0.5 }
    conn_slot.LayoutData.Offsets.Left = 0
    conn_slot.LayoutData.Offsets.Top = 30

    -- Start with connection panel hidden
    overlay.conn_panel.Visibility = VIS_HIDDEN

    -- Set canvas/status visibility
    overlay.canvas.Visibility = VIS_SELF_HIT_INVIS
    overlay.status_border.Visibility = VIS_SELF_HIT_INVIS

    -- Add to viewport
    overlay.root:AddToViewport(99)

    overlay.initialized = true
    overlay.visible = true
    panel_shown = false
    log("Overlay created successfully")

    -- Clicks on the Connect button, read only while the panel is open.
    ClickWatch.watch("connect",
        function() return overlay.connect_btn end,
        function(source) APOverlay.request_connect(source) end,
        function() return panel_shown and overlay.initialized end)

    -- Clicks on the Close button: hides the window and gives the pointer back.
    ClickWatch.watch("close",
        function() return overlay.close_btn end,
        function() APOverlay.hide_panel() end,
        function() return panel_shown and overlay.initialized end)

    -- Apply any queued state
    if queued_connected then
        APOverlay.set_connected(queued_connected)
        queued_connected = nil
    elseif queued_connected == false then
        APOverlay.set_disconnected()
        queued_connected = nil
    elseif queued_status then
        APOverlay.set_status(queued_status.text, queued_status.r, queued_status.g, queued_status.b)
        queued_status = nil
    end

    -- Re-apply item log
    if #item_log_lines > 0 and overlay.item_log_text then
        put("item_log_text", table.concat(item_log_lines, "\n"))
    end
end

-- ============================================================================
-- Public API
-- ============================================================================

function APOverlay.is_initialized()
    if overlay.initialized and not is_alive() then
        return false
    end
    return overlay.initialized
end

-- ----------------------------------------------------------------------------
-- Pointer and click input while the panel is open.
-- The game plays in game-only input, so the pointer is off and the boxes cannot
-- be clicked. Opening the panel turns the pointer and click events on, switches
-- to game-and-UI input with the first box focused, and ignores camera look.
-- Closing it puts back exactly what was there. If the pointer is already on
-- (the pause menu or another screen has input), nothing is changed and nothing
-- is restored, so the panel never fights it.
-- ----------------------------------------------------------------------------

local cursor_state = nil   -- { pc, show, click, over, mode_set, look_ignored } when this module changed input
local release_check = nil  -- function() -> true when the panel should close itself (run start, death...)

local function get_pc()
    local pc = nil
    pcall(function() pc = FindFirstOf("CrabPC") end)
    if pc then
        local ok, v = pcall(function() return pc:IsValid() end)
        if ok and v then return pc end
    end
    return nil
end

local function read_flag(pc, name)
    local ok, v = pcall(function() return pc[name] end)
    if ok and type(v) == "boolean" then return v end
    return nil
end

local function capture_input()
    if cursor_state then return end
    local pc = get_pc()
    if not pc then return end
    if read_flag(pc, "bShowMouseCursor") == true then
        log("Pointer already on (pause menu or other screen) - leaving input alone")
        return
    end
    local st = {
        pc = pc,
        show = read_flag(pc, "bShowMouseCursor"),
        click = read_flag(pc, "bEnableClickEvents"),
        over = read_flag(pc, "bEnableMouseOverEvents"),
    }
    pcall(function() pc.bShowMouseCursor = true end)
    pcall(function() pc.bEnableClickEvents = true end)
    pcall(function() pc.bEnableMouseOverEvents = true end)
    pcall(function() pc:SetIgnoreLookInput(true); st.look_ignored = true end)
    pcall(function()
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        if lib and overlay.server_input then
            lib:SetInputMode_GameAndUIEx(pc, overlay.server_input, 0, false)
            st.mode_set = true
        end
    end)
    cursor_state = st
    log("Pointer on for the panel (UI input " .. tostring(st.mode_set) .. ")")
end

local function release_input()
    local st = cursor_state
    if not st then return end
    cursor_state = nil
    local pc = st.pc
    local ok, v = pcall(function() return pc:IsValid() end)
    if not (ok and v) then return end   -- level changed: the new controller starts clean
    if st.mode_set then
        pcall(function()
            local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
            if lib then lib:SetInputMode_GameOnly(pc) end
        end)
    end
    if st.look_ignored then pcall(function() pc:SetIgnoreLookInput(false) end) end
    if st.show ~= nil then pcall(function() pc.bShowMouseCursor = st.show end) end
    if st.click ~= nil then pcall(function() pc.bEnableClickEvents = st.click end) end
    if st.over ~= nil then pcall(function() pc.bEnableMouseOverEvents = st.over end) end
    log("Pointer restored")
end

--- True while this module has the pointer switched on.
function APOverlay.pointer_captured()
    return cursor_state ~= nil
end

--- main.lua gives a function that returns true when the panel must close by itself.
function APOverlay.set_release_check(fn)
    release_check = fn
end

local function start_input_watchdog()
    if release_check then pcall(release_check, true) end   -- remember the state at open
    GameThread.loop(500, function()
        if not cursor_state then return true end   -- nothing to watch; stop until the next open
        local pc_ok = false
        pcall(function() pc_ok = cursor_state.pc:IsValid() end)
        local stop = not pc_ok
        if not stop and release_check then
            local ok, r = pcall(release_check)
            stop = ok and r == true
        end
        if stop then
            -- hide_panel releases the pointer (this loop already runs on the game thread)
            GameThread.run(function() APOverlay.hide_panel() end)
            return true
        end
        return false
    end)
end

local function set_panel(shown)
    panel_shown = shown
    pcall(function()
        overlay.conn_panel:SetVisibility(shown and VIS_VISIBLE or VIS_HIDDEN)
    end)
    if shown then
        capture_input()
        if cursor_state then start_input_watchdog() end
    else
        release_input()
    end
end

function APOverlay.show_panel()
    if not is_alive() or not overlay.conn_panel then return end
    if panel_shown then return end
    set_panel(true)
end

function APOverlay.hide_panel()
    if not overlay.conn_panel then release_input() return end
    -- release even when the widgets died, so the pointer never sticks
    if not is_alive() then release_input() panel_shown = false return end
    set_panel(false)
end

function APOverlay.set_status(text, r, g, b)
    if not is_alive() then
        queued_status = { text = text, r = r, g = g, b = b }
        return
    end
    if overlay.strip_states then
        local label = text
        local who = text:match("^AP: (.+)$")
        if who == "Connecting..." then label = "Connecting..."
        elseif who and who:find("^Disconnected") then label = "Not connected"
        elseif who then label = "Connected as " .. who end
        label = "\xE2\x97\x8F " .. label
        shown.strip_state = label
        local which = "busy"
        if r and g and b then
            if r > 0.8 and g < 0.6 then which = "off" elseif g > 0.8 and r < 0.6 then which = "ok" end
        end
        for key, w in pairs(overlay.strip_states) do
            set_text(w, key == which and label or "")
            pcall(function() w:SetVisibility(key == which and VIS_VISIBLE or VIS_COLLAPSED) end)
        end
    end
    if overlay.status_text then
        put("status_text", text)
        if r and g and b then
            pcall(function()
                set_text_color(overlay.status_text, r, g, b, 1)
            end)
        end
    end
end

local timeout_handler = nil
local conn_gen = 0
local info_gen = 0
local info_provider = nil

--- Reset everything that belongs to a connection: checklist, victory line and message log.
function APOverlay.clear_progress()
    item_log_lines = {}
    put("biome_access_text", "")
    put("equip_weapons_text", "(connect to see weapons)")
    put("equip_melee_text", "")
    put("equip_abilities_text", "")
    put("strip_info", "")
    if overlay.eq then
        for _, sec in pairs(overlay.eq) do
            for _, k in ipairs({ "head", "done", "rec", "extra" }) do set_text(sec[k], "") end
        end
        set_text(overlay.eq.w.head, "WEAPONS")
        set_text(overlay.eq.w.rec, "(connect to see weapons)")
    end
    put("victory_summary_text", "")
    put("item_log_text", "(none)")
    put("info_text", "")
end

-- ----------------------------------------------------------------------------
-- Connect requests. main.lua gives the connect function; the Connect button runs the very same one.
-- ----------------------------------------------------------------------------
local connect_handler = nil
local connect_requests = 0

function APOverlay.set_connect_handler(fn)
    connect_handler = fn
end

--- Connect, disconnect or retry, `source` is only for the log and readback ("pointer", "test"...).
function APOverlay.request_connect(source)
    connect_requests = connect_requests + 1
    shown.connect_source = tostring(source or "?")
    shown.connect_requests = connect_requests
    if not connect_handler then
        log("Connect pressed (" .. shown.connect_source .. ") but no handler is set")
        return false
    end
    local ok, err = pcall(connect_handler, source)
    if not ok then log("Connect failed: " .. tostring(err)) end
    return ok
end

--- Run a watched button's click action the way a pointer click does ("connect"). For tests and debug tools.
function APOverlay.click(name, source)
    return ClickWatch.fire(name, source or "test")
end

--- main.lua supplies a function returning { server, slot, seed, items, checked }.
function APOverlay.set_info_provider(fn)
    info_provider = fn
end

--- main.lua supplies what to do when the server never answers (it queues a disconnect with the message).
function APOverlay.set_timeout_handler(fn)
    timeout_handler = fn
end

function APOverlay.refresh_info()
    if overlay.state ~= "connected" or not info_provider then
        put("info_text", "")
        put("strip_info", "")
        return
    end
    local ok, d = pcall(info_provider)
    put("info_text", ok and ConnStatus.info_text(d) or "")
    put("strip_info", ok and ConnStatus.strip_text(d) or "")
end

function APOverlay._start_info_timer()
    info_gen = info_gen + 1
    local mine = info_gen
    GameThread.loop(2000, function()
        if mine ~= info_gen or not is_alive() then return true end
        if panel_shown then APOverlay.refresh_info() end
        return false
    end)
end

local function start_timeout_watch()
    conn_gen = conn_gen + 1
    local mine = conn_gen
    GameThread.loop(1000, function()
        if mine ~= conn_gen or overlay.state ~= "connecting" then return true end
        if ConnStatus.timed_out(overlay.connecting_since, os.clock()) then
            local msg = ConnStatus.timeout_message(overlay.connect_server, ConnStatus.CONNECT_TIMEOUT)
            if timeout_handler then
                pcall(timeout_handler, msg)
            else
                APOverlay.set_disconnected(msg)
            end
            return true
        end
        return false
    end)
end

function APOverlay.set_connected(slot_name)
    overlay.connected = true
    overlay.state = "connected"
    conn_gen = conn_gen + 1   -- stops the timeout watch
    if not is_alive() then
        queued_connected = slot_name or "Connected"
        return
    end
    APOverlay.set_status("AP: " .. (slot_name or "Connected"), 0.3, 1, 0.3)
    put("connect_btn_text", HINT_CONNECTED)
    put("error_text", "")
    APOverlay.refresh_info()
end

function APOverlay.set_disconnected(reason)
    overlay.connected = false
    overlay.state = "idle"
    conn_gen = conn_gen + 1
    local friendly = ConnStatus.friendly(reason)
    set_error_shown(friendly)
    if not is_alive() then
        queued_connected = false
        return
    end
    local msg = "AP: Disconnected"
    local short = ConnStatus.short(reason)
    if short ~= "" then msg = msg .. " (" .. short .. ")" end
    APOverlay.set_status(msg, 1, 0.4, 0.4)
    put("connect_btn_text", HINT_IDLE)
    put("error_text", friendly)
    APOverlay.clear_progress()
end

function APOverlay.set_connecting(server)
    overlay.state = "connecting"
    overlay.connecting_since = os.clock()
    overlay.connect_server = server or overlay.connect_server
    set_error_shown("")
    start_timeout_watch()
    if not is_alive() then
        queued_status = { text = "AP: Connecting...", r = 1, g = 1, b = 0.3 }
        return
    end
    APOverlay.set_status("AP: Connecting...", 1, 1, 0.3)
    put("connect_btn_text", HINT_CONNECTING)
    put("error_text", "")
end

function APOverlay.add_item_log(text)
    table.insert(item_log_lines, wrap_line(text))
    while #item_log_lines > MAX_LOG_LINES do
        table.remove(item_log_lines, 1)
    end
    if is_alive() and overlay.item_log_text then
        put("item_log_text", table.concat(item_log_lines, "\n"))
    end
end

function APOverlay.get_server()
    if is_alive() and overlay.server_input then
        local ok, result = pcall(function() return overlay.server_input:GetText():ToString() end)
        if ok and result then return result end
    end
    return nil
end

function APOverlay.get_slot()
    if is_alive() and overlay.slot_input then
        local ok, result = pcall(function() return overlay.slot_input:GetText():ToString() end)
        if ok and result then return result end
    end
    return nil
end

function APOverlay.get_password()
    if is_alive() and overlay.password_input then
        local ok, result = pcall(function() return overlay.password_input:GetText():ToString() end)
        if ok and result then return result end
    end
    return nil
end

--- Put server, slot and password into the input boxes (nil leaves a box as it is).
function APOverlay.set_fields(server, slot, password)
    if not is_alive() then return false end
    local function fill(box, v)
        if box and v ~= nil then pcall(function() box:SetText(FText(tostring(v))) end) end
    end
    fill(overlay.server_input, server)
    fill(overlay.slot_input, slot)
    fill(overlay.password_input, password)
    return true
end

--- Everything the panel and status label currently say, for tests and debug tools.
function APOverlay.get_shown()
    local out = { state = overlay.state, panel = panel_shown,
                  connect_button = overlay.connect_btn ~= nil,
                  connect_clicks = ClickWatch.counts.connect or 0,
                  close_button = overlay.close_btn ~= nil,
                  close_clicks = ClickWatch.counts.close or 0,
                  pointer_captured = cursor_state ~= nil }
    for k, v in pairs(shown) do out[k] = v end
    return out
end

function APOverlay.is_connected()
    return overlay.connected
end

function APOverlay.destroy()
    release_input()
    if overlay.root then
        pcall(function() overlay.root:RemoveFromViewport() end)
    end
    overlay.initialized = false
    overlay.visible = false
    overlay.root = nil
    feed_entries = {}
    log("Overlay destroyed")
end

-- ============================================================================
-- Equipment Progress
-- ============================================================================

--- Update the equipment progress checklist and victory summary.
--- For each pool item, shows one of three states:
---   [check] - completed: final-island run done with this equipment at the required rank
---   [+]     - received as an AP item but not yet completed
---   [-]     - not yet received
---@param LocationData table LocationData module
---@param ItemApply table ItemApply module (for .unlocked)
---@param ItemData table ItemData module (for .get_da / .CATEGORY)
---@param APClient table|nil APClient module (for is_location_checked).  If nil,
---       completion check marks are skipped and only [+]/[-] are shown.
function APOverlay.update_equipment_progress(LocationData, ItemApply, ItemData, APClient)
    if not is_alive() then return end
    if not LocationData or not ItemApply or not ItemData then return end

    local CAT = ItemData.CATEGORY
    local req_rank = LocationData.required_rank or 0

    --- Build a per-item line: figure out the (received, completed) state and
    --- emit "  [marker] Name".  loc_id_fn converts a name to the relevant
    --- equipment-run location id.
    local function build_line(name, da_full_name, loc_id_fn)
        local got = da_full_name and ItemApply.unlocked[da_full_name]
        local completed = false
        if APClient and loc_id_fn then
            if APClient.is_location_checked then
                completed = LocationData.final_run_checked(loc_id_fn, name, req_rank,
                    function(id) return APClient:is_location_checked(id) == true end,
                    function(kind, n) return APClient.is_run_completed ~= nil and APClient:is_run_completed(kind, n) end)
            end
        end
        local marker
        if completed then
            marker = "[\xE2\x9C\x93]"  -- ✓ U+2713 CHECK MARK (UTF-8)
        elseif got then
            marker = "[+]"
        else
            marker = "[-]"
        end
        local suffix = ""
        if LocationData.biome_layout and APClient and APClient.is_location_checked and loc_id_fn then
            local cleared = LocationData.equipment_biomes_cleared(loc_id_fn, name, req_rank,
                function(id) return APClient:is_location_checked(id) == true end)
            local names = {}
            for biome, label in ipairs(LocationData.BIOME_LABELS) do
                if cleared[biome] then names[#names + 1] = label end
            end
            suffix = " - " .. #names .. "/4 biomes"
            if #names > 0 then suffix = suffix .. " (" .. table.concat(names, ", ") .. ")" end
        end
        return "  " .. marker .. " " .. name .. suffix, got, completed
    end

    -- Biomes the player can enter (biome lock seeds only; otherwise every biome is open)
    local okb, BiomeLock = pcall(require, "AP/BiomeLock")
    if okb and BiomeLock and BiomeLock.is_active() then
        local open = {}
        for real, label in ipairs(BiomeLock.NAMES) do
            if BiomeLock.is_owned(real) then open[#open + 1] = label end
        end
        put("biome_access_text", "Biomes unlocked (" .. #open .. "/" .. #BiomeLock.NAMES .. "): "
            .. table.concat(open, ", "))
    else
        put("biome_access_text", "")
    end

    -- Collect what to list for each kind of equipment: received or completed items only.
    -- Finished items come first (green), then the received ones (white).
    local function collect(pool, category, loc_fn)
        local done_lines, rec_lines, received, completed, total = {}, {}, 0, 0, 0
        for name, _ in pairs(pool or {}) do
            total = total + 1
            local fn = ItemData.get_da(category, name)
            local line, got, done = build_line(name, fn, loc_fn)
            if got then received = received + 1 end
            if done then
                completed = completed + 1
                done_lines[#done_lines + 1] = line
            elseif got then
                rec_lines[#rec_lines + 1] = line
            end
        end
        table.sort(done_lines)
        table.sort(rec_lines)
        local lines = {}
        for _, l in ipairs(done_lines) do lines[#lines + 1] = l end
        for _, l in ipairs(rec_lines) do lines[#lines + 1] = l end
        return { lines = lines, ndone = #done_lines, received = received, completed = completed, total = total }
    end

    local w = collect(LocationData.pool_weapons, CAT.WEAPON, LocationData.weapon_run_location_id_by_name)
    local m = collect(LocationData.pool_melee, CAT.MELEE, LocationData.melee_run_location_id_by_name)
    local ab = collect(LocationData.pool_abilities, CAT.ABILITY, LocationData.ability_run_location_id_by_name)
    local w_needed = LocationData.weapons_for_completion or 0
    local m_needed = LocationData.melee_for_completion or 0
    local a_needed = LocationData.ability_for_completion or 0

    -- The panel has a fixed height, so the item lines share a budget. Weapons go first but leave a few
    -- lines for melee and abilities; whatever does not fit is counted in the "+N" line instead.
    local budget = EQUIP_LINE_BUDGET
    local function take(sec, reserve)
        local cap = math.max(0, math.min(#sec.lines, budget - reserve))
        sec.shown = cap
        budget = budget - cap
    end
    take(w, math.min(#m.lines, 3) + math.min(#ab.lines, 3))
    take(m, math.min(#ab.lines, 3))
    take(ab, 0)

    local function section(label, sec, needed)
        if sec.total == 0 then return nil end
        local out = { head = string.upper(label) .. " " .. sec.received .. "/" .. sec.total .. " RECEIVED  \xC2\xB7  "
            .. sec.completed .. "/" .. needed .. " COMPLETED", full = {} }
        out.full[1] = label .. " (" .. sec.received .. "/" .. sec.total .. " received, "
            .. sec.completed .. "/" .. needed .. " completed):"
        local done_l, rec_l = {}, {}
        for i = 1, sec.shown do
            out.full[#out.full + 1] = sec.lines[i]
            if i <= sec.ndone then done_l[#done_l + 1] = sec.lines[i] else rec_l[#rec_l + 1] = sec.lines[i] end
        end
        local extra = {}
        local hidden = #sec.lines - sec.shown
        if hidden > 0 then extra[#extra + 1] = "+" .. hidden .. " more received" end
        local missing = sec.total - #sec.lines
        if missing > 0 then extra[#extra + 1] = "+" .. missing .. " not found yet" end
        if #extra > 0 then
            out.extra = "  " .. table.concat(extra, ", ")
            out.full[#out.full + 1] = out.extra
        end
        out.done = table.concat(done_l, "\n")
        out.rec = table.concat(rec_l, "\n")
        out.text = table.concat(out.full, "\n")
        return out
    end

    local function show(key, shown_key, sec, empty_text)
        put(shown_key, sec and sec.text or empty_text)
        local ws = overlay.eq and overlay.eq[key]
        if not ws then return end
        local function set(wid, text)
            set_text(wid, text)
            if wid then pcall(function() wid:SetVisibility((text == "") and VIS_COLLAPSED or VIS_VISIBLE) end) end
        end
        if sec then
            set(ws.head, sec.head)
            set(ws.done, sec.done)
            set(ws.rec, sec.rec)
            set(ws.extra, sec.extra or "")
        else
            set(ws.head, key == "w" and "WEAPONS" or "")
            set(ws.done, "")
            set(ws.rec, key == "w" and "(none in pool)" or "")
            set(ws.extra, "")
        end
    end
    show("w", "equip_weapons_text", section("Weapons", w, w_needed), "Weapons: (none in pool)")
    show("m", "equip_melee_text", section("Melee", m, m_needed), "")
    show("a", "equip_abilities_text", section("Abilities", ab, a_needed), "")

    -- Victory summary
    local rank_name = LocationData.RANK_NAMES
        and LocationData.RANK_NAMES[LocationData.required_rank + 1] or "?"
    put("victory_summary_text",
        "Goal: " .. w_needed .. " weapons, " .. m_needed .. " melee, "
        .. a_needed .. " abilities on " .. rank_name)
end

-- ============================================================================
-- Item Feed — color-coded, timed messages below status bar
-- ============================================================================

local function flags_to_bg_color(flags)
    flags = flags or 0
    if flags & ITEM_FLAG_TRAP ~= 0 then
        return { 0.35, 0.05, 0.05, 0.75 }
    elseif flags & ITEM_FLAG_PROGRESSION ~= 0 then
        return { 0.2, 0.1, 0.35, 0.75 }
    elseif flags & ITEM_FLAG_USEFUL ~= 0 then
        return { 0.05, 0.12, 0.3, 0.75 }
    else
        return { 0.05, 0.18, 0.18, 0.75 }
    end
end

local function flags_to_accent_color(flags)
    flags = flags or 0
    if flags & ITEM_FLAG_TRAP ~= 0 then
        return { 1, 0.2, 0.2, 0.9 }
    elseif flags & ITEM_FLAG_PROGRESSION ~= 0 then
        return { 0.7, 0.4, 1, 0.9 }
    elseif flags & ITEM_FLAG_USEFUL ~= 0 then
        return { 0.3, 0.5, 1, 0.9 }
    else
        return { 0.3, 0.8, 0.8, 0.9 }
    end
end

--- Classify a Crab Champions item name by common patterns if flags are missing.
--- Returns AP flags: 1=progression, 2=useful, 4=trap, 0=filler
local function classify_item_name(name)
    if not name then return 0 end
    local lower = name:lower()
    -- Weapons, melee, abilities are progression
    if lower:find("rifle") or lower:find("pistol") or lower:find("launcher")
       or lower:find("shotgun") or lower:find("sniper") or lower:find("minigun")
       or lower:find("flamethrower") or lower:find("crossbow") or lower:find("seagle")
       or lower:find("wand") or lower:find("staff") or lower:find("scepter")
       or lower:find("cannons") or lower:find("cannon")
       or lower:find("claw") or lower:find("dagger") or lower:find("hammer")
       or lower:find("katana") or lower:find("pickaxe")
       or lower:find("air strike") or lower:find("black hole") or lower:find("electro globe")
       or lower:find("grappling hook") or lower:find("grenade") or lower:find("ice blast")
       or lower:find("laser beam") then
        return ITEM_FLAG_PROGRESSION
    end
    -- Relics and mods are useful
    if lower:find("ring") or lower:find("amulet") or lower:find("icebreaker")
       or lower:find("jacket") or lower:find("armor") or lower:find("goblet")
       or lower:find("backpack") or lower:find("roller") or lower:find("shot")
       or lower:find("claws") or lower:find("explosion") or lower:find("turret")
       or lower:find("blade") or lower:find("vortex") or lower:find("mushroom") then
        return ITEM_FLAG_USEFUL
    end
    -- Crystal filler
    if lower:find("crystal") or lower:find("nothing") then return 0 end
    -- Default: useful (most perks)
    return ITEM_FLAG_USEFUL
end

--- Add a formatted item send/receive message to the feed.
--- @param info table with: sender, receiver, item, location, flags, is_self_send, is_self_recv
function APOverlay.add_feed_item(info)
    if not info then return end

    -- Use provided flags, or try to classify by name
    local flags = info.flags or 0
    if flags == 0 and info.item then
        flags = classify_item_name(info.item)
    end

    local text

    if info.is_self_send and info.is_self_recv then
        text = "You found your " .. (info.item or "?") .. " (" .. (info.location or "?") .. ")"
    elseif info.is_self_send then
        text = "You sent " .. (info.receiver or "?") .. "'s " .. (info.item or "?") .. " (" .. (info.location or "?") .. ")"
    elseif info.is_self_recv then
        text = (info.sender or "?") .. " sent you " .. (info.item or "?") .. " (" .. (info.location or "?") .. ")"
    else
        text = (info.sender or "?") .. " sent " .. (info.receiver or "?") .. "'s " .. (info.item or "?")
    end

    APOverlay.add_feed_line(text, flags)
end

--- Add a raw text line to the feed with classification flags for coloring.
function APOverlay.add_feed_line(text, flags)
    if not is_alive() or not overlay.feed_vbox then return end

    text = wrap_line(text)
    flags = flags or 0
    feed_counter = feed_counter + 1

    local bg = flags_to_bg_color(flags)
    local accent = flags_to_accent_color(flags)

    -- Outer HBox: [accent stripe] [text area]
    local row = make("/Script/UMG.HorizontalBox", overlay.feed_vbox, "APFeedRow_" .. feed_counter)
    if not row then return end

    -- Accent stripe
    local stripe = make("/Script/UMG.Border", row, "APFeedStripe_" .. feed_counter)
    if stripe then
        stripe:SetBrushColor(FLinearColor(accent[1], accent[2], accent[3], accent[4]))
        stripe:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        local stripe_spacer = make("/Script/UMG.Spacer", stripe, "APFeedStripeSp_" .. feed_counter)
        if stripe_spacer then
            stripe_spacer.Size = { X = 4, Y = 0 }
            stripe:SetContent(stripe_spacer)
        end
        row:AddChildToHorizontalBox(stripe)
    end

    -- Text area with tinted background
    local border = make("/Script/UMG.Border", row, "APFeedBg_" .. feed_counter)
    if border then
        border:SetBrushColor(FLinearColor(bg[1], bg[2], bg[3], bg[4]))
        border:SetPadding({ Left = 8, Top = 3, Right = 10, Bottom = 3 })
        local tb = make_text(border, "APFeedText_" .. feed_counter, text, 12, nil)
        if tb then
            border:SetContent(tb)
        end
        row:AddChildToHorizontalBox(border)
    end

    overlay.feed_vbox:AddChildToVerticalBox(row)
    row.Visibility = VIS_SELF_HIT_INVIS

    table.insert(feed_entries, {
        widget = row,
        expire = os.clock() + FEED_DURATION,
    })

    while #feed_entries > MAX_FEED do
        local oldest = table.remove(feed_entries, 1)
        if oldest.widget then
            pcall(function() oldest.widget:SetVisibility(VIS_COLLAPSED) end)
        end
    end
end

--- Timer that removes expired feed entries.
function APOverlay._start_feed_timer()
    GameThread.loop(1000, function()
        if not is_alive() or not overlay.feed_vbox then
            return false  -- stop if overlay died
        end

        local now = os.clock()
        local i = 1
        while i <= #feed_entries do
            local entry = feed_entries[i]
            if now >= entry.expire then
                pcall(function() entry.widget:SetVisibility(VIS_COLLAPSED) end)
                table.remove(feed_entries, i)
            else
                i = i + 1
            end
        end

        return false  -- keep looping
    end)
end

return APOverlay
