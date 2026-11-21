
# Join Our Discord : 

https://discord.gg/UwgTfKXEps 
# WipeMenu Showcase : 

https://www.youtube.com/watch?v=Vhah98hqCYM


# UltimateXwipemenu installation

1. Start `oxmysql`, `ox_lib`, `ox_inventory`, the selected framework and configured integrations first.
2. Import `sql/install.sql` to prepare the wipe-backup and character-swap tables. The resource also creates these tables on startup.
3. Configure `config/config.lua` and upload the resource through the Cfx.re Keymaster Asset Escrow portal.




Only config/config.lua needs to be edited for this resource's settings and integrations.
The integration_*.lua files implement the protected core; customers do not edit them.
Changes take effect after restarting the resource.

INSTALL
1. Back up your server and database. Copy this resource folder into resources.
2. Start oxmysql and ox_lib, then your framework and selected integrations.
3. Use your existing mysql_connection_string in server.cfg. Database credentials
   belong to the server, never to a client/shared resource file.
4. Edit config/config.lua using the selections below. Start only one copy of each script.
5. Add "ensure UltimateXwipemenu" to server.cfg AFTER the required resources.
6. The script creates its own SQL tables automatically. It does not install or
   replace the framework, inventory or garage's SQL tables.
7. Test permissions and the main player flow on a test server before going live.

