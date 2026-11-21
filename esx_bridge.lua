-- Shared ESX Legacy adapter. No globals or exports belonging to other resources
-- are replaced. The existing QB-shaped integration API is private to this resource.
UltimateXESX = {}
local E = UltimateXESX
local server = IsDuplicityVersion()
local core
local function active()
    return GetResourceState('es_extended') == 'started'
        and GetResourceState('qbx_core') ~= 'started' and GetResourceState('qb-core') ~= 'started'
end
function E.Active()
    local selected=Config and Config.Framework or AdminFrameworkConfig and AdminFrameworkConfig.framework
    if selected and selected~='auto' then return selected=='esx' end
    return active()
end
function E.ClientEvent(name)
    return E.Active() and (GetCurrentResourceName()..':esx:'..name) or name
end
local function esx() return exports.es_extended:getSharedObject() end
local function decode(value)
    if type(value)=='table' then return value end
    local ok,result=pcall(json.decode,value or '{}');return ok and type(result)=='table' and result or {}
end
local function account(name) return name=='cash' and 'money' or name end
local function validAmount(n) return type(n)=='number' and n==n and n>=0 and n<1000000000 end
function E.Permission(src,role)
    if tonumber(src)==0 then return true end
    if type(role)=='table' then for _,v in pairs(role) do if E.Permission(src,v) then return true end end;return false end
    if type(role)~='string' then return false end
    local p=esx().GetPlayerFromId(tonumber(src));local group=p and p.getGroup()
    return group==role or (role=='god' and group=='superadmin')
        or (role=='admin' and (group=='superadmin' or group=='admin'))
        or IsPlayerAceAllowed(src,role) or IsPlayerAceAllowed(src,'group.'..role)
end
local function jobData(j,duty)
    j=j or {};local grade=tonumber(j.grade) or 0
    if type(j.onDuty)=='boolean' then duty=j.onDuty end
    return {name=j.name or 'unemployed',label=j.label or j.name,grade={level=grade,name=j.grade_label or j.grade_name},
        isboss=j.grade_name=='boss',onduty=duty~=false,type=j.type}
end
function E.Jobs()
    local result={}
    for name,j in pairs(esx().GetJobs()) do
        local grades={}
        for g,v in pairs(j.grades or {}) do grades[tostring(g)]={name=v.label or v.name,payment=v.salary or 0,isboss=v.name=='boss'} end
        result[name]={label=j.label,type=j.type,grades=grades,defaultDuty=true,offDutyPay=false}
    end
    return result
end
function E.Player(src)
    local x=esx().GetPlayerFromId(tonumber(src));if not x then return nil end
    local original=x.getMeta and x.getMeta() or {};local metadata={}
    for key,value in pairs(type(original)=='table' and original or {}) do metadata[key]=value end
    local dead=x.get('dead')
    if type(dead)=='boolean' then metadata.isdead=dead else metadata.isdead=metadata.isdead==true end
    local duty=x.get('ultimatexDuty');local j=x.getJob()
    if duty==nil then duty=j.onDuty end
    for _,status in ipairs(x.get('status') or {}) do
        if status.name=='hunger' or status.name=='thirst' then metadata[status.name]=(status.val or 0)/10000 end
    end
    local money={cash=x.getMoney(),bank=(x.getAccount('bank') or {}).money or 0}
    if x.getAccounts then
        for key,v in pairs(x.getAccounts(true)) do
            local a=type(v)=='table' and v.name or key;local balance=type(v)=='table' and v.money or v
            money[a=='money' and 'cash' or a]=balance
        end
    end
    local name=x.getName() or '';local first=x.get('firstName') or name:match('^(%S+)') or ''
    local last=x.get('lastName') or name:match('^%S+%s+(.+)$') or ''
    local pd={source=tonumber(src),citizenid=x.identifier,license=GetPlayerIdentifierByType(src,'license'),
        charinfo={firstname=first,lastname=last,birthdate=x.get('dateofbirth'),gender=x.get('sex')=='f' and 1 or 0,phone=x.get('phoneNumber')},
        job=jobData(j,duty),gang={name='none',grade={level=0}},money=money,metadata=metadata,items=x.getInventory()}
    local f={};local p={PlayerData=pd,Functions=f}
    function f.GetMoney(a) local v=x.getAccount(account(a));return v and v.money or 0 end
    local function change(a,n,mode,reason)
        if not validAmount(n) then return false end
        a=account(a);local v=x.getAccount(a);if not v then return false end
        if mode=='remove' and v.money<n then return false end
        if mode=='add' then x.addAccountMoney(a,n,reason) elseif mode=='remove' then x.removeAccountMoney(a,n,reason) else x.setAccountMoney(a,n,reason) end
        pd.money[a=='money' and 'cash' or a]=x.getAccount(a).money;return true
    end
    function f.AddMoney(a,n,r) return change(a,n,'add',r) end
    function f.RemoveMoney(a,n,r) return change(a,n,'remove',r) end
    function f.SetMoney(a,n,r) return change(a,n,'set',r) end
    function f.SetJob(name,grade)
        if not esx().DoesJobExist(name,tonumber(grade)) then return false end
        x.setJob(name,tonumber(grade));pd.job=jobData(x.getJob(),x.get('ultimatexDuty'));return true
    end
    function f.SetJobDuty(value)
        local current=x.getJob()
        x.set('ultimatexDuty',value==true);x.setJob(current.name,current.grade,value==true);pd.job=jobData(x.getJob(),value==true)
        Player(src).state:set('ultimatexDuty',value==true,true)
        TriggerClientEvent(E.ClientEvent('QBCore:Client:SetDuty'),src,value==true);return true
    end
    function f.SetMetaData(key,value)
        if x.setMeta then x.setMeta(key,value) end;pd.metadata[key]=value
        if key=='hunger' or key=='thirst' then
            local statuses=x.get('status') or {};local found=false
            for _,s in ipairs(statuses) do if s.name==key then s.val=math.floor(value*10000);found=true end end
            if not found then statuses[#statuses+1]={name=key,val=math.floor(value*10000)} end
            x.set('status',statuses);TriggerClientEvent('esx_status:set',src,key,math.floor(value*10000))
        end
    end
    function f.SetPlayerData(key,value)
        if key=='charinfo' then
            x.set('firstName',value.firstname);x.set('lastName',value.lastname);x.setName((value.firstname or '')..' '..(value.lastname or ''))
            x.set('dateofbirth',value.birthdate);x.set('sex',value.gender==1 and 'f' or 'm')
            MySQL.update.await('UPDATE users SET firstname=?,lastname=?,dateofbirth=?,sex=? WHERE identifier=?',
                {value.firstname,value.lastname,value.birthdate,value.gender==1 and 'f' or 'm',x.identifier})
        elseif key=='money' then for a,n in pairs(value) do if not f.SetMoney(a,n) then return false end end
        elseif key=='items' and next(value)==nil and GetResourceState('ox_inventory')=='started' then exports.ox_inventory:ClearInventory(src)
        else error('Unsupported ESX player field: '..tostring(key)) end
        pd[key]=value;return true
    end
    function f.Save()
        local result=promise.new();local answered=false
        local function finish(success) if not answered then answered=true;result:resolve(success~=false) end end
        local framework=esx()
        if type(framework.SavePlayer)=='function' then framework.SavePlayer(x,finish)
        else exports.es_extended:SavePlayer(tonumber(src),finish) end
        SetTimeout(15000,function() finish(false) end)
        assert(Citizen.Await(result),'ESX could not save the character before this operation')
        return true
    end
    function f.AddItem(item,count,slot,info) return exports.ox_inventory:AddItem(src,item,count,info,slot) end
    function f.RemoveItem(item,count,slot) return exports.ox_inventory:RemoveItem(src,item,count,nil,slot) end
    function f.GetItemByName(item) local v=exports.ox_inventory:GetItem(src,item);if v then v.amount=v.count;v.info=v.metadata end;return v end
    function f.GetItemBySlot(slot) return exports.ox_inventory:GetSlot(src,slot) end
    return p
end
function E.Players()
    local out={};for _,id in ipairs(GetPlayers()) do local p=E.Player(tonumber(id));if p then out[tonumber(id)]=p end end;return out
end
function E.ByIdentifier(cid)
    local x=esx().GetPlayerFromIdentifier(cid);return x and E.Player(x.source)
end
function E.Offline(cid)
    local p=E.ByIdentifier(cid);if p then return p end
    local r=MySQL.single.await('SELECT * FROM users WHERE identifier=?',{cid});if not r then return nil end
    local j=esx().GetJobs()[r.job];local g=j and j.grades[tostring(r.job_grade)] or {}
    return {Offline=true,PlayerData={citizenid=cid,charinfo={firstname=r.firstname,lastname=r.lastname},job=jobData({name=r.job,label=j and j.label,grade=r.job_grade,grade_name=g.name})},Functions={
        SetJob=function(name,grade) if not esx().DoesJobExist(name,tonumber(grade)) then return false end;MySQL.update.await('UPDATE users SET job=?,job_grade=? WHERE identifier=?',{name,grade,cid});return true end,
        Save=function() return true end}}
end
function E.CreateJob(name,definition)
    assert(type(name)=='string' and name:match('^[%w_]+$'),'Invalid ESX job')
    local framework=esx();local existing=framework.GetJobs()[name]
    local queries={{query='INSERT INTO jobs (name,label) VALUES (?,?) ON DUPLICATE KEY UPDATE label=VALUES(label)',values={name,definition.label or name}},
        {query='DELETE FROM job_grades WHERE job_name=?',values={name}}}
    local function skin(v) return type(v)=='table' and json.encode(v) or type(v)=='string' and v or '{}' end
    for g,v in pairs(definition.grades or {}) do
        local old=existing and existing.grades[tostring(g)] or {}
        local role=v.isboss and 'boss' or old.name and old.name~='boss' and old.name or ('grade'..g)
        queries[#queries+1]={query='INSERT INTO job_grades (job_name,grade,name,label,salary,skin_male,skin_female) VALUES (?,?,?,?,?,?,?)',
            values={name,tonumber(g),role,v.name or tostring(g),v.payment or 0,skin(old.skin_male),skin(old.skin_female)}}
    end
    -- ESX installations do not all have a unique key on (job_name, grade).
    if not MySQL.transaction.await(queries) then return false end
    if type(framework.RefreshJob)=='function' then framework.RefreshJob(name)
    else
        framework.RefreshJobs()
        for _,id in ipairs(GetPlayers()) do
            local player=framework.GetPlayerFromId(tonumber(id));local job=player and player.getJob()
            if job and job.name==name then player.setJob(name,framework.DoesJobExist(name,job.grade) and job.grade or 0,job.onDuty) end
        end
    end
    if core then core.Shared.Jobs=E.Jobs() end;return true
end
function E.Society(name,n,remove)
    if GetResourceState('esx_addonaccount')~='started' then return false end
    local a;TriggerEvent('esx_addonaccount:getSharedAccount',name:match('^society_') and name or 'society_'..name,function(v) a=v end)
    if not a then return false end
    if n==nil then return a.money end
    if not validAmount(n) or (remove and a.money<n) then return false end
    if remove then a.removeMoney(n) else a.addMoney(n) end;return true
end
local function notify(message,kind,duration)
    if type(message)=='table' then message=message.text or message.caption or '' end
    if lib and lib.notify then
        lib.notify({description=tostring(message),type=kind=='primary' and 'inform' or kind or 'inform',duration=duration})
    else esx().ShowNotification(tostring(message),kind=='primary' and 'info' or kind,duration) end
end
function E.Core()
    if core then return core end
    local f={};core={Functions=f,Shared={Jobs=server and E.Jobs() or {},Gangs={},Vehicles={}},Commands={List={},Refresh=function() end}}
    local function random(n,chars) local s='';for _=1,n do local i=math.random(#chars);s=s..chars:sub(i,i) end;return s end
    core.Shared.RandomInt=function(n) return random(n,'0123456789') end
    core.Shared.RandomStr=function(n) return random(n,'ABCDEFGHIJKLMNOPQRSTUVWXYZ') end
    if server then
        f.GetPlayer=E.Player;f.GetPlayerByCitizenId=E.ByIdentifier;f.GetOfflinePlayerByCitizenId=E.Offline
        f.GetQBPlayers=E.Players;f.GetPlayers=function() local ids={};for id in pairs(E.Players()) do ids[#ids+1]=id end;return ids end
        f.HasPermission=E.Permission;f.CreateCallback=function(name,fn) esx().RegisterServerCallback(name,fn) end
        f.CreateUseableItem=function(name,fn) esx().RegisterUsableItem(name,fn) end
        f.Notify=function(src,message,kind,duration) TriggerClientEvent(GetCurrentResourceName()..':esx:notify',src,message,kind,duration) end
        core.Commands.Add=function(name,help,args,required,fn,role)
            core.Commands.List[name]={name=name,help=help,permission=role}
            RegisterCommand(name,function(src,values) if not role or role=='user' or E.Permission(src,role) then fn(src,values) end end,false)
        end
    else
        f.GetPlayerData=function(cb)
            local raw=esx().GetPlayerData() or {};local m={}
            for _,a in pairs(raw.accounts or {}) do m[a.name=='money' and 'cash' or a.name]=a.money end
            local data={citizenid=raw.identifier,job=jobData(raw.job,LocalPlayer.state.ultimatexDuty),money=m,metadata=raw.metadata or {},charinfo={firstname=raw.firstName,lastname=raw.lastName},gang={name='none',grade={level=0}}}
            if cb then cb(data) end;return data
        end
        f.TriggerCallback=function(name,cb,...) esx().TriggerServerCallback(name,cb,...) end
        f.Notify=notify;f.GetVehicleProperties=function(v) if lib and lib.getVehicleProperties then return lib.getVehicleProperties(v) end;return esx().Game.GetVehicleProperties(v) end
        f.SetVehicleProperties=function(v,p) if lib and lib.setVehicleProperties then return lib.setVehicleProperties(v,p) end;return esx().Game.SetVehicleProperties(v,p) end
        f.SpawnVehicle=function(model,cb,coords,networked)
            esx().Game.SpawnVehicle(model,coords or GetEntityCoords(PlayerPedId()),coords and coords.w or 0,cb,networked)
        end
        f.DeleteVehicle=function(v) DeleteEntity(v) end
        f.GetPlate=function(v) return (GetVehicleNumberPlateText(v) or ''):match('^%s*(.-)%s*$') end
        f.GetClosestVehicle=function() return esx().Game.GetClosestVehicle() end
    end
    return core
end
function E.GetCore(resource)
    if E.Active() or resource=='es_extended' then return E.Core() end
    return exports[resource]:GetCoreObject()
end
E.Qbox=setmetatable({}, {__index=function(_,name)
    return function(_,...)
        local args={...};local src=args[1]
        if name=='GetPlayer' then return E.Player(src) elseif name=='GetPlayerData' then return E.Core().Functions.GetPlayerData()
        elseif name=='GetJobs' then return E.Jobs() elseif name=='GetGangs' or name=='GetVehiclesByName' then return {}
        elseif name=='GetPlayerByCitizenId' then return E.ByIdentifier(src) elseif name=='GetQBPlayers' then return E.Players()
        elseif name=='GetOfflinePlayer' then return E.Offline(src) elseif name=='CreateJob' then return E.CreateJob(src,args[2])
        elseif name=='Notify' then return E.Core().Functions.Notify(...)
        elseif name=='DisablePersistence' then return end
        local p=E.Player(src);if not p then return false end
        local methods={SetJob='SetJob',SetJobDuty='SetJobDuty',AddMoney='AddMoney',RemoveMoney='RemoveMoney',SetMetadata='SetMetaData',GetMoney='GetMoney'}
        if methods[name] then return p.Functions[methods[name]](table.unpack(args,2)) end
        error('Unsupported ESX bridge method: '..name)
    end
end})
function E.CoreExports() return E.Active() and E.Qbox or exports.qbx_core end
function E.Configure(c)
    if c.Framework~='esx' and not (c.Framework=='auto' and active()) then return end
    c.Framework='esx';c.CoreResource='es_extended';c.Custom=c.Custom or {}
    local custom=c.Custom
    custom.Role=custom.Role or E.Permission
    custom.AdminRole=custom.AdminRole or function(src) if E.Permission(src,'god') then return 'god' elseif E.Permission(src,'admin') then return 'admin' end end
    custom.IsAdmin=custom.IsAdmin or function(src) return E.Permission(src,'admin') end
    for _,key in ipairs({'Keys','Fuel','Banking','GarageSystem'}) do
        if key=='Keys' and (c[key]=='auto' or c[key]=='qb-vehiclekeys' or c[key]=='qbx_vehiclekeys') then
            c[key]=GetResourceState('qb-vehiclekeys')=='started' and 'qb-vehiclekeys' or 'none'
        elseif key=='Fuel' and c[key] and c[key]~='custom' and c[key]~='native' and GetResourceState(c[key])~='started' then c[key]='native'
        elseif key=='GarageSystem' and c[key] then c[key]='sql'
        elseif key=='Banking' and c[key] then c[key]='custom' end
    end
    custom.Society=custom.Society or function(name,n) return E.Society(name,n) end
    custom.SocietyBalance=custom.SocietyBalance or function(name) return E.Society(name) or 0 end
    custom.SocietyAdd=custom.SocietyAdd or function(name,n) return E.Society(name,n) end
    custom.SocietyRemove=custom.SocietyRemove or function(name,n) return E.Society(name,n,true) end
    custom.SocietyWithdraw=custom.SocietyWithdraw or custom.SocietyRemove
    if c.Database and type(c.Database)=='table' then
        if c.Database.Vehicles then
            c.Database.Vehicles='owned_vehicles';c.Database.Owner='owner';c.Database.Props='vehicle';c.Database.Model='vehicle';c.Database.State='stored'
        elseif c.Database.table then c.Database.table='owned_vehicles';c.Database.owner='owner';c.Database.props='vehicle'
        elseif c.Database.player_vehicles then
            c.Database.player_vehicles={table='owned_vehicles',columns={citizenid='owner',mods='vehicle',state='stored'}}
            if c.Database.players then c.Database.players={table='users',columns={citizenid='identifier'}} end
        end
    end
    if c.VehicleDatabase then c.VehicleDatabase={table='owned_vehicles',columns={citizenid='owner',model='ultx_model',props='vehicle',plate='plate',state='stored'},extra={type='car'},outState=0} end
    custom.PlateExists=custom.PlateExists or function(plate) return MySQL.scalar.await('SELECT 1 FROM owned_vehicles WHERE plate=?',{plate})~=nil end
    custom.CreateOwnedVehicle=custom.CreateOwnedVehicle or function(p,model,plate,props)
        props.model=props.model or joaat(model);props.plate=plate
        local changed=MySQL.update.await('INSERT INTO owned_vehicles (owner,plate,vehicle,type,stored,ultx_model) VALUES (?,?,?, ?,0,?)',{p.PlayerData.citizenid,plate,json.encode(props),'car',model})
        return changed and changed>0 and plate or false
    end
    custom.DeleteOwnedVehicle=custom.DeleteOwnedVehicle or function(plate,cid) return MySQL.update.await('DELETE FROM owned_vehicles WHERE plate=? AND owner=?',{plate,cid})>0 end
    custom.SaveOwnedProps=custom.SaveOwnedProps or function(props,plate,cid)
        local changed=MySQL.update.await('UPDATE owned_vehicles SET vehicle=? WHERE plate=? AND owner=?',{json.encode(props),plate,cid})
        return changed==1 or changed==0 and MySQL.scalar.await('SELECT 1 FROM owned_vehicles WHERE plate=? AND owner=?',{plate,cid})~=nil
    end
    custom.OfflineEmployees=custom.OfflineEmployees or function(name)
        local rows=MySQL.query.await('SELECT identifier,firstname,lastname,job_grade FROM users WHERE job=?',{name});local out={}
        local j=esx().GetJobs()[name]
        for _,r in ipairs(rows) do local g=j and j.grades[tostring(r.job_grade)] or {};out[#out+1]={id=r.identifier,cid=r.identifier,name=(r.firstname or '')..' '..(r.lastname or ''),grade=r.job_grade,isboss=g.name=='boss',offline=true} end
        return out
    end
    if c.Society then c.Society='custom';c.SocietyResource='esx_addonaccount' end
    if c.CustomBossMenu~=nil then c.CustomBossMenu=true end
    if c.usebossmenuspecial~=nil then c.usebossmenuspecial=true end
    if c.ExtraTables then
        local seen={};for _,t in ipairs(c.ExtraTables) do seen[t[1]]=true end
        for _,t in ipairs({{'user_licenses','owner'},{'billing','identifier'},{'datastore_data','owner'},
            {'addon_inventory_items','owner'},{'addon_account_data','owner'}}) do
            if not seen[t[1]] then c.ExtraTables[#c.ExtraTables+1]=t end
        end
    end
end
if not server then
    RegisterNetEvent(GetCurrentResourceName()..':esx:notify',notify)
    AddEventHandler('esx:playerLoaded',function() if E.Active() then TriggerEvent(E.ClientEvent('QBCore:Client:OnPlayerLoaded')) end end)
    AddEventHandler('esx:onPlayerLogout',function() if E.Active() then TriggerEvent(E.ClientEvent('QBCore:Client:OnPlayerUnload')) end end)
    AddEventHandler('esx:setJob',function(job) if E.Active() then TriggerEvent(E.ClientEvent('QBCore:Client:OnJobUpdate'),jobData(job,LocalPlayer.state.ultimatexDuty)) end end)
    AddEventHandler('esx:jobDataRefreshed',function(job) if E.Active() then TriggerEvent(E.ClientEvent('QBCore:Client:OnJobUpdate'),jobData(job,LocalPlayer.state.ultimatexDuty)) end end)
end
