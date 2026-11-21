-- ESX database boundary for the wipe menu's canonical player/vehicle queries.
local E=UltimateXESX
local function dec(v) if type(v)=='table' then return v end;local ok,r=pcall(json.decode,v or '{}');return ok and type(r)=='table' and r or {} end
local players=[[ (SELECT u.*,
    identifier AS citizenid, CONCAT('license:',SUBSTRING_INDEX(identifier,':',-1)) AS license,
    CONCAT(COALESCE(firstname,''),' ',COALESCE(lastname,'')) AS name,
    JSON_OBJECT('firstname',firstname,'lastname',lastname,'birthdate',dateofbirth,'gender',IF(sex='f',1,0)) AS charinfo,
    JSON_SET(COALESCE(accounts,'{}'),'$.cash',COALESCE(CAST(JSON_UNQUOTE(JSON_EXTRACT(accounts,'$.money')) AS DECIMAL(20,0)),0)) AS money
    FROM users u) players ]]
local vehicles=[[ (SELECT owner AS citizenid, owner AS license, plate, vehicle AS mods,
    ultx_model AS vehicle, stored AS state, type, 'pillboxgarage' AS garage FROM owned_vehicles) player_vehicles ]]
local function accounts(v)
    local m=dec(v);m.money=m.cash or m.money or 0;m.cash=nil;return json.encode(m)
end
function E.SQL(sql,params)
    params=params or {}
    if sql:match('^%s*SELECT') then
        sql=sql:gsub('FROM%s+`players`',function() return 'FROM '..players end)
        sql=sql:gsub('FROM%s+players%f[^%w_]',function() return 'FROM '..players end)
        sql=sql:gsub('FROM%s+`player_vehicles`',function() return 'FROM '..vehicles end)
        sql=sql:gsub('FROM%s+player_vehicles%f[^%w_]',function() return 'FROM '..vehicles end)
        return sql,params
    end
    if sql:match('^%s*SHOW COLUMNS FROM%s+`?players') then return 'SHOW COLUMNS FROM users',params end
    if sql:match('^%s*SHOW COLUMNS FROM%s+`?player_vehicles') then return 'SHOW COLUMNS FROM owned_vehicles',params end
    if sql:match('^%s*UPDATE players SET money%s*=') then return 'UPDATE users SET accounts=? WHERE identifier=?',{accounts(params[1]),params[2]} end
    if sql:match('^%s*UPDATE players SET charinfo%s*=') then
        local c=dec(params[1]);return 'UPDATE users SET firstname=?,lastname=?,dateofbirth=?,sex=? WHERE identifier=?',
            {c.firstname,c.lastname,c.birthdate,c.gender==1 and 'f' or 'm',params[2]}
    end
    if sql:match('^%s*INSERT INTO%s+`?players`?%s*%(') then
        local cols=sql:match('%((.-)%)');local row={};local i=0
        for col in cols:gmatch('[%w_]+') do i=i+1;row[col]=params[i] end
        -- Backups contain the original users columns as well as display aliases.
        local omit={citizenid=true,license=true,name=true,charinfo=true,money=true,id=true}
        local names,values,marks={},{},{}
        local expressions={};local index=0
        for expression in (sql:match('VALUES%s*%((.*)%)') or ''):gmatch('[^,]+') do index=index+1;expressions[index]=expression end
        local byColumn={};index=0
        for col in cols:gmatch('[%w_]+') do index=index+1;byColumn[col]=expressions[index] end
        row.identifier=row.identifier or row.citizenid
        if row.money then row.accounts=accounts(row.money) end
        if row.charinfo then local c=dec(row.charinfo);row.firstname=c.firstname;row.lastname=c.lastname;row.dateofbirth=c.birthdate;row.sex=c.gender==1 and 'f' or 'm' end
        for col,v in pairs(row) do if not omit[col] then names[#names+1]='`'..col..'`';values[#values+1]=v;marks[#marks+1]=byColumn[col] or '?' end end
        return 'INSERT INTO users ('..table.concat(names,',')..') VALUES ('..table.concat(marks,',')..')',values
    end
    if sql:match('^%s*INSERT INTO%s+`?player_vehicles`?%s*%(') then
        local cols=sql:match('%((.-)%)');local row={};local i=0
        for col in cols:gmatch('[%w_]+') do i=i+1;row[col]=params[i] end
        local native={};local omit={citizenid=true,license=true,mods=true,state=true,garage=true,id=true}
        for k,v in pairs(row) do if not omit[k] then native[k]=v end end
        native.owner=row.owner or row.citizenid;native.vehicle=row.mods or row.vehicle
        native.type=row.type or 'car';native.stored=row.stored or row.state or 0
        native.ultx_model=row.ultx_model or row.vehicle
        local names,values,marks={},{},{}
        for k,v in pairs(native) do names[#names+1]='`'..k..'`';values[#values+1]=v;marks[#marks+1]='?' end
        return 'INSERT INTO owned_vehicles ('..table.concat(names,',')..') VALUES ('..table.concat(marks,',')..')',values
    end
    -- Remaining mutations use simple native fields, never a read-only SQL view.
    if sql:find('players',1,true) then sql=sql:gsub('%f[%w_]players%f[^%w_]','users'):gsub('%f[%w_]citizenid%f[^%w_]','identifier') end
    if sql:find('player_vehicles',1,true) then sql=sql:gsub('%f[%w_]player_vehicles%f[^%w_]','owned_vehicles'):gsub('%f[%w_]citizenid%f[^%w_]','owner') end
    return sql,params
end
function E.Query(sql,params)
    if sql:match('^%s*SELECT %* FROM player_vehicles') then
        local query=sql:gsub('%f[%w_]player_vehicles%f[^%w_]','owned_vehicles'):gsub('%f[%w_]citizenid%f[^%w_]','owner')
        local rows=MySQL.query.await(query,params or {})
        for _,row in ipairs(rows) do
            row.mods=row.vehicle;row.vehicle=row.ultx_model or dec(row.vehicle).model
            row.citizenid=row.owner;row.license=row.owner;row.state=row.stored;row.garage=row.parking or 'pillboxgarage'
        end
        return rows
    end
    local query,values=E.SQL(sql,params)
    return MySQL.query.await(query,values)
end
function E.Transaction(queries)
    local result={}
    for _,q in ipairs(queries) do local sql,values=E.SQL(q.query,q.values);result[#result+1]={query=sql,values=values} end
    return MySQL.transaction.await(result)
end
