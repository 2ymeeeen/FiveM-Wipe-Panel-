Integration = {}
local I = Integration
local custom = Config.Custom or {}
local function started(name) assert(GetResourceState(name) == 'started', '[integration] Start ' .. name .. ' first') end
local function requireId(s) assert(type(s)=='string' and s:match('^[%w_]+$'), 'Invalid configured SQL identifier'); return s end
if Config.CoreResource == 'auto' then Config.CoreResource = (Config.Framework=='esx' and 'es_extended' or Config.Framework=='qbox' and 'qbx_core' or 'qb-core') end
local core
if (Config.Framework=='qbcore' or Config.Framework=='esx') then
    started(Config.CoreResource); core = UltimateXESX.GetCore(Config.CoreResource)
    I.Core = {Functions={},Shared=core.Shared,Commands={}}
    for key,fn in pairs(core.Functions) do I.Core.Functions[key]=fn end
elseif Config.Framework == 'qbox' then
    started(Config.CoreResource)
    I.Core = {Functions={},Commands={},Shared={Jobs=exports[Config.CoreResource]:GetJobs(),Vehicles=exports[Config.CoreResource]:GetVehiclesByName()}}
    for _,name in ipairs({'GetPlayer','GetPlayerByCitizenId','GetQBPlayers'}) do
        local exportName=name
        I.Core.Functions[name]=function(...) return exports[Config.CoreResource][exportName](exports[Config.CoreResource],...) end
    end
    I.Core.Functions.GetPlayers=function() local ids={} for id in pairs(I.Core.Functions.GetQBPlayers()) do ids[#ids+1]=id end return ids end
    I.Core.Functions.CreateCallback=function(name,fn)
        lib.callback.register(name,function(src,...)
            local response=promise.new()
            fn(src,function(result) response:resolve(result) end,...)
            return Citizen.Await(response)
        end)
    end
    local function random(n,chars) local out='' for _=1,n do local index=math.random(1,#chars);out=out..chars:sub(index,index) end return out end
    I.Core.Shared.RandomInt=function(n) return random(n,'0123456789') end
    I.Core.Shared.RandomStr=function(n) return random(n,'ABCDEFGHIJKLMNOPQRSTUVWXYZ') end
elseif Config.Framework == 'custom' then
    assert(custom.Core, 'Configure Config.Custom.Core on the server'); I.Core=custom.Core()
else error('Invalid Config.Framework') end
function I.IsAdmin(src, permission)
    local access = Config.AdminAccess or {}
    local function ace(names)
        for _, name in ipairs(names) do if IsPlayerAceAllowed(src, name) then return true end end
        return false
    end
    local isGod = ace({'ayman.role.god', 'qbcore.god', 'god'})
    local isAdmin = ace({'ayman.role.admin', 'qbcore.admin', 'admin'})
    if (Config.Framework=='qbcore' or Config.Framework=='esx') then
        local functions = core.Functions
        isGod = isGod or functions.HasPermission(src, 'god') == true
        isAdmin = isAdmin or functions.HasPermission(src, 'admin') == true
    end
    -- Check god first because god may inherit admin permissions.
    if isGod then return access.god == true end
    if isAdmin then return access.admin == true end
    if access.admin ~= true and access.god ~= true then return false end
    if Config.Custom.IsAdmin then return Config.Custom.IsAdmin(src, permission) == true end
    return false
end
I.Core.Functions.HasPermission=I.IsAdmin
I.Core.Commands.Add=function(name,_,_,_,fn,permission)
    RegisterCommand(name,function(src,args)
        if src>0 and (not permission or I.IsAdmin(src,permission)) then fn(src,args) end
    end,false)
end
-- Wrap player money methods without mutating the framework's original Player object.
local getPlayer=I.Core.Functions.GetPlayer
local byCitizen=I.Core.Functions.GetPlayerByCitizenId
local function wrap(p)
    if not p or not custom.Money then return p end
    local copy={};for k,v in pairs(p) do copy[k]=v end
    if custom.Money.GetBalances then
        local balances=custom.Money.GetBalances(p)
        assert(type(balances)=='table','Custom.Money.GetBalances must return cash/bank balances')
        copy.PlayerData={};for key,value in pairs(p.PlayerData) do copy.PlayerData[key]=value end
        copy.PlayerData.money=balances
    end
    copy.Functions={};for k,v in pairs(p.Functions) do copy.Functions[k]=v end
    for _,key in ipairs({'AddMoney','RemoveMoney','SetMoney'}) do
        if custom.Money[key] then local name=key;copy.Functions[name]=function(...) return custom.Money[name](p,...) end end
    end
    return copy
end
I.Core.Functions.GetPlayer=function(...) return wrap(getPlayer(...)) end
I.Core.Functions.GetPlayerByCitizenId=function(...) return wrap(byCitizen(...)) end
function I.Notify(src,message,kind) TriggerClientEvent(GetCurrentResourceName()..':integration:notify',src,message,kind or 'primary') end

-- SQL adapters preserve old code's canonical names and normalize SELECT results.
-- Each table is mapped separately; the resources' own tables are not renamed.
function I.MapSQL(sql)
    if custom.MapSQL then return custom.MapSQL(sql) end
    local selected
    for original,spec in pairs(Config.Database or {}) do
        if sql:match('%f[%w_]'..original..'%f[^%w_]') then
            assert(not selected,'Joins between mapped tables require Custom.MapSQL')
            selected={original=original,spec=spec}
        end
    end
    if not selected then return sql end
    local original,spec=selected.original,selected.spec
    requireId(spec.table)
    local mapping={[original]=spec.table}
    for from,to in pairs(spec.columns or {}) do requireId(from);requireId(to);mapping[from]=to end
    -- SQL strings (JSON paths, literal values) must not be rewritten.
    local function words(part) return (part:gsub('[%a_][%w_]*',function(word) return mapping[word] or word end)) end
    local out,index={},1
    while index<=#sql do
        local quote=sql:find("'",index,true)
        if not quote then out[#out+1]=words(sql:sub(index));break end
        out[#out+1]=words(sql:sub(index,quote-1))
        local finish=quote+1
        while finish<=#sql do
            if sql:sub(finish,finish)=='\\' then finish=finish+2
            elseif sql:sub(finish,finish)=="'" then
                if sql:sub(finish+1,finish+1)=="'" then finish=finish+2 else break end
            else finish=finish+1 end
        end
        out[#out+1]=sql:sub(quote,finish);index=finish+1
    end
    return table.concat(out),spec
end
function I.Query(sql,params)
    if custom.Query then return custom.Query(sql,params or {}) end
    local mapped,spec=I.MapSQL(sql)
    local result=MySQL.query.await(mapped,params or {})
    if spec and type(result)=='table' then
        for _,row in ipairs(result) do
            if type(row)=='table' then
                local normalized={}
                for from,to in pairs(spec.columns or {}) do if row[to]~=nil then normalized[from]=row[to];if from~=to then row[to]=nil end end end
                for key,value in pairs(normalized) do row[key]=value end
            end
        end
    end
    return result
end
function I.Transaction(queries)
    if Config.Framework=='esx' then return UltimateXESX.Transaction(queries) end
    local mapped={}
    for _,item in ipairs(queries) do mapped[#mapped+1]={query=I.MapSQL(item.query),values=item.values} end
    return MySQL.transaction.await(mapped)
end
function I.Inventory()
    if custom.Inventory then return custom.Inventory() end
    local name=Config.InventoryResource or (Config.Inventory=='qb' and 'qb-inventory' or 'ox_inventory')
    started(name)
    return exports[name]
end
I.InventoryApi=nil -- created on demand by inventory resources, not vehicle scripts
function I.ClearInventory(src)
    if custom.ClearInventory then return custom.ClearInventory(src) end
    return I.Inventory():ClearInventory(src)
end
function I.DeleteInventoryRecord(id)
    if custom.DeleteInventoryRecord then return custom.DeleteInventoryRecord(id) end
    if (Config.InventoryResource or 'ox_inventory') == 'ox_inventory' then
        return I.Query('DELETE FROM ox_inventory WHERE name = ?', {id})
    end
    -- A custom inventory adapter must persist its ClearInventory/RemoveInventory calls.
end
function I.PlateExists(plate)
    if custom.PlateExists then return custom.PlateExists(plate) end
    if Config.GarageSystem=='qbx_vehicles' then return exports.qbx_vehicles:DoesPlayerVehiclePlateExist(plate) end
    return #(I.Query('SELECT 1 FROM player_vehicles WHERE plate = ? LIMIT 1',{plate}) or {})>0
end
function I.CreateOwnedVehicle(player,model,plate,props)
    if custom.CreateOwnedVehicle then return custom.CreateOwnedVehicle(player,model,plate,props,Config.Garage) end
    if Config.GarageSystem=='qbx_vehicles' then
        return exports.qbx_vehicles:CreatePlayerVehicle({model=model,citizenid=player.PlayerData.citizenid,garage=Config.Garage,props=props})
    end
    local sql=I.MapSQL('INSERT INTO player_vehicles (license,citizenid,vehicle,hash,mods,plate,garage,state) VALUES (?,?,?,?,?,?,?,?)')
    return MySQL.insert.await(sql,{player.PlayerData.license,player.PlayerData.citizenid,model,tostring(joaat(model)),json.encode(props),plate,Config.Garage,Config.GarageOutState or 0})
end
function I.DeleteOwnedVehicle(plate,cid)
    if custom.DeleteOwnedVehicle then return custom.DeleteOwnedVehicle(plate,cid) end
    if Config.GarageSystem=='qbx_vehicles' then
        local id=exports.qbx_vehicles:GetVehicleIdByPlate(plate)
        local vehicle=id and exports.qbx_vehicles:GetPlayerVehicle(id)
        if not vehicle or vehicle.citizenid~=cid then return false end
        return exports.qbx_vehicles:DeletePlayerVehicles('vehicleId',id)
    end
    if #(I.Query('SELECT 1 FROM player_vehicles WHERE plate = ? AND citizenid = ?',{plate,cid}) or {})==0 then return false end
    I.Query('DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ?',{plate,cid});return true
end
function I.SaveOwnedProps(props,plate,cid,ent)
    if custom.SaveOwnedProps then return custom.SaveOwnedProps(props,plate,cid,ent) end
    if Config.GarageSystem=='qbx_vehicles' then return exports.qbx_vehicles:SaveVehicle(ent,{state=0,garage=Config.Garage,props=props}) end
    I.Query('UPDATE player_vehicles SET mods = ? WHERE plate = ? AND citizenid = ?',{json.encode(props),plate,cid});return true
end
function I.Keys(src,ent,plate)
    if custom.KeysServer then return custom.KeysServer(src,ent,plate) end
    if Config.Keys=='qbx_vehiclekeys' then return exports.qbx_vehiclekeys:GiveKeys(src,ent,true)
    elseif Config.Keys=='qb-vehiclekeys' then TriggerClientEvent('vehiclekeys:client:SetOwner',src,plate)
    elseif Config.Keys~='none' then error('Configure Custom.KeysServer for this key system') end
end
local expected={}
function I.ExpectDelivery(src,plate,model,vehicleId)
    local p=I.Core.Functions.GetPlayer(src)
    expected[src]={plate=plate,model=model,vehicleId=vehicleId,cid=p and p.PlayerData.citizenid,expires=os.time()+30}
end
RegisterNetEvent(GetCurrentResourceName()..':integration:delivery',function(net,plate)
    local src=source;local pending=expected[src];local p=I.Core.Functions.GetPlayer(src)
    if not pending or not p or p.PlayerData.citizenid~=pending.cid or pending.expires<os.time() or pending.plate~=plate or type(net)~='number' then return end
    local ent=NetworkGetEntityFromNetworkId(net)
    if ent==0 or not DoesEntityExist(ent) or GetEntityType(ent)~=2 or NetworkGetEntityOwner(ent)~=src or GetVehicleNumberPlateText(ent):gsub('%s','')~=plate:gsub('%s','') or GetEntityModel(ent)~=joaat(pending.model) then return end
    expected[src]=nil
    if pending.vehicleId and Config.GarageSystem=='qbx_vehicles' then
        Entity(ent).state:set('vehicleid',pending.vehicleId,true)
        assert(exports.qbx_vehicles:SaveVehicle(ent,{state=0,garage=Config.Garage}), 'Qbox delivery save failed')
    end
    I.Keys(src,ent,plate)
end)
AddEventHandler('playerDropped',function() expected[source]=nil end)
