local QBCore = Integration.Core
local session, H = {}, {}
local mutationBusy=false
local mutations={identity=true,removeVehicle=true,wipe=true,setMoney=true,econApply=true,restore=true,switchCitizenId=true}
local KINDS = { money = true, inventory = true, vehicles = true, full = true }

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
local optionalTables={ox_inventory=true,inventories=true,givecar_temp=true}
for _,list in ipairs({Config.ExtraTables or {},Config.CitizenIdTables or {}}) do
    for _,definition in ipairs(list) do optionalTables[definition[1]]=true end
end
local function q(sql, p)
    -- Qbox does not install every QB inventory/appearance table. Check optional
    -- tables before querying them; catching a failed query still logs in oxmysql.
    local tableName=sql:match('FROM%s+`?([%w_]+)')
    if tableName and optionalTables[tableName] then
        local spec=(Config.Database or {})[tableName]
        local actual=spec and spec.table or tableName
        local present=Integration.Query('SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=? LIMIT 1',{actual})
        if not present or not present[1] then return {} end
    end
    local ok,r=pcall(Integration.Query,sql,p or {})
    if ok then return r or {} end
    local missing=tostring(r):lower():find("doesn't exist",1,true) or tostring(r):find('1146',1,true)
    local required=sql:match('%f[%w]players%f[%W]') or sql:find('player_vehicles',1,true) or sql:find('wipe_backups',1,true)
    if missing and not required then return {} end
    error('Database query failed: '..tostring(r))
end
local function x(sql,p) return q(sql,p) end
local function dec(v)
    if type(v) == 'table' then return v end
    if type(v) == 'string' then local ok, r = pcall(json.decode, v) if ok and type(r) == 'table' then return r end end
    return {}
end
local function clean(s, n) s = tostring(s or ''):gsub('%c', ' ') return (s:sub(1, n or 200):match('^%s*(.-)%s*$')) end
local function num(v) v = tonumber(v) return v and v==v and math.abs(v)<=9007199254740991 and math.floor(v) or nil end
local function nameOf(ci) return ci and ((ci.firstname or '?') .. ' ' .. (ci.lastname or '')) or 'Unknown' end
local function online(cid) return QBCore.Functions.GetPlayerByCitizenId(cid) end
local function charinfoOf(cid)
    local P = online(cid)
    if P then return P.PlayerData.charinfo, P end
    local r = q('SELECT charinfo FROM players WHERE citizenid = ?', { cid })[1]
    return r and dec(r.charinfo) or nil
end

local function log(src, action, target, reason, details)
    print(('[wipemenu] Admin: %s [%s] | Action: %s | Target: %s | Reason: %s | Details: %s'):format(
        GetPlayerName(src) or 'Console', tostring(src), tostring(action), tostring(target or '-'),
        clean(reason, 150), tostring(details or '-')))
    local category
    if action == 'WIPE FULL' or action == 'RESTORE FULL' then category = 'full'
    elseif action:find('MONEY', 1, true) or action:find('Money', 1, true) or action == 'Economy cut' then category = 'money'
    elseif action:find('VEHICLES', 1, true) or action == 'Remove vehicle' then category = 'vehicles' end
    local url = category and (Config.LogWebhooks or {})[category]
    if not url or url == '' then return end
    local body = {username='Wipe Menu', allowed_mentions={parse={}}, embeds={{
        title=tostring(action), color=Config.LogColor or 15844367,
        fields={
            {name='Administrator', value=clean((GetPlayerName(src) or 'Console') .. ' [' .. tostring(src) .. ']', 1024)},
            {name='Target', value=clean(target or '-', 1024)},
            {name='Reason', value=clean(reason, 150) ~= '' and clean(reason, 150) or 'Not provided'},
            {name='Details', value=tostring(details or '-'):sub(1,1024)}
        }, timestamp=os.date('!%Y-%m-%dT%H:%M:%SZ')
    }}}
    local ok = pcall(PerformHttpRequest, url, function(status)
        if status < 200 or status >= 300 then print('[wipemenu] Discord log delivery failed (HTTP ' .. tostring(status) .. ').') end
    end, 'POST', json.encode(body), {['Content-Type']='application/json'})
    if not ok then print('[wipemenu] Unable to send Discord log; action remains completed.') end
end

local function deleteWorldVehicle(plate)
    local want = plate:gsub('%s', ''):upper()
    for _, veh in ipairs(GetAllVehicles()) do
        if (GetVehicleNumberPlateText(veh) or ''):gsub('%s', ''):upper() == want then DeleteEntity(veh) end
    end
end

local restoreColumns = {}
local function insertRow(tbl, row, skip, batch)
    assert(type(tbl) == 'string' and tbl:match('^[%w_]+$'), 'Invalid restore table')
    local schema = restoreColumns[tbl]
    if not schema then
        schema = {}
        local spec = (Config.Database or {})[tbl]
        local reverse = {}
        for canonical, actual in pairs(spec and spec.columns or {}) do reverse[actual] = canonical end
        for _, column in ipairs(q('SHOW COLUMNS FROM `' .. tbl .. '`')) do
            schema[reverse[column.Field] or column.Field] = tostring(column.Type):lower():match('^%a+')
        end
        restoreColumns[tbl] = schema
    end
    local cols, vals, ph = {}, {}, {}
    for k, v in pairs(row) do
        if not skip[k] then
            assert(k:match('^[%w_]+$'), 'Invalid restore column')
            cols[#cols + 1] = '`' .. k .. '`'
            local columnType = schema[k]
            local expression = '?'
            local epoch = tonumber(v)
            if epoch and (columnType == 'datetime' or columnType == 'timestamp' or columnType == 'date') then
                -- oxmysql serializes SQL date objects as epoch milliseconds.
                -- Older/custom backups may contain epoch seconds instead.
                if math.abs(epoch) >= 100000000000 then epoch = epoch / 1000 end
                v = epoch
                expression = columnType == 'date' and 'DATE(FROM_UNIXTIME(?))' or 'FROM_UNIXTIME(?)'
            elseif type(v) == 'table' then v = json.encode(v)
            elseif type(v) == 'boolean' then v = v and 1 or 0 end
            vals[#vals + 1] = v
            ph[#ph + 1] = expression
        end
    end
    local sql=('INSERT INTO %s (%s) VALUES (%s)'):format(tbl, table.concat(cols, ','), table.concat(ph, ','))
    if batch then batch[#batch+1]={query=sql,values=vals} else x(sql,vals) end
end

MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS wipe_backups (
        id INT AUTO_INCREMENT PRIMARY KEY, citizenid VARCHAR(100) NOT NULL, name VARCHAR(100), kind VARCHAR(20),
        data LONGTEXT, admin VARCHAR(80), reason VARCHAR(255), created_at BIGINT, restored TINYINT DEFAULT 0,
        restored_at BIGINT NULL, INDEX (citizenid))]])
end)

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ backup / wipe / restore â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
local function snapshot(cid)
    local P = online(cid)
    if P then P.Functions.Save() end
    local snap = {
        player = q('SELECT * FROM players WHERE citizenid = ?', { cid })[1],
        vehicles = q('SELECT * FROM player_vehicles WHERE citizenid = ?', { cid }),
        ox = q('SELECT * FROM ox_inventory WHERE owner = ?', { cid }),
        inv = q('SELECT * FROM inventories WHERE identifier = ?', { cid }),
        extra = {},
    }
    local backupTables={}
    for _, list in ipairs({Config.ExtraTables,Config.CitizenIdTables or {}}) do for _,t in ipairs(list) do
        if not backupTables[t[1]] then backupTables[t[1]]=t end
    end end
    for _, t in pairs(backupTables) do
        assert(t[1]:match('^[%w_]+$') and t[2]:match('^[%w_]+$'),'Invalid backup table')
        local rows = q(('SELECT * FROM %s WHERE %s = ?'):format(t[1], t[2]), { cid })
        if #rows > 0 then snap.extra[t[1]] = rows end
    end
    if P and snap.player then
        snap.player.money=json.encode(P.PlayerData.money)
        snap.player.charinfo=json.encode(P.PlayerData.charinfo)
        if Config.Inventory=='ox' then
            snap.player.inventory=json.encode(Integration.Inventory():GetInventoryItems(P.PlayerData.source))
        else snap.player.inventory=json.encode(P.PlayerData.items or {}) end
    end
    return snap
end

local function saveBackup(cid, name, kind, snap, src, reason)
    local id=MySQL.insert.await('INSERT INTO wipe_backups (citizenid, name, kind, data, admin, reason, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { cid, name, kind, json.encode(snap), ('%s [%d]'):format(GetPlayerName(src) or 'Console', src), reason, os.time() })
    if not id then error('Backup could not be saved. Wipe cancelled.') end
end

local function wipeMoney(cid)
    local P = online(cid)
    if P then
        local keys = {}
        for k in pairs(P.PlayerData.money) do keys[#keys + 1] = k end
        for _, k in ipairs(keys) do P.Functions.SetMoney(k, 0, 'wipemenu') end
    else
        local r = q('SELECT money FROM players WHERE citizenid = ?', { cid })[1]
        local m = dec(r and r.money)
        for k in pairs(m) do m[k] = 0 end
        x('UPDATE players SET money = ? WHERE citizenid = ?', { json.encode(m), cid })
    end
end

local function wipeInventory(cid)
    local P = online(cid)
    if P then
        local s = P.PlayerData.source
        Integration.ClearInventory(s)
        pcall(function() P.Functions.SetPlayerData('items', {}) end)
    end
    x('UPDATE players SET inventory = ? WHERE citizenid = ?', { '[]', cid })
    x('DELETE FROM ox_inventory WHERE owner = ?', { cid })
    x('DELETE FROM inventories WHERE identifier = ?', { cid })
end

local function wipeVehicles(cid)
    for _, r in ipairs(q('SELECT plate FROM player_vehicles WHERE citizenid = ?', { cid })) do
        deleteWorldVehicle(r.plate)
        x('DELETE FROM givecar_temp WHERE plate = ?', { r.plate })
    end
    x('DELETE FROM player_vehicles WHERE citizenid = ?', { cid })
end

local function wipeFull(cid, noWait)
    local P = online(cid)
    if P then
        DropPlayer(P.PlayerData.source, 'Your character has been wiped by an administrator.')
        local deadline=GetGameTimer()+10000
        while online(cid) and GetGameTimer()<deadline do Wait(100) end
        if online(cid) then error('Player has not disconnected. Wipe cancelled; backup retained.') end
        Wait(1000) -- allow the disconnect save to finish before deleting records
    end
    wipeVehicles(cid)
    x('DELETE FROM ox_inventory WHERE owner = ?', { cid })
    x('DELETE FROM inventories WHERE identifier = ?', { cid })
    for _, t in ipairs(Config.ExtraTables) do x(('DELETE FROM %s WHERE %s = ?'):format(t[1], t[2]), { cid }) end
    x('DELETE FROM players WHERE citizenid = ?', { cid })
end

local function doWipe(cid, kind, noWait)
    if kind == 'money' then wipeMoney(cid)
    elseif kind == 'inventory' then wipeInventory(cid)
    elseif kind == 'vehicles' then wipeVehicles(cid)
    elseif kind == 'full' then wipeFull(cid, noWait) end
end

local function restoreSnap(kind, snap, cid, batch)
    local directWrite=x
    local function x(sql,values)
        if batch then batch[#batch+1]={query=sql,values=values} else directWrite(sql,values) end
    end
    local P = online(cid)
    local msg = 'Restored'
    if kind == 'full' then
        if snap.player and #q('SELECT 1 FROM players WHERE citizenid = ?', { cid }) == 0 then
            insertRow('players', snap.player, { id = true, last_updated = true }, batch)
        end
        for _, r in ipairs(snap.vehicles or {}) do insertRow('player_vehicles', r, { id = true }, batch) end
        for _, r in ipairs(snap.ox or {}) do insertRow('ox_inventory', r, { id = true, lastupdated = true }, batch) end
        for _, r in ipairs(snap.inv or {}) do insertRow('inventories', r, { id = true }, batch) end
        for t, rows in pairs(snap.extra or {}) do for _, r in ipairs(rows) do insertRow(t, r, { id = true }, batch) end end
    elseif kind == 'money' then
        local m = dec(snap.player and snap.player.money)
        if P then for k, v in pairs(m) do P.Functions.SetMoney(k, v, 'wipemenu-restore') end
        else x('UPDATE players SET money = ? WHERE citizenid = ?', { json.encode(m), cid }) end
    elseif kind == 'inventory' then
        x('DELETE FROM ox_inventory WHERE owner = ?', { cid }); x('DELETE FROM inventories WHERE identifier = ?', { cid })
        for _, r in ipairs(snap.ox or {}) do insertRow('ox_inventory', r, { id = true, lastupdated = true }, batch) end
        for _, r in ipairs(snap.inv or {}) do insertRow('inventories', r, { id = true }, batch) end
        if snap.player and snap.player.inventory then x('UPDATE players SET inventory = ? WHERE citizenid = ?', { snap.player.inventory, cid }) end
        if P then msg = 'Restored - the player must relog to see the items' end
    else -- vehicles / vehicle
        for _, r in ipairs(snap.vehicles or {}) do
            if #q('SELECT 1 FROM player_vehicles WHERE plate = ?', { r.plate }) == 0 then insertRow('player_vehicles', r, { id = true }, batch) end
        end
    end
    return msg
end

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ session / dispatcher â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
QBCore.Commands.Add(Config.Command, 'Open the wipe control menu (Admin)', {}, false, function(source)
    session[source] = true
    TriggerClientEvent('wipemenu:client:open', source, { admin = GetPlayerName(source) })
end, Config.Permission)

RegisterNetEvent('wipemenu:server:close', function() session[source] = nil end)
AddEventHandler('playerDropped', function() session[source] = nil end)

QBCore.Functions.CreateCallback('wipemenu:call', function(src, cb, action, data)
    if not (QBCore.Functions.HasPermission(src,Config.Permission) or QBCore.Functions.HasPermission(src,'god')) then session[src]=nil return cb({error='Admin permission required.'}) end
    if not session[src] then return cb({ error = 'Session expired - run /' .. Config.Command .. ' again' }) end
    if type(action)~='string' or #action>40 then return cb({error='Invalid action'}) end
    if Config.Framework=='esx' and action=='switchCitizenId' then return cb({error='ESX character identifiers cannot be swapped between accounts.'}) end
    local h = H[action]
    if not h then return cb({ error = 'Unknown action' }) end
    if mutations[action] and mutationBusy then return cb({error='Another change is running. Try again.'}) end
    if mutations[action] then mutationBusy=true end
    local ok, res = pcall(h, src, type(data) == 'table' and data or {})
    if mutations[action] then mutationBusy=false end
    if not ok then print('[wipemenu] ERROR in ' .. tostring(action) .. ': ' .. tostring(res)) return cb({ error = 'Server error - check the console' }) end
    cb(res or { ok = true })
end)

H.dashboard = function()
    local function c(sql, p) local r = q(sql, p)[1] return r and r.c or 0 end
    local day = os.time() - 86400
    return { online = #GetPlayers(), chars = c('SELECT COUNT(*) c FROM players'),
        fullWipes = c("SELECT COUNT(*) c FROM wipe_backups WHERE kind = 'full' AND created_at > ?", { day }),
        otherWipes = c("SELECT COUNT(*) c FROM wipe_backups WHERE kind <> 'full' AND created_at > ?", { day }),
        restores = c('SELECT COUNT(*) c FROM wipe_backups WHERE restored = 1 AND restored_at > ?', { day }),
        backups = c('SELECT COUNT(*) c FROM wipe_backups') }
end

H.search = function(_, d)
    local s = clean(d.q, 60):lower()
    if s == '' then return { list = {} } end
    local out, seen = {}, {}
    local function add(cid, ci)
        if seen[cid] then return end
        seen[cid] = true
        local P = online(cid)
        out[#out + 1] = { citizenid = cid, name = nameOf(ci), phone = ci.phone, online = P ~= nil, source = P and P.PlayerData.source }
    end
    for _, P in pairs(QBCore.Functions.GetQBPlayers()) do
        local pd = P.PlayerData
        if tostring(pd.source) == s or pd.citizenid:lower():find(s, 1, true) or nameOf(pd.charinfo):lower():find(s, 1, true)
            or (pd.license or ''):lower():find(s, 1, true) then add(pd.citizenid, pd.charinfo) end
    end
    local like = '%' .. s:gsub('[%%_]', '') .. '%'
    for _, r in ipairs(q([[SELECT citizenid, charinfo FROM players WHERE LOWER(citizenid) LIKE ? OR LOWER(license) LIKE ?
        OR LOWER(CONCAT(JSON_UNQUOTE(JSON_EXTRACT(charinfo,'$.firstname')),' ',JSON_UNQUOTE(JSON_EXTRACT(charinfo,'$.lastname')))) LIKE ? LIMIT 20]],
        { like, like, like })) do add(r.citizenid, dec(r.charinfo)) end
    return { list = out }
end

H.profile = function(_, d)
    local cid = tostring(d.cid or '')
    local ci, P = charinfoOf(cid)
    if not ci then return { error = 'Character not found' } end
    local row = q('SELECT license, money FROM players WHERE citizenid = ?', { cid })[1] or {}
    local money = P and P.PlayerData.money or dec(row.money)
    local cnt = q('SELECT COUNT(*) c FROM player_vehicles WHERE citizenid = ?', { cid })[1]
    local s = P and P.PlayerData.source
    local res = { citizenid = cid, name = nameOf(ci), firstname = ci.firstname, lastname = ci.lastname, birthdate = ci.birthdate,
        phone = ci.phone, nationality = ci.nationality, online = P ~= nil, source = s,
        cash = money.cash or 0, bank = money.bank or 0, vehicles = cnt and cnt.c or 0, license = row.license }
    return res
end

H.identity = function(src, d)
    local cid, reason = tostring(d.cid or ''), clean(d.reason, 150)
    local ci, P = charinfoOf(cid)
    if not ci then return { error = 'Character not found' } end
    local before = nameOf(ci)
    for _, f in ipairs({ 'firstname', 'lastname', 'birthdate', 'nationality' }) do
        local v = clean(d[f], 50)
        if v ~= '' then ci[f] = v end
    end
    if P then P.Functions.SetPlayerData('charinfo', ci); P.Functions.Save()
    else x('UPDATE players SET charinfo = ? WHERE citizenid = ?', { json.encode(ci), cid }) end
    log(src, 'Edit identity', cid .. ' (' .. before .. ')', reason, ('New: %s | %s | %s | %s'):format(nameOf(ci), ci.birthdate or '-', ci.phone or '-', ci.nationality or '-'))
    return { ok = true, msg = 'Identity updated' }
end

H.vehicles = function(_, d)
    local out = {}
    for _, r in ipairs(q('SELECT vehicle, plate, garage, state FROM player_vehicles WHERE citizenid = ?', { tostring(d.cid or '') })) do
        local info = QBCore.Shared.Vehicles and QBCore.Shared.Vehicles[r.vehicle]
        out[#out + 1] = { name = info and (((info.brand or '') .. ' ' .. (info.name or '')):match('^%s*(.-)%s*$')) or r.vehicle,
            model = r.vehicle, plate = r.plate, garage = r.garage, state = r.state }
    end
    return { list = out }
end

H.removeVehicle = function(src, d)
    local cid, plate, reason = tostring(d.cid or ''), tostring(d.plate or ''), clean(d.reason, 150)
    local row = q('SELECT * FROM player_vehicles WHERE citizenid = ? AND plate = ?', { cid, plate })[1]
    if not row then return { error = 'Vehicle not found' } end
    saveBackup(cid, nameOf(charinfoOf(cid)), 'vehicle', { vehicles = { row } }, src, reason)
    deleteWorldVehicle(plate)
    x('DELETE FROM givecar_temp WHERE plate = ?', { plate })
    x('DELETE FROM player_vehicles WHERE citizenid = ? AND plate = ?', { cid, plate })
    log(src, 'Remove vehicle', cid .. ' (' .. nameOf(charinfoOf(cid)) .. ')', reason, ('%s | plate %s | garage %s'):format(row.vehicle, plate, row.garage or '-'), 15105570)
    return { ok = true, msg = 'Vehicle removed' }
end

H.wipe = function(src, d)
    local cid, kind, reason = tostring(d.cid or ''), d.kind, clean(d.reason, 150)
    if not KINDS[kind] then return { error = 'Invalid action' } end
    local snap = snapshot(cid)
    if not snap.player then return { error = 'Character not found' } end
    local name = nameOf(dec(snap.player.charinfo))
    saveBackup(cid, name, kind, snap, src, reason)
    doWipe(cid, kind)
    log(src, 'WIPE ' .. kind:upper(), cid .. ' (' .. name .. ')', reason, 'A backup was saved to the Restore Vault', 15158332)
    return { ok = true, msg = 'Wipe done - backup saved to the Restore Vault' }
end

H.money = function()
    local rows = q([[SELECT citizenid, charinfo, money,
        COALESCE(CAST(JSON_EXTRACT(money,'$.cash') AS DECIMAL(20,0)),0) AS cash,
        COALESCE(CAST(JSON_EXTRACT(money,'$.bank') AS DECIMAL(20,0)),0) AS bank
        FROM players ORDER BY (cash + bank) DESC LIMIT 50]])
    local t = q([[SELECT COALESCE(SUM(CAST(JSON_EXTRACT(money,'$.cash') AS DECIMAL(20,0))),0) cash,
        COALESCE(SUM(CAST(JSON_EXTRACT(money,'$.bank') AS DECIMAL(20,0))),0) bank FROM players]])[1] or {}
    local list = {}
    for _, r in ipairs(rows) do
        local P = online(r.citizenid)
        local cash, bank = tonumber(r.cash) or 0, tonumber(r.bank) or 0
        if P then cash, bank = P.PlayerData.money.cash or 0, P.PlayerData.money.bank or 0 end
        list[#list + 1] = { citizenid = r.citizenid, name = nameOf(dec(r.charinfo)), cash = cash, bank = bank, online = P ~= nil }
    end
    return { list = list, cash = tonumber(t.cash) or 0, bank = tonumber(t.bank) or 0 }
end

H.setMoney = function(src, d)
    local cid, reason = tostring(d.cid or ''), clean(d.reason, 150)
    local mode = d.mode == 'add' and 'add' or 'set'
    local vals = { cash = num(d.cash), bank = num(d.bank) }
    if vals.cash == nil and vals.bank == nil then return { error = 'Enter an amount' } end
    local ci, P = charinfoOf(cid)
    if not ci then return { error = 'Character not found' } end
    local details, m = {}, nil
    if not P then m = dec((q('SELECT money FROM players WHERE citizenid = ?', { cid })[1] or {}).money) end
    for acc, v in pairs(vals) do
        local cur = (P and P.PlayerData.money[acc] or (m and m[acc])) or 0
        local new = mode == 'add' and cur + v or v
        if new < 0 then new = 0 end
        if P then P.Functions.SetMoney(acc, new, 'wipemenu') else m[acc] = new end
        details[#details + 1] = ('%s: %s -> %s'):format(acc, cur, new)
    end
    if m then x('UPDATE players SET money = ? WHERE citizenid = ?', { json.encode(m), cid }) end
    log(src, 'Money (' .. mode .. ')', cid .. ' (' .. nameOf(ci) .. ')', reason, table.concat(details, '\n'), 3066993)
    return { ok = true, msg = 'Money updated' }
end

local function econParams(d)
    local each, rem, acc = num(d.each), num(d.remove), d.account
    if not (each and each > 0 and rem and rem > 0) then return nil, 'Enter valid numbers' end
    if rem > each then return nil, 'The removed amount cannot be bigger than the "for each" amount' end
    if acc ~= 'cash' and acc ~= 'bank' and acc ~= 'both' then return nil, 'Invalid account' end
    return { accs = acc == 'both' and { 'cash', 'bank' } or { acc }, each = each, rem = rem }
end

local function econCut(m, p)
    local out, total = {}, 0
    for _, a in ipairs(p.accs) do
        local cur = tonumber(m[a]) or 0
        local r = math.min(math.floor(cur / p.each) * p.rem, math.floor(cur))
        if r > 0 then out[a] = r; total = total + r end
    end
    return out, total
end

local function econRun(d, apply)
    local p, err = econParams(d)
    if not p then return nil, err end
    local rows, n, total, queries = q('SELECT citizenid, money FROM players'), 0, 0, {}
    for _, r in ipairs(rows) do
        local P = online(r.citizenid)
        local m = P and P.PlayerData.money or dec(r.money)
        local out, t = econCut(m, p)
        if t > 0 then
            n = n + 1; total = total + t
            if apply then
                if P then for a, v in pairs(out) do P.Functions.RemoveMoney(a, v, 'wipemenu-economy') end
                else
                    for a, v in pairs(out) do m[a] = (tonumber(m[a]) or 0) - v end
                    queries[#queries + 1] = { query = 'UPDATE players SET money = ? WHERE citizenid = ?', values = { json.encode(m), r.citizenid } }
                end
            end
        end
    end
    for i = 1, #queries, 100 do
        local chunk = {}
        for j = i, math.min(i + 99, #queries) do chunk[#chunk + 1] = queries[j] end
        if not Integration.Transaction(chunk) then error('Economy database transaction failed; operation may be partially applied. Check the server log.') end
    end
    return { ok = true, players = n, total = total, all = #rows }
end

H.econPreview = function(_, d)
    local r, err = econRun(d, false)
    return r or { error = err }
end

H.econApply = function(src, d)
    local reason = clean(d.reason, 150)
    local r, err = econRun(d, true)
    if not r then return { error = err } end
    log(src, 'Economy cut', 'ALL PLAYERS', reason,
        ('Account: %s\nFor each %s remove %s\nPlayers affected: %d / %d\nTotal removed: %s'):format(d.account, d.each, d.remove, r.players, r.all, r.total), 15105570)
    r.msg = ('Done - removed %s from %d players'):format(r.total, r.players)
    return r
end

H.backups = function(_, d)
    local s = '%' .. clean(d.q, 60):gsub('[%%_]', '') .. '%'
    local cond = d.scope == 'full' and "kind = 'full'" or "kind <> 'full'"
    local list = q('SELECT id, citizenid, name, kind, admin, reason, created_at, restored FROM wipe_backups WHERE (name LIKE ? OR citizenid LIKE ?) AND '
        .. cond .. ' ORDER BY id DESC LIMIT 100', { s, s })
    local function c(w) local r = q('SELECT COUNT(*) c FROM wipe_backups WHERE ' .. w)[1] return r and r.c or 0 end
    return { list = list, counts = { full = c("kind = 'full'"), other = c("kind <> 'full'") } }
end


local function related()
    local out={{'player_vehicles','citizenid'},{'ox_inventory','owner'},{'inventories','identifier'}}
    local seen={player_vehicles=true,ox_inventory=true,inventories=true}
    for _,list in ipairs({Config.ExtraTables,Config.CitizenIdTables or {}}) do
        for _,t in ipairs(list) do
            assert(t[1]:match('^[%w_]+$') and t[2]:match('^[%w_]+$'),'Invalid configured table')
            if not seen[t[1]] then out[#out+1]=t;seen[t[1]]=true end
        end
    end
    return out
end
local function exists(tbl)
    local spec=(Config.Database or {})[tbl]
    local r=q('SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=?',{spec and spec.table or tbl})[1]
    if not r then return false end
    assert(tostring(r.ENGINE or r.engine):lower()=='innodb','InnoDB required: '..tbl)
    return true
end
local function removeQueries(batch,cid)
    for _,t in ipairs(related()) do if exists(t[1]) then batch[#batch+1]={query=('DELETE FROM %s WHERE %s=?'):format(t[1],t[2]),values={cid}} end end
    assert(exists('players'),'Players table missing')
    batch[#batch+1]={query='DELETE FROM players WHERE citizenid=?',values={cid}}
end
local function accountOnline(license,cid,kick)
    local found=false
    for _,id in ipairs(GetPlayers()) do
        local P=QBCore.Functions.GetPlayer(tonumber(id))
        if P and (P.PlayerData.license==license or P.PlayerData.citizenid==cid) then
            found=true
            if kick then DropPlayer(tonumber(id),'Administrator restoring your character. Reconnect when complete.') end
        end
    end
    return found
end
H.restore=function(src,d)
    local row=q('SELECT * FROM wipe_backups WHERE id=?',{num(d.id) or 0})[1]
    if not row then return {error='Backup not found'} end
    if tonumber(row.restored)==1 then return {error='Already restored'} end
    if not ({full=true,money=true,inventory=true,vehicles=true,vehicle=true})[row.kind] then return {error='Invalid backup type'} end
    local snap=dec(row.data)
    if type(snap)~='table' or next(snap)==nil then return {error='Backup is empty or corrupt'} end
    for _,key in ipairs({'vehicles','ox','inv','extra'}) do if snap[key]~=nil and type(snap[key])~='table' then return {error='Invalid backup section: '..key} end end
    local current=q('SELECT * FROM players WHERE citizenid=?',{row.citizenid})[1]
    local license=snap.player and snap.player.license or current and current.license
    if not license then return {error='Backup account cannot be identified'} end
    accountOnline(license,row.citizenid,true)
    local deadline=GetGameTimer()+10000
    while accountOnline(license,row.citizenid) and GetGameTimer()<deadline do Wait(100) end
    if accountOnline(license,row.citizenid) then return {error='Disconnect timed out; nothing restored'} end
    Wait(Config.CharacterSaveWaitMs or 2000)
    if accountOnline(license,row.citizenid) then return {error='Player reconnected; restore cancelled'} end
    if row.kind~='full' then
        if (row.kind=='inventory' or row.kind=='money') and type(snap.player)~='table' then return {error='Incomplete backup'} end
        if not current then return {error='Restore the full character first; this partial backup has no current character'} end
        local batch={}
        local msg=restoreSnap(row.kind,snap,row.citizenid,batch)
        batch[#batch+1]={query='UPDATE wipe_backups SET restored=1,restored_at=? WHERE id=?',values={os.time(),row.id}}
        for i=#batch,1,-1 do
            local statement=batch[i].query
            local tbl=statement:match('INSERT INTO ([%w_]+)') or statement:match('DELETE FROM ([%w_]+)') or statement:match('UPDATE ([%w_]+)')
            if tbl and not exists(tbl) then
                if statement:match('DELETE FROM') and (tbl=='ox_inventory' or tbl=='inventories') then table.remove(batch,i)
                else error('Restore table missing: '..tbl) end
            end
        end
        if not Integration.Transaction(batch) then error('Partial restore transaction rolled back') end
        log(src,'RESTORE '..row.kind:upper(),row.citizenid,clean(d.reason,150),'Backup #'..row.id)
        return {ok=true,msg=msg}
    end
    if type(snap.player)~='table' or snap.player.citizenid~=row.citizenid then return {error='Incomplete/mismatched character backup'} end
    local characters=q('SELECT * FROM players WHERE license=?',{license})
    current=q('SELECT * FROM players WHERE citizenid=?',{row.citizenid})[1]
    if current and current.license~=license then return {error='Citizen ID belongs to another account'} end
    local replacement=current or (Config.Framework~='esx' and #characters==1 and characters[1] or nil)
    local ci=dec(snap.player.charinfo)
    if replacement then
        local rci=dec(replacement.charinfo);ci.cid=rci.cid or replacement.cid or ci.cid
        if snap.player.cid~=nil then snap.player.cid=replacement.cid or ci.cid end
        saveBackup(replacement.citizenid,nameOf(rci),'full',snapshot(replacement.citizenid),src,'Safety backup before restore #'..row.id)
    else
        local used={}
        for _,r in ipairs(characters) do local c=dec(r.charinfo);used[tonumber(c.cid or r.cid) or 0]=true end
        local slot=1 while used[slot] do slot=slot+1 end
        if (Config.RestoreCharacterSlots or 0)>0 and slot>Config.RestoreCharacterSlots then return {error='No free character slot'} end
        ci.cid=slot;if snap.player.cid~=nil then snap.player.cid=slot end
    end
    snap.player.charinfo=json.encode(ci)
    local batch={}
    if replacement then removeQueries(batch,replacement.citizenid) end
    insertRow('players',snap.player,{id=true,last_updated=true},batch)
    for _,r in ipairs(snap.vehicles or {}) do insertRow('player_vehicles',r,{id=true},batch) end
    for _,r in ipairs(snap.ox or {}) do insertRow('ox_inventory',r,{id=true,lastupdated=true},batch) end
    for _,r in ipairs(snap.inv or {}) do insertRow('inventories',r,{id=true},batch) end
    local approved={} for _,t in ipairs(related()) do approved[t[1]]=true end
    for tbl,rows in pairs(snap.extra or {}) do
        assert(approved[tbl],'Backup table must be configured before restore: '..tostring(tbl))
        assert(exists(tbl),'Missing backup table: '..tbl)
        for _,r in ipairs(rows) do insertRow(tbl,r,{id=true},batch) end
    end
    for _,item in ipairs(batch) do local tbl=item.query:match('INSERT INTO ([%w_]+)');if tbl then assert(exists(tbl),'Missing table: '..tbl) end end
    batch[#batch+1]={query='UPDATE wipe_backups SET restored=1,restored_at=? WHERE id=?',values={os.time(),row.id}}
    if not Integration.Transaction(batch) then error('Restore transaction rolled back; previous character preserved') end
    log(src,'RESTORE FULL',row.citizenid,clean(d.reason,150),'Backup #'..row.id..(replacement and ' | Replaced '..replacement.citizenid or ' | Added character'))
    return {ok=true,msg='Character restored. Player can reconnect.'}
end

-- Exchange account ownership; citizen IDs and character-owned items stay intact.
local swapReady=false
local swapRetryAt,swapLastError=0,nil
local function loadSwapCharacters(first,second)
    local a=q('SELECT * FROM players WHERE citizenid=?',{first})[1]
    local b=q('SELECT * FROM players WHERE citizenid=?',{second})[1]
    assert(a and b,'Both characters must exist')
    assert(a.license and b.license and a.license~=b.license,'Characters must belong to different accounts')
    return a,b
end
local function buildSwap(batch,a,b)
    assert(exists('players'),'Players table missing')
    local columns={}
    for _,c in ipairs(q('SHOW COLUMNS FROM players')) do columns[c.Field]=true end
    local ca,cb=dec(a.charinfo),dec(b.charinfo)
    local slotA,slotB=ca.cid or a.cid,cb.cid or b.cid
    ca.cid,cb.cid=slotB,slotA
    local function update(character,owner,info,slot)
        local parts,values={'license=?','charinfo=?'},{owner.license,json.encode(info)}
        if columns.license2 then parts[#parts+1]='license2=?';values[#values+1]=owner.license2 or owner.license end
        if columns.cid then parts[#parts+1]='cid=?';values[#values+1]=slot or owner.cid or 1 end
        values[#values+1]=character.citizenid
        batch[#batch+1]={query='UPDATE players SET '..table.concat(parts,',')..' WHERE citizenid=?',values=values}
    end
    update(a,b,ca,slotB);update(b,a,cb,slotA)
    for _,t in ipairs(Config.CharacterSwapAccountTables or {{'player_vehicles','citizenid','license'}}) do
        assert(t[1]:match('^[%w_]+$') and t[2]:match('^[%w_]+$') and t[3]:match('^[%w_]+$'),'Invalid swap account table')
        if exists(t[1]) then
            batch[#batch+1]={query=('UPDATE %s SET %s=? WHERE %s=?'):format(t[1],t[3],t[2]),values={b.license,a.citizenid}}
            batch[#batch+1]={query=('UPDATE %s SET %s=? WHERE %s=?'):format(t[1],t[3],t[2]),values={a.license,b.citizenid}}
        end
    end
end
MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS ultimate_character_swaps (
        id INT AUTO_INCREMENT PRIMARY KEY, first_cid VARCHAR(50),second_cid VARCHAR(50),
        first_license VARCHAR(100),second_license VARCHAR(100),admin VARCHAR(100),
        status VARCHAR(20) DEFAULT 'pending',error TEXT,created_at BIGINT,finished_at BIGINT
    ) ENGINE=InnoDB]])
    swapReady=true
end)
H.switchCitizenId=function(src,d)
    local first,second=clean(d.current,50),clean(d.new,50)
    if not first:match('^[%w]+$') or not second:match('^[%w]+$') or first==second then return {error='Enter two different existing citizen IDs'} end
    if not swapReady then return {error='Swap queue starting'} end
    local a,b=loadSwapCharacters(first,second)
    if q("SELECT id FROM ultimate_character_swaps WHERE status='pending' AND (first_cid IN (?,?) OR second_cid IN (?,?))",{first,second,first,second})[1] then return {error='One character already has a pending swap'} end
    local id=MySQL.insert.await('INSERT INTO ultimate_character_swaps(first_cid,second_cid,first_license,second_license,admin,created_at) VALUES (?,?,?,?,?,?)',{first,second,a.license,b.license,GetPlayerName(src),os.time()})
    assert(id,'Could not save swap request')
    log(src,'Character swap queued',first..' <-> '..second,'','Request #'..id)
    return {ok=true,msg='Character swap queued. Both accounts must disconnect before it applies.'}
end
CreateThread(function()
    while true do
        Wait(5000)
        if swapReady and not mutationBusy and os.time()>=swapRetryAt then
            mutationBusy=true
            local ok,err=pcall(function()
                for _,job in ipairs(q("SELECT * FROM ultimate_character_swaps WHERE status='pending' ORDER BY id")) do
                    if not accountOnline(job.first_license,job.first_cid) and not accountOnline(job.second_license,job.second_cid) then
                        Wait(Config.CharacterSaveWaitMs or 2000)
                        if not accountOnline(job.first_license,job.first_cid) and not accountOnline(job.second_license,job.second_cid) then
                            local done,failure=pcall(function()
                                local a,b=loadSwapCharacters(job.first_cid,job.second_cid)
                                assert(a.license==job.first_license and b.license==job.second_license,'Character ownership changed; swap cancelled')
                                local batch={}
                                -- Safety snapshots and ownership updates commit together.
                                for _,character in ipairs({a,b}) do
                                    local snap=snapshot(character.citizenid)
                                    insertRow('wipe_backups',{citizenid=character.citizenid,name=nameOf(dec(character.charinfo)),kind='full',data=json.encode(snap),admin=job.admin,reason='Safety backup before character swap #'..job.id,created_at=os.time(),restored=0},{},batch)
                                end
                                buildSwap(batch,a,b)
                                batch[#batch+1]={query="UPDATE ultimate_character_swaps SET status='done',finished_at=? WHERE id=?",values={os.time(),job.id}}
                                assert(Integration.Transaction(batch),'Swap rolled back; both characters unchanged')
                            end)
                            if not done then x("UPDATE ultimate_character_swaps SET status='failed',error=?,finished_at=? WHERE id=?",{tostring(failure):sub(1,1000),os.time(),job.id}) end
                        end
                    end
                end
            end)
            mutationBusy=false
            if not ok then
                swapRetryAt=os.time()+60
                local message=tostring(err):sub(1,500)
                if swapLastError~=message then print('[wipemenu] Swap queue paused: '..message);swapLastError=message end
            else swapLastError=nil end
        end
    end
end)
