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
-- Two functions duplicated rather than required across the resource boundary: package.loaded is
-- per-Lua-state, so requiring sd-phone's bridge would re-run its framework banner and register a
-- second set of player handlers. Call shapes are kept identical to sd-phone's on purpose.
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

---Picks the backend's count-of-item implementation once at load; every path answers 0, never nil.
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

    -- ps/lj-inventory and the no-inventory case resolve through the framework's own player object.
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

---Picks the usable-item registrar once at load; the ox path derives a per-item export on THIS
---resource ('tablet' -> 'useTablet'), which is what the README's ox_inventory definition points at.
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
-- No longer a refusal: the tablet borrows the identity of the SIM in the phone the player carries,
-- exactly as it borrows everything else, so a request already answers as the right number. The flag
-- survives only to reach the UI, which needs it to tell "no SIM" apart from "this server has none".
-- sd-phone flips it seconds into boot behind an inventory probe, so it is polled until it settles
-- and mirrored into global state for the client, which has no export of its own to ask.
-- ---------------------------------------------------------------------------

---@return boolean
local function simModeActive()
    if GetResourceState(PHONE) ~= 'started' then return false end
    local ok, res = pcall(function() return exports[PHONE]:isSimModeActive() end)
    return ok and res == true
end

CreateThread(function()
    GlobalState.sdTabletSimMode = false
    -- 60s covers sd-phone's own probe with room to spare; the first true is final.
    for _ = 1, 30 do
        if simModeActive() then
            GlobalState.sdTabletSimMode = true
            print('^3[sd-tablet]^0 sd-phone is running unique phones / SIM cards - the tablet acts '
                .. 'as the SIM in the phone the player is carrying.')
            return
        end
        Wait(2000)
    end
end)

-- ---------------------------------------------------------------------------
-- Ownership
--
-- Resolving a colour searches the inventory once per configured item, and every caller is
-- client-reachable at whatever rate it likes - so the OWNED SET is cached per player for a short
-- window. The set rather than the resolved colour: caching the answer would key it on the
-- client-supplied `preferred`, which a client could vary to miss the cache every time.
-- ---------------------------------------------------------------------------

---@type integer ms an owned-colour set stays good for; long enough to collapse a burst.
local OWNERSHIP_TTL <const> = 3000

---@type table<number, { at: integer, colors: string[] }> Server id -> cached owned set.
local ownershipCache = {}

---Every configured colour this player currently carries, in config order.
---@param source number player server id
---@return string[] colors
local function ownedColors(source)
    local now = GetGameTimer()
    local hit = ownershipCache[source]
    if hit and now - hit.at < OWNERSHIP_TTL then return hit.colors end

    local colors, seen = {}, {}
    for _, entry in ipairs(cfg.Items or {}) do
        -- Several items map to one colour, so a colour already found needs no second search.
        if not seen[entry.color] and countItem(source, entry.item) > 0 then
            seen[entry.color] = true
            colors[#colors + 1] = entry.color
        end
    end

    ownershipCache[source] = { at = now, colors = colors }
    return colors
end

---Drops a player's cached owned set, so the next read goes back to the inventory.
---@param source number player server id
local function invalidateOwnership(source)
    ownershipCache[source] = nil
end

---The colour this player carries, preferring their last-opened one so the keybind stays stable.
---@param source number player server id
---@param preferred string|nil last-used colour hint from the client
---@return string|nil color colour to open with, nil when no tablet item is owned
local function resolveOwnedColor(source, preferred)
    local colors = ownedColors(source)
    if #colors == 0 then return nil end
    if preferred then
        for i = 1, #colors do
            if colors[i] == preferred then return preferred end
        end
    end
    return colors[1]
end

---Clamps a client-supplied colour hint to something safe to compare against a config value.
---@param value any
---@return string|nil
local function cleanColor(value)
    if type(value) ~= 'string' or value == '' or #value > 32 then return nil end
    return value
end

AddEventHandler('playerDropped', function()
    invalidateOwnership(source)
end)

---Whether a player may open a tablet right now, and in which colour.
---@param source number player server id
---@param preferred string|nil last-used colour hint from the client
---@return boolean ok
---@return string|nil message reason to show when refused
---@return string|nil color colour to open with
local function mayOpen(source, preferred)
    -- No SIM check: the identity comes from the SIM in the phone they carry, so this answers as
    -- the right number either way, and with none the shared UI shows its own No Service screen.
    if not cfg.Items or cfg.RequireItem == false then
        return true, nil, resolveOwnedColor(source, preferred) or cfg.DefaultColor
    end
    local color = resolveOwnedColor(source, preferred)
    if color then return true, nil, color end
    return false, 'You don\'t have a tablet.'
end

---Keybind open request; the item check is authoritative here because a client-side one is only a
---suggestion. `preferred` is client-supplied, so it is clamped and the cost bounded by the cache.
lib.callback.register('sd-tablet:server:resolveOpen', function(source, preferred)
    local ok, message, color = mayOpen(source, cleanColor(preferred))
    return { ok = ok, message = message, color = color }
end)

-- ---------------------------------------------------------------------------
-- Hold broadcast
--
-- Nearby clients weld a local prop copy off the replicated `sdTablet` player bag. The bag is
-- written HERE because a client can write its own, so a client-written colour would be the item
-- check with the item removed - and every change costs each observer a prop delete + spawn.
-- Writes are coalesced rather than dropped: a stow arriving inside the window still has to land,
-- or the prop is stranded in every observer's view until the player next opens the tablet.
-- ---------------------------------------------------------------------------

if cfg.PropVisibleToOthers then
    ---@type integer Minimum ms between bag writes for one player; a real hold never bursts.
    local HOLD_MIN_INTERVAL <const> = 400

    ---@type table<string, true> Colours any configured item can open, for the no-item-check case.
    local CONFIGURED_COLORS = {}
    for _, entry in ipairs(cfg.Items or {}) do CONFIGURED_COLORS[entry.color] = true end
    if cfg.DefaultColor then CONFIGURED_COLORS[cfg.DefaultColor] = true end

    ---@class HoldState
    ---@field at integer game time of the last write
    ---@field value string|false what is on the bag now
    ---@field pending string|false value waiting for the window to expire
    ---@field hasPending boolean `pending` is meaningful (false is a legal value, so nil won't do)
    ---@field queued boolean a timer is already armed to flush `pending`

    ---@type table<number, HoldState>
    local holdState = {}

    ---Writes the bag and stamps the window.
    ---@param src number
    ---@param state HoldState
    ---@param value string|false
    local function applyHold(src, state, value)
        state.at    = GetGameTimer()
        state.value = value
        Player(src).state:set('sdTablet', value, true)
    end

    ---Resolves what this player may claim to be holding.
    ---@param src number
    ---@param color any client-supplied colour, or false/nil to stow
    ---@return string|false|nil value bag value to write, nil to ignore the request entirely
    local function resolveHold(src, color)
        if color == nil or color == false then return false end

        local clean = cleanColor(color)
        if not clean then return nil end

        -- Item check off: any configured colour is an honest claim. On: they must hold it.
        if not cfg.Items or cfg.RequireItem == false then
            return CONFIGURED_COLORS[clean] and clean or nil
        end
        return resolveOwnedColor(src, clean) == clean and clean or false
    end

    RegisterNetEvent('sd-tablet:server:setHolding', function(color)
        local src = source
        local value = resolveHold(src, color)
        if value == nil then return end

        local state = holdState[src]
        if not state then
            state = { at = 0, value = false, hasPending = false, queued = false }
            holdState[src] = state
        end

        -- Already what the bag says; costs observers nothing, so drop it whatever the rate.
        if state.value == value then
            state.hasPending = false
            return
        end

        local wait = HOLD_MIN_INTERVAL - (GetGameTimer() - state.at)
        if wait <= 0 then
            state.hasPending = false
            return applyHold(src, state, value)
        end

        -- Inside the window: keep the latest value and let one armed timer apply it.
        state.pending    = value
        state.hasPending = true
        if state.queued then return end
        state.queued = true
        SetTimeout(wait, function()
            local cur = holdState[src]
            if not cur then return end
            cur.queued = false
            if not cur.hasPending then return end
            cur.hasPending = false
            local pending = cur.pending
            if pending ~= cur.value then applyHold(src, cur, pending) end
        end)
    end)

    AddEventHandler('playerDropped', function()
        holdState[source] = nil
    end)

    -- Restarting leaves every holder's bag set with no observer left to clean it up.
    AddEventHandler('onResourceStop', function(resource)
        if resource ~= GetCurrentResourceName() then return end
        for _, id in ipairs(GetPlayers()) do
            local src = tonumber(id)
            if src then Player(src).state:set('sdTablet', false, true) end
        end
    end)
end

-- Boot: registers every usable tablet item once, deferred a tick so the inventory's exports exist.
CreateThread(function()
    Wait(50)
    if not cfg.Items then return end
    for _, entry in ipairs(cfg.Items) do
        registerUsable(entry.item, function(source)
            -- Using an item can consume or move it, so the cached set is now a guess.
            invalidateOwnership(source)
            -- No ownership check: using the item IS the proof.
            TriggerClientEvent('sd-tablet:client:openFromItem', source, entry.color)
        end)
    end
end)

---Public export: does this player own a tablet - exports['sd-tablet']:hasTablet(source).
---@param source number player server id
---@return boolean
exports('hasTablet', function(source)
    if type(source) ~= 'number' then return false end
    if not GetPlayerName(source) then return false end
    if not cfg.Items then return false end
    return resolveOwnedColor(source, nil) ~= nil
end)

---Public export: which colour tablet does this player carry - exports['sd-tablet']:tabletColor(source).
---@param source number player server id
---@return string|nil color owned colour, nil when no tablet item is owned
exports('tabletColor', function(source)
    if type(source) ~= 'number' then return nil end
    if not GetPlayerName(source) then return nil end
    if not cfg.Items then return nil end
    return resolveOwnedColor(source, nil)
end)

if not framework then
    print('^1[sd-tablet] No supported framework detected (qbx_core / qb-core / es_extended). '
        .. 'The item check will refuse every open.^0')
end
