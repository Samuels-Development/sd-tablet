-- Build-presence guard: a source checkout without a compiled NUI would open to a blank tablet.
if not LoadResourceFile(GetCurrentResourceName(), 'web/build/index.html') then
    print('^1[sd-tablet] NUI build not found at web/build/index.html.^0')
    print('^3[sd-tablet] Build it: cd web && bun install && bun run build^0')
end

---@type table sd-tablet config root (configs/config.lua).
local config = require 'configs.config'
---@type table Tablet settings (configs/tablet.lua).
local cfg <const> = config.Tablet
---@type string The resource that owns the phone data.
local PHONE <const> = 'sd-phone'

-- ---------------------------------------------------------------------------
-- Framework + inventory
--
-- sd-phone has a full inventory bridge (bridge/server/inventory.lua) and this file needs two
-- lines of it: "does this player hold the item" and "run this when they use it". It is
-- deliberately NOT required across the resource boundary.
--
-- ox_lib's require DOES support it - `require '@sd-phone.bridge.server.inventory'` resolves,
-- because package.searchpath pulls the named resource out of the module path and LoadResourceFile
-- reads it, and nested requires inside the loaded chunk resolve back into sd-phone because the
-- chunk is loaded under an `@@sd-phone/...` name. It is still the wrong thing to do:
--
--   * package.loaded is per-Lua-state, so sd-tablet would get its own second copy of the module
--     and of everything it pulls in - re-running bridge/shared/framework.lua (which PRINTS a
--     "[SD-PHONE] Framework detected" banner and hard-errors when no framework is up) and
--     bridge/server/player.lua (which registers playerDropped and character-lifecycle handlers,
--     and would keep a second, redundant identity cache).
--   * it welds this resource to sd-phone's internal file layout, which is private and moves.
--
-- Two functions' worth of duplication is the cheaper trade. The backend list and the call shapes
-- are kept identical to sd-phone's bridge on purpose: if a server's inventory works there, it
-- works here.
-- ---------------------------------------------------------------------------

---@class TabletFramework
---@field name 'qbx'|'qb'|'esx'
---@field qb boolean true for both QBox and QBCore, whose player objects share a shape
---@field core any live core object; nil on QBox, which is all discrete exports

---@return TabletFramework|nil
local function detectFramework()
    if GetResourceState('qbx_core') == 'started' then return { name = 'qbx', qb = true } end
    if GetResourceState('qb-core') == 'started' then
        return { name = 'qb', qb = true, core = exports['qb-core']:GetCoreObject() }
    end
    if GetResourceState('es_extended') == 'started' then
        return { name = 'esx', qb = false, core = exports['es_extended']:getSharedObject() }
    end
    return nil
end

---@type TabletFramework|nil
local framework = detectFramework()

---@type string[] Supported inventory resources, in the same detection-priority order sd-phone uses.
local CANDIDATES <const> = {
    'ox_inventory',
    'tgiann-inventory',
    'jaksam_inventory',
    'qs-inventory',
    'qs-inventory-pro',
    'origen_inventory',
    'qb-inventory',
    'ps-inventory',
    'lj-inventory',
    'codem-inventory',
}

---@return string|nil resource name, nil when none is started
local function detectInventory()
    for i = 1, #CANDIDATES do
        if GetResourceState(CANDIDATES[i]) == 'started' then return CANDIDATES[i] end
    end
    return nil
end

---@type string|nil Detected inventory resource; nil routes the chooser to the framework paths.
local active = detectInventory()

---Framework-native player object for a source. Nil when the source isn't a loaded player.
---@param src number
---@return any|nil
local function getPlayer(src)
    if not framework then return nil end
    if framework.name == 'qbx' then return exports.qbx_core:GetPlayer(src) end
    if framework.qb then return framework.core.Functions.GetPlayer(src) end
    return framework.core.GetPlayerFromId(src)
end

---Pick the inventory backend's count-of-item implementation once at load. Every path answers 0,
---never nil, when the player or item can't be resolved.
---@return fun(source: number, item: string): number
local function chooseCount()
    if active == 'ox_inventory' then
        return function(src, item)
            local items = exports.ox_inventory:Search(src, 'slots', item)
            if type(items) ~= 'table' then return 0 end
            local total = 0
            for _, row in pairs(items) do total = total + (row.count or 0) end
            return total
        end
    end
    if active == 'tgiann-inventory' then
        return function(src, item) return exports['tgiann-inventory']:GetItemCount(src, item) or 0 end
    end
    if active == 'jaksam_inventory' then
        return function(src, item) return exports.jaksam_inventory:getTotalItemAmount(src, item) or 0 end
    end
    if active == 'codem-inventory' then
        return function(src, item) return exports['codem-inventory']:GetItemsTotalAmount(src, item) or 0 end
    end
    if active == 'origen_inventory' then
        return function(src, item) return exports.origen_inventory:getItemCount(src, item, false, false) or 0 end
    end
    if active == 'qs-inventory' or active == 'qs-inventory-pro' then
        local inv = active
        return function(src, item) return exports[inv]:GetItemTotalAmount(src, item) or 0 end
    end
    if active == 'qb-inventory' then
        return function(src, item) return exports['qb-inventory']:GetItemCount(src, item) or 0 end
    end

    -- ps-inventory / lj-inventory and the no-inventory-resource case all resolve through the
    -- framework's own player object, which those forks keep authoritative.
    if framework and framework.name == 'esx' then
        return function(src, item)
            local p = getPlayer(src); if not p then return 0 end
            local data = p.getInventoryItem(item)
            return data and (data.count or data.amount) or 0
        end
    end
    if framework and framework.qb then
        return function(src, item)
            local p = getPlayer(src); if not p then return 0 end
            local data = p.Functions.GetItemByName(item)
            return data and (data.amount or data.count) or 0
        end
    end
    return function() return 0 end
end

---@type fun(source: number, item: string): number Backend item-count reader, bound once at load.
local countItem = chooseCount()

---Pick the "register a usable item" implementation once at load. The ox path derives a per-item
---export ('tablet' -> 'useTablet') on THIS resource, which is why the ox_inventory item
---definition in the README points at `sd-tablet.useTablet`.
---@return fun(item: string, cb: fun(source: number)): nil
local function chooseRegisterUsable()
    if active == 'ox_inventory' then
        return function(item, cb)
            local exportName = 'use' .. item:gsub('^%l', string.upper)
            exports(exportName, function(event, _item, inv)
                if event == 'usingItem' then cb(inv.id) end
            end)
        end
    end
    if active == 'qs-inventory-pro' then
        return function(item, cb) return exports['qs-inventory-pro']:CreateUsableItem(item, cb) end
    end
    if active == 'origen_inventory' then
        return function(item, cb) return exports.origen_inventory:CreateUseableItem(item, cb) end
    end

    if framework and framework.name == 'esx' then
        return function(item, cb) return framework.core.RegisterUsableItem(item, cb) end
    end
    if framework and framework.name == 'qbx' then
        return function(item, cb) return exports.qbx_core:CreateUseableItem(item, cb) end
    end
    if framework and framework.qb then
        return function(item, cb) return framework.core.Functions.CreateUseableItem(item, cb) end
    end

    return function(item)
        print(('^1[sd-tablet] no supported registration path for usable item %q - open it with the keybind.^0'):format(item))
    end
end

---@type fun(item: string, cb: fun(source: number)): nil Usable-item registrar, bound once at load.
local registerUsable = chooseRegisterUsable()

-- ---------------------------------------------------------------------------
-- SIM mode
--
-- Under sd-phone's unique-phones/SIM mode the acting identity comes from the SIM in the player's
-- ACTIVE PHONE, so a tablet - which has no SIM tray and no device identity - has no identity to
-- act as. Rather than open a device that shows the wrong data, both open paths refuse.
--
-- isSimModeActive is a SERVER export, and sd-phone only flips the flag several seconds into boot,
-- after it has waited for the inventory to start and probed it for per-slot metadata support. So
-- the flag is polled until it settles rather than read once, and mirrored into global state for
-- the client, which has no export of its own to ask.
-- ---------------------------------------------------------------------------

---@return boolean
local function simModeActive()
    if GetResourceState(PHONE) ~= 'started' then return false end
    local ok, res = pcall(function() return exports[PHONE]:isSimModeActive() end)
    return ok and res == true
end

CreateThread(function()
    GlobalState.sdTabletSimMode = false
    -- 60s of polling covers sd-phone's own probe (up to ~10s of waiting for ox_inventory, plus a
    -- schema ensure) with room to spare on a slow boot. The flag is set once and never cleared,
    -- so the first true is final.
    for _ = 1, 30 do
        if simModeActive() then
            GlobalState.sdTabletSimMode = true
            print('^3[sd-tablet]^0 sd-phone is running unique phones / SIM cards - the tablet stays closed. '
                .. 'A tablet has no SIM, so it has no identity to act as.')
            return
        end
        Wait(2000)
    end
end)

-- ---------------------------------------------------------------------------
-- Ownership
-- ---------------------------------------------------------------------------

---Whether a player may open a tablet right now.
---@param source number player server id
---@return boolean ok, string|nil message reason to show when refused
local function mayOpen(source)
    if simModeActive() then
        return false, 'This server uses SIM cards - a tablet has no SIM. Use your phone.'
    end
    if not cfg.Item or cfg.RequireItem == false then return true end
    if countItem(source, cfg.Item) > 0 then return true end
    return false, 'You don\'t have a tablet.'
end

---Keybind open request: may this player open a tablet? The client asks before every open, so the
---item check is authoritative in the only place it can be - a client-side check is a suggestion.
lib.callback.register('sd-tablet:server:resolveOpen', function(source)
    local ok, message = mayOpen(source)
    return { ok = ok, message = message }
end)

-- Boot: registers the usable tablet item once. Deferred a tick like sd-phone's, so the inventory
-- resource's own exports exist by the time we hand it a callback.
CreateThread(function()
    Wait(50)
    if not cfg.Item then return end
    registerUsable(cfg.Item, function(source)
        -- No ownership check here: using the item IS the proof. The SIM refusal still applies,
        -- and is answered with a toast rather than silence so the player knows why nothing opened.
        if simModeActive() then
            TriggerClientEvent('ox_lib:notify', source, {
                title       = 'Tablet',
                description = 'This server uses SIM cards - a tablet has no SIM. Use your phone.',
                type        = 'error',
            })
            return
        end
        TriggerClientEvent('sd-tablet:client:openFromItem', source)
    end)
end)

---Public export: does this player own a tablet - exports['sd-tablet']:hasTablet(source).
---@param source number player server id
---@return boolean
exports('hasTablet', function(source)
    if type(source) ~= 'number' then return false end
    if not GetPlayerName(source) then return false end
    if not cfg.Item then return false end
    return countItem(source, cfg.Item) > 0
end)

if not framework then
    print('^1[sd-tablet] No supported framework detected (qbx_core / qb-core / es_extended). '
        .. 'The item check will refuse every open.^0')
end
