-- Optional QB/QBX webhook bridge. Standard smallresources installs may not expose GetWebhook.
local function smallresourcesWebhook(name)
    if not IsDuplicityVersion() then return '' end
    local configured = GetConvar(GetCurrentResourceName() .. '_webhook_' .. name, '')
    if configured ~= '' then return configured end
    for _, resource in ipairs({'qbx_smallresources', 'qbx-smallresources', 'qb-smallresources'}) do
        if GetResourceState(resource) == 'started' then
            local ok, url = pcall(function() return exports[resource]:GetWebhook(name) end)
            if ok and type(url) == 'string' and url ~= '' then return url end
        end
    end
    return ''
end
Config = {}
-- Admin panels: server admin/god roles only. false blocks that role.
Config.AdminAccess = { admin = true, god = true }
Config.Command    = 'wipemenu'
Config.Permission = 'admin'      -- 'admin' or 'god'  (god is safer for a wipe tool)
Config.Inventory  = 'ox'         -- 'qb' (qb-inventory) or 'ox' (ox_inventory)
Config.InventoryResource = 'ox_inventory'

-- Extra tables wiped (and backed up) on a FULL character wipe: { table, owner column }
-- Missing tables are skipped automatically.
Config.ExtraTables = {
    { 'playerskins',     'citizenid' },
    { 'player_outfits',  'citizenid' },
    { 'player_houses',   'citizenid' },
    { 'apartments',      'citizenid' },
    { 'player_contacts', 'citizenid' },
}



-- Customer integrations: this is the only editable Lua file.
Config.Framework = 'auto' -- qbcore / qbox / esx / custom
Config.CoreResource = 'auto' -- qb-core / qbx_core, selected by Framework
Config.AdminAce = 'UltimateXwipemenu.admin'
Config.Custom = {}
-- CLIENT custom hooks, assigned here:
-- Config.Custom.Core = function() return a QB-shaped client facade end
-- Config.Custom.Target = function() return a QB-target-compatible object end
-- Config.Custom.Notify = function(message, kind, duration) ... end
-- Config.Custom.Fuel = function(vehicle, amount) ... end
-- Config.Custom.KeysClient = function(plate, vehicle) ... end
-- Config.GiveKeys remains overridable here; default uses authorized server delivery.
-- Server database names/columns. SQL layouts and JSON formats must be compatible.
Config.Database = {
    players = { table='players', columns={citizenid='citizenid',license='license',charinfo='charinfo',money='money',inventory='inventory'} },
    player_vehicles = { table='player_vehicles', columns={license='license',citizenid='citizenid',vehicle='vehicle',hash='hash',mods='mods',plate='plate',garage='garage',state='state'} },
    ox_inventory = { table='ox_inventory', columns={owner='owner',name='name',data='data'} },
    inventories = { table='inventories', columns={identifier='identifier',items='items'} }
}
-- Webhook URLs can be entered below. This config is shared: players can download its contents.
-- Leave URLs empty in packages supplied to customers.
if IsDuplicityVersion() then
    Config.LogWebhooks = {
        full = '',
        money = '',
        vehicles = ''
    }
    Config.LogColor = 15844367

    -- SERVER custom hooks (configure these for unsupported systems):
    -- Config.Custom.Core = function() return a QB-shaped server facade end
    -- Config.Custom.IsAdmin = function(source, permission) return true or false end
    -- Config.Custom.Money = {GetBalances=function(player) return {cash=...,bank=...} end,
    --     AddMoney=function(player,method,amount,reason) ... end,
    --     RemoveMoney=function(player,method,amount,reason) ... end,
    --     SetMoney=function(player,method,amount,reason) ... end}
    -- Config.Custom.Inventory = function() return your inventory adapter end
    -- Config.Custom.ClearInventory = function(source) ... end
    -- Config.Custom.KeysServer = function(source,vehicle,plate) ... end
    -- Config.Custom.MapSQL = function(sql) return rewrittenSQL end
    -- Config.Custom.Query = function(canonicalSQL, parameters) return canonicalRows end
    -- Config.Custom.DeleteInventoryRecord = function(stashId) ... end
    -- Config.Custom.PlateExists = function(plate) return true or false end
    -- Config.Custom.CreateOwnedVehicle = function(player,model,plate,props,garage) return id end
    -- Config.Custom.DeleteOwnedVehicle = function(plate,citizenid) return success end
    -- Config.Custom.SaveOwnedProps = function(props,plate,citizenid,vehicle) return success end
end


UltimateXESX.Configure(Config)
-- Resolve auto selections once at startup. Explicit selections remain unchanged.
-- Start integrations before this resource; restart after changing them.
do
    local function running(name) return GetResourceState(name) == 'started' end
    local function pick(setting, candidates, fallback)
        if Config[setting] ~= 'auto' then return end
        for _, name in ipairs(candidates) do
            if running(name) then Config[setting] = name return end
        end
        if fallback then Config[setting] = fallback return end
        error('[' .. GetCurrentResourceName() .. '] Cannot detect ' .. setting .. '; start a supported resource or configure it explicitly.')
    end
    if Config.Framework == 'auto' then
        if running('qbx_core') then Config.Framework = 'qbox'
        elseif running('qb-core') then Config.Framework = 'qbcore'
        else error('No QBCore/Qbox detected; set Config.Framework and Config.CoreResource explicitly.') end
    end
    if Config.CoreResource == 'auto' then Config.CoreResource = (Config.Framework=='esx' and 'es_extended' or Config.Framework=='qbox' and 'qbx_core' or 'qb-core') end
    pick('Target', {'ox_target', 'qb-target'})
    pick('Fuel', {'ox_fuel', 'LegacyFuel', 'ps-fuel', 'cdn-fuel'}, 'native')
    if IsDuplicityVersion() then
        pick('Keys', {'qbx_vehiclekeys', 'qb-vehiclekeys'})
        pick('Banking', {'qb-banking', 'qb-management'})
        if Config.Inventory == 'auto' then
            if running('ox_inventory') then Config.Inventory = 'ox'
            elseif running('qb-inventory') then Config.Inventory = 'qb'
            else error('No supported inventory detected; configure Config.Inventory/custom adapter.') end
        end
        -- Hotel/stashes require the ox-compatible API; native QB inventory is not equivalent.
        pick('InventoryResource', {'ox_inventory'})
        pick('GarageSystem', {'qbx_vehicles', 'op-garages'}, 'sql')
    end
end

-- Additional ownership tables for ID changes and character replacement.
Config.CitizenIdTables = {} -- {{"custom_table","citizenid"}}
Config.CharacterSaveWaitMs = 2000
Config.RestoreCharacterSlots = 0 -- Set your multicharacter capacity; 0 leaves it unrestricted here.

-- Tables holding account license in addition to the character citizen ID.
-- Add custom tables using this same ownership layout.
Config.CharacterSwapAccountTables = {{"player_vehicles","citizenid","license"}}

if IsDuplicityVersion() then Config.LogWebhooks={full=smallresourcesWebhook('AdminLogs'),money=smallresourcesWebhook('playermoney'),vehicles=smallresourcesWebhook('admincar')} end

if Config.Framework=='esx' and IsDuplicityVersion() then Config.Custom.Query=function(...) return UltimateXESX.Query(...) end end
