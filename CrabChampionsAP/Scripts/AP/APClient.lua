-- AP/APClient.lua
-- High-level Archipelago client for Crab Champions (UE4SS + lua-apclientpp)
--
-- IMPORTANT: lua-apclientpp requires that instantiation and poll() happen
-- on the SAME thread. UE4SS mod loading and RegisterHook callbacks run on
-- different Lua states/threads. So ALL DLL interaction (creation, handlers,
-- polling) must happen inside a single LoopAsync callback.

local APClientWrapper = require("AP/APClientWrapper")
local APConfig = require("AP/APConfig")

local Client = {
    enabled = false,

    -- Config (populated from ap_config.json)
    server = "localhost:38281",
    slot = "",
    password = "",
    game = "Crab Champions",
    uuid = "",
    tags = { "AP" },
    items_handling = 7,
    version = { 0, 5, 1 },

    -- Runtime state
    _client = nil,
    _connected = false,
    _slot_connected = false,
    _deferred_init = false,

    -- Slot data from server
    slot_number = -1,
    team = -1,
    slot_data = {},

    -- Item tracking (append-only with index-based ack)
    _applied_index = 0,
    _pending_items = {},

    -- Location tracking
    _checked = {},           -- set[location_id] = true

    -- Outgoing queues (populated by hooks, consumed by LoopAsync)
    _outgoing_checks = {},   -- array of location_ids to send
    _outgoing_say = {},      -- array of chat messages
    _outgoing_status = nil,  -- status code to send

    -- Command queue (populated by Console keybinds on game thread, consumed by LoopAsync)
    _pending_commands = {},  -- array of {cmd=string, args=table}
    _config_path = nil,      -- stored for config reload

    -- Callbacks (set by mod code)
    on_item = nil,           -- function(item_entry)
    on_message = nil,        -- function(text)
    on_slot_connected = nil, -- function(slot_data)
    on_deathlink = nil,      -- function(source, cause)
}

local LOG_PREFIX = "[CrabAP]"

local function log(msg)
    print(LOG_PREFIX .. " " .. tostring(msg))
end

-- AP status constants
Client.STATUS_UNKNOWN  = 0
Client.STATUS_CONNECTED = 5
Client.STATUS_READY    = 10
Client.STATUS_PLAYING  = 20
Client.STATUS_GOAL     = 30

--- Initialize the AP client (config only).
--- DLL interaction is deferred to a LoopAsync callback so that
--- instantiation and polling happen on the same thread.
---@param config_path string|nil Path to ap_config.json
---@return boolean success
function Client:init(config_path)
    -- Load config (pure Lua, no DLL needed)
    config_path = config_path or "Mods/ArchipelagoMod/Scripts/ap_config.json"
    self._config_path = config_path
    local config = APConfig.load(config_path)

    self.server = config.server or self.server
    self.slot = config.slot or self.slot
    self.password = config.password or self.password
    self.game = config.game or self.game
    self.uuid = config.uuid or self.uuid
    self.items_handling = config.items_handling or self.items_handling

    if config.tags and type(config.tags) == "table" then
        self.tags = config.tags
    end

    if self.slot == "" then
        log("WARNING: No slot name configured in ap_config.json")
    end

    -- Mark for deferred init — actual DLL work happens in LoopAsync
    self._deferred_init = true
    self.enabled = true
    log("Config loaded (server=" .. self.server .. ", slot=" .. self.slot .. ")")

    -- Start the async loop — ALL DLL interaction happens here
    self:_start_async_loop()

    return true
end

--- Start LoopAsync that owns all DLL interaction.
--- This ensures instantiation + poll run on the same thread.
function Client:_start_async_loop()
    local self_ref = self

    LoopAsync(500, function()
        -- Always process commands, even when disabled (needed for reconnect)
        if #self_ref._pending_commands > 0 then
            local cmds = self_ref._pending_commands
            self_ref._pending_commands = {}
            for _, entry in ipairs(cmds) do
                local cmd_ok, cmd_err = pcall(self_ref._execute_command, self_ref, entry.cmd, entry.args)
                if not cmd_ok then
                    log("Command error (" .. tostring(entry.cmd) .. "): " .. tostring(cmd_err))
                end
            end
        end

        if not self_ref.enabled then return false end -- idle but keep looping

        local ok, err = pcall(function()
            -- Deferred init: load DLL + create client (first iteration)
            if self_ref._deferred_init then
                self_ref:_create_client()
            end

            if not self_ref._client then return end

            -- Poll the network (handlers fire here)
            self_ref._client:poll()

            -- Process outgoing queues
            self_ref:_process_outgoing()

            -- Apply pending received items
            self_ref:_apply_pending_items()
        end)

        if not ok then
            log("Async loop error: " .. tostring(err))
        end

        return false -- keep looping
    end)

    log("LoopAsync started (500ms) — client will connect on first tick")
end

--- Create the native client (called from LoopAsync thread).
function Client:_create_client()
    self._deferred_init = false

    log("Creating AP client...")
    self._client = APClientWrapper.new(self.uuid, self.game, self.server)
    if not self._client then
        log("ERROR: Failed to create AP client")
        self.enabled = false
        return
    end

    self:_register_handlers()
    log("AP client ready (server=" .. self.server .. ", slot=" .. self.slot .. ")")
end

--- Register all event handlers on the native client.
function Client:_register_handlers()
    local c = self._client

    c:set_socket_connected_handler(function()
        self._connected = true
        log("Socket connected to " .. self.server)
    end)

    c:set_socket_disconnected_handler(function()
        self._connected = false
        self._slot_connected = false
        log("Socket disconnected")
    end)

    c:set_socket_error_handler(function(err)
        log("Socket error: " .. tostring(err))
    end)

    c:set_room_info_handler(function()
        log("Room info received, connecting slot '" .. self.slot .. "'...")
        c:ConnectSlot(self.slot, self.password, self.items_handling, self.tags, self.version)
    end)

    c:set_slot_connected_handler(function(slot_data)
        self._slot_connected = true
        self.slot_data = slot_data or {}
        log("Slot connected successfully")

        if self.on_slot_connected then
            pcall(self.on_slot_connected, self.slot_data)
        end
    end)

    c:set_slot_refused_handler(function(reasons)
        self._slot_connected = false
        local reason_str = "unknown"
        if type(reasons) == "table" then
            reason_str = table.concat(reasons, ", ")
        elseif reasons then
            reason_str = tostring(reasons)
        end
        log("ERROR: Slot connection refused: " .. reason_str)
    end)

    c:set_items_received_handler(function(items)
        self:_on_items_received(items)
    end)

    c:set_location_checked_handler(function(locations)
        if type(locations) == "table" then
            for _, loc in ipairs(locations) do
                self._checked[tonumber(loc)] = true
            end
        end
    end)

    c:set_print_json_handler(function(data)
        self:_on_print_json(data)
    end)

    c:set_bounced_handler(function(bounce)
        self:_on_bounced(bounce)
    end)

    c:set_data_package_changed_handler(function(data)
        log("Data package updated")
    end)
end

-- ---------------------------------------------------------------
-- Incoming: Items
-- ---------------------------------------------------------------

function Client:_on_items_received(items)
    if not items then return end
    if type(items) == "table" then
        for _, it in ipairs(items) do
            self:_enqueue_item(it)
        end
    else
        log("items_received: unexpected type " .. type(items))
    end
end

function Client:_enqueue_item(it)
    local idx = tonumber(it.index) or nil
    local item_id = tonumber(it.item) or nil
    local from_player = tonumber(it.player) or 0
    local flags = tonumber(it.flags) or 0

    if not idx then
        idx = self._applied_index + #self._pending_items + 1
    end

    if idx <= self._applied_index then return end

    table.insert(self._pending_items, {
        index = idx,
        item = item_id,
        player = from_player,
        flags = flags,
    })
end

-- ---------------------------------------------------------------
-- Incoming: Messages
-- ---------------------------------------------------------------

function Client:_on_print_json(data)
    if not data then return end

    local message = nil

    if type(data) == "string" then
        message = data
    elseif type(data) == "table" then
        local parts = data.data or data
        if type(parts) == "table" then
            local text_parts = {}
            for _, part in ipairs(parts) do
                if type(part) == "table" then
                    local ptype = part.type or "text"
                    local text = part.text or ""

                    if ptype == "player_id" then
                        local pid = tonumber(text) or 0
                        local alias = self._client:get_player_alias(pid)
                        text_parts[#text_parts + 1] = alias or ("Player" .. pid)
                    elseif ptype == "item_id" then
                        local iid = tonumber(text) or 0
                        local name = self._client:get_item_name(iid, self.game)
                        text_parts[#text_parts + 1] = name or ("Item#" .. iid)
                    elseif ptype == "location_id" then
                        local lid = tonumber(text) or 0
                        local name = self._client:get_location_name(lid, self.game)
                        text_parts[#text_parts + 1] = name or ("Location#" .. lid)
                    else
                        text_parts[#text_parts + 1] = text
                    end
                elseif type(part) == "string" then
                    text_parts[#text_parts + 1] = part
                end
            end
            message = table.concat(text_parts)
        end
    end

    if message and message ~= "" then
        log("MSG: " .. message)
        if self.on_message then
            pcall(self.on_message, message)
        end
    end
end

-- ---------------------------------------------------------------
-- Incoming: Bounce / DeathLink
-- ---------------------------------------------------------------

function Client:_on_bounced(bounce)
    if not bounce or type(bounce) ~= "table" then return end

    local tags = bounce.tags or {}
    local data = bounce.data or {}

    for _, tag in ipairs(tags) do
        if tag == "DeathLink" then
            local source = data.source or "unknown"
            local cause = data.cause or ""
            local msg = "DeathLink from " .. source
            if cause ~= "" then
                msg = msg .. ": " .. cause
            end
            log(msg)

            if self.on_deathlink then
                pcall(self.on_deathlink, source, cause)
            end
            if self.on_message then
                pcall(self.on_message, msg)
            end
            return
        end
    end
end

-- ---------------------------------------------------------------
-- Outgoing queue processing (runs in LoopAsync thread)
-- ---------------------------------------------------------------

function Client:_process_outgoing()
    if not self._client or not self._slot_connected then return end

    -- Location checks
    if #self._outgoing_checks > 0 then
        local new_checks = {}
        for _, lid in ipairs(self._outgoing_checks) do
            lid = tonumber(lid)
            if lid and not self._checked[lid] then
                new_checks[#new_checks + 1] = lid
                self._checked[lid] = true
            end
        end
        self._outgoing_checks = {}

        if #new_checks > 0 then
            self._client:LocationChecks(new_checks)
            log("Sent " .. #new_checks .. " location check(s)")
        end
    end

    -- Chat messages
    if #self._outgoing_say > 0 then
        for _, text in ipairs(self._outgoing_say) do
            self._client:Say(tostring(text))
        end
        self._outgoing_say = {}
    end

    -- Status update
    if self._outgoing_status then
        self._client:StatusUpdate(self._outgoing_status)
        log("Sent status: " .. tostring(self._outgoing_status))
        self._outgoing_status = nil
    end
end

function Client:_apply_pending_items()
    if #self._pending_items == 0 then return end

    table.sort(self._pending_items, function(a, b) return a.index < b.index end)

    for i = 1, #self._pending_items do
        local it = self._pending_items[i]
        if it.index > self._applied_index then
            if self.on_item then
                local ok, err = pcall(self.on_item, it)
                if not ok then
                    log("ERROR applying item index=" .. tostring(it.index) .. ": " .. tostring(err))
                    break
                end
            end
            self._applied_index = it.index
        end
    end

    self._pending_items = {}
end

-- ---------------------------------------------------------------
-- Command execution (runs on LoopAsync thread)
-- ---------------------------------------------------------------

--- Execute a queued command on the LoopAsync thread.
---@param cmd string Command name: "connect", "disconnect", "reload_config"
---@param args table|nil Optional arguments
function Client:_execute_command(cmd, args)
    if cmd == "disconnect" then
        log("Disconnecting...")
        self._client = nil
        self._connected = false
        self._slot_connected = false
        self.enabled = false
        log("Disconnected by user")

    elseif cmd == "connect" then
        -- Reload config so any edits take effect
        if self._config_path then
            local config = APConfig.load(self._config_path)
            self.server = config.server or self.server
            self.slot = config.slot or self.slot
            self.password = config.password or self.password
            if config.tags and type(config.tags) == "table" then
                self.tags = config.tags
            end
        end
        -- Reset state for fresh connection
        self._connected = false
        self._slot_connected = false
        self._applied_index = 0
        self._pending_items = {}
        self._checked = {}
        self.enabled = true
        self._deferred_init = true
        log("Reconnecting to " .. self.server .. " as " .. self.slot .. "...")

    elseif cmd == "reload_config" then
        if self._config_path then
            local config = APConfig.load(self._config_path)
            self.server = config.server or self.server
            self.slot = config.slot or self.slot
            self.password = config.password or self.password
            if config.tags and type(config.tags) == "table" then
                self.tags = config.tags
            end
            log("Config reloaded (server=" .. self.server .. ", slot=" .. self.slot .. ")")
        else
            log("ERROR: No config path stored — cannot reload")
        end
    else
        log("Unknown command: " .. tostring(cmd))
    end
end

--- Queue a command for execution on the LoopAsync thread.
--- Safe to call from the game thread (RegisterKeyBind, RegisterHook).
---@param cmd string Command name
---@param args table|nil Optional arguments
function Client:queue_command(cmd, args)
    self._pending_commands[#self._pending_commands + 1] = {
        cmd = cmd,
        args = args or {},
    }
end

-- ---------------------------------------------------------------
-- Public API (safe to call from any thread — queues for LoopAsync)
-- ---------------------------------------------------------------

--- Queue a location check by numeric ID.
---@param location_id number
function Client:send_check(location_id)
    location_id = tonumber(location_id)
    if not location_id then return end
    if self._checked[location_id] then return end
    self._outgoing_checks[#self._outgoing_checks + 1] = location_id
end

--- Queue multiple location checks.
---@param location_ids table Array of numeric location IDs
function Client:send_checks(location_ids)
    for _, lid in ipairs(location_ids) do
        self:send_check(lid)
    end
end

--- Queue a chat message.
---@param text string
function Client:say(text)
    self._outgoing_say[#self._outgoing_say + 1] = tostring(text)
end

--- Queue victory (goal completion).
function Client:send_victory()
    self._outgoing_status = self.STATUS_GOAL
    log("Victory queued!")
end

--- Queue a status update.
---@param status number Status code
function Client:send_status(status)
    self._outgoing_status = status
end

--- Queue a DeathLink bounce.
---@param source string Who died
---@param cause string|nil How they died
function Client:send_deathlink(source, cause)
    -- DeathLink needs direct client access; queue it specially
    self._outgoing_deathlink = {
        source = source or self.slot,
        cause = cause or "",
    }
end

-- ---------------------------------------------------------------
-- State queries (safe from any thread)
-- ---------------------------------------------------------------

function Client:is_connected()
    return self._connected
end

function Client:is_slot_connected()
    return self._slot_connected
end

function Client:is_location_checked(location_id)
    return self._checked[tonumber(location_id)] == true
end

return Client
