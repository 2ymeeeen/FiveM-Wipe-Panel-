Integration = {}
local I=Integration
local custom=Config.Custom or {}
if Config.CoreResource=='auto' then Config.CoreResource=(Config.Framework=='esx' and 'es_extended' or Config.Framework=='qbox' and 'qbx_core' or 'qb-core') end
if (Config.Framework=='qbcore' or Config.Framework=='esx') then
    local core=UltimateXESX.GetCore(Config.CoreResource)
    I.Core={Functions={}}
    for key,fn in pairs(core.Functions) do I.Core.Functions[key]=fn end
elseif Config.Framework=='qbox' then
    I.Core={Functions={}}
    I.Core.Functions.GetPlayerData=function() return exports[Config.CoreResource]:GetPlayerData() or {} end
    I.Core.Functions.TriggerCallback=function(name,callback,...) lib.callback(name,false,callback,...) end
    I.Core.Functions.Notify=function(message,kind,duration) exports[Config.CoreResource]:Notify(message,kind=='primary' and 'inform' or kind,duration) end
    I.Core.Functions.GetVehicleProperties=function(ent) return lib.getVehicleProperties(ent) end
elseif Config.Framework=='custom' then assert(custom.Core,'Configure client Custom.Core'); I.Core=custom.Core()
else error('Invalid Config.Framework') end
if custom.Notify then I.Core.Functions.Notify=custom.Notify end
RegisterNetEvent(GetCurrentResourceName()..':integration:notify',function(message,kind) I.Core.Functions.Notify(message,kind) end)
function I.Fuel(ent,amount)
    if custom.Fuel then return custom.Fuel(ent,amount) end
    SetVehicleFuelLevel(ent,amount)
    if Config.Fuel=='LegacyFuel' or Config.Fuel=='ps-fuel' or Config.Fuel=='cdn-fuel' then exports[Config.Fuel]:SetFuel(ent,amount)
    elseif Config.Fuel~='native' and Config.Fuel~='ox_fuel' then error('Configure Custom.Fuel') end
    Entity(ent).state:set('fuel',amount,true)
end
function I.Delivery(plate,ent)
    if custom.KeysClient then custom.KeysClient(plate,ent) end
    TriggerServerEvent(GetCurrentResourceName()..':integration:delivery',NetworkGetNetworkIdFromEntity(ent),plate)
end
function I.ResolveTarget()
    if Config.Target=='auto' then return GetResourceState('ox_target')=='started' and 'ox_target' or 'qb-target' end
    return Config.Target
end
local selected=I.ResolveTarget()
if not selected then I.Target=nil -- resources without world targets do not require a target
elseif selected=='qb-target' then I.Target=exports['qb-target']
elseif selected=='ox_target' then
    local zones={}
    local function options(target)
        local out={}
        for _,option in ipairs(target.options) do
            local action=option.action;local canInteract=option.canInteract
            out[#out+1]={name=option.label,label=option.label,icon=option.icon,distance=target.distance,
                canInteract=canInteract,onSelect=function(data) action(data.entity) end}
        end
        return out
    end
    I.Target={}
    function I.Target:AddBoxZone(name,pos,width,length,zone,target)
        zones[name]=exports.ox_target:addBoxZone({name=name,coords=pos,size=vector3(width,length,zone.maxZ-zone.minZ),rotation=zone.heading or 0,options=options(target)})
    end
    function I.Target:AddCircleZone(name,pos,radius,_,target)
        zones[name]=exports.ox_target:addSphereZone({name=name,coords=pos,radius=radius,options=options(target)})
    end
    function I.Target:RemoveZone(name) if zones[name] then exports.ox_target:removeZone(zones[name]);zones[name]=nil end end
    function I.Target:AddTargetEntity(ent,target) exports.ox_target:addLocalEntity(ent,options(target)) end
    function I.Target:RemoveTargetEntity(ent,label) exports.ox_target:removeLocalEntity(ent,label) end
elseif selected=='custom' then assert(custom.Target,'Configure Custom.Target');I.Target=custom.Target()
else error('Invalid Config.Target') end
