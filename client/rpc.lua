-- The tablet's single NUI callback.
--
-- The shared React bundle is built with `device.rpcAction = 'rpc'`, so instead of POSTing each
-- action to a callback of its own name it wraps every one in { action, payload } and posts it
-- here. That envelope is what makes the tablet possible at all: sd-phone's UI reaches roughly 460
-- distinct callback names, plenty of them built at runtime by app modules, and a companion could
-- never register that set up front. A missing name would 404 into a JSON parse error rather than
-- a usable response.
--
-- One dispatcher, three outcomes, in this order:
--   denied  -> refused here, without troubling sd-phone
--   local   -> answered by this resource, because it is about THIS device
--   else    -> forwarded to sd-phone's own handler over client/bridge.lua
--
-- A forwarded action may also be WATCHED on its way past (rpc.watch). A watcher is an observer and
-- never an outcome: sd-phone still runs the action and still owns the answer.

---@type table Device policy (client.policy): DENY / LOCAL / push-filter tables.
local policy = require 'client.policy'
---@type table sd-phone invoke transport (client.bridge): token-matched request/reply.
local bridge = require 'client.bridge'

---@type table Module table; returned at end of file.
local rpc = {}

---@type table<string, fun(payload: any, cb: fun(result: any))> Device-local handlers, supplied by
---client/main.lua once it has defined them.
local handlers = nil

---Registers the device-local handler set. Called once from client/main.lua after open/close and
---the typing and flashlight state they read exist.
---
---The completeness check is the point of doing this through a bind rather than letting main.lua
---register handlers ad hoc: policy.LOCAL is the authoritative list of what must not be forwarded,
---and an entry there with no implementation here would fall through to sd-phone and drive the
---PHONE's hardware from the tablet's screen. Loud at boot beats subtle in play.
---@param localHandlers table<string, fun(payload: any, cb: fun(result: any))>
function rpc.bind(localHandlers)
    for action in pairs(policy.LOCAL) do
        if type(localHandlers[action]) ~= 'function' then
            error(('sd-tablet: no device-local handler for %s (declared in client/policy.lua)'):format(action))
        end
    end
    handlers = localHandlers
end

---@type fun(...)|nil Debug printer, installed by main.lua when config.Debug is on.
local trace = nil

---Installs a debug printer for refused and forwarded actions.
---@param fn fun(...)|nil
function rpc.setTrace(fn) trace = fn end

---@type table<string, fun(payload: any)> Watchers on forwarded actions, keyed by action name.
local watchers = {}

---Watches a FORWARDED action on its way out, without taking it over: sd-phone still runs it and
---still owns the answer.
---
---Some device state is only ever settled between the page and sd-phone, never announced to Lua at
---all - which lens the Camera app is framing with is decided by an NUI callback and nothing else.
---This device needs it (the hand prop has to be hidden from the player's own rear shot), and the
---envelope passing through here is the only place on this side that carries it.
---@param action string NUI action name
---@param fn fun(payload: any)
function rpc.watch(action, fn) watchers[action] = fn end

---Single NUI entry point. Every action the tablet's UI performs arrives here.
---@param data table|nil { action: string, payload: any }
---@param cb fun(result: any) NUI response
RegisterNUICallback('rpc', function(data, cb)
    ---@type boolean A local handler that answers twice (or throws after answering) must not
    ---produce two HTTP responses for one NUI fetch.
    local answered = false
    local function answer(result)
        if answered then return end
        answered = true
        cb(result)
    end

    local action = type(data) == 'table' and data.action or nil
    if type(action) ~= 'string' or action == '' then
        return answer({ success = false, message = 'Bad request' })
    end

    if policy.denied(action) then
        if trace then trace('denied', action) end
        return answer({ success = false, message = 'Not available on this device', unsupported = true })
    end

    if policy.LOCAL[action] then
        -- Only reachable before rpc.bind runs, i.e. an NUI post during resource start. Answering
        -- honestly is better than forwarding a device action to the other device.
        if not handlers then
            return answer({ success = false, message = 'Device not ready' })
        end
        local ok, err = pcall(handlers[action], data.payload, answer)
        if not ok then
            print(('^1[sd-tablet:rpc]^0 %s failed: %s'):format(action, err))
            answer({ success = false, message = 'Handler error' })
        end
        return
    end

    if trace then trace('forward', action) end
    -- pcall'd: a watcher is an observer, and a broken one must never cost the UI its answer.
    local watcher = watchers[action]
    if watcher then pcall(watcher, data.payload) end
    bridge.invoke(action, data.payload or {}, answer)
end)

return rpc
