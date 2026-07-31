-- The tablet's app catalog: dock, home wallpaper, and every app the tablet knows about.
--
-- WHICH APPS ARE INSTALLED IS NOT DECIDED HERE. Installed apps live on the player's shared phone
-- profile, server-side, and the tablet reads exactly the same list the phone does - that is the
-- whole point of the device. This file only says which apps the tablet is CAPABLE of showing.
-- The rule that follows from that:
--
--   Every `id` below must also exist in sd-phone's configs/apps.lua.
--   Installing from the tablet's App Store goes to sd-phone's server, which validates the id
--   against ITS catalog; an id only the tablet knows is refused, and an app only the phone knows
--   simply doesn't appear on the tablet.
--
-- Per-app flags behave exactly as they do on the phone:
--   base = true       ships installed and cannot be removed (never in the App Store)
--   enabled = false   the app is not shown on THIS DEVICE. It is not uninstalled - the phone
--                     keeps it - so this is how you keep an app phone-only.
--
-- There is no `phone` entry and there never can be: a tablet cannot place or answer a call, and
-- sd-phone's companion seam refuses every call action on its own side regardless of what is
-- listed here.
return {
    -- Wallpaper name, resolved by the React app's wallpaper registry (web/src/shell/wallpapers.ts).
    Wallpaper = 'lockscreen.jpg',

    -- Apps shown in the dock (bottom row). App `id`s match the keys in `Apps` below - the icon,
    -- label and route are looked up from there. The phone's dock leads with `phone`; this one
    -- leads with the two things a tablet is actually for.
    Dock = { 'messages', 'mail', 'camera', 'photos' },

    -- All apps. The homescreen renders every app whose `id` doesn't appear in `Dock` in the
    -- device's grid, in the order defined below. `route` is the SPA path the React app navigates
    -- to when the icon is tapped.
    Apps = {
        { id = 'messages', label = 'Messages', icon = 'messages', route = '/messages', accent = '#34c759', base = true, enabled = true },
        { id = 'mail', label = 'Mail', icon = 'mail', route = '/mail', accent = '#0a84ff', base = true, enabled = true },
        { id = 'maps', label = 'Maps', icon = 'maps', route = '/maps', accent = '#f0c43a', base = true, enabled = true },
        { id = 'compass', label = 'Compass', icon = 'compass', route = '/compass', accent = '#1c1c1e', base = true, enabled = true },
        { id = 'camera', label = 'Camera', icon = 'camera', route = '/camera', accent = '#1c1c1e', base = true, enabled = true },
        { id = 'photos', label = 'Photos', icon = 'photos', route = '/photos', accent = '#ffffff', base = true, enabled = true },
        { id = 'music', label = 'Music', icon = 'music', route = '/music', accent = '#fa233b', base = true, enabled = true },
        { id = 'weather', label = 'Weather', icon = 'weather', route = '/weather', accent = '#5ac8fa', base = true, enabled = true },
        { id = 'clock', label = 'Clock', icon = 'clock', route = '/clock', accent = '#1c1c1e', base = true, enabled = true },
        { id = 'calendar', label = 'Calendar', icon = 'calendar', route = '/calendar', accent = '#ffffff', base = true, enabled = true },
        { id = 'notes', label = 'Notes', icon = 'notes', route = '/notes', accent = '#fec547', base = true, enabled = true },
        { id = 'voicememos', label = 'Voice Memos', icon = 'voicememos', route = '/voicememos', accent = '#ff3b30', base = true, enabled = true },
        { id = 'bank', label = 'Bank', icon = 'bank', route = '/bank', accent = '#00b894', base = true, enabled = true },
        { id = 'health', label = 'Health', icon = 'health', route = '/health', accent = '#ff2d55', base = true, enabled = true },
        { id = 'documents', label = 'Files', icon = 'documents', route = '/documents', accent = '#3478F6', base = true, enabled = true },
        { id = 'groups', label = 'Groups', icon = 'groups', route = '/groups', accent = '#6C63FF', base = false, enabled = true },
        { id = 'birdy', label = 'Squawk', icon = 'birdy', route = '/birdy', accent = '#1d9bf0', base = false, enabled = true },
        { id = 'services', label = 'Services', icon = 'services', route = '/services', accent = '#16B8A6', base = false, enabled = true },
        { id = 'pages', label = 'Pages', icon = 'pages', route = '/pages', accent = '#FBC02D', base = false, enabled = true },
        { id = 'review', label = 'Review', icon = 'review', route = '/review', accent = '#E03131', base = false, enabled = false },
        { id = 'marketplace', label = 'Marketplace', icon = 'marketplace', route = '/marketplace', accent = '#0a84ff', base = false, enabled = true },
        { id = 'darkchat', label = 'Dark Chat', icon = 'darkchat', route = '/darkchat', accent = '#1c1c1e', base = false, enabled = true },
        { id = 'cherry', label = 'Cherry', icon = 'cherry', route = '/cherry', accent = '#F0285A', base = false, enabled = true },
        { id = 'photogram', label = 'Photogram', icon = 'photogram', route = '/photogram', accent = '#D62976', base = false, enabled = true },
        { id = 'garages', label = 'Garages', icon = 'garages', route = '/garages', accent = '#6E5CF2', base = false, enabled = true },
        { id = 'homes', label = 'Homes', icon = 'homes', route = '/homes', accent = '#12B866', base = false, enabled = true },
        { id = 'ryde', label = 'Ryde', icon = 'ryde', route = '/ryde', accent = '#1c1c1e', base = false, enabled = true },
        -- The Radio app is RF, not telephony, so the call ban does not reach it. Set enabled to
        -- false if you would rather a radio needed a radio.
        { id = 'radio', label = 'Radio', icon = 'radio', route = '/radio', accent = '#30B0C7', base = false, enabled = true },
        { id = 'stocks', label = 'Stocks', icon = 'stocks', route = '/stocks', accent = '#16C784', base = false, enabled = true },
        { id = 'settings', label = 'Settings', icon = 'settings', route = '/settings', accent = '#8e8e93', base = true, enabled = true },
        { id = 'appstore', label = 'App Store', icon = 'appstore', route = '/appstore', accent = '#0a84ff', base = true, enabled = true },
        { id = 'calculator', label = 'Calculator', icon = 'calculator', route = '/calculator', accent = '#333335', base = true, enabled = true },
        { id = 'passwords', label = 'Passwords', icon = 'passwords', route = '/passwords', accent = '#1c1c1e', base = true, enabled = true },
        { id = 'cookie', label = 'Cookie', icon = 'cookie', route = '/cookie', accent = '#C77D2E', base = false, enabled = true },
        { id = 'wordle', label = 'Wordle', icon = 'wordle', route = '/wordle', accent = '#6AAA64', base = false, enabled = true },
        { id = 'flappy', label = 'Flappy', icon = 'flappy', route = '/flappy', accent = '#4EC0CA', base = false, enabled = true },
        { id = 'blocks', label = 'Blocks', icon = 'blocks', route = '/blocks', accent = '#7C4DFF', base = false, enabled = true },
        { id = 'blackjack', label = 'Blackjack', icon = 'blackjack', route = '/blackjack', accent = '#157347', base = false, enabled = true },
        { id = 'climber', label = 'Climber', icon = 'climber', route = '/climber', accent = '#8BC34A', base = false, enabled = true },
        { id = 'railrunner', label = 'Rail Runner', icon = 'railrunner', route = '/railrunner', accent = '#3C5290', base = false, enabled = false },
        { id = 'connectfour', label = 'Connect 4', icon = 'connectfour', route = '/connectfour', accent = '#1E66D0', base = false, enabled = true },
        { id = 'chess', label = 'Chess', icon = 'chess', route = '/chess', accent = '#3B3B3B', base = false, enabled = true },
        { id = 'battleship', label = 'Battleship', icon = 'battleship', route = '/battleship', accent = '#17A0B5', base = false, enabled = true },
        { id = 'vibez', label = 'Vibez', icon = 'vibez', route = '/vibez', accent = '#A855F7', base = false, enabled = false },
        { id = 'weazelnews', label = 'Weazel News', icon = 'weazelnews', route = '/weazelnews', accent = '#C8102E', base = false, enabled = true },
        { id = 'streaks', label = 'Streaks', icon = 'streaks', route = '/streaks', accent = '#FF7A1A', base = false, enabled = true },
    },
}
