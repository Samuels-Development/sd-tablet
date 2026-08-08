-- sd-tablet client shell: this device's NUI frame, focus, open/close lifecycle, hand prop, hold
-- clip and the device-local callbacks that must never be forwarded. Every app, server round-trip
-- and live push belongs to sd-phone and is borrowed across the companion seam - there is one copy
-- of the data and both devices read it. Voice calls are refused on sd-phone's side of the seam.

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

-- Every string this resource puts in front of a player comes from locales/<lang>.json. The React
-- app has its own catalog keyed off config.Locale; this is only the Lua half - refusals, the
-- notify title, and the two keybind labels FiveM shows in its binding menu.
lib.locale()

-- Apps disabled in configs/apps.lua never reach the NUI; built once, the catalog is static per boot.
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

-- What this PLAYER may see also depends on their job, which only sd-phone's server knows; asked on
-- every open so a multijob switch needs no event. Called directly rather than through the seam,
-- because it decides what goes INTO the open payload - an older sd-phone leaves the catalog alone.
--
-- `false`, not a number: ox_lib's second argument is a call-suppression window, not a timeout, so
-- a number would make a second open inside it answer nil and take the older-sd-phone branch - which
-- fails OPEN, handing a civilian every terminal icon. sd-phone's own visibleApps passes false too.
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

-- Format keys are stringified so the table can never encode as a JSON array, which would land in
-- the UI off-by-one. Same treatment as sd-phone's.
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

---@type integer Session-start ms; the Health app's "time awake" anchor, stamped from the same
---events sd-phone uses so the two devices agree without asking each other.
local SESSION_START_MS = GetCloudTimeAsInt() * 1000

---@type boolean True while a UI text field is focused.
local typingInTablet = false
---@type boolean True while the focused field is digit-only; keep-input stays on and the digit
---weapon binds are suppressed instead, so the player can still move.
local typingNumeric = false
---@type boolean True while the hold-to-look keybind has released the cursor for camera control.
local lookMode = false
---@type boolean True while a forwarded sd-phone camera surface owns the view on our behalf.
local cameraActive = false
---@type boolean True while that surface frames with the REAR lens, i.e. the player and anything in
---their hands must stay out of the shot. Tracked from the rpc.watch wiring further down.
local cameraRearLens = false
---@type boolean True while the Camera app has handed the mouse to the game to aim the lens.
local cameraCursorFree = false

---@type fun() Tablet close; assigned further down, referenced by threads defined before it.
local CloseTablet

---Debug breadcrumb. Two ways to turn it on, because they answer different questions:
---config.Debug is the resource's own switch and prints at info so it shows with no setup, while
---`setr ox:printlevel:sd-tablet debug` turns the same output on live, without editing a config.
---@param ... any values to print
local function debugPrint(...)
    if config.Debug then return lib.print.info(...) end
    lib.print.debug(...)
end

---Shows an on-screen toast; ox_lib is a hard dependency, so it is always the backend here.
---@param description string
---@param kind string|nil 'error' | 'inform' | 'success'
local function notify(description, kind)
    lib.notify({
        -- UUIDv7, not a random int: ox_lib treats the id as a dedupe key, so a collision replaces
        -- a toast the player is still reading.
        id          = lib.uuid.generate(),
        title       = locale('tablet'),
        description = description,
        type        = kind or 'inform',
        position    = 'top-right',
        duration    = 3000,
    })
end

---Calls an sd-phone client export, tolerating one that does not exist - a missing export raises
---rather than returning nil, so a newer sd-phone is picked up and an older one falls back to config.
---@param name string export name
---@param ... any arguments
---@return boolean ok, any value
local function callPhoneExport(name, ...)
    return exports[PHONE][name](exports[PHONE], ...)
end

local function phoneExport(name, ...)
    if GetResourceState(PHONE) ~= 'started' then return false, nil end
    local ok, res = pcall(callPhoneExport, name, ...)
    if not ok then return false, nil end
    return true, res
end

-------------------------------------------------------------------- capability reads

---Whether sd-phone is running unique phones / SIM cards. Not a refusal - it rides in the open
---payload so the shared UI can tell "no SIM in the phone you carry" apart from "this server has no
---SIMs". Read from our server's global state, preferring a client export if a future sd-phone adds one.
---@return boolean
local function simModeActive()
    local ok, res = phoneExport('isSimModeActive')
    if ok and type(res) == 'boolean' then return res end
    return GlobalState.sdTabletSimMode == true
end

---@type boolean|nil Whether sd-phone has cell masts configured; nil until answered.
local towersConfigured = nil
---@type boolean|nil Whether sd-phone has Wi-Fi networks configured; nil until answered.
local wifiSystemOn = nil
---@type boolean|nil Whether sd-phone reports Bluetooth configured; nil until answered.
local bluetoothSystemOn = nil

---Cosmetic signal bars; sd-phone's live model owns the real number whenever masts are configured.
---@return integer bars 0..4
local function signalBars()
    if towersConfigured == nil then
        local ok, towers = phoneExport('getCellTowers')
        if ok then towersConfigured = type(towers) == 'table' and #towers > 0 end
    end
    if towersConfigured then
        -- Not cached: this one is the LIVE reading, and it moves with the player.
        local gotBars, bars = phoneExport('getServiceBars')
        if gotBars and type(bars) == 'number' then return bars end
    end
    return cfg.StatusBar.SignalBars
end

---Whether this server runs Wi-Fi at all; an empty network list means it is off in sd-phone's config.
---@return boolean
local function wifiConfigured()
    if wifiSystemOn == nil then
        local ok, networks = phoneExport('getWifiNetworks')
        if ok then wifiSystemOn = type(networks) == 'table' and #networks > 0 end
    end
    return wifiSystemOn == true
end

---Whether this server runs Bluetooth at all; no sd-phone export answers it yet, so config is used.
---@return boolean
local function bluetoothConfigured()
    if bluetoothSystemOn == nil then
        local ok, res = phoneExport('isBluetoothConfigured')
        if ok and type(res) == 'boolean' then bluetoothSystemOn = res end
    end
    if bluetoothSystemOn ~= nil then return bluetoothSystemOn end
    return cfg.StatusBar.BluetoothConfigured ~= false
end

-------------------------------------------------------------------- hold pose

---@type integer Reading pose: LOOPING | NOT_INTERRUPTABLE | UPPERBODY | SECONDARY - the last two
---are what leave the legs free to walk.
local POSE_FLAGS <const> = 1 | 8 | 16 | 32
---@type integer|nil Handle of the attached tablet prop, nil while stowed.
local prop = nil

---@type string Colour the tablet is currently held in; always a key of TABLET_COLORS.
local currentColor = cfg.DefaultColor or 'black'

---@type table<string, true> Whitelist for every colour arriving from the server or a statebag.
local TABLET_COLORS = {}
for _, entry in ipairs(cfg.Items or {}) do TABLET_COLORS[entry.color] = true end
if not TABLET_COLORS[currentColor] then TABLET_COLORS[currentColor] = true end

---Whether sd-phone framed the shot with the NATIVE cell-cam, which pins the ped and spawns its own
---prop, rather than its scripted camera, which leaves the ped alone. Answers both "must keep-input
---go off" and "must our pose stand down". sd-phone only reaches for the native when the surface may
---not keep the player moving, and exposes no export for it - hence the mirrored movement keys.
---@return boolean
local function nativeCellCam()
    if not cameraActive then return false end
    return cfg.AllowMovement == false or cfg.AllowMovementInCamera == false
end

---Whether the pose applies; it stands down only for the native cell-cam, whose own pose ours fights.
---@return boolean
local function shouldHold()
    if not cfg.HoldAnimation then return false end
    if nativeCellCam() then return false end
    return tabletState.open
end

---@type table<integer, true> Models known not to be available on this client.
local unavailableModels = {}

---Welds a collision-free tablet prop to a ped's hand bone. Always LOCAL: a networked prop's
---ownership can migrate to a client whose sync then freezes it mid-hold.
---@param ped integer ped to attach the prop to
---@param color string colour to weld; must be a key of TABLET_COLORS
---@return integer|nil prop the welded prop entity, or nil if the model wouldn't stream
local function createProp(ped, color)
    local model = joaat(cfg.PropPrefix .. color)
    if unavailableModels[model] then return nil end

    -- Answers the props-resource-not-started case outright, with no request and no waiting.
    if not IsModelInCdimage(model) then
        unavailableModels[model] = true
        return nil
    end

    -- lib.requestModel errors rather than returning on timeout, hence the pcall. Releasing on the
    -- failure path matters: this branch can run repeatedly and would leak a streaming reference.
    if not pcall(lib.requestModel, model, 1000) then
        SetModelAsNoLongerNeeded(model)
        unavailableModels[model] = true
        return nil
    end

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

---@type string|false|nil Last hold state handed to the server; nil until the first broadcast.
local lastHoldSent = nil

local function broadcastHoldState()
    if not cfg.PropVisibleToOthers then return end
    local desired = shouldHold() and currentColor or false
    if desired == lastHoldSent then return end
    lastHoldSent = desired
    TriggerServerEvent('sd-tablet:server:setHolding', desired)
end

---@type boolean True while a playPose thread is between requesting the model and taking the handle.
local propPending = false

---Plays the hold clip and welds the prop on its own thread; the pose must never gate the open.
local function playPose()
    CreateThread(function()
        local ped = cache.ped
        if not IsEntityPlayingAnim(ped, cfg.AnimDict, cfg.AnimName, 3) then
            -- lib.playAnim loads AND releases the dict; it errors when the clip never streams.
            if not pcall(lib.playAnim, ped, cfg.AnimDict, cfg.AnimName, 8.0, -8.0, -1, POSE_FLAGS) then
                return
            end
        end
        -- That load yields, so the player may have closed the tablet or the cell-cam taken over.
        if not shouldHold() then
            StopAnimTask(ped, cfg.AnimDict, cfg.AnimName, 1.0)
            return
        end
        if prop and DoesEntityExist(prop) then return end
        if propPending then return end
        propPending = true
        -- Re-read rather than reuse `ped`: cache.ped is current across the yield above.
        local obj = createProp(cache.ped, currentColor)
        propPending = false
        if not obj then return end
        if not shouldHold() or (prop and DoesEntityExist(prop)) then
            DeleteObject(obj)
            return
        end
        prop = obj
    end)
end

---Stops our clip and removes the prop.
local function stopPose()
    local ped = cache.ped
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

-- A respawn or a ped-model change hands the player a NEW ped, and our prop is still welded to the
-- old one - which the game does not necessarily delete, so it can be left hanging in the world.
-- The clip re-applies itself on the tick below, but the orphaned prop never would. ox_lib already
-- tracks the ped for `cache.ped`, so this subscribes to that change rather than adding a poll.
lib.onCache('ped', function()
    removeProp()
    if tabletState.open then updatePose() end
end)

-- Re-applies the held clip if the game clears it: an upper-body secondary task loses to sprints,
-- jumps and vehicle transitions, and this device is explicitly usable while walking. Backs off to
-- a 1s tick while stowed, since the thread lives for the whole session either way.
CreateThread(function()
    while true do
        if not tabletState.open then
            Wait(1000)
        else
            if shouldHold() and not IsEntityPlayingAnim(cache.ped, cfg.AnimDict, cfg.AnimName, 3) then
                playPose()
            end
            Wait(500)
        end
    end
end)

-- Keeps the tablet out of the player's own rear shot. Hiding a ped does not hide what is attached
-- to it, and our prop is a separate resource's entity, so sd-phone's own hide never covers it.
-- SetEntityLocallyInvisible lasts one frame, hence the per-frame re-assert.
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
        -- The native cell-cam pins the ped anyway, so keep-input there only leaks movement keys.
        SetNuiFocusKeepInput((not typingInTablet or typingNumeric) and not nativeCellCam())
    end
end

---@type boolean True while the per-frame input thread is running.
local inputThreadRunning = false

-- The four control sets this device suppresses, as data. They are handed to ox_lib's
-- lib.disableControls, which keeps ONE refcounted set and re-asserts all of it in a single call
-- per frame - so the thread below toggles a group when the state changes rather than issuing the
-- same two dozen DisableControlAction calls every frame regardless.

---@type integer[] INPUT_FRONTEND_PAUSE and its alternate; held whenever the tablet is on screen.
local CONTROLS_PAUSE <const> = { 199, 200 }

---@type integer[] Combat, melee, weapon-wheel, cover, chat - and the scroll-wheel fall-throughs
---under keep-input, because the UI owns the wheel.
local CONTROLS_MOVEMENT <const> = {
    24, 25, 37, 106, 245, 246, 257, 263, 264, 140, 141, 142, 143,
    14, 15, 16, 17, 81, 82, 83, 84, 85, 99, 100,
}

---@type integer[] Mouse-look. Dropped while the Camera app aims the lens, or it would be immovable.
local CONTROLS_LOOK <const> = { 1, 2 }

---@type integer[] The number row, which GTA binds to weapon slots while a digit field is focused.
local CONTROLS_DIGITS <const> = { 157, 158, 159, 160, 161, 162, 163, 164, 165, 166 }

---@type table<table, true> Groups currently added to lib.disableControls.
local appliedControls = {}

---Adds or removes a group exactly once per state change; Add/Remove are refcounted, so an
---unbalanced pair would leave a control disabled for the rest of the session.
---@param group integer[]
---@param wanted boolean
local function setControlGroup(group, wanted)
    if wanted == (appliedControls[group] or false) then return end
    appliedControls[group] = wanted or nil
    if wanted then
        lib.disableControls:Add(group)
    else
        lib.disableControls:Remove(group)
    end
end

---Runs ONE per-frame thread per open: holds the pause control down unconditionally, and with
---AllowMovement on also suppresses combat, mouse-look, weapon-wheel and chat as sd-phone does.
local function startInputThread()
    if inputThreadRunning then return end
    inputThreadRunning = true
    CreateThread(function()
        -- Outer loop so a reopen DURING the trailing hold below rejoins instead of dying with the
        -- flag about to clear, which would leave an open tablet suppressing nothing.
        while true do
            while tabletState.open do
                setControlGroup(CONTROLS_PAUSE, true)

                ---@type boolean Whether the movement suppression applies this frame.
                local suppress = false
                if cfg.AllowMovement then
                    if IsPauseMenuActive() then
                        CloseTablet()
                    else
                        suppress = (not typingInTablet or typingNumeric) and not nativeCellCam()
                    end
                end

                setControlGroup(CONTROLS_MOVEMENT, suppress)
                -- The Camera app's Alt toggle aims the lens with the mouse; suppressing mouse-look
                -- while it has would make the lens immovable.
                setControlGroup(CONTROLS_LOOK, suppress and not lookMode and not cameraCursorFree)
                setControlGroup(CONTROLS_DIGITS, suppress and typingNumeric)

                -- Not a control, so it stays a native and stays inside the frame loop.
                if suppress then DisablePlayerFiring(cache.playerId, true) end

                lib.disableControls()
                Wait(0)
            end

            -- Held a few frames past the close, or the closing keypress opens the escape menu.
            -- Pause is re-asserted rather than assumed: the loop above always adds it in practice,
            -- but the hold is the one suppression that must not depend on how we got here.
            setControlGroup(CONTROLS_PAUSE, true)
            setControlGroup(CONTROLS_MOVEMENT, false)
            setControlGroup(CONTROLS_LOOK, false)
            setControlGroup(CONTROLS_DIGITS, false)

            local held = 0
            while held < 15 and not tabletState.open do
                lib.disableControls()
                held = held + 1
                Wait(0)
            end
            if not tabletState.open then break end
        end
        setControlGroup(CONTROLS_PAUSE, false)
        -- No yield since the break, so an open cannot be refused by a flag about to clear.
        inputThreadRunning = false
    end)
end

---Releases the NUI cursor so the mouse rotates the camera with the tablet still on screen;
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
    -- Never grab the cursor back while the Camera app has released it, or its cursorOn desyncs.
    if tabletState.open and not cameraCursorFree then
        SetNuiFocus(true, true)
        syncKeepInput()
    end
end

-- sd-phone announces cell-cam state as plain client events, so we hear them with no wiring there.
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

---Builds the sd-phone:open payload: OpenPhone's shape from the tablet's own config, with the phone
---app absent from the dock and catalog.
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
        -- The honest answer, not a flat false: the shared UI needs it to know whether "no SIM"
        -- means No Service or simply that this server does not use SIMs at all.
        sim = { enabled = simModeActive() },
    }
end

---Fetches the acting character's installed apps + home layout and pushes them into the open NUI.
---Routed through the seam so the tablet can never resolve WHOSE apps these are differently from
---the phone. The installed list is genuinely shared; the home LAYOUT is not (36 icons to a page
---here against the phone's 24), so it travels as a per-device envelope that the SHARED bundle
---unwraps by its own id. The layout is pushed exactly as stored - slicing it here breaks both.
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

---Pulls one weather snapshot directly; sd-phone's 5s poll covers us after, but waiting that long
---for the Weather app to paint on open is a visible stall.
local function pushWeather()
    bridge.invoke('sd-phone:weather:get', {}, function(res)
        if not tabletState.open or type(res) ~= 'table' then return end
        SendNUIMessage({ action = 'sd-phone:weather', data = res })
    end)
end

---Whether the tablet may go on screen. Every condition is re-readable: the open path checks them
---again after the payload round-trip, which is long enough to die, dive in or take a wheel.
---@return boolean ok
---@return string|nil message reason to show when refused
local function canOpen()
    if tabletState.open then return false end

    if GetResourceState(PHONE) ~= 'started' then
        return false, locale('cannot_connect')
    end

    -- One switch disables both devices: a script taking the phone away means no screen, not a spare.
    local gotDisabled, disabled = phoneExport('isDisabled')
    if gotDisabled and disabled == true then
        return false, locale('cannot_use')
    end

    -- No SIM check: the tablet borrows the identity of the SIM in the phone you carry, exactly as
    -- it borrows everything else, so a request already answers as the right number. With no SIM
    -- the shared UI shows its own No Service screen, the same as the phone does.
    if cfg.BlockWhileDead and IsEntityDead(cache.ped) then
        return false, locale('cannot_use')
    end
    if cfg.BlockWhileSwimming and IsPedSwimming(cache.ped) then
        return false, locale('cannot_use_swimming')
    end
    -- cache.vehicle is false on foot; seat -1 is the driver's.
    if cfg.BlockWhileDriving and cache.vehicle and cache.seat == -1 then
        return false, locale('cannot_use_driving')
    end

    return true
end

---Opens the tablet NUI, arms the mirror, and takes the screen from the phone if it had it.
---Refuses while dead, swimming, driving, or disabled.
---@return boolean opened
local function OpenTablet()
    local ok, message = canOpen()
    if not ok then
        if message then notify(message, 'error') end
        return false
    end

    -- Built BEFORE anything is committed: openPayload yields on a server round-trip, and taking
    -- focus or arming the mirror first would leave the player behind a cursor with nothing on
    -- screen for its duration. The lock flag is stamped first because the payload carries it.
    tabletState.locked = cfg.StartLocked ~= false
    local payload = openPayload()

    -- Re-run across that yield: the player can die, dive in or take a wheel while the server answers.
    local stillOk, lateMessage = canOpen()
    if not stillOk then
        if lateMessage then notify(lateMessage, 'error') end
        return false
    end

    -- One device at a time, so focus, the cell-cam and pma-voice only ever have one owner.
    exports[PHONE]:close()

    tabletState.open = true

    mirror.arm(true)
    mirror.setCompanionOpen(true)

    updatePose()

    SetNuiFocus(true, true)
    if cfg.AllowMovement then
        typingInTablet = false
        typingNumeric  = false
        SetNuiFocusKeepInput(true)
    end
    startInputThread()

    SendNUIMessage({ action = 'sd-phone:open', data = payload })
    SendNUIMessage({ action = 'sd-phone:session', data = { startMs = SESSION_START_MS } })

    -- "A device of ours is on screen": sd-phone keys its cell-service, Wi-Fi and Health feeds off
    -- this, and the Camera app restores NUI focus on exit ONLY if it believes a device is watching.
    TriggerEvent('sd-phone:client:openState', true)

    -- AirShare presence: players appear in each other's share sheets while a device is out.
    TriggerServerEvent('sd-phone:server:phone:setOpen', true)

    -- Both need a round-trip and the lockscreen is already up, so they follow rather than gate it.
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

    -- Seam down first, or sd-phone keeps mirroring pushes and focus at a screen that is gone.
    mirror.setCompanionOpen(false)
    mirror.arm(false)

    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'sd-phone:close' })

    TriggerEvent('sd-phone:client:openState', false)
    TriggerServerEvent('sd-phone:server:phone:setOpen', false)

    updatePose()

    debugPrint('tablet closed')
end

-- sd-phone fires this at the top of OpenPhone: the other half of the exclusion our open starts.
AddEventHandler('sd-phone:client:companion:close', function()
    CloseTablet()
end)

---The admin panel is a surface inside sd-phone's OWN frame, and neither its focus call (re-routed
---to us by the seam) nor its push (dropped here, we have no panel) survives a companion holding
---the screen - so give the screen up for it exactly as we do for the phone. Either cross-resource
---ordering lands, because CloseTablet clears the companion flag before announcing openState(false).
RegisterNetEvent('sd-phone:client:admin:open', function()
    CloseTablet()
end)

-- Teardown of the SHARED profile. Both fire when neither device need be on screen, i.e. exactly
-- when the mirror is disarmed - and our hidden NUI would then reopen on stale data. Registering
-- the net events ourselves is the only delivery that does not depend on being visible; the
-- matching pushes are dropped at the mirror so an OPEN tablet never handles them twice.

---A cloud-backup restore replaced the profile's data in place: drop every cached trace and
---rehydrate. Installed apps re-run with it, since a restore changes the list and the layout.
RegisterNetEvent('sd-phone:client:profileReset', function()
    SendNUIMessage({ action = 'sd-phone:profileReset' })
    if tabletState.open then pushInstalledApps() end
end)

---An admin wipe reloads the React app to an empty page; a device left flagged open behind it holds
---focus with nothing to release it, so it stands down first and the focus drop trails the push.
RegisterNetEvent('sd-phone:client:wipe', function()
    CloseTablet()
    SendNUIMessage({ action = 'sd-phone:wipe' })
    SetNuiFocus(false, false)
end)

-------------------------------------------------------------------- entry points

---Keybind toggle; ownership is server-authoritative because the item check is the only thing
---standing between a keybind and a free tablet.
local function ToggleTablet()
    if tabletState.open then CloseTablet() return end

    -- The last-used colour is a hint the server only honours while that item is still owned.
    --
    -- The second argument stays `false`. It reads like a timeout and is NOT one: ox_lib documents
    -- it as "prevent the event from being called for the given time", so a number makes a repeat
    -- call inside that window return nil with no round-trip at all - which the check below would
    -- report as "you don't have a tablet" for a player who simply reopened too soon. Every await
    -- is already bounded by ox_lib's own `ox:callbackTimeout`, and that path raises rather than
    -- answering nil, so there is nothing here for a number to buy.
    local res = lib.callback.await('sd-tablet:server:resolveOpen', false, currentColor)
    if type(res) ~= 'table' or res.ok ~= true then
        notify((type(res) == 'table' and res.message) or locale('no_tablet'), 'error')
        return
    end
    if res.color and TABLET_COLORS[res.color] then currentColor = res.color end
    OpenTablet()
end

lib.addKeybind({
    name        = 'sdtablet_toggle',
    description = locale('keybind_toggle'),
    defaultKey  = cfg.Keybind,
    onPressed   = ToggleTablet,
})

-- Hold-to-look: press frees the mouse for camera rotation, release restores the cursor.
lib.addKeybind({
    name        = 'sdtablet_look',
    description = locale('keybind_look'),
    defaultKey  = cfg.LookKeybind,
    onPressed   = enterLookMode,
    onReleased  = exitLookMode,
})

---Opens after an item is used, in its colour; ownership is proven by the use callback firing at
---all, and the colour is whitelist-checked because it arrives over the network.
---@param color string|nil colour of the item that was used
RegisterNetEvent('sd-tablet:client:openFromItem', function(color)
    if color and TABLET_COLORS[color] then currentColor = color end
    OpenTablet()
end)

-------------------------------------------------------------------- device-local NUI handlers

-- Actions the shared UI performs on the DEVICE it runs on; forwarding any would run sd-phone's
-- counterpart against a frame nobody is looking at. rpc.lua refuses to bind unless all exist.
---@type table<string, fun(payload: any, cb: fun(result: any))>
local LOCAL_HANDLERS = {
    ---React to Lua: the NUI requests the device be closed (swipe down / back gesture).
    ['sd-phone:close'] = function(_, cb)
        CloseTablet()
        cb({ ok = true })
    end,

    ---React to Lua: unlock gesture finished; re-arms on the next open. No passcode check belongs
    ---here - the React app compares it, and the lockscreen is privacy, not a security boundary.
    ['sd-phone:unlock'] = function(_, cb)
        tabletState.locked = false
        cb({ ok = true })
    end,

    ---React to Lua: the closed-shell peek was tapped; put the device back on screen.
    ['sd-phone:requestOpen'] = function(_, cb)
        OpenTablet()
        cb({ ok = true })
    end,

    ---React to Lua: a text field gained or lost focus. Full typing releases keep-input; numeric
    ---typing keeps it, with the digit weapon binds suppressed by the input thread instead.
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

    ---React to Lua: lockscreen torch. A tablet has none, so it is answered rather than denied -
    ---the lockscreen asks unprompted, and a refusal would toast for a button nobody pressed.
    ['sd-phone:flashlight:toggle'] = function(_, cb)
        cb({ on = false })
    end,

    ---React to Lua: current beam state. Always off, for the same reason.
    ['sd-phone:flashlight:state'] = function(_, cb)
        cb({ on = false })
    end,
}

rpc.bind(LOCAL_HANDLERS)
-- Installed unconditionally now that debugPrint is level-filtered: with config.Debug off the
-- trace costs one filtered call per action and `setr ox:printlevel:sd-tablet debug` turns it on
-- live, which is the whole point of not having to restart to see a forward.
rpc.setTrace(function(kind, action) debugPrint(kind, action) end)

-- The FLIP only ever travels page -> Lua as this callback, so watching it through is the one place
-- this side can learn the lens. The app always enters on the rear one, and both ways to flip end here.
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

-- Cosmetic drain, 1% per 30s while open; the tablet's OWN charge, so the phone's push is dropped.
CreateThread(function()
    while true do
        Wait(30000)
        if tabletState.open and tabletState.battery > 0 then
            tabletState.battery = tabletState.battery - 1
            SendNUIMessage({ action = 'sd-phone:battery', data = tabletState.battery })
        end
    end
end)

---@type table<integer, { obj: integer, color: string }> Server id -> welded local copy + its colour.
local remoteProps = {}

---@type table<integer, integer> Server id -> game time of the last rebuild accepted for that holder.
local remoteLastBuild = {}

---@type table<integer, true> Holders mid-spawn; createProp yields, so two changes would orphan one.
local remoteBuilding = {}

---@type integer Minimum ms between rebuilds for one holder. A rebuild is a delete plus a spawn on
---EVERY observer, so the receiving side bounds it rather than trusting the sender's rate - the
---case this exists for is a client alternating two valid colours, which never repeats a value and
---so slips straight past the "already welded in this colour" check below.
local REMOTE_REBUILD_MIN <const> = 500

---Deletes a remote holder's welded prop copy, if any. Idempotent.
---@param source integer server id of the remote holder
local function removeRemoteProp(source)
    local entry = remoteProps[source]
    if entry and DoesEntityExist(entry.obj) then DeleteObject(entry.obj) end
    remoteProps[source] = nil
end

-- Cross-player visibility: the server ownership-checks the colour and writes the replicated
-- `sdTablet` bag, and every client welds its own local copy onto the holder's ped off it.
if cfg.PropVisibleToOthers then
    ---Resolves a `player:<serverId>` bag to (serverId, ped); ped is 0 when out of scope here.
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
        if not source or source == cache.serverId then return end
        -- Stowing is never throttled: it only deletes, and refusing it would strand a prop.
        if not value or ped == 0 then
            removeRemoteProp(source)
            return
        end
        -- The bag carries the holder's colour, so an unknown one is dropped rather than welded.
        if not TABLET_COLORS[value] then return end

        local entry = remoteProps[source]
        if entry and entry.color == value and DoesEntityExist(entry.obj) then return end

        -- Everything past here spawns an entity, so it is rate-limited and single-flighted.
        if remoteBuilding[source] then return end
        local now = GetGameTimer()
        local last = remoteLastBuild[source]
        if last and now - last < REMOTE_REBUILD_MIN then return end
        remoteLastBuild[source] = now

        remoteBuilding[source] = true
        removeRemoteProp(source)
        local obj = createProp(ped, value)
        remoteBuilding[source] = nil
        if obj then remoteProps[source] = { obj = obj, color = value } end
    end)

    -- 1s sweep for copies whose owner left scope, idling at 2s while nothing is welded.
    CreateThread(function()
        while true do
            if not next(remoteProps) and not next(remoteLastBuild) then
                Wait(2000)
            else
                Wait(1000)
                for source, entry in pairs(remoteProps) do
                    local plyr = GetPlayerFromServerId(source)
                    local ped = plyr ~= -1 and GetPlayerPed(plyr) or 0
                    if ped == 0 or not DoesEntityExist(ped) or not DoesEntityExist(entry.obj) then
                        removeRemoteProp(source)
                    end
                end
                -- Stamps outlive their prop by design - clearing one on stow would let a client
                -- alternating hold/stow past the throttle - so they retire when the player leaves.
                for source in pairs(remoteLastBuild) do
                    if not remoteProps[source] and GetPlayerFromServerId(source) == -1 then
                        remoteLastBuild[source] = nil
                    end
                end
            end
        end
    end)
end

---Re-stamps the session anchor and tells the NUI the character resolved: settings only resolve
---once the citizenid exists. Pushed even while closed, because the hidden NUI would otherwise
---reopen on the previous character's settings.
local function pushCharacterLoaded()
    SESSION_START_MS = GetCloudTimeAsInt() * 1000
    SendNUIMessage({ action = 'sd-phone:client:characterLoaded' })
    SendNUIMessage({ action = 'sd-phone:session', data = { startMs = SESSION_START_MS } })
end
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', pushCharacterLoaded)
RegisterNetEvent('esx:playerLoaded', pushCharacterLoaded)

---sd-phone fires this when settings appear after the UI has hydrated; our copy needs the nudge too.
RegisterNetEvent('sd-phone:client:rehydrate', pushCharacterLoaded)

---Restart with the character already in: the load events won't re-fire, but the NUI still needs it.
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

---exports['sd-tablet']:open() - no ownership check; the caller has already decided.
---CALL THIS FROM A THREAD: it yields on a server round-trip, so a call from a resource's top level
---or a native callback raises rather than returns. CreateThread around it is always safe.
---@return boolean opened
exports('open', OpenTablet)

---exports['sd-tablet']:close()
exports('close', function() CloseTablet() end)

---Launches an app - exports['sd-tablet']:openApp(appId, link); the counterpart to sd-phone's, which
---targets the phone. Yields when the tablet is closed, so call it from a thread.
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

---Resource-stop cleanup: releases focus, stops the clip, deletes props and stands the seam down.
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
    -- The `sdTablet` bag is the server's to write, and it clears every player's on its own stop.
    -- Writing false here too would desync it and get the next open deduped away as "no change".
    for source in pairs(remoteProps) do removeRemoteProp(source) end
end)
