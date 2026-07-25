--[[
  TrainerCombat HUD
  Announce only when the player tries to change/recall a Pal DURING a lock.
]]

local Config = require("config")
local SkillCd = require("skill_cd_ui")

local Hud = {
    hooked = false,
    loopStarted = false,
    lastBlockedAnnounceAt = 0,
    palUtil = nil,
}

local function log(msg)
    print("[TrainerCombat] " .. msg)
end

local function getPalUtility()
    if Hud.palUtil ~= nil then
        local ok = pcall(function()
            return Hud.palUtil:IsValid()
        end)
        if ok then
            return Hud.palUtil
        end
    end
    Hud.palUtil = StaticFindObject("/Script/Pal.Default__PalUtility")
    return Hud.palUtil
end

local function getPalPlayerController()
    local ok, pc = pcall(function()
        return FindFirstOf("PalPlayerController")
    end)
    if ok and pc ~= nil and pc:IsValid() then
        return pc
    end
    return nil
end

local function announce(text)
    local util = getPalUtility()
    local pc = getPalPlayerController()
    if util == nil or pc == nil then
        error("missing PalUtility/controller")
    end
    util:SendSystemAnnounce(pc, text)
end

local function chatNotify(text)
    local util = getPalUtility()
    local pc = getPalPlayerController()
    if util == nil or pc == nil then
        error("missing PalUtility/controller")
    end
    local uid = pc:GetPlayerUId()
    util:SendSystemToPlayerChat(pc, text, { uid })
end

local function doAnnounce(msg)
    local ok = pcall(function()
        announce(msg)
    end)
    if ok then
        return true
    end
    return pcall(function()
        chatNotify(msg)
    end)
end

local function tryStepCoolDownTimer()
    if not Config.Hud or not Config.Hud.UseStepCoolDownTimer then
        return
    end
    local pc = getPalPlayerController()
    if pc == nil then
        return
    end
    local ok, err = pcall(function()
        pc:StartStepCoolDownCoolTimer()
    end)
    if ok then
        log("StartStepCoolDownCoolTimer OK")
    else
        log("StartStepCoolDownCoolTimer failed: " .. tostring(err))
    end
end

local function startLoop(getRemainingFn)
    if Hud.loopStarted then
        return
    end
    if LoopAsync == nil then
        return
    end

    Hud.loopStarted = true

    -- Only used to tick experimental skill CD UI (no announce spam).
    LoopAsync(200, function()
        if not Config.Hud or not Config.Hud.Enabled then
            return false
        end
        if not Config.Hud.UseSkillCooldownUI then
            return false
        end

        local ok, rem = pcall(getRemainingFn)
        if not ok or type(rem) ~= "number" or rem <= 0 then
            return false
        end

        pcall(function()
            SkillCd.Tick(rem)
        end)
        return false
    end)
end

--- Public announce helper (e.g. Phase 2A attack boost line).
function Hud.Announce(text)
    if text == nil or text == "" then
        return false
    end
    return doAnnounce(tostring(text))
end

function Hud.Register(getRemainingFn)
    if Hud.hooked then
        return
    end
    if not Config.Hud or not Config.Hud.Enabled then
        log("HUD disabled")
        return
    end
    Hud.hooked = true
    startLoop(getRemainingFn)
    log("HUD ready (announce only on blocked change/recall)")
end

function Hud.NotifyLockStarted(seconds, slotIndex)
    local duration = seconds or Config.SummonLockSeconds or 8.0

    if Config.Hud and Config.Hud.UseSkillCooldownUI then
        pcall(function()
            SkillCd.Start(slotIndex, duration)
        end)
    end

    tryStepCoolDownTimer()
    -- No start announce (by design).
end

--- Called when player tries to swap/summon/recall while locked.
function Hud.NotifyStillLocked(remaining)
    if not Config.Hud or Config.Hud.UseSystemAnnounce == false then
        return
    end

    local nowClock = os.clock()
    local debounce = Config.Hud.BlockedAnnounceDebounce or 0.75
    if (nowClock - Hud.lastBlockedAnnounceAt) < debounce then
        return
    end
    Hud.lastBlockedAnnounceAt = nowClock

    local whole = math.ceil((remaining or 0) - 0.0001)
    if whole < 0 then
        whole = 0
    end

    if doAnnounce("Pal lock: " .. tostring(whole) .. "s left") then
        log("blocked-action announce: " .. tostring(whole) .. "s left")
    end
end

function Hud.NotifyLockEnded(reason)
    pcall(function()
        SkillCd.Stop()
    end)
    -- No "Pal lock cleared" toast — announce only lock CD / sphere CD / orders / skill CD.
    if reason ~= nil and reason ~= "lock expired" then
        log("lock-cleared (" .. tostring(reason) .. ")")
    end
end

return Hud
