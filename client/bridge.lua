-- Request/reply transport to sd-phone's companion callback seam, over client-local TriggerEvents.
-- The reply is async, but a handler with no server work answers INSIDE the invoke - so the pending
-- entry is written first and every path answers through a one-shot closure.

---@type string The resource we borrow callbacks from.
local PHONE <const> = 'sd-phone'
---@type integer Watchdog window; generous because an sd-phone callback can be a DB round-trip.
local TIMEOUT_MS <const> = 15000

---@type table Module table; returned at end of file.
local bridge = {}

---@type table<string, { cb: fun(result: any), action: string, expires: integer }> Pending by token.
local pending = {}
---@type integer Monotonic request counter; never reused within a session.
local seq = 0
---@type boolean True while the expiry sweeper thread is alive.
local sweeping = false
---@type string Token namespace; replies are broadcast, so another companion's can never collide.
local PREFIX <const> = GetCurrentResourceName() .. ':'

---Resolves one outstanding request; unknown tokens are another companion's, or already expired.
---@param token any token we minted and echoed out
---@param result any handler response
AddEventHandler('sd-phone:client:companion:reply', function(token, result)
    local entry = pending[token]
    if not entry then return end
    pending[token] = nil
    entry.cb(result)
end)

---Expires overdue requests; one thread rather than an uncancellable timer per forwarded action.
local function startSweeper()
    if sweeping then return end
    sweeping = true
    CreateThread(function()
        -- Nothing yields between the condition going false and the flag clearing, so no invoke can
        -- arm a sweeper that is on its way out.
        while next(pending) do
            Wait(1000)
            local now = GetGameTimer()

            -- Collected first, answered after. `entry.cb` is the NUI callback's own sink, which is
            -- free to call bridge.invoke again - and adding a key to a table mid-`pairs` is
            -- undefined in Lua 5.4, up to and including a hard "invalid key to 'next'". Clearing
            -- one is explicitly allowed, so only the answers move out of the loop.
            local due
            for token, entry in pairs(pending) do
                if now >= entry.expires then
                    pending[token] = nil
                    due = due or {}
                    due[#due + 1] = entry.cb
                end
            end

            if due then
                for i = 1, #due do due[i]({ success = false, message = 'No response' }) end
            end
        end
        sweeping = false
    end)
end

---Runs one of sd-phone's NUI callbacks on this device's behalf; `cb` fires EXACTLY once.
---@param action string NUI action name as sd-phone registered it
---@param payload any handler payload
---@param cb fun(result: any) response sink - the NUI callback's own cb
function bridge.invoke(action, payload, cb)
    ---@type boolean Set by whichever path answers first.
    local answered = false
    local function answer(result)
        if answered then return end
        answered = true
        cb(result)
    end

    -- A stopped sd-phone would swallow the invoke and leave the UI spinning for the whole window.
    if GetResourceState(PHONE) ~= 'started' then
        answer({ success = false, message = 'Phone service unavailable', unsupported = true })
        return
    end

    seq = seq + 1
    local token = PREFIX .. seq
    pending[token] = { cb = answer, action = action, expires = GetGameTimer() + TIMEOUT_MS }

    TriggerEvent('sd-phone:client:companion:invoke', token, action, payload)

    -- Already answered inside the TriggerEvent above, so there is nothing left to watch.
    if not pending[token] then return end

    startSweeper()
end

---Number of requests still waiting on sd-phone. Debug/diagnostics only.
---@return integer
function bridge.pendingCount()
    local n = 0
    for _ in pairs(pending) do n = n + 1 end
    return n
end

-- sd-phone stopping mid-request takes its reply with it; fail every outstanding call at once.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= PHONE then return end
    local outstanding = pending
    pending = {}
    for _, entry in pairs(outstanding) do
        entry.cb({ success = false, message = 'Phone service unavailable', unsupported = true })
    end
end)

return bridge
