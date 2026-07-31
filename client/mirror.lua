-- The other half of the seam: sd-phone's NUI pushes and focus changes, applied to OUR frame.
--
-- sd-phone/client/companion.lua shadows SendNUIMessage and re-emits every push as
-- 'sd-phone:client:companion:push' while the mirror is armed, and re-routes SetNuiFocus /
-- SetNuiFocusKeepInput to 'sd-phone:client:companion:focus' / ':keepInput' while a companion owns
-- the screen. Both are plain client events, so they arrive here without any net traffic.
--
-- The focus half is what makes forwarded surfaces work at all. The Camera app is the clearest
-- case: its handlers run inside sd-phone, and they take and release NUI focus as the viewfinder
-- opens, hands the mouse to the game to aim the lens, and closes again. Those calls are asking on
-- behalf of whichever device is actually visible, so they land here and we apply them to ours.

---@type table Device policy (client.policy): which pushes are the phone's own hardware.
local policy = require 'client.policy'

---@type string The resource we mirror.
local PHONE <const> = 'sd-phone'

---@type table Module table; returned at end of file.
local mirror = {}

---@class MirrorDevice
---@field isOpen fun(): boolean is the tablet on screen
---@field close fun() take the tablet off screen

---@type MirrorDevice Bound by client/main.lua. The inert default keeps every handler below safe
---during resource start, before main.lua has finished defining open and close.
local device = {
    isOpen = function() return false end,
    close  = function() end,
}

---Binds the device this mirror feeds.
---@param handle MirrorDevice
function mirror.bind(handle) device = handle end

---Arms or disarms sd-phone's push mirror. Armed on open, disarmed on close - never left on,
---because an armed mirror makes sd-phone fire a client event for every push it makes for the rest
---of the session, and pumps its weather poll for a device nobody is looking at.
---@param enabled boolean
---pcall'd, not because the export is optional, but because both of these are also called from the
---close path that runs WHILE sd-phone is stopping - the window where the resource still reports
---as started but its exports have already gone.
function mirror.arm(enabled)
    if GetResourceState(PHONE) ~= 'started' then return end
    pcall(function() exports[PHONE]:setCompanionMirror(enabled == true) end)
end

---Announces that this device has taken or released the screen. sd-phone uses it to hand focus
---over, to keep its weather poll running while its own phone is stowed, and to give up the screen
---when the phone is opened.
---@param open boolean
function mirror.setCompanionOpen(open)
    if GetResourceState(PHONE) ~= 'started' then return end
    pcall(function() exports[PHONE]:setCompanionOpen(open == true) end)
end

-------------------------------------------------------------------- pushes

---One mirrored NUI push. Everything data-shaped goes straight into our frame; the phone's own
---hardware is filtered out by client/policy.lua.
---@param data table NUI message { action = string, data = any }
AddEventHandler('sd-phone:client:companion:push', function(data)
    if not device.isOpen() then return end
    if type(data) ~= 'table' or type(data.action) ~= 'string' then return end
    if policy.dropPush(data.action) then return end

    SendNUIMessage(data)
end)

-------------------------------------------------------------------- focus

---@param hasFocus any
---@param hasCursor any
AddEventHandler('sd-phone:client:companion:focus', function(hasFocus, hasCursor)
    if not device.isOpen() then return end
    SetNuiFocus(hasFocus == true, hasCursor == true)
end)

---@param keepInput any
AddEventHandler('sd-phone:client:companion:keepInput', function(keepInput)
    if not device.isOpen() then return end
    SetNuiFocusKeepInput(keepInput == true)
end)

-------------------------------------------------------------------- lifecycle

-- sd-phone stopping mid-session leaves the tablet with no callbacks to forward to and no pushes
-- to receive: it is a dead frame holding the player's cursor. Close it.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= PHONE then return end
    if device.isOpen() then device.close() end
end)

return mirror
