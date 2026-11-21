local QBCore = Integration.Core

RegisterNetEvent('wipemenu:client:open', function(d)
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', admin = d and d.admin or 'Admin' })
end)

RegisterNUICallback('call', function(d, cb)
    if type(d)~='table' or type(d.action)~='string' then return cb({error='Invalid request'}) end
    local completed=false
    local function finish(result)
        if completed then return end
        completed=true;cb(result)
    end
    SetTimeout(45000,function() finish({error='Server response timed out. Check the result before repeating a change.'}) end)
    local ok=pcall(function()
        QBCore.Functions.TriggerCallback('wipemenu:call',function(res)
            finish(res or {error='No response from server'})
        end,d.action,d.data)
    end)
    if not ok then finish({error='Could not contact the server. Check framework configuration.'}) end
end)

RegisterNUICallback('close', function(_, cb)
    SetNuiFocus(false, false)
    TriggerServerEvent('wipemenu:server:close')
    cb('ok')
end)

AddEventHandler('onResourceStop', function(r)
    if r == GetCurrentResourceName() then SetNuiFocus(false, false) end
end)
