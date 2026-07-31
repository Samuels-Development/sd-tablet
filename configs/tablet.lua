-- Tablet open / close behaviour, the hand prop, and the cosmetic status bar.
--
-- A few values here are DELIBERATE DUPLICATES of sd-phone settings (Mail.Domain, Number). They
-- are presentation only - the tablet never stores a number or an address, it only renders the
-- ones sd-phone's server hands it - but they have to match sd-phone's configs/mail.lua and
-- configs/phone.lua or the same address will be formatted two different ways on the two devices.
-- They are copied rather than read across the resource boundary on purpose: reaching into another
-- resource's config files at load time makes the tablet fail to boot whenever sd-phone's file
-- layout moves, and a wrongly formatted phone number is a much cheaper failure than that.
return {
    -- Inventory item that opens the tablet when used. Unlike the phone there are no colour
    -- variants: a tablet is a tablet. Set to false to disable item-based opening entirely.
    Item = 'tablet',

    -- Require the player to actually carry `Item` before the keybind opens anything. The check is
    -- server-side (server/main.lua), so turning this off is the only way to open without one.
    -- Ignored when Item is false, which leaves the keybind open to everybody.
    RequireItem = true,

    -- Default keybind to open / close the tablet. Players can rebind it via FiveM's keybinding
    -- menu (Settings -> Key Bindings -> FiveM). F1 is sd-phone's, so this is the next one over.
    Keybind = 'F2',

    -- Hold this key (while the tablet is open) to free the mouse for camera rotation without
    -- closing the tablet. This is what lets a walking player aim the lens in the Camera app.
    -- sd-phone's own look keybind only answers while the PHONE is open, so the tablet needs its
    -- own. Same default, because only one of the two devices is ever on screen.
    LookKeybind = 'MOUSE_EXTRABTN1',

    -- Safety blocks against use-on-floor exploits, matching sd-phone's.
    BlockWhileDead     = true,
    BlockWhileSwimming = true,

    -- Refuse to open while the player is DRIVING. A tablet is a two-handed device; the phone has
    -- no equivalent block because a phone is not. Passengers are unaffected. Checked at open
    -- only - getting into a car with the tablet already out does not close it.
    BlockWhileDriving  = true,

    -- Let the player walk around while the tablet is open, exactly as sd-phone's AllowMovement
    -- does: mouse-look, aiming, firing, melee and weapon switching are suppressed so the mouse
    -- only drives the on-screen cursor, and focusing a text field hands full control back to the
    -- UI so typing WASD in a search box doesn't move you. Set false to freeze the player.
    AllowMovement = true,

    -- Keep that movement alive while the Camera app's viewfinder owns the screen. Needs
    -- AllowMovement.
    --
    -- MUST MATCH sd-phone's configs/phone.lua AllowMovementInCamera (and AllowMovement above must
    -- match its AllowMovement). The viewfinder is sd-phone's and the tablet only forwards it, so
    -- this pair is not just our movement rule - it is how the tablet works out WHICH camera
    -- sd-phone took the view with. Movement allowed means its scripted camera, which animates
    -- nothing and leaves the hold pose and the hand prop alone; movement off means the native
    -- cell-cam, which pins the ped and spawns a phone of its own, so ours has to stand down for
    -- it. Get the pair wrong and the tablet either vanishes out of the player's hands while they
    -- shoot, or sits in them alongside a phone that GTA put there.
    AllowMovementInCamera = true,

    -- Start every open on the lockscreen. The passcode is part of the shared phone settings, so
    -- it is the SAME passcode as the phone's. Set false to open straight onto the home screen -
    -- reasonable for a tablet that never leaves a desk.
    StartLocked = true,

    -- Third-person "holding a tablet" pose + prop. Looping upper-body clip, so the player can
    -- still walk. Unlike the phone there is one model, not one per frame colour.
    HoldAnimation = true,
    AnimDict      = 'amb@code_human_in_bus_passenger_idles@female@tablet@base',
    AnimName      = 'base',
    PropModel     = 'prop_cs_tablet',
    PropBone      = 60309,   -- SKEL_L_Hand: the tablet clip holds the device in the LEFT hand

    -- Fine-tune where the prop sits in the hand. prop_cs_tablet is authored so a zero
    -- offset/rotation weld to SKEL_L_Hand lands in the reading grip for the clip above; nudge
    -- these only if you swap in a model whose origin is off the grip point.
    PropOffset = vec3(0.0, 0.0, 0.0),
    PropRot    = vec3(0.0, 0.0, 0.0),

    -- Let other players see the tablet in your hands. The holder broadcasts a replicated statebag
    -- and every nearby client spawns its own LOCAL welded copy (the clip already replicates on
    -- its own). Deliberately NOT a networked object: a networked prop's ownership can migrate to
    -- another client whose sync then freezes it mid-hold. Set false for local-only.
    PropVisibleToOthers = true,

    -- Cosmetic status bar. The tablet keeps its OWN battery - it is a different device with a
    -- different charge - which is why the phone's battery push is dropped at the mirror rather
    -- than shown here.
    StatusBar = {
        Carrier      = 'LifeInvader',
        SignalBars   = 4,      -- 0..4, used only when no cell towers are configured in sd-phone
        ShowWifi     = true,
        BatteryStart = 100,    -- 0..100, ticks down while the tablet is open

        -- sd-phone runs Bluetooth from configs/bluetooth.lua but exposes no client export for
        -- "is it configured", so the tablet cannot ask. Mirror sd-phone's Bluetooth.Enabled here.
        -- If a future sd-phone adds an isBluetoothConfigured export, it wins over this value.
        BluetoothConfigured = true,
    },

    -- Lockscreen clock, same registry of options as sd-phone's configs/lockscreen.lua.
    Lockscreen = {
        ShowDate  = true,
        Use24Hour = false,
    },

    -- MUST MATCH sd-phone's configs/mail.lua Domain. Display only - the tablet never mints an
    -- address, it renders the ones sd-phone's server already owns.
    Mail = {
        Domain = 'lifeinvader.com',
    },

    -- MUST MATCH sd-phone's configs/phone.lua Number. Display only, for the same reason: numbers
    -- are always STORED as bare digits, and this is how they are printed. Keyed by digit count
    -- so numbers of different lengths stay readable side by side.
    Number = {
        Length  = 10,
        Formats = {
            [10] = '(XXX) XXX-XXXX',
        },
    },
}
