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
    -- Inventory items that open the tablet, one per colour. Using an item opens the tablet with
    -- that colour's prop in hand (PropPrefix .. colour); the keybind reopens with the last colour
    -- you used, falling back to whichever listed item you actually carry. Set to false to disable
    -- item-based opening entirely. `tablet` is the pre-colour item, kept so tablets already in
    -- players' inventories keep working.
    Items = {
        { item = 'tablet',        color = 'black'  },
        { item = 'tablet_black',  color = 'black'  },
        { item = 'tablet_blue',   color = 'blue'   },
        { item = 'tablet_green',  color = 'green'  },
        { item = 'tablet_orange', color = 'orange' },
        { item = 'tablet_pink',   color = 'pink'   },
        { item = 'tablet_purple', color = 'purple' },
        { item = 'tablet_red',    color = 'red'    },
        { item = 'tablet_yellow', color = 'yellow' },
    },

    -- Colour the tablet opens with before any item has been used this session (the keybind
    -- fallback). Must be one of the colours listed in Items.
    DefaultColor = 'black',

    -- Require the player to actually carry one of `Items` before the keybind opens anything. The
    -- check is server-side (server/main.lua), so turning this off is the only way to open without
    -- one. Ignored when Items is false, which leaves the keybind open to everybody.
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

    -- The boot animation: your logo over a lit backdrop, played once when the resource starts and
    -- the player first opens the tablet, never on ordinary opens after that. Off by default so an
    -- untouched install goes straight to the lockscreen; set true to turn it on. Players who pick
    -- No Motion in Accessibility never see it either way. The tablet keeps its OWN value rather
    -- than reading sd-phone's configs/phone.lua BootScreen, for the reason at the top of this file.
    BootScreen = false,

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
    -- still walk. The prop model is PropPrefix .. <colour> (e.g. sd_tablet_red), so the tablet in
    -- hand matches the item you opened. These models are streamed by the sd-tablet-props resource
    -- - ensure it's started, or no prop will attach (the tablet itself still works).
    HoldAnimation = true,
    AnimDict      = 'amb@code_human_in_bus_passenger_idles@female@tablet@base',
    AnimName      = 'base',
    PropPrefix    = 'sd_tablet_',
    PropBone      = 60309,   -- SKEL_L_Hand: this clip holds the device in the LEFT hand

    -- Other clips worth swapping in. Each needs its bone AND the transform below changed with it,
    -- because they do not all hold the device in the same hand or at the same wrist angle:
    --
    --   ps-mdt's clip, right hand, matching how ps-mdt itself welds a tablet:
    --     AnimDict = 'amb@code_human_in_bus_passenger_idles@female@tablet@idle_a'
    --     AnimName = 'idle_a'      PropBone = 28422
    --     PropOffset = vec3(-0.012, 0.001, 0.037)     PropRot = vec3(0.0, -90.0, 0.0)
    --
    --   Tourist map, both hands, completely still - no reaching in to swipe:
    --     AnimDict = 'amb@world_human_tourist_map@male@base'
    --     AnimName = 'base'        PropBone = 28422

    -- Zero, because the sd_tablet_<colour> models are built to the same convention as the vanilla
    -- prop_cs_tablet: centre origin, X across the screen, Y through it, Z up it. They weld where
    -- the vanilla tablet welds, so a clip authored around that needs no transform at all. A clip
    -- that turns the wrist differently still does - see the swaps above.
    PropOffset = vec3(0.0, 0.0, 0.0),
    PropRot    = vec3(0.0, 0.0, 0.0),

    -- Let other players see the tablet: the server ownership-checks the colour and writes a
    -- replicated statebag, and every nearby client welds its own LOCAL copy off it.
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
