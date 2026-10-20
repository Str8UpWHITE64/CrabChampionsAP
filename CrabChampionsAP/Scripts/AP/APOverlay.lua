-- AP/APOverlay.lua
-- In-game UMG overlay for Archipelago connection and status display.
-- Uses UE4SS StaticConstructObject to create UMG widgets from Lua.
-- Based on the GroundedAP overlay pattern.

local APOverlay = {}

local ConnStatus = require("AP/ConnStatus")

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

-- ============================================================================
-- Helpers
-- ============================================================================

local function FLinearColor(R, G, B, A)
    return { R = R, G = G, B = B, A = A }
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
    connect_btn_text = nil,
    error_text = nil,    -- plain-words reason the last connect failed
    info_text = nil,     -- slot, seed, counts while connected

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
local MAX_LOG_LINES = 5

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
        overlay.connect_btn_text = nil
        overlay.error_text = nil
        overlay.info_text = nil
        overlay.equip_weapons_text = nil
        overlay.equip_melee_text = nil
        overlay.equip_abilities_text = nil
        overlay.victory_summary_text = nil
        overlay.item_log_text = nil
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

local function make_text(parent, name, text, size, color)
    local tb = make("/Script/UMG.TextBlock", parent, name)
    if not tb then return nil end
    tb.Font.Size = size or 14
    pcall(function() tb:SetText(FText(text or "")) end)
    if color then
        local c = FSlateColor(color[1], color[2], color[3], color[4] or 1)
        pcall(function() tb.ColorAndOpacity = c end)
        pcall(function() tb:SetColorAndOpacity(c) end)
    end
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

-- What each text widget currently shows, by overlay field name. Kept in Lua so the harness
-- (and tests) can read it back without touching widgets.
local shown = {}

local function put(key, text)
    shown[key] = text or ""
    set_text(overlay[key], text)
end

local MAX_LINE_CHARS = 55

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
    overlay.conn_panel:SetBrushColor(FLinearColor(0.05, 0.05, 0.1, 0.85))
    overlay.conn_panel:SetPadding({ Left = 20, Top = 15, Right = 20, Bottom = 15 })

    overlay.conn_vbox = make("/Script/UMG.VerticalBox", overlay.conn_panel, "APConnVBox")
    overlay.conn_panel:SetContent(overlay.conn_vbox)

    -- Title
    local title = make_text(overlay.conn_vbox, "APTitle",
        "Archipelago Connection", 20, { 0.4, 0.8, 1, 1 })
    if title then overlay.conn_vbox:AddChildToVerticalBox(title) end

    overlay.info_text = make_text(overlay.conn_vbox, "APInfoText", "", 14, { 0.6, 1, 0.7, 1 })
    if overlay.info_text then overlay.conn_vbox:AddChildToVerticalBox(overlay.info_text) end

    add_spacer(overlay.conn_vbox, "APSpacer1", 10)

    -- Server row
    local server_row = make("/Script/UMG.HorizontalBox", overlay.conn_vbox, "APServerRow")
    if server_row then
        local lbl = make_text(server_row, "APServerLabel", "Server:    ", 16, { 0.9, 0.9, 0.9, 1 })
        if lbl then server_row:AddChildToHorizontalBox(lbl) end

        overlay.server_input = make("/Script/UMG.EditableTextBox", server_row, "APServerInput")
        if overlay.server_input then
            pcall(function()
                overlay.server_input:SetText(FText(ap_config and ap_config.server or "localhost:38281"))
                overlay.server_input.WidgetStyle.Font.Size = 16
                overlay.server_input.MinimumDesiredWidth = 300
            end)
            server_row:AddChildToHorizontalBox(overlay.server_input)
        end
        overlay.conn_vbox:AddChildToVerticalBox(server_row)
    end

    add_spacer(overlay.conn_vbox, "APSpacer2", 5)

    -- Slot row
    local slot_row = make("/Script/UMG.HorizontalBox", overlay.conn_vbox, "APSlotRow")
    if slot_row then
        local lbl = make_text(slot_row, "APSlotLabel", "Slot:         ", 16, { 0.9, 0.9, 0.9, 1 })
        if lbl then slot_row:AddChildToHorizontalBox(lbl) end

        overlay.slot_input = make("/Script/UMG.EditableTextBox", slot_row, "APSlotInput")
        if overlay.slot_input then
            pcall(function()
                overlay.slot_input:SetText(FText(ap_config and ap_config.slot or ""))
                overlay.slot_input.WidgetStyle.Font.Size = 16
                overlay.slot_input.MinimumDesiredWidth = 300
            end)
            slot_row:AddChildToHorizontalBox(overlay.slot_input)
        end
        overlay.conn_vbox:AddChildToVerticalBox(slot_row)
    end

    add_spacer(overlay.conn_vbox, "APSpacer3", 5)

    -- Password row
    local pw_row = make("/Script/UMG.HorizontalBox", overlay.conn_vbox, "APPwRow")
    if pw_row then
        local lbl = make_text(pw_row, "APPwLabel", "Password: ", 16, { 0.9, 0.9, 0.9, 1 })
        if lbl then pw_row:AddChildToHorizontalBox(lbl) end

        overlay.password_input = make("/Script/UMG.EditableTextBox", pw_row, "APPwInput")
        if overlay.password_input then
            pcall(function()
                overlay.password_input:SetText(FText(ap_config and ap_config.password or ""))
                overlay.password_input.WidgetStyle.Font.Size = 16
                overlay.password_input.MinimumDesiredWidth = 300
                overlay.password_input.IsPassword = true
            end)
            pw_row:AddChildToHorizontalBox(overlay.password_input)
        end
        overlay.conn_vbox:AddChildToVerticalBox(pw_row)
    end

    add_spacer(overlay.conn_vbox, "APSpacer4", 10)

    -- Connect hint
    local hint_border = make("/Script/UMG.Border", overlay.conn_vbox, "APHintBorder")
    if hint_border then
        hint_border:SetBrushColor(FLinearColor(0.15, 0.35, 0.55, 0.9))
        hint_border:SetPadding({ Left = 15, Top = 8, Right = 15, Bottom = 8 })
        overlay.connect_btn_text = make_text(hint_border, "APConnectHintText",
            "Press F3 to Connect   (F4 closes this window)", 16, { 1, 1, 1, 1 })
        if overlay.connect_btn_text then
            hint_border:SetContent(overlay.connect_btn_text)
        end
        overlay.conn_vbox:AddChildToVerticalBox(hint_border)
    end

    overlay.error_text = make_text(overlay.conn_vbox, "APErrorText", "", 15, { 1, 0.55, 0.45, 1 })
    if overlay.error_text then overlay.conn_vbox:AddChildToVerticalBox(overlay.error_text) end

    add_spacer(overlay.conn_vbox, "APSpacer5", 12)

    -- =================================================================
    -- Equipment Progress section
    -- =================================================================
    local equip_heading = make_text(overlay.conn_vbox, "APEquipHeading",
        "Equipment Progress", 16, { 0.4, 0.8, 1, 1 })
    if equip_heading then overlay.conn_vbox:AddChildToVerticalBox(equip_heading) end

    add_spacer(overlay.conn_vbox, "APSpacer6", 5)

    overlay.equip_weapons_text = make_text(overlay.conn_vbox, "APEquipWeapons",
        "(connect to see weapons)", 12, { 0.7, 0.7, 0.7, 1 })
    if overlay.equip_weapons_text then
        overlay.conn_vbox:AddChildToVerticalBox(overlay.equip_weapons_text)
    end

    overlay.equip_melee_text = make_text(overlay.conn_vbox, "APEquipMelee",
        "", 12, { 0.7, 0.7, 0.7, 1 })
    if overlay.equip_melee_text then
        overlay.conn_vbox:AddChildToVerticalBox(overlay.equip_melee_text)
    end

    overlay.equip_abilities_text = make_text(overlay.conn_vbox, "APEquipAbilities",
        "", 12, { 0.7, 0.7, 0.7, 1 })
    if overlay.equip_abilities_text then
        overlay.conn_vbox:AddChildToVerticalBox(overlay.equip_abilities_text)
    end

    add_spacer(overlay.conn_vbox, "APSpacer7", 8)

    overlay.victory_summary_text = make_text(overlay.conn_vbox, "APVictorySummary",
        "", 13, { 1, 0.9, 0.4, 1 })
    if overlay.victory_summary_text then
        overlay.conn_vbox:AddChildToVerticalBox(overlay.victory_summary_text)
    end

    add_spacer(overlay.conn_vbox, "APSpacer8", 12)

    -- =================================================================
    -- Recent Items log
    -- =================================================================
    local log_label = make_text(overlay.conn_vbox, "APLogLabel",
        "Recent Items:", 12, { 0.6, 0.6, 0.6, 1 })
    if log_label then overlay.conn_vbox:AddChildToVerticalBox(log_label) end

    overlay.item_log_text = make_text(overlay.conn_vbox, "APLogText",
        "(none)", 12, { 0.7, 0.9, 0.7, 1 })
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
    conn_slot.LayoutData.Offsets.Top = 0

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
    LoopAsync(500, function()
        if not cursor_state then return true end   -- nothing to watch; stop until the next open
        local pc_ok = false
        pcall(function() pc_ok = cursor_state.pc:IsValid() end)
        local stop = not pc_ok
        if not stop and release_check then
            local ok, r = pcall(release_check)
            stop = ok and r == true
        end
        if stop then
            -- hide_panel releases the pointer; ExecuteInGameThread keeps widget calls on the game thread
            ExecuteInGameThread(function() APOverlay.hide_panel() end)
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

function APOverlay.toggle_panel()
    if not is_alive() or not overlay.conn_panel then return end
    set_panel(not panel_shown)
    log("Connection panel " .. (panel_shown and "shown" or "hidden"))
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
    if overlay.status_text then
        put("status_text", text)
        if r and g and b then
            pcall(function()
                overlay.status_text:SetColorAndOpacity(FSlateColor(r, g, b, 1))
            end)
        end
    end
end

local HINT_IDLE = "Press F3 to Connect   (F4 closes this window)"
local HINT_CONNECTED = "Press F3 to Disconnect   (F4 closes this window)"
local HINT_CONNECTING = "Connecting...   (F3 to try again)"

local timeout_handler = nil
local conn_gen = 0
local info_gen = 0
local info_provider = nil

--- Reset everything that belongs to a connection: checklist, victory line and message log.
function APOverlay.clear_progress()
    item_log_lines = {}
    put("equip_weapons_text", "(connect to see weapons)")
    put("equip_melee_text", "")
    put("equip_abilities_text", "")
    put("victory_summary_text", "")
    put("item_log_text", "(none)")
    put("info_text", "")
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
        return
    end
    local ok, d = pcall(info_provider)
    put("info_text", ok and ConnStatus.info_text(d) or "")
end

function APOverlay._start_info_timer()
    info_gen = info_gen + 1
    local mine = info_gen
    LoopAsync(2000, function()
        if mine ~= info_gen or not is_alive() then return true end
        if panel_shown then APOverlay.refresh_info() end
        return false
    end)
end

local function start_timeout_watch()
    conn_gen = conn_gen + 1
    local mine = conn_gen
    LoopAsync(1000, function()
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
    shown.error_text = friendly
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
    shown.error_text = ""
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

--- Everything the panel and status label currently say, for the harness and tests.
function APOverlay.get_shown()
    local out = { state = overlay.state, panel = panel_shown }
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
    local run_length = LocationData.run_length or 28
    local req_rank = LocationData.required_rank or 0

    --- Build a per-item line: figure out the (received, completed) state and
    --- emit "  [marker] Name".  loc_id_fn converts a name to the relevant
    --- equipment-run location id.
    local function build_line(name, da_full_name, loc_id_fn)
        local got = da_full_name and ItemApply.unlocked[da_full_name]
        local completed = false
        if APClient and loc_id_fn then
            local lid = loc_id_fn(run_length, name, req_rank)
            if lid and APClient.is_location_checked then
                completed = APClient:is_location_checked(lid) == true
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
        return "  " .. marker .. " " .. name, got, completed
    end

    -- Build weapons checklist
    local pw = LocationData.pool_weapons or {}
    local w_received, w_completed = 0, 0
    local w_lines = {}
    for wname, _ in pairs(pw) do
        local fn = ItemData.get_da(CAT.WEAPON, wname)
        local line, got, done = build_line(wname, fn, LocationData.weapon_run_location_id_by_name)
        if got then w_received = w_received + 1 end
        if done then w_completed = w_completed + 1 end
        table.insert(w_lines, line)
    end
    table.sort(w_lines)

    local w_needed = LocationData.weapons_for_completion or 0
    local w_total = 0
    for _ in pairs(pw) do w_total = w_total + 1 end

    if w_total > 0 then
        put("equip_weapons_text",
            "Weapons (" .. w_received .. "/" .. w_total .. " received, "
            .. w_completed .. "/" .. w_needed .. " completed):\n"
            .. table.concat(w_lines, "\n"))
    else
        put("equip_weapons_text", "Weapons: (none in pool)")
    end

    -- Build melee checklist
    local pm = LocationData.pool_melee or {}
    local m_received, m_completed = 0, 0
    local m_lines = {}
    for mname, _ in pairs(pm) do
        local fn = ItemData.get_da(CAT.MELEE, mname)
        local line, got, done = build_line(mname, fn, LocationData.melee_run_location_id_by_name)
        if got then m_received = m_received + 1 end
        if done then m_completed = m_completed + 1 end
        table.insert(m_lines, line)
    end
    table.sort(m_lines)

    local m_needed = LocationData.melee_for_completion or 0
    local m_total = 0
    for _ in pairs(pm) do m_total = m_total + 1 end

    if m_total > 0 then
        put("equip_melee_text",
            "Melee (" .. m_received .. "/" .. m_total .. " received, "
            .. m_completed .. "/" .. m_needed .. " completed):\n"
            .. table.concat(m_lines, "\n"))
    else
        put("equip_melee_text", "")
    end

    -- Build abilities checklist
    local pa = LocationData.pool_abilities or {}
    local a_received, a_completed = 0, 0
    local a_lines = {}
    for aname, _ in pairs(pa) do
        local fn = ItemData.get_da(CAT.ABILITY, aname)
        local line, got, done = build_line(aname, fn, LocationData.ability_run_location_id_by_name)
        if got then a_received = a_received + 1 end
        if done then a_completed = a_completed + 1 end
        table.insert(a_lines, line)
    end
    table.sort(a_lines)

    local a_needed = LocationData.ability_for_completion or 0
    local a_total = 0
    for _ in pairs(pa) do a_total = a_total + 1 end

    if a_total > 0 then
        put("equip_abilities_text",
            "Abilities (" .. a_received .. "/" .. a_total .. " received, "
            .. a_completed .. "/" .. a_needed .. " completed):\n"
            .. table.concat(a_lines, "\n"))
    else
        put("equip_abilities_text", "")
    end

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
    LoopAsync(1000, function()
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
