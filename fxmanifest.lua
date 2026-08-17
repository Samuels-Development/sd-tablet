fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'sd-tablet'
author 'Samuel#0008'
version '0.9.8'
description 'In-game tablet: a second device running the sd-phone React bundle over sd-phone\'s own client and server layer. Shares every byte of player data with the phone - messages, mail, contacts, installed apps, settings - and can do everything the phone can except make or receive voice calls'

shared_scripts {
    '@ox_lib/init.lua',
}

-- Only the entry point is a script; every other client file is a module reached through ox_lib's
-- require, which reads it out of files{} below. Same layout as sd-phone.
client_scripts {
    'client/main.lua',
}

server_scripts {
    'server/main.lua',
}

ui_page 'web/build/index.html'

files {
    'configs/*.lua',
    'client/**.lua',
    -- ox_lib's locale module reads these with LoadResourceFile, so they ship as files. Both
    -- realms call lib.locale(): the client resolves the player's ox_lib language setting, the
    -- server the `ox:locale` convar.
    'locales/*.json',
    'web/build/index.html',
    'web/build/sdphone-sdk.js',
    'web/build/assets/*.js',
    'web/build/assets/*.css',
    'web/build/assets/*.png',
    'web/build/assets/*.jpg',
    'web/build/assets/*.webp',
    'web/build/assets/*.svg',
    'web/build/assets/*.woff2',
    'web/build/assets/*.woff',
    'web/build/assets/*.mp3',
}

-- sd-phone is a hard dependency, not a soft one: every NUI action this device answers is one of
-- sd-phone's handlers, invoked across the companion seam. Without it the tablet is a blank frame.
-- NOT `provide 'lb-phone'` - sd-phone already claims that, and two providers of one name is a
-- start-order coin toss.
dependencies {
    'ox_lib',
    'sd-phone',
}
