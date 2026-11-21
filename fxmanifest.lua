fx_version 'cerulean'
game 'gta5'
shared_script 'esx_bridge.lua'
lua54 'yes'
author 'UltimateX'
description 'UltimateX Wipe Control - /wipemenu (QBCore)'
version '1.0.0'

ui_page 'html/index.html'
files { 'html/*' }

shared_scripts { '@ox_lib/init.lua', 'config/config.lua' }
client_scripts { 'client/integration_client.lua', 'client/client.lua' }
server_scripts { '@oxmysql/lib/MySQL.lua', 'esx_database.lua', 'server/integration_server.lua', 'server/server.lua' }

dependencies { 'oxmysql', 'ox_lib', 'ox_inventory' }
files { 'sql/*.sql' }



escrow_ignore { 'config/config.lua', 'sql/*.sql', 'README.md' }

