-- Request/reply transport to sd-phone's NUI callback registry.
--
-- sd-phone/client/companion.lua listens for 'sd-phone:client:companion:invoke' (token, action,
-- payload), runs its own recorded handler for that action, and answers with
-- 'sd-phone:client:companion:reply' (token, result). Client-side TriggerEvent dispatches to
-- handlers in every resource on this client, so the two events are all the transport there is -
-- no net traffic, no serialisation beyond what the event system already does.
--
-- The reply is ASYNCHRONOUS and must be treated as such. sd-phone's proxied callbacks sit on
-- `lib.callback.await`, which yields; the invoke TriggerEvent therefore returns to us long before
-- the answer exists. A handler that does no server work, on the other hand, answers INSIDE the
-- TriggerEvent call - so the pending entry has to be in the map before the event is fired, and
-- both orderings have to be safe. They are: the map is written first, and every path answers
-- through a one-shot closure.

---@type string The resource we borrow callbacks from.
local PHONE <const> = 'sd-phone'
---@type integer Watchdog window. Generous on purpose: an sd-phone callback can be a database
---round-trip on a loaded server, and answering early would show the player a false failure for a
---request that then succeeds. This exists so the UI can never hang forever, not to enforce a
---latency budget.
local TIMEOUT_MS <const> = 15000

---@type table Module table; returned at end of file.
local bridge = {}

---@type table<string, { cb: fun(result: any), action: string }> Outstanding requests by token.
local pending = {}
---@type integer Monotonic request counter; never reused within a session.
local seq = 0
---@type string Token namespace. The reply event is broadcast to the whole client, so a second
---companion device's replies land in our handler too - prefixing with the resource name means our
---tokens can never collide with theirs, and theirs never match our pending map.
local PREFIX <const> = GetCurrentResourceName() .. ':'

---Resolves one outstanding request. Unknown tokens are another companion's (or a late reply to a
---request the watchdog already answered) and are ignored.
---@param token any token we minted and echoed out
---@param result any handler response
AddEventHandler('sd-phone:client:companion:reply', function(token, result)
    local entry = pending[token]
    if not entry then return end
    pending[token] = nil
    entry.cb(result)
end)

---Runs one of sd-phone's NUI callbacks on this device's behalf and hands the response back.
---`cb` is called EXACTLY once: by the reply, by the watchdog, or immediately when sd-phone isn't
---running to be asked.
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

    -- A stopped or restarting sd-phone would swallow the invoke and leave the UI on a spinner for
    -- the whole watchdog window; failing now is both faster and truthful.
    if GetResourceState(PHONE) ~= 'started' then
        answer({ success = false, message = 'Phone service unavailable', unsupported = true })
        return
    end

    seq = seq + 1
    local token = PREFIX .. seq
    pending[token] = { cb = answer, action = action }

    TriggerEvent('sd-phone:client:companion:invoke', token, action, payload)

    -- Already gone: the handler answered inside the TriggerEvent above (no server round-trip).
    -- Arming a watchdog for it would keep a closure alive for 15s for nothing.
    if not pending[token] then return end

    SetTimeout(TIMEOUT_MS, function()
        if not pending[token] then return end
        pending[token] = nil
        answer({ success = false, message = 'No response' })
    end)
end

---Number of requests still waiting on sd-phone. Debug/diagnostics only.
---@return integer
function bridge.pendingCount()
    local n = 0
    for _ in pairs(pending) do n = n + 1 end
    return n
end

-- sd-phone stopping mid-request takes its reply with it. Fail every outstanding call at once
-- rather than leaving the UI to discover it one 15s watchdog at a time.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= PHONE then return end
    local outstanding = pending
    pending = {}
    for _, entry in pairs(outstanding) do
        entry.cb({ success = false, message = 'Phone service unavailable', unsupported = true })
    end
end)

return bridge
