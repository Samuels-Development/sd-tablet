-- What this device refuses, what it answers itself, and which of sd-phone's NUI pushes are about
-- the PHONE rather than about the player.
--
-- Three tables, one question each, and every one of them is data rather than control flow so the
-- whole device policy can be read at a glance:
--
--   DENY       actions no companion device may ever run.
--   LOCAL      actions that act on THIS device's NUI and must never leave the resource.
--   DROP       pushes that describe sd-phone's own hardware and would corrupt our frame.
--
-- Anything not named here forwards, and anything not named here passes. That default is
-- deliberate: sd-phone grows apps constantly, and a tablet that had to be told about each new one
-- would silently lose it. The three lists are small, closed sets of DEVICE concerns.

---@type table Module table; returned at end of file.
local policy = {}

-------------------------------------------------------------------- deny

-- Defence in depth. sd-phone's client/companion.lua already refuses every one of these on its own
-- side, which is what actually makes them unreachable - the refusal has to live there, or a
-- hand-edited tablet build could simply stop asking. Repeating it here means a denied action
-- never even leaves this resource, so the failure is instant and the console is quiet.
--
-- Voice calling is the phone's alone (calls, FaceTime video, street payphones, the call log's
-- seen-marker, and the Services app's "call this company" button).
-- The admin panel is added on top of sd-phone's list: it is an overlay bolted to the phone shell,
-- it grabs NUI focus for itself, and the tablet's device profile does not build it. Every admin
-- callback re-checks the admin ace server-side, so this is tidiness, not a security control -
-- delete the prefix if you want /phoneadmin to work from a tablet.
---@type string[]
local DENY_PREFIX = {
    'sd-phone:call:',
    'sd-phone:video:',
    'sd-phone:payphone:',
    'sd-phone:admin:',
}

---@type table<string, boolean>
local DENY = {
    ['sd-phone:calls:seen']           = true,
    ['sd-phone:services:callCompany'] = true,
}

---Whether an action is closed to this device.
---@param action string NUI action name
---@return boolean
function policy.denied(action)
    if DENY[action] then return true end
    for i = 1, #DENY_PREFIX do
        local prefix = DENY_PREFIX[i]
        if action:sub(1, #prefix) == prefix then return true end
    end
    return false
end

-------------------------------------------------------------------- local

-- Actions that act on the DEVICE, not on the player. Forwarding any of these would drive
-- sd-phone's hardware from the tablet's UI: `sd-phone:close` would close a phone that isn't open,
-- `sd-phone:typing` would set keep-input on a frame nobody can see, and the flashlight pair would
-- light a torch on a device the player isn't holding. Each one has a tablet equivalent in
-- client/main.lua, and client/rpc.lua asserts at boot that none of them is missing.
---@type table<string, boolean>
policy.LOCAL = {
    ['sd-phone:close']              = true,
    ['sd-phone:unlock']             = true,
    ['sd-phone:typing']             = true,
    ['sd-phone:openApp']            = true,
    ['sd-phone:requestOpen']        = true,
    ['sd-phone:flashlight:toggle']  = true,
    ['sd-phone:flashlight:state']   = true,
}

-- Deliberately NOT above: sd-phone:apps:list and sd-phone:apps:saveLayout. They read device-shaped,
-- because the home LAYOUT really is per-device - 36 icons to a page here against the phone's 24 -
-- but they are storage, and the storage is one row on sd-phone's server keyed to the shared
-- citizenid. This resource owns no database and no identity to key one with. The device split
-- lives inside that row instead: the shared bundle sends its own device id with every save,
-- sd-phone's server merges it into a per-device envelope, and the bundle takes its own slice back
-- out on read. Forwarding is therefore exactly what keeps the two layouts apart, and answering
-- either one here would hand the tablet a layout that survives nothing.

-------------------------------------------------------------------- push filter

-- sd-phone mirrors EVERY NUI push it makes while a companion is armed, because almost all of them
-- are player data - a message arriving, a badge count, a bank transaction, the weather, the
-- shared installed-app list - and every one of those has to reach the tablet or the device is a
-- lie. These are the exceptions: pushes that describe sd-phone's own hardware and, replayed into
-- our frame, would make the tablet impersonate the phone.
--
--   sd-phone:open       the PHONE's open payload: its geometry, its dock, its app list, its SIM.
--                       We send our own; letting this land would repaint the tablet as a phone.
--   sd-phone:close      the phone going away is not the tablet going away. Mutual exclusion is
--                       handled by the companion:close event, which is explicit about who closes.
--   sd-phone:battery    a different device with a different charge. The tablet drains its own.
--   sd-phone:launchApp  exports['sd-phone']:openApp targets the PHONE - and opens it, which
--                       closes us first anyway. exports['sd-tablet']:openApp is the tablet's.
--   sd-phone:frameColor which coloured phone shell the player is holding. A tablet has no
--                       variants; this would recolour a rail that isn't there.
--   sd-phone:admin:open the admin overlay, matching the DENY prefix above. It arrives with a
--                       focus grab attached, so a half-built panel would strand the cursor; the
--                       tablet closes for it instead (client/main.lua).
--
-- The last two are a different case, and the only ones here that the tablet DOES want: a profile
-- reset and an admin wipe are the shared data going away, so our cached copy has to go with it.
-- They are dropped because sd-phone pushes both while a device may be CLOSED - i.e. while this
-- mirror is disarmed - so a push is not delivery we can rely on. client/main.lua registers the two
-- net events itself, which reaches us either way, and dropping the pushes is what stops an OPEN
-- tablet handling each of them twice.
--
--   sd-phone:profileReset a cloud-backup restore replaced the profile's data in place.
--   sd-phone:wipe         an admin wipe; the React app clears local storage and reloads.
--
-- sd-phone:simState is deliberately NOT dropped. The tablet has no SIM tray of its own, but it
-- borrows the identity of the SIM in the phone you are carrying, so it has to hear when that
-- changes: without it the shared UI sits on No Service forever on a SIM server.
---@type table<string, boolean>
local DROP = {
    ['sd-phone:open']         = true,
    ['sd-phone:close']        = true,
    ['sd-phone:battery']      = true,
    ['sd-phone:launchApp']    = true,
    ['sd-phone:frameColor']   = true,
    ['sd-phone:admin:open']   = true,
    ['sd-phone:profileReset'] = true,
    ['sd-phone:wipe']         = true,
}

---Whether a mirrored push must not reach this device's frame. Denied actions are dropped too:
---sd-phone already withholds call, video and payphone pushes, and re-checking costs one table
---lookup against the possibility of an incoming call ringing on a device that cannot answer it.
---@param action string NUI push action name
---@return boolean
function policy.dropPush(action)
    if DROP[action] then return true end
    return policy.denied(action)
end

return policy
