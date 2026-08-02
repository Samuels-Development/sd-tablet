-- sd-tablet client shell.
--
-- This resource contains no apps. sd-phone's client owns every NUI callback, every server
-- round-trip and every live push the shared React bundle needs, and the tablet borrows all of it
-- across the companion seam in sd-phone/client/companion.lua. What lives here is only what is
-- true of THIS DEVICE and nothing else:
--
--   * its own NUI frame, its own focus, its own open/close lifecycle
--   * the sd-phone:open payload that tells the shared bundle it is a tablet
--   * the hand prop and the hold clip
--   * device-local NUI callbacks (close, unlock, typing, flashlight...) that must never be
--     forwarded, or they would drive the phone's hardware from the tablet's screen
--
-- Everything else - messages, mail, contacts, installed apps, settings, the lot - is the same
-- server-side character on the same tables, reached through the same handlers. That is not a
-- synchronisation feature; there is only one copy of the data and both devices read it.
--
-- The one thing the tablet cannot do is place or answer a voice call. That refusal lives on
-- sd-phone's side of the seam (see its DENY list), so it holds even for a hand-edited build;
-- client/policy.lua repeats it here only so a refused action never leaves the resource.

---@type table sd-phone invoke transport (client.bridge): token-matched request/reply.
local bridge = require 'client.bridge'
---@type table Push + focus mirror (client.mirror): sd-phone's NUI traffic, applied to our frame.
local mirror = require 'client.mirror'
---@type table The single 'rpc' NUI callback (client.rpc): deny / local / forward dispatcher.
local rpc    = require 'client.rpc'
---@type table sd-tablet config root (configs/config.lua).
local config = require 'configs.config'

---@type table Tablet settings (configs/tablet.lua).
local cfg <const> = config.Tablet
---@type string The resource we borrow everything from.
local PHONE <const> = 'sd-phone'

-- Apps disabled in configs/apps.lua never reach the NUI, so neither the home screen nor the App
-- Store can show them. Built once - the catalog is static per boot.
---@type table[] Enabled app entries, config order preserved.
local ENABLED_APPS = {}
---@type string[] Dock ids with disabled apps dropped.
local ENABLED_DOCK = {}
do
    local ids = {}
    for _, app in ipairs(config.Apps.Apps or {}) do
        if app.enabled ~= false then
            ENABLED_APPS[#ENABLED_APPS + 1] = app
            if app.id then ids[app.id] = true end
        end
    end
    for _, id in ipairs(config.Apps.Dock or {}) do
        if ids[id] then ENABLED_DOCK[#ENABLED_DOCK + 1] = id end
    end
end

-- The catalog above is what this SERVER has; what this PLAYER may see also depends on the job they
-- hold, which only sd-phone's server knows. Asked on every open, so switching job on a multijob
-- server puts the right terminal on the home screen with no event to miss.
--
-- The callback is sd-phone's, called directly rather than through the companion seam: this decides
-- what goes INTO our open payload, so it has to be answered before the frame exists to forward
-- anything. A server without it (an older sd-phone) leaves the catalog untouched.
---@return table[] apps
---@return string[] dock
local function visibleApps()
    local ok, hidden = pcall(lib.callback.await, 'sd-phone:server:apps:hidden', false)
    if not ok or type(hidden) ~= 'table' or #hidden == 0 then return ENABLED_APPS, ENABLED_DOCK end

    local drop = {}
    for i = 1, #hidden do drop[hidden[i]] = true end

    local apps, dock = {}, {}
    for i = 1, #ENABLED_APPS do
        local app = ENABLED_APPS[i]
        if not drop[app.id] then apps[#apps + 1] = app end
    end
    for i = 1, #ENABLED_DOCK do
        if not drop[ENABLED_DOCK[i]] then dock[#dock + 1] = ENABLED_DOCK[i] end
    end
    return apps, dock
end

-- Number display config for the NUI. Format keys are stringified deliberately: a Lua table whose
-- integer keys run contiguously from 1 encodes as a JSON ARRAY, which would land in the UI
-- off-by-one, so this guarantees an object either way. Same treatment as sd-phone's.
---@type { formats: table<string, string>, length: integer }
local NUMBER_FORMAT = {}
do
    local numberCfg = type(cfg.Number) == 'table' and cfg.Number or {}
    local formats = {}
    for length, pattern in pairs(type(numberCfg.Formats) == 'table' and numberCfg.Formats or {}) do
        if type(pattern) == 'string' and pattern ~= '' then formats[tostring(length)] = pattern end
    end
    NUMBER_FORMAT = { formats = formats, length = math.floor(tonumber(numberCfg.Length) or 10) }
end

---@type table Tablet visibility state: open/locked flags + cosmetic battery percentage.
local tabletState = {
    open    = false,  -- true while the NUI is focused on the tablet
    locked  = true,   -- true while the lockscreen is shown
    battery = cfg.StatusBar.BatteryStart,
}

---@type integer Wall-clock ms of the session start (re-stamped on character load); the Health
---app's "time awake" anchor. Stamped the same way sd-phone stamps its own, from the same events,
---so the two devices agree without either having to ask the other.
local SESSION_START_MS = GetCloudTimeAsInt() * 1000

---@type boolean True while a UI text field is focused.
local typingInTablet = false
---@type boolean True while the focused field is digit-only (PIN pads): keep-input stays on so the
---player can move, and the digit weapon binds are suppressed instead.
local typingNumeric = false
---@type boolean True while the hold-to-look keybind has released the cursor for camera control.
local lookMode = false
---@type boolean True while a forwarded sd-phone camera surface owns the view on our behalf.
local cameraActive = false
---@type boolean True while that surface is framing with the REAR lens, i.e. the player - and
---anything in their hands - must stay out of their own shot. Tracked from the lens callback the UI
---forwards; see the rpc.watch wiring further down.
local cameraRearLens = false
---@type boolean True while the Camera app has handed the mouse to the game to aim the lens.
local cameraCursorFree = false

---@type fun() Tablet close; assigned further down, referenced by threads defined before it.
local CloseTablet

---Prints debug output when config.Debug is enabled.
---@param ... any values to print
local function debugPrint(...)
    if config.Debug then print('[sd-tablet:client]', ...) end
end

---Shows an on-screen toast. ox_lib is a hard dependency of both resources, so it is always the
---backend here - unlike sd-phone, which has a whole bridge because its notify reaches players
---from the server too.
---@param description string
---@param kind string|nil 'error' | 'inform' | 'success'
local function notify(description, kind)
    lib.notify({
        id          = math.random(1, 999999),
        title       = 'Tablet',
        description = description,
        type        = kind or 'inform',
        position    = 'top-right',
        duration    = 3000,
    })
end

---Calls an sd-phone client export, tolerating one that does not exist. Several readings the open
---payload wants (service bars, Wi-Fi networks) have exports; a couple do not yet, and calling a
---missing export raises rather than returning nil. Wrapping the call means a newer sd-phone that
---adds one is picked up with no change here, and an older one falls back to config.
---@param name string export name
---@param ... any arguments
---@return boolean ok, any value
local function phoneExport(name, ...)
    if GetResourceState(PHONE) ~= 'started' then return false, nil end
    -- The INDEX is what raises on a missing export ("No such export x in resource y"), not the
    -- call, so it has to happen inside the pcall - hence the closure rather than pcall'ing the
    -- looked-up function directly.
    local ok, res = pcall(function(...) return exports[PHONE][name](exports[PHONE], ...) end, ...)
    if not ok then return false, nil end
    return true, res
end

-------------------------------------------------------------------- capability reads

---Whether sd-phone is running unique phones / SIM cards.
---
---This is the one mode a tablet cannot participate in. Under SIM mode the acting identity is
---resolved from the SIM sitting in the player's ACTIVE PHONE, so every server callback the tablet
---forwards would answer for whichever phone they last opened - or for nothing at all if they are
---not carrying one. A tablet has no SIM tray and no device identity of its own, so rather than
---opening a device that shows the wrong player's data (or an empty one), it refuses.
---
---sd-phone exposes isSimModeActive as a SERVER export only, and the flag settles several seconds
---into boot behind an inventory-support probe. sd-tablet's server therefore publishes it as
---global state; the pcall'd client export is checked first so a future sd-phone that adds one
---takes precedence.
---@return boolean
local function simModeActive()
    local ok, res = phoneExport('isSimModeActive')
    if ok and type(res) == 'boolean' then return res end
    return GlobalState.sdTabletSimMode == true
end

---Cosmetic signal bars for the status bar. sd-phone's live cell-service model owns the real
---number whenever masts are configured; with none, service is always full and the config value is
---the honest answer.
---@return integer bars 0..4
local function signalBars()
    local ok, towers = phoneExport('getCellTowers')
    if ok and type(towers) == 'table' and #towers > 0 then
        local gotBars, bars = phoneExport('getServiceBars')
        if gotBars and type(bars) == 'number' then return bars end
    end
    return cfg.StatusBar.SignalBars
end

---Whether this server runs Wi-Fi at all (as opposed to whether the player is on it). Empty
---network list means the system is switched off in sd-phone's configs/wifi.lua.
---@return boolean
local function wifiConfigured()
    local ok, networks = phoneExport('getWifiNetworks')
    return ok and type(networks) == 'table' and #networks > 0
end

---Whether this server runs Bluetooth at all. No sd-phone export answers this today, so the config
---mirror is the fallback; see configs/tablet.lua.
---@return boolean
local function bluetoothConfigured()
    local ok, res = phoneExport('isBluetoothConfigured')
    if ok and type(res) == 'boolean' then return res end
    return cfg.StatusBar.BluetoothConfigured ~= false
end

-------------------------------------------------------------------- hold pose

---@type integer Flags for the reading pose: loop, resist interruption, upper body only, secondary
---task. Upper-body plus secondary is what leaves the legs free to walk.
local POSE_FLAGS <const> = 1 | 8 | 16 | 32
---@type integer|nil Handle of the attached tablet prop, nil while stowed.
local prop = nil

---@type string Colour the tablet is currently held in; always a key of TABLET_COLORS.
local currentColor = cfg.DefaultColor or 'black'

---@type table<string, true> Colours any configured item can open, used to whitelist every colour
---that arrives from the server or off another player's statebag.
local TABLET_COLORS = {}
for _, entry in ipairs(cfg.Items or {}) do TABLET_COLORS[entry.color] = true end
if not TABLET_COLORS[currentColor] then TABLET_COLORS[currentColor] = true end

---Whether sd-phone framed the current shot with the NATIVE cell-cam rather than with its own
---scripted camera. The two are nothing alike from this side: the native pins the ped at engine
---level, plays a pose of its own and spawns its own phone prop, while the scripted one only takes
---the view and leaves the ped entirely alone. So this one question answers both "must keep-input
---go off" and "must our hold pose stand down".
---
---sd-phone reaches for the native ONLY when the surface may not keep the player moving (its
---client/phonecam.lua movementAllowed), which under stock config is never - so `cameraActive`
---alone would stand the pose down for a camera that replaced nothing, deleting the tablet out of
---the player's hands mid-shot. It exposes no export for which camera won, so this reads the
---mirrored movement keys configs/tablet.lua already documents as having to match sd-phone's.
---@return boolean
local function nativeCellCam()
    if not cameraActive then return false end
    return cfg.AllowMovement == false or cfg.AllowMovementInCamera == false
end

---Whether the pose applies right now. It stands down only for the native cell-cam, whose own pose
---and own phone prop ours would fight - the same deference, and the same condition, as sd-phone's
---pose module.
---@return boolean
local function shouldHold()
    if not cfg.HoldAnimation then return false end
    if nativeCellCam() then return false end
    return tabletState.open
end

---Creates a tablet prop, disables its collision, and rigidly welds it to a ped's hand bone. Local
---to this client: cross-player visibility spawns one of these per nearby holder, never a networked
---object, because a networked prop's ownership can migrate to a client whose sync then freezes it.
---@param ped integer ped to attach the prop to
---@param color string colour to weld; must be a key of TABLET_COLORS
---@return integer|nil prop the welded prop entity, or nil if the model wouldn't stream
local function createProp(ped, color)
    local model = joaat(cfg.PropPrefix .. color)
    RequestModel(model)
    local started = GetGameTimer()
    while not HasModelLoaded(model) and GetGameTimer() - started < 1000 do Wait(0) end
    if not HasModelLoaded(model) then return nil end
    local coords = GetEntityCoords(ped)
    local obj = CreateObject(model, coords.x, coords.y, coords.z, false, true, true)
    SetEntityCollision(obj, false, false)
    AttachEntityToEntity(obj, ped, GetPedBoneIndex(ped, cfg.PropBone),
        cfg.PropOffset.x, cfg.PropOffset.y, cfg.PropOffset.z,
        cfg.PropRot.x, cfg.PropRot.y, cfg.PropRot.z,
        false, false, false, false, 2, true)
    SetModelAsNoLongerNeeded(model)
    return obj
end

---Deletes our own attached prop, if any. Idempotent.
local function removeProp()
    if prop and DoesEntityExist(prop) then DeleteObject(prop) end
    prop = nil
end

---Broadcasts the hold state via the replicated `sdTablet` player statebag: the held colour while
---holding, false otherwise, so nearby clients weld a matching copy. No-op when cross-player
---visibility is off.
local function broadcastHoldState()
    if not cfg.PropVisibleToOthers then return end
    LocalPlayer.state:set('sdTablet', shouldHold() and currentColor or false, true)
end

---Plays the hold clip and welds the prop, on its own thread: the pose is cosmetic and must never
---gate the tablet opening.
local function playPose()
    CreateThread(function()
        RequestAnimDict(cfg.AnimDict)
        local started = GetGameTimer()
        while not HasAnimDictLoaded(cfg.AnimDict) and GetGameTimer() - started < 1000 do Wait(0) end
        -- The player may have closed the tablet, or the cell-cam taken the pose, during the load.
        if not shouldHold() then return end
        local ped = PlayerPedId()
        if not IsEntityPlayingAnim(ped, cfg.AnimDict, cfg.AnimName, 3) then
            TaskPlayAnim(ped, cfg.AnimDict, cfg.AnimName, 8.0, -8.0, -1, POSE_FLAGS, 0.0, false, false, false)
        end
        if not (prop and DoesEntityExist(prop)) then prop = createProp(ped, currentColor) end
    end)
end

---Stops our clip and removes the prop.
local function stopPose()
    local ped = PlayerPedId()
    if IsEntityPlayingAnim(ped, cfg.AnimDict, cfg.AnimName, 3) then
        StopAnimTask(ped, cfg.AnimDict, cfg.AnimName, 1.0)
    end
    removeProp()
end

---Starts or stops the pose to match the current state, then broadcasts the result.
local function updatePose()
    if shouldHold() then playPose() else stopPose() end
    broadcastHoldState()
end

-- Re-applies the held clip on a 500ms poll if the game clears it. Movement is what clears it: an
-- upper-body secondary task loses to sprints, jumps and vehicle transitions, and this device is
-- explicitly usable while walking.
CreateThread(function()
    while true do
        if shouldHold() and not IsEntityPlayingAnim(PlayerPedId(), cfg.AnimDict, cfg.AnimName, 3) then
            playPose()
        end
        Wait(500)
    end
end)

-- Keeps the tablet out of the player's own rear shot. sd-phone hides the holder for exactly this
-- reason and hides ITS prop on the next line (client/pose.lua), because hiding a ped does not hide
-- what is attached to it - and our prop is a separate entity, spawned by a separate resource, so
-- its hide never covers ours. Locally invisible lasts one frame, hence the per-frame re-assert.
CreateThread(function()
    while true do
        if cameraActive and cameraRearLens and prop and DoesEntityExist(prop) then
            SetEntityLocallyInvisible(prop)
            Wait(0)
        else
            Wait(200)
        end
    end
end)

-------------------------------------------------------------------- movement + focus

---Sets keep-input from the typing and camera flags. No-op unless the tablet is open with
---AllowMovement on.
local function syncKeepInput()
    if tabletState.open and cfg.AllowMovement then
        -- The native cell-cam pins the ped at engine level whatever keep-input says, so keeping it
        -- on there would only leak the movement keys into the game underneath a frozen player.
        SetNuiFocusKeepInput((not typingInTablet or typingNumeric) and not nativeCellCam())
    end
end

---@type boolean True while the movement-suppression thread is running.
local movementThreadRunning = false

---Runs one thread per open that suppresses combat, mouse-look, weapon-wheel and chat controls
---each frame, and closes the tablet when the pause menu activates. Mirrors sd-phone's, because
---the two devices share a UI and must not feel different to hold.
local function startMovementThread()
    if not cfg.AllowMovement or movementThreadRunning then return end
    movementThreadRunning = true
    CreateThread(function()
        while tabletState.open do
            if IsPauseMenuActive() then
                CloseTablet()
            elseif (not typingInTablet or typingNumeric) and not nativeCellCam() then
                DisablePlayerFiring(PlayerId(), true)
                -- The Camera app's Alt toggle hands the mouse to the game to aim the lens, so
                -- leave mouse-look alone while it has: suppressing it makes the lens immovable.
                if not lookMode and not cameraCursorFree then
                    DisableControlAction(0, 1, true)
                    DisableControlAction(0, 2, true)
                end
                DisableControlAction(0, 24, true)
                DisableControlAction(0, 25, true)
                DisableControlAction(0, 257, true)
                DisableControlAction(0, 263, true)
                DisableControlAction(0, 264, true)
                DisableControlAction(0, 140, true)
                DisableControlAction(0, 141, true)
                DisableControlAction(0, 142, true)
                DisableControlAction(0, 143, true)
                DisableControlAction(0, 37, true)
                DisableControlAction(0, 106, true)
                DisableControlAction(0, 245, true)
                DisableControlAction(0, 246, true)
                -- Scroll-wheel fall-throughs under keep-input: the UI owns the wheel, so vehicle
                -- radio cycling, the radio wheel and weapon cycling must not react.
                DisableControlAction(0, 14, true)
                DisableControlAction(0, 15, true)
                DisableControlAction(0, 16, true)
                DisableControlAction(0, 17, true)
                DisableControlAction(0, 81, true)
                DisableControlAction(0, 82, true)
                DisableControlAction(0, 83, true)
                DisableControlAction(0, 84, true)
                DisableControlAction(0, 85, true)
                DisableControlAction(0, 99, true)
                DisableControlAction(0, 100, true)
                if typingNumeric then
                    -- Digit pad up: the number row must not fire GTA weapon-slot binds.
                    for control = 157, 166 do
                        DisableControlAction(0, control, true)
                    end
                end
            end
            Wait(0)
        end
        movementThreadRunning = false
    end)
end

---Enters look mode: releases the NUI cursor so the mouse rotates the camera while the tablet
---stays on screen. This is how a walking player aims the lens in the forwarded Camera app -
---sd-phone's own look keybind only answers while the PHONE is open, so this device needs its own.
local function enterLookMode()
    if lookMode or not tabletState.open or not cfg.AllowMovement then return end
    if typingInTablet or nativeCellCam() then return end
    lookMode = true
    SetNuiFocus(false, false)
end

---Exits look mode: restores the NUI cursor and keep-input. No-op unless currently looking.
local function exitLookMode()
    if not lookMode then return end
    lookMode = false
    -- Never grab the cursor back while the Camera app has deliberately released it, or its own
    -- cursorOn flag desyncs and the viewfinder's key relays go dead.
    if tabletState.open and not cameraCursorFree then
        SetNuiFocus(true, true)
        syncKeepInput()
    end
end

-- sd-phone announces the cell-cam's state as plain client events, so the tablet hears them
-- without any wiring on the other side: the Camera app it drives is OUR screen's.
---@param on any truthy while the cell-cam view is live
AddEventHandler('sd-phone:client:cameraMode', function(on)
    if not tabletState.open then return end
    cameraActive = on and true or false
    if not cameraActive then
        cameraCursorFree = false
        cameraRearLens   = false
    end
    updatePose()
    syncKeepInput()
end)

---@param on any truthy while the NUI cursor is showing
AddEventHandler('sd-phone:client:cameraCursor', function(on)
    if not tabletState.open then return end
    cameraCursorFree = not (on and true or false)
    syncKeepInput()
end)

-------------------------------------------------------------------- open / close

---Builds the tablet's sd-phone:open payload. Same shape as sd-phone's OpenPhone, from the tablet's
---own config, with the phone app absent from both the dock and the catalog and the SIM block
---always disabled - a tablet has no tray, and SIM mode refuses to open one at all.
---@return table
local function openPayload()
    local apps, dock = visibleApps()
    return {
        locale              = config.Locale,
        locked              = tabletState.locked,
        battery             = tabletState.battery,
        carrier             = cfg.StatusBar.Carrier,
        signal              = signalBars(),
        showWifi            = cfg.StatusBar.ShowWifi,
        wifiConfigured      = wifiConfigured(),
        bluetoothConfigured = bluetoothConfigured(),
        use24h              = cfg.Lockscreen.Use24Hour,
        showDate            = cfg.Lockscreen.ShowDate,
        dock                = dock,
        apps                = apps,
        mailDomain          = cfg.Mail.Domain,
        number              = NUMBER_FORMAT,
        wallpaper           = {
            lock = config.Apps.Wallpaper,
            home = config.Apps.Wallpaper,
        },
        sim = { enabled = false },
    }
end

---Fetches the acting character's installed apps + home layout and pushes them into the open NUI.
---
---Routed through the seam rather than straight to sd-phone's server callback on purpose: sd-phone
---resolves WHOSE apps these are from the acting identity, and going through its own NUI handler
---means the tablet can never resolve that differently from the phone. This is the payload that
---makes the two devices the same device - an app installed on the phone is on the tablet the next
---time it opens, because there is only one installed list.
---
---The installed list is genuinely shared; the home LAYOUT is not, because a layout only means
---anything against the grid it was arranged on - 36 icons to a page here against the phone's 24.
---So one stored column holds an envelope, { devices = { phone = '...', tablet = '...' } }, written
---per device by sd-phone's server (server/apps/actions.lua) off the `device` the UI sends with
---each save, and unwrapped by the SHARED bundle, which knows its own id (web/src/apps/appstore/
---appsApi.ts, parseLayout). Neither end of that is ours to second-guess: the layout goes through
---this push exactly as the server stored it, envelope and all, and our copy of the bundle takes
---the tablet slice out of it. Slicing or namespacing anything here would break both devices.
local function pushInstalledApps()
    bridge.invoke('sd-phone:apps:list', {}, function(res)
        if not tabletState.open then return end
        local data = type(res) == 'table' and res.success and res.data or nil
        SendNUIMessage({
            action = 'sd-phone:apps',
            data   = {
                installedApps = (data and data.installed) or {},
                homeLayout    = data and data.layout or nil,
            },
        })
    end)
end

---Pulls one weather + world-time snapshot and pushes it in. sd-phone's 5s poll already covers a
---companion device, but waiting up to five seconds for the Weather app to paint on open is a
---visible stall, so the first snapshot is asked for directly.
local function pushWeather()
    bridge.invoke('sd-phone:weather:get', {}, function(res)
        if not tabletState.open or type(res) ~= 'table' then return end
        SendNUIMessage({ action = 'sd-phone:weather', data = res })
    end)
end

---Opens the tablet NUI, arms the mirror, and takes the screen from the phone if it had it.
---Refuses while dead, swimming, driving, disabled, or in SIM mode.
---@return boolean opened
local function OpenTablet()
    if tabletState.open then return false end

    if GetResourceState(PHONE) ~= 'started' then
        notify('The tablet can\'t connect right now.', 'error')
        return false
    end

    -- One switch disables both devices: a script that takes the player's phone away (a scene, a
    -- cell, a cutscene) means them to have no screen at all, not a spare one.
    local gotDisabled, disabled = phoneExport('isDisabled')
    if gotDisabled and disabled == true then
        notify('You can\'t use your tablet right now.', 'error')
        return false
    end

    if simModeActive() then
        notify('This server uses SIM cards - a tablet has no SIM. Use your phone.', 'error')
        return false
    end

    local ped = PlayerPedId()
    if cfg.BlockWhileDead and IsEntityDead(ped) then
        notify('You can\'t use your tablet right now.', 'error')
        return false
    end
    if cfg.BlockWhileSwimming and IsPedSwimming(ped) then
        notify('You can\'t use your tablet while swimming.', 'error')
        return false
    end
    if cfg.BlockWhileDriving and IsPedInAnyVehicle(ped, false)
        and GetPedInVehicleSeat(GetVehiclePedIsIn(ped, false), -1) == ped then
        notify('Not while you\'re driving.', 'error')
        return false
    end

    -- One device at a time: the phone gives up the screen here, so focus, the cell-cam and
    -- pma-voice only ever have one owner. sd-phone does the mirror image of this in OpenPhone.
    exports[PHONE]:close()

    tabletState.open   = true
    tabletState.locked = cfg.StartLocked ~= false

    mirror.arm(true)
    mirror.setCompanionOpen(true)

    CreateThread(function()
        while tabletState.open do
            DisableControlAction(0, 199, true) -- INPUT_FRONTEND_PAUSE
            DisableControlAction(0, 200, true) -- INPUT_FRONTEND_PAUSE_ALTERNATE
            Wait(0)
        end
        for _ = 1, 15 do
            DisableControlAction(0, 199, true)
            DisableControlAction(0, 200, true)
            Wait(0)
        end
    end)

    updatePose()

    SetNuiFocus(true, true)
    if cfg.AllowMovement then
        typingInTablet = false
        typingNumeric  = false
        SetNuiFocusKeepInput(true)
        startMovementThread()
    end

    SendNUIMessage({ action = 'sd-phone:open', data = openPayload() })
    SendNUIMessage({ action = 'sd-phone:session', data = { startMs = SESSION_START_MS } })

    -- "A device of ours is on screen." sd-phone's own modules key several live feeds off this
    -- event, and every one of them is about the player rather than the handset: the cell-service
    -- and Wi-Fi scans only tick while a device is up, Health only pushes vitals while one is up,
    -- and - decisively - the Camera app restores NUI focus on exit ONLY if it believes a device is
    -- watching. Without this, leaving the viewfinder on the tablet strands the player with no
    -- cursor. The event is local, so announcing it is the supported way to say so.
    TriggerEvent('sd-phone:client:openState', true)

    -- AirShare presence: players appear in each other's share sheets while a device is out.
    TriggerServerEvent('sd-phone:server:phone:setOpen', true)

    -- Both need a round-trip, and the tablet is already on screen behind the lockscreen, so they
    -- land as follow-ups rather than gating the reveal.
    pushWeather()
    pushInstalledApps()

    debugPrint('tablet opened')
    return true
end

---Closes the tablet NUI, disarms the mirror, releases focus and drops the pose. Idempotent.
function CloseTablet()
    if not tabletState.open then return end

    tabletState.open = false
    typingInTablet   = false
    typingNumeric    = false
    lookMode         = false
    cameraActive     = false
    cameraRearLens   = false
    cameraCursorFree = false

    -- Stand the seam down first. Leaving either flag set makes sd-phone keep firing a client
    -- event for every push it makes, keep pumping its weather poll, and keep handing us focus
    -- calls meant for a screen that is no longer there.
    mirror.setCompanionOpen(false)
    mirror.arm(false)

    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'sd-phone:close' })

    TriggerEvent('sd-phone:client:openState', false)
    TriggerServerEvent('sd-phone:server:phone:setOpen', false)

    updatePose()

    debugPrint('tablet closed')
end

-- sd-phone opening its own phone tells every companion to stand down (client/main.lua fires this
-- at the top of OpenPhone, before it takes focus). This is the other half of the exclusion the
-- open path above starts.
AddEventHandler('sd-phone:client:companion:close', function()
    CloseTablet()
end)

---The admin panel is a second surface inside sd-phone's OWN frame, and it opens by taking NUI
---focus for itself (its client/admin.lua) before pushing itself in. Neither half survives a
---companion holding the screen: the focus call is re-routed to us by the seam, and the push is
---dropped here because this device's build has no panel to receive it - so the panel would render
---in a frame nobody is looking at while the cursor sat on ours, and nothing would be clickable
---until the tablet was closed. So give the screen up for it exactly as we do for the phone.
---
---Both cross-resource orderings land correctly, because CloseTablet clears the companion flag
---BEFORE it announces sd-phone:client:openState(false):
---  * sd-phone first - it takes focus (routed to a tablet that is about to close) and pushes the
---    panel (dropped at our mirror); our close then fires openState(false), and sd-phone's admin
---    handler re-asserts focus on that event with the seam already down, so it lands on its frame.
---  * us first - the seam is down before sd-phone's handler runs, so its focus call is never
---    routed anywhere and lands on its own frame directly.
---Either way the panel and the cursor end up in the same frame.
RegisterNetEvent('sd-phone:client:admin:open', function()
    CloseTablet()
end)

-- Teardown of the SHARED profile. Both of these are pushed by sd-phone into its own frame, and
-- both fire at moments when neither device need be on screen - which is exactly when the mirror is
-- disarmed, so neither would ever reach us. Our NUI is loaded from resource start and keeps
-- running hidden, so a missed teardown leaves it to reopen on the previous profile's cached data.
-- Registering the two net events ourselves is the only delivery that does not depend on being
-- visible; the matching pushes are dropped at the mirror (client/policy.lua), which is what stops
-- an OPEN tablet handling each of them twice.

---A cloud-backup restore replaced the acting profile's data in place: the NUI drops every cached
---trace (kept-alive apps, hydrated settings, data stores) and rehydrates. The installed-apps
---follow-up re-runs with it, since a restore changes both the installed list and the home layout.
RegisterNetEvent('sd-phone:client:profileReset', function()
    SendNUIMessage({ action = 'sd-phone:profileReset' })
    if tabletState.open then pushInstalledApps() end
end)

---An admin wipe tells the React app to clear its local storage and RELOAD, which tears our UI down
---to an empty page. A device left flagged open behind an empty page holds focus with nothing on
---screen to release it and refuses to reopen, so it stands down first - and the focus drop trails
---the push for the same reason sd-phone's does: the reloaded frame must not inherit one.
RegisterNetEvent('sd-phone:client:wipe', function()
    CloseTablet()
    SendNUIMessage({ action = 'sd-phone:wipe' })
    SetNuiFocus(false, false)
end)

-------------------------------------------------------------------- entry points

---Keybind toggle: closes when open, otherwise asks the server whether this player may open one.
---Ownership is server-authoritative for the same reason sd-phone's is - the item check is the
---only thing standing between a keybind and a free tablet.
local function ToggleTablet()
    if tabletState.open then CloseTablet() return end

    -- The last-used colour rides along as a hint so the keybind keeps handing back the same
    -- tablet; the server only honours it while that item is still owned.
    local res = lib.callback.await('sd-tablet:server:resolveOpen', false, currentColor)
    if type(res) ~= 'table' or res.ok ~= true then
        notify((type(res) == 'table' and res.message) or 'You don\'t have a tablet.', 'error')
        return
    end
    if res.color and TABLET_COLORS[res.color] then currentColor = res.color end
    OpenTablet()
end

-- Keybind wiring; the `-` command is the no-op release half of the +command mapping.
RegisterCommand('+sdtablet_toggle', ToggleTablet, false)
RegisterCommand('-sdtablet_toggle', function() end, false)
RegisterKeyMapping('+sdtablet_toggle', 'Toggle Tablet', 'keyboard', cfg.Keybind)

-- Hold-to-look: the +command frees the mouse for camera rotation, the -command restores the cursor.
RegisterCommand('+sdtablet_look', enterLookMode, false)
RegisterCommand('-sdtablet_look', exitLookMode, false)
RegisterKeyMapping('+sdtablet_look', 'Tablet: Hold to look around', 'keyboard', cfg.LookKeybind)

---Opens the tablet after a tablet item is used, in that item's colour. The server has already
---resolved ownership by definition - it is the item's own use callback that fired this. The colour
---is whitelist-checked because it arrives over the network.
---@param color string|nil colour of the item that was used
RegisterNetEvent('sd-tablet:client:openFromItem', function(color)
    if color and TABLET_COLORS[color] then currentColor = color end
    OpenTablet()
end)

-------------------------------------------------------------------- device-local NUI handlers

-- Every one of these is an action the shared UI performs on the DEVICE it is running on. Each has
-- a counterpart in sd-phone/client/main.lua that does the same job for the phone; forwarding any
-- of them would run the phone's version against a frame nobody is looking at. client/policy.lua
-- lists them and client/rpc.lua refuses to bind unless all of them exist.
---@type table<string, fun(payload: any, cb: fun(result: any))>
local LOCAL_HANDLERS = {
    ---React to Lua: the NUI requests the device be closed (swipe down / back gesture).
    ['sd-phone:close'] = function(_, cb)
        CloseTablet()
        cb({ ok = true })
    end,

    ---React to Lua: unlock gesture finished. Clears the locked flag; it re-arms on the next open.
    ['sd-phone:unlock'] = function(_, cb)
        tabletState.locked = false
        cb({ ok = true })
    end,

    ---React to Lua: the closed-shell peek was tapped; put the device back on screen.
    ['sd-phone:requestOpen'] = function(_, cb)
        OpenTablet()
        cb({ ok = true })
    end,

    ---React to Lua: a text field gained or lost focus. Full typing releases keep-input so keys
    ---reach only the field; numeric typing (PIN pads) keeps it so the player can still move, with
    ---the digit weapon binds suppressed by the movement thread instead.
    ---@param data table|nil { typing: boolean, numeric: boolean }
    ['sd-phone:typing'] = function(data, cb)
        typingInTablet = data and data.typing and true or false
        typingNumeric  = typingInTablet and data and data.numeric and true or false
        syncKeepInput()
        cb({ ok = true })
    end,

    ---React to Lua: an app icon was tapped; prints a debug breadcrumb, exactly as the phone does.
    ---@param data table|nil { id: string }
    ['sd-phone:openApp'] = function(data, cb)
        debugPrint('openApp:', data and data.id or '?')
        cb({ ok = true })
    end,

    ---React to Lua: lockscreen torch button. A tablet has no torch, so the beam is always off -
    ---answered rather than denied, because the lockscreen asks unprompted and a refusal would
    ---surface as an error toast for a button the player never pressed.
    ['sd-phone:flashlight:toggle'] = function(_, cb)
        cb({ on = false })
    end,

    ---React to Lua: current beam state. Always off, for the same reason.
    ['sd-phone:flashlight:state'] = function(_, cb)
        cb({ on = false })
    end,
}

rpc.bind(LOCAL_HANDLERS)
if config.Debug then
    rpc.setTrace(function(kind, action) debugPrint(kind, action) end)
end

-- Which lens the forwarded Camera app is framing with. sd-phone announces the viewfinder opening
-- and closing as client events, but the FLIP only ever travels page -> Lua as this callback, so
-- watching it on its way through is the one place this side can learn the lens. The app always
-- enters on the rear one (its enterCameraView resets frontCam), and both ways to flip - the
-- on-screen button and the Up-arrow that sd-phone relays into the page - end here, so there is no
-- second path to miss.
rpc.watch('sd-phone:camera:open',  function() cameraRearLens = true  end)
rpc.watch('sd-phone:camera:close', function() cameraRearLens = false end)
rpc.watch('sd-phone:camera:selfie', function(payload)
    cameraRearLens = not (type(payload) == 'table' and payload.on)
end)

mirror.bind({
    isOpen = function() return tabletState.open end,
    close  = function() CloseTablet() end,
})

-------------------------------------------------------------------- background

-- Cosmetic battery drain: one percent every 30s while the tablet is open, pushed to the React app.
-- The tablet's own charge, which is why the phone's battery push is dropped at the mirror.
CreateThread(function()
    while true do
        Wait(30000)
        if tabletState.open and tabletState.battery > 0 then
            tabletState.battery = tabletState.battery - 1
            SendNUIMessage({ action = 'sd-phone:battery', data = tabletState.battery })
        end
    end
end)

---@type table<integer, { obj: integer, color: string }> Server id -> local tablet-prop copy welded
---onto that remote holder's ped, with the colour it was welded in.
local remoteProps = {}

---Deletes a remote holder's welded prop copy, if any. Idempotent.
---@param source integer server id of the remote holder
local function removeRemoteProp(source)
    local entry = remoteProps[source]
    if entry and DoesEntityExist(entry.obj) then DeleteObject(entry.obj) end
    remoteProps[source] = nil
end

-- Cross-player prop visibility: the holder broadcasts the replicated `sdTablet` player statebag
-- and every client welds its own local prop copy onto the holder's ped.
if cfg.PropVisibleToOthers then
    ---Resolves a `player:<serverId>` bag to (serverId, ped); ped is 0 when that player isn't in
    ---scope on this client.
    ---@param bagName string
    ---@return integer? source, integer ped
    local function bagOwner(bagName)
        local source = tonumber(bagName:match('player:(%d+)'))
        if not source then return nil, 0 end
        local plyr = GetPlayerFromServerId(source)
        if plyr == -1 then return source, 0 end
        return source, GetPlayerPed(plyr)
    end

    AddStateBagChangeHandler('sdTablet', nil, function(bagName, _key, value)
        local source, ped = bagOwner(bagName)
        if not source or source == GetPlayerServerId(PlayerId()) then return end
        if not value or ped == 0 then
            removeRemoteProp(source)
            return
        end
        -- The bag carries the holder's colour, so an unknown one is dropped rather than welded.
        if not TABLET_COLORS[value] then return end
        local entry = remoteProps[source]
        if entry and entry.color == value and DoesEntityExist(entry.obj) then return end
        removeRemoteProp(source)
        local obj = createProp(ped, value)
        if obj then remoteProps[source] = { obj = obj, color = value } end
    end)

    -- 1s sweep: removes copies whose owner left scope or whose prop no longer exists.
    CreateThread(function()
        while true do
            Wait(1000)
            for source, entry in pairs(remoteProps) do
                local plyr = GetPlayerFromServerId(source)
                local ped = plyr ~= -1 and GetPlayerPed(plyr) or 0
                if ped == 0 or not DoesEntityExist(ped) or not DoesEntityExist(entry.obj) then
                    removeRemoteProp(source)
                end
            end
        end
    end)
end

---Re-stamps the session anchor and tells the NUI the character resolved, mirroring sd-phone's own
---handling: settings only resolve once the citizenid exists, so the UI re-pulls its per-player
---state the moment the framework reports the player in. Both devices stamp from the same events,
---which is why the Health app's "time awake" agrees across them.
---Pushed even while the tablet is closed, for the same reason sd-phone pushes it while the phone
---is: the NUI is loaded from resource start and keeps running hidden, so a skipped signal leaves
---it to reopen on the previous character's settings.
local function pushCharacterLoaded()
    SESSION_START_MS = GetCloudTimeAsInt() * 1000
    SendNUIMessage({ action = 'sd-phone:client:characterLoaded' })
    SendNUIMessage({ action = 'sd-phone:session', data = { startMs = SESSION_START_MS } })
end
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', pushCharacterLoaded)
RegisterNetEvent('esx:playerLoaded', pushCharacterLoaded)

---sd-phone's server fires this when settings appear after the UI has already hydrated (its
---lb-phone import writes phone_settings partway through boot). The tablet's copy of that UI needs
---the same nudge; net events reach every resource that registered them.
RegisterNetEvent('sd-phone:client:rehydrate', pushCharacterLoaded)

---Resource restart with the character already in: the framework load events above won't re-fire,
---but the freshly reloaded NUI still needs the character signal.
AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    SetTimeout(5000, pushCharacterLoaded)
end)

-------------------------------------------------------------------- exports

---exports['sd-tablet']:isOpen()
---@return boolean
exports('isOpen', function() return tabletState.open end)

---exports['sd-tablet']:isLocked()
---@return boolean
exports('isLocked', function() return tabletState.locked end)

---exports['sd-tablet']:open() - no ownership check; the caller is another script that has already
---decided this player may have a tablet on screen.
---@return boolean opened
exports('open', OpenTablet)

---exports['sd-tablet']:close()
exports('close', function() CloseTablet() end)

---Launches an app on the tablet - exports['sd-tablet']:openApp(appId, link). The tablet's own
---counterpart to exports['sd-phone']:openApp, which targets the phone (and opens it, which closes
---this device). Returns false on a refused open or malformed arguments.
---@param appId string app id as the home screen knows it (e.g. 'messages')
---@param link table|nil optional deep-link payload
---@return boolean accepted
exports('openApp', function(appId, link)
    if type(appId) ~= 'string' or appId == '' then return false end
    if link ~= nil and type(link) ~= 'table' then return false end
    if not tabletState.open then
        OpenTablet()
        if not tabletState.open then return false end
    end
    SendNUIMessage({ action = 'sd-phone:launchApp', data = { id = appId, link = link } })
    return true
end)

-------------------------------------------------------------------- cleanup

---Resource-stop cleanup: releases NUI focus, deletes props, clears the statebag, stops the clip,
---and stands the seam down so a restarting tablet doesn't leave sd-phone mirroring into nothing.
---@param resource string name of the resource that stopped
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if tabletState.open then
        SetNuiFocus(false, false)
        mirror.setCompanionOpen(false)
        mirror.arm(false)
        TriggerEvent('sd-phone:client:openState', false)
    end
    stopPose()
    if cfg.PropVisibleToOthers then LocalPlayer.state:set('sdTablet', false, true) end
    for source in pairs(remoteProps) do removeRemoteProp(source) end
end)
