fx_version 'cerulean'
game 'gta5'


author 'Azure(TheStoicBear)'
description 'AZ Tow: Tow job + civilian spawn, dispatch, AI calls, impound system integrated with Az-Framework exports'
version '1.0.0'


shared_script 'config.lua'
server_scripts {
    '@Az-Framework/init.lua',
    'server.lua'
}
client_script 'client.lua'
shared_scripts {
    '@ox_lib/init.lua',
}

ui_page 'html/index.html'


files {
'html/index.html'
}