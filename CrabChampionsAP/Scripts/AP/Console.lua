-- AP/Console.lua
-- In-game console UI for the Archipelago mod.
-- Provides keybind controls and categorized logging via the UE4SS debug console.
--
-- Keybinds:
--   F6 = Toggle AP connection (connect / disconnect)
--   F7 = Reload config from ap_config.json
--   F8 = Print status summary

local Console = {}

-- References (set during init)
local client = nil

------------------------------------------------------------
-- Categorized logging
------------------------------------------------------------

--- Print a categorized log message to the UE4SS console.
---@param category string  e.g. "STATUS", "ITEM", "MSG", "CHECK", "ERROR", "CMD", "INFO"
---@param message string
function Console.log(category, message)
    print(string.format("[CrabAP][%s] %s", category, tostring(message)))
end

------------------------------------------------------------
-- Status display
------------------------------------------------------------

--- Print a multi-line status summary to the console.
function Console.print_status()
    local sep = "=================================="
    Console.log("INFO", sep)
    Console.log("INFO", "  Archipelago Mod Status")
    Console.log("INFO", sep)
    Console.log("INFO", "  Server:      " .. (client.server or "?"))
    Console.log("INFO", "  Slot:        " .. (client.slot or "?"))
    Console.log("INFO", "  Connected:   " .. tostring(client:is_connected()))
    Console.log("INFO", "  Slot OK:     " .. tostring(client:is_slot_connected()))

    -- Count checked locations
    local checked_count = 0
    if client._checked then
        for _ in pairs(client._checked) do checked_count = checked_count + 1 end
    end
    Console.log("INFO", "  Checked:     " .. checked_count .. " locations")
    Console.log("INFO", "  Items:       " .. (client._applied_index or 0) .. " received")

    -- Show goal equipment if slot data is available
    local opts = client.slot_data and client.slot_data.options or client.slot_data or {}
    if opts and opts.pool_weapons then
        Console.log("INFO", sep)
        Console.log("INFO", "  Goal Equipment")
        Console.log("INFO", sep)
        Console.log("INFO", "  Rank:        " .. tostring(opts.required_rank_name or "?"))
        Console.log("INFO", "  Run Length:  " .. tostring(opts.run_length or "?") .. " islands")

        local pw = opts.pool_weapons or {}
        local wfc = opts.weapons_for_completion or #pw
        Console.log("INFO", "  Weapons:     " .. wfc .. " of " .. #pw .. " needed")
        for _, name in ipairs(pw) do
            Console.log("INFO", "    - " .. name)
        end

        local pm = opts.pool_melee or {}
        local mfc = opts.melee_for_completion or 0
        if mfc > 0 then
            Console.log("INFO", "  Melee:       " .. mfc .. " of " .. #pm .. " needed")
            for _, name in ipairs(pm) do
                Console.log("INFO", "    - " .. name)
            end
        end

        local pa = opts.pool_abilities or {}
        local afc = opts.ability_for_completion or 0
        if afc > 0 then
            Console.log("INFO", "  Abilities:   " .. afc .. " of " .. #pa .. " needed")
            for _, name in ipairs(pa) do
                Console.log("INFO", "    - " .. name)
            end
        end
    end
    Console.log("INFO", sep)
end

------------------------------------------------------------
-- Keybind handlers
------------------------------------------------------------

local function on_toggle_connection()
    if client:is_connected() or client:is_slot_connected() then
        Console.log("CMD", "Disconnecting from AP server...")
        client:queue_command("disconnect")
    else
        Console.log("CMD", "Connecting to AP server...")
        client:queue_command("connect")
    end
end

local function on_reload_config()
    Console.log("CMD", "Reloading config from ap_config.json...")
    client:queue_command("reload_config")
end

local function on_print_status()
    Console.print_status()
end

------------------------------------------------------------
-- Initialization
------------------------------------------------------------

--- Initialize the console module.
---@param ap_client table  APClient instance
---@param cfg_path string  Path to ap_config.json (stored on client already)
function Console.init(ap_client, cfg_path)
    client = ap_client

    -- Register keybinds
    RegisterKeyBind(Key.F6, on_toggle_connection)
    RegisterKeyBind(Key.F7, on_reload_config)
    RegisterKeyBind(Key.F8, on_print_status)

    -- Print help banner
    Console.log("INFO", "=== Archipelago Controls ===")
    Console.log("INFO", "  F3 = Connect/Disconnect (overlay)")
    Console.log("INFO", "  F4 = Toggle AP overlay panel")
    Console.log("INFO", "  F6 = Toggle connection (console)")
    Console.log("INFO", "  F7 = Reload config")
    Console.log("INFO", "  F8 = Show status")
    Console.log("INFO", "Open console with ~ (tilde)")
end

return Console
