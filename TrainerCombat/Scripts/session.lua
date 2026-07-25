--[[
  Shared world-session gate for TrainerCombat.
  Suspend on ClientRestart / unload so hooks and LoopAsync skip FindAllOf
  and UFunction calls on dying objects (ACCESS_VIOLATION on reload).
]]

local Session = {
    alive = true,
    id = 0,
    _onSuspend = {},
    _onResume = {},
}

local MOD = "[TrainerCombat]"

local function log(msg)
    print(string.format("%s %s", MOD, msg))
end

function Session.IsAlive()
    return Session.alive == true
end

function Session.Id()
    return Session.id
end

function Session.OnSuspend(fn)
    if type(fn) == "function" then
        table.insert(Session._onSuspend, fn)
    end
end

function Session.OnResume(fn)
    if type(fn) == "function" then
        table.insert(Session._onResume, fn)
    end
end

function Session.Suspend(reason)
    Session.id = Session.id + 1
    Session.alive = false
    log("session suspend (" .. tostring(reason) .. ") id=" .. tostring(Session.id))
    for _, fn in ipairs(Session._onSuspend) do
        pcall(fn, reason, Session.id)
    end
    return Session.id
end

function Session.Resume(reason)
    if Session.alive then
        return
    end
    Session.alive = true
    log("session resume (" .. tostring(reason) .. ") id=" .. tostring(Session.id))
    for _, fn in ipairs(Session._onResume) do
        pcall(fn, reason, Session.id)
    end
end

--- Run fn after delay only if the same session id is still current AND world is alive.
function Session.Defer(delayMs, fn)
    if type(fn) ~= "function" then
        return
    end
    if ExecuteWithDelay == nil then
        if Session.IsAlive() then
            pcall(fn)
        end
        return
    end
    local id = Session.id
    ExecuteWithDelay(delayMs or 1, function()
        if id ~= Session.id or not Session.IsAlive() then
            return
        end
        pcall(fn)
    end)
end

--- Run fn after delay if session id still matches (even while suspended).
--- Use for resume probes / post-teardown settle — NOT for FindAllOf work.
function Session.After(delayMs, fn)
    if type(fn) ~= "function" then
        return
    end
    if ExecuteWithDelay == nil then
        pcall(fn)
        return
    end
    local id = Session.id
    ExecuteWithDelay(delayMs or 1, function()
        if id ~= Session.id then
            return
        end
        pcall(fn)
    end)
end

return Session
