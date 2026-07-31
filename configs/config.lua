-- Main config - an index that stitches the per-group config files together, exactly like
-- sd-phone's. Every consumer does `require 'configs.config'` and reads the same table; to change
-- a group's settings, edit its own file in this folder.
--
-- The tablet deliberately has FAR fewer knobs than the phone. Everything that belongs to the
-- player rather than to the device - mail accounts, message limits, garages, banking, cell
-- towers, Wi-Fi, the app back-ends - stays configured in sd-phone and is reached through it, so
-- there is exactly one place to change any of it and the two devices can never disagree.

local config = {
    -- Locale file sd-phone's React bundle loads. Keep it the same as sd-phone's configs/config.lua
    -- unless you genuinely want the tablet in another language.
    Locale = 'en',

    -- Debug / dev logging toggle. Prints open/close and every refused or forwarded RPC.
    Debug  = false,

    -- Per-group settings (one file each).
    Tablet = require 'configs.tablet',   -- item, keybind, prop/anim, movement, safety blocks, status bar
    Apps   = require 'configs.apps',     -- dock, wallpaper, app catalog (no phone app)
}

return config
