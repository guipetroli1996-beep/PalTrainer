--[[
  TrainerCombat — summon / swap lock (combat-only gate)

  On summon (ActivateOtomo):
    - if SummonLockOnlyInCombat: only start lock while in combat window
    - else: always start SummonLockSeconds timer
    - disable throw + switch via PalPlayerController flags (real input block)

  Combat window =
    battle mode, damage taken/dealt by player/party, OR recent trainer orders
    (Aim+LMB / Aim+1/2/3). Mere proximity to wild Pals does NOT count.
  Lock starts when:
    - a Pal is sent out (ActivateOtomo) while the combat window is open, OR
    - combat begins while a Pal is already fielded (first hit / battle mode /
      trainer order). Not on recall alone.

  Lock also lifts early when the active Pal dies / is force-inactivated.

  Crash safety: SetDisable* flags are deferred (never inside ActivateOtomo);
  ClientRestart suspends FindAllOf / flag UFunctions until world resumes.

  Announce on blocked attempts (throw/recall only):
    - Keyboard E via RegisterKeyBind
    - Controller L1/LB (Gamepad_LeftShoulder) via poll

  Requires Mods/shared/UEHelpers (ships with UE4SS).
]]

local UEHelpers = require("UEHelpers")
local Config = require("config")
local Session = require("session")
local Hud = require("hud")
local Weapons = require("weapons")
local Schematics = require("schematics")
local Threat = require("threat")
local Attack = require("attack")
local MarkStandby = require("mark_standby")

local MOD = "[TrainerCombat]"
local otomoHooked = false
local deathHooked = false
local combatHooksRegistered = false
local keyBindsRegistered = false
local gamepadPollStarted = false
local FLAG_STRING = "TrainerCombatCD"

-- Forward decls (combat hooks call these before their definitions).
local startDeathWatch

local State = {
    lockUntil = nil,
    unlockToken = 0,
    flagsLocked = false,
    activeSlot = nil,
    lastActivateHandledAt = nil,
    cachedFlagName = nil,
    cachedShoulderFKey = nil,
    lastShoulderDown = false,
    -- Ignore LB that is still held from the summon press that started the lock.
    ignoreShoulderUntil = 0,
    deathWatchToken = 0,
    deathWatchLoopStarted = false,
    holderWatchStarted = false,
    -- Combat-only gate
    battleMode = false,
    lastCombatAt = nil,
    -- True after we armed a lock for the current fight; stays true until combat ends
    -- so hostile/damage cannot re-lock after the timer expires mid-fight.
    lockedThisCombat = false,
    -- False while unloading / main menu / ClientRestart (skip FindAllOf & flag UFunctions).
    worldAlive = true,
    sessionId = 0,
    pendingActivateSlot = nil,
    resumeAfterSuspendAt = nil,
}

local HOLDER_BP =
    "/Game/Pal/Blueprint/Component/OtomoHolder/BP_OtomoPalHolderComponent.BP_OtomoPalHolderComponent_C"

local function now()
    return os.clock()
end

local function log(msg)
    print(string.format("%s %s", MOD, msg))
end

local function debug(msg)
    if Config.Debug then
        log(msg)
    end
end

local function unwrap(param)
    if param == nil then
        return nil
    end
    local ok, val = pcall(function()
        if param.get ~= nil then
            return param:get()
        end
        return param
    end)
    if not ok then
        return param
    end
    local ok2, val2 = pcall(function()
        if val ~= nil and val.get ~= nil then
            return val:get()
        end
        return val
    end)
    if ok2 then
        return val2
    end
    return val
end

local function lockRemaining()
    if State.lockUntil == nil then
        return 0
    end
    local left = State.lockUntil - now()
    if left < 0 then
        return 0
    end
    return left
end

local function isLocked()
    return lockRemaining() > 0
end

local function summonLockOnlyInCombat()
    return Config.Features ~= nil and Config.Features.SummonLockOnlyInCombat == true
end

local function getCombatMemorySeconds()
    local s = Config.CombatMemorySeconds
    if type(s) ~= "number" or s < 0 then
        return 12.0
    end
    return s
end

local function markCombat(reason)
    State.lastCombatAt = now()
    debug("combat marked (" .. tostring(reason) .. ")")
end

local function inCombatWindow()
    if Config.DebugAlwaysInCombat == true then
        return true
    end
    if State.battleMode == true then
        return true
    end
    if State.lastCombatAt ~= nil then
        if (now() - State.lastCombatAt) <= getCombatMemorySeconds() then
            return true
        end
    end
    -- Trainer orders (Aim+LMB / Aim+1/2/3) mark MarkStandby combat — include so
    -- mid-fight pal swap/recall still starts summon lock even before damage hooks fire.
    if MarkStandby ~= nil and MarkStandby.IsPlayerInCombat ~= nil then
        local ok, inTrainerCombat = pcall(function()
            return MarkStandby.IsPlayerInCombat() == true
        end)
        if ok and inTrainerCombat then
            return true
        end
    end
    return false
end

local function endCombatSessionIfNeeded(reason)
    if not State.lockedThisCombat then
        return
    end
    if inCombatWindow() or isLocked() then
        return
    end
    State.lockedThisCombat = false
    State.lastCombatAt = nil
    log("combat session ended — lock may arm again next fight (" .. tostring(reason or "?") .. ")")
end

local function startCombatSessionPoll()
    if State.combatSessionPollStarted or LoopAsync == nil then
        return
    end
    if not summonLockOnlyInCombat() then
        return
    end
    State.combatSessionPollStarted = true
    LoopAsync(500, function()
        if isWorldAlive() and summonLockOnlyInCombat() then
            endCombatSessionIfNeeded("poll")
        end
        return false
    end)
end

local function getFlagName()
    if State.cachedFlagName ~= nil then
        return State.cachedFlagName
    end
    local ok, fname = pcall(function()
        return UEHelpers.FindOrAddFName(FLAG_STRING)
    end)
    if ok and fname ~= nil then
        State.cachedFlagName = fname
        return fname
    end
    ok, fname = pcall(function()
        return FName(FLAG_STRING)
    end)
    if ok then
        State.cachedFlagName = fname
        return fname
    end
    return nil
end

local function getPlayerController()
    -- Never enumerate UObjects while the world is tearing down / on menu.
    if not Session.IsAlive() then
        return nil
    end
    local ok, pc = pcall(function()
        return FindFirstOf("PalPlayerController")
    end)
    if ok and pc ~= nil and pc:IsValid() then
        return pc
    end
    return nil
end

local function worldLooksReadyForResume()
    -- Prefer UEHelpers (no FindFirstOf). Menu / teardown must return false.
    local pc = nil
    pcall(function()
        if UEHelpers.GetPlayerController ~= nil then
            pc = UEHelpers.GetPlayerController()
        end
    end)
    local okPc = false
    pcall(function()
        okPc = pc ~= nil and pc:IsValid() == true
    end)
    if not okPc then
        return false
    end

    local pawn = nil
    pcall(function()
        pawn = pc:K2_GetPawn()
    end)
    if pawn == nil then
        pcall(function()
            pawn = pc:GetControlledPawn()
        end)
    end
    local okPawn = false
    pcall(function()
        okPawn = pawn ~= nil and pawn:IsValid() == true
    end)
    if not okPawn then
        return false
    end

    local name = nil
    pcall(function()
        name = pawn:GetFullName()
    end)
    if type(name) ~= "string" then
        return false
    end
    -- Title/menu pawns are not PalPlayerCharacter.
    if string.find(name, "PalPlayerCharacter", 1, true)
        or string.find(name, "BP_Player_", 1, true)
        or string.find(name, "PlayerCharacter", 1, true) then
        return true
    end
    return false
end

local function isWorldAlive()
    return Session.IsAlive()
end

local function beginWorldSuspend(reason)
    Session.Suspend(reason)
    State.sessionId = Session.Id()
    State.worldAlive = false
    State.unlockToken = State.unlockToken + 1
    State.deathWatchToken = State.deathWatchToken + 1
    State.lockUntil = nil
    State.lockStartedAt = nil
    State.flagsLocked = false
    State.battleMode = false
    State.lastCombatAt = nil
    State.lockedThisCombat = false
    State.lockedOtomoName = nil
    State.lockedOtomoRef = nil
    State.sawLiveOtomoThisLock = false
    State.activeSlot = nil
    State.pendingActivateSlot = nil
    State.resumeAfterSuspendAt = now()
end

local function endWorldSuspend(reason)
    if Session.IsAlive() then
        State.worldAlive = true
        return
    end
    Session.Resume(reason)
    State.worldAlive = true
    State.sessionId = Session.Id()
end

--- Resume only when gameplay world looks ready (never mid-ClientRestart).
local function trySafeResume(reason)
    if Session.IsAlive() then
        return true
    end
    if not worldLooksReadyForResume() then
        return false
    end
    endWorldSuspend(reason)
    return true
end

local function scheduleSafeResumeProbes(reason)
    local delays = { 2500, 5000, 8000, 12000 }
    for _, ms in ipairs(delays) do
        Session.After(ms, function()
            if Session.IsAlive() then
                return
            end
            if trySafeResume(tostring(reason) .. "+" .. tostring(ms) .. "ms") then
                -- Session.OnResume already asked MarkStandby to restore trainer mode.
                -- If ActivateOtomo was queued during suspend, re-arm modules too.
                local slot = State.pendingActivateSlot
                if slot ~= nil then
                    State.pendingActivateSlot = nil
                    State.activeSlot = slot
                    Session.Defer(500, function()
                        pcall(function()
                            Threat.OnPalActivated(slot)
                        end)
                        pcall(function()
                            Attack.OnPalActivated(slot)
                        end)
                        pcall(function()
                            MarkStandby.OnPalActivated(slot)
                        end)
                    end)
                else
                    -- Ride ClientRestart often has no pending slot — reassert standby.
                    Session.Defer(300, function()
                        pcall(function()
                            MarkStandby.OnSessionResume("resume-probe+" .. tostring(ms) .. "ms")
                        end)
                    end)
                end
            end
        end)
    end
end

local function applyDisableFlags(disabled, reason)
    if not Config.Features.UseGameDisableFlags then
        return
    end
    -- Never touch controllers while the world is tearing down / on main menu.
    if not isWorldAlive() then
        debug("flags skipped — world suspended (" .. tostring(reason) .. ")")
        if disabled == false then
            State.flagsLocked = false
        end
        return
    end

    local function doApply()
        if not isWorldAlive() then
            return
        end
        local fname = getFlagName()
        if fname == nil then
            log("flags skipped — could not create FName (" .. tostring(reason) .. ")")
            return
        end

        -- SP: only the local controller. FindAllOf during menu/reload can crash.
        local pc = getPlayerController()
        if pc == nil then
            log("flags skipped — no PalPlayerController (" .. tostring(reason) .. ")")
            if disabled == false then
                State.flagsLocked = false
            end
            return
        end

        local okThrow, errThrow = pcall(function()
            pc:SetDisableThrowPalFlag(fname, disabled)
        end)
        local okSwitch, errSwitch = pcall(function()
            pc:SetDisableSwitchPalFlag(fname, disabled)
        end)

        State.flagsLocked = disabled
        log(string.format(
            "flags disabled=%s reason=%s throw=%s switch=%s",
            tostring(disabled),
            tostring(reason),
            okThrow and "ok" or tostring(errThrow),
            okSwitch and "ok" or tostring(errSwitch)
        ))
    end

    -- Prefer deferred apply — calling SetDisable* inside ActivateOtomo crashes.
    if ExecuteWithDelay ~= nil then
        local session = Session.Id()
        local wantDisable = disabled == true
        ExecuteWithDelay(1, function()
            if session ~= Session.Id() or not Session.IsAlive() then
                return
            end
            if wantDisable then
                if not isLocked() then
                    return
                end
            else
                if isLocked() then
                    return
                end
            end
            pcall(doApply)
        end)
    else
        pcall(doApply)
    end
end

--- Death/timer unlock: clear flags now and again shortly after (game can re-assert disable).
local function forceClearDisableFlags(reason)
    if not isWorldAlive() then
        State.flagsLocked = false
        return
    end
    applyDisableFlags(false, reason)
    if ExecuteWithDelay == nil then
        return
    end
    local token = State.unlockToken
    local session = Session.Id()
    ExecuteWithDelay(50, function()
        if token ~= State.unlockToken or session ~= Session.Id() then
            return
        end
        if isLocked() or not Session.IsAlive() then
            return
        end
        applyDisableFlags(false, reason .. " +50ms")
    end)
    ExecuteWithDelay(300, function()
        if token ~= State.unlockToken or session ~= Session.Id() then
            return
        end
        if isLocked() or not Session.IsAlive() then
            return
        end
        applyDisableFlags(false, reason .. " +300ms")
    end)
    ExecuteWithDelay(1000, function()
        if token ~= State.unlockToken or session ~= Session.Id() then
            return
        end
        if isLocked() or not Session.IsAlive() then
            return
        end
        applyDisableFlags(false, reason .. " +1s")
    end)
end

local function scheduleUnlock()
    State.unlockToken = State.unlockToken + 1
    local token = State.unlockToken
    local delayMs = math.floor(Config.SummonLockSeconds * 1000) + 50

    if ExecuteWithDelay == nil then
        log("WARNING: ExecuteWithDelay missing — flags may stay locked")
        return
    end

    ExecuteWithDelay(delayMs, function()
        if token ~= State.unlockToken then
            return
        end
        if not isWorldAlive() then
            State.lockUntil = nil
            return
        end
        State.deathWatchToken = State.deathWatchToken + 1
        State.lockUntil = nil
        State._otomoMissingSince = nil
        forceClearDisableFlags("lock expired")
        pcall(function()
            Hud.NotifyLockEnded("lock expired")
        end)
        log("summon lock expired (timer)")
    end)
end

local function startSummonLock(reason)
    if not isWorldAlive() then
        endWorldSuspend("summon-lock")
    end
    -- Cancel any previous unlock timer / death watch from a prior summon.
    State.unlockToken = State.unlockToken + 1
    State.deathWatchToken = State.deathWatchToken + 1
    State.lockUntil = now() + Config.SummonLockSeconds
    State.lockStartedAt = now()
    State.sawLiveOtomoThisLock = false
    State.lockedOtomoName = nil
    State.lockedOtomoRef = nil
    State._otomoMissingSince = nil
    State._otomoDownSince = nil
    -- Same LB press that summons is still held; do not treat it as a blocked attempt.
    State.lastShoulderDown = true
    State.ignoreShoulderUntil = now() + 0.45
    log(string.format(
        "summon lock started (%.1fs) via %s",
        Config.SummonLockSeconds,
        tostring(reason)
    ))
    -- Deferred inside applyDisableFlags (safe outside ActivateOtomo stack).
    applyDisableFlags(true, reason)
    scheduleUnlock()
    pcall(function()
        Hud.NotifyLockStarted(Config.SummonLockSeconds, State.activeSlot)
    end)
end

local function clearLock(reason)
    State.unlockToken = State.unlockToken + 1
    State.deathWatchToken = State.deathWatchToken + 1
    State.lockUntil = nil
    State.lockStartedAt = nil
    State.sawLiveOtomoThisLock = false
    State.lockedOtomoName = nil
    State.lockedOtomoRef = nil
    State._otomoMissingSince = nil
    State._otomoDownSince = nil
    if isWorldAlive() then
        forceClearDisableFlags(reason)
    else
        State.flagsLocked = false
    end
    log("lock cleared (" .. tostring(reason) .. ")")
end

local function getLocalPlayerCharacter()
    local pc = getPlayerController()
    if pc == nil then
        return nil
    end
    local char = nil
    pcall(function()
        char = pc:K2_GetPawn()
    end)
    if char ~= nil and char:IsValid() then
        return char
    end
    pcall(function()
        char = pc:GetControlledPawn()
    end)
    if char ~= nil and char:IsValid() then
        return char
    end
    return nil
end

local function getActiveOtomoActor()
    if not isWorldAlive() then
        return nil
    end
    local slot = State.activeSlot
    local fromHolder = nil
    if slot ~= nil then
        pcall(function()
            local holder = FindFirstOf("BP_OtomoPalHolderComponent_C")
            if holder ~= nil and holder:IsValid() then
                fromHolder = holder:TryGetOtomoActorBySlotIndex(slot)
            end
        end)
        if fromHolder ~= nil and fromHolder:IsValid() then
            return fromHolder
        end
    end

    local char = getLocalPlayerCharacter()
    if char == nil then
        return nil
    end
    local otomo = nil
    pcall(function()
        local param = char.CharacterParameterComponent
        if param ~= nil and param:IsValid() then
            otomo = param.OtomoPal
        end
    end)
    if otomo ~= nil and otomo:IsValid() then
        return otomo
    end
    return nil
end

local function hasActiveOtomoOut()
    local otomo = getActiveOtomoActor()
    if otomo == nil then
        return false
    end
    local ok = false
    pcall(function()
        ok = otomo:IsValid() == true
    end)
    return ok
end

--- Start lock when SummonLock wants it (combat gate applied here).
--- Pal change/summon while in combat ALWAYS re-locks (even after a prior timer).
local function maybeStartSummonLock(reason)
    if not Config.Features.SummonLock then
        return false
    end
    if summonLockOnlyInCombat() and not inCombatWindow() then
        log(string.format(
            "summon lock skipped — out of combat (%s)",
            tostring(reason)
        ))
        return false
    end
    startSummonLock(reason)
    if summonLockOnlyInCombat() then
        State.lockedThisCombat = true
    end
    return true
end

--- Mark combat window. If a Pal is already out and we have not locked yet this
--- fight, start summon lock immediately (fixes free mid-fight swaps before the
--- next ActivateOtomo — damage/battle often arrive only after the first swap).
local function markCombatFromEvent(reason)
    if not Config.Features.SummonLock or not summonLockOnlyInCombat() then
        return
    end
    if not isWorldAlive() then
        return
    end
    markCombat(reason)

    if isLocked() then
        return
    end
    -- One lock arm from combat-start per fight; ActivateOtomo still re-locks later.
    if State.lockedThisCombat then
        return
    end
    if State.activeSlot == nil then
        return
    end
    if maybeStartSummonLock("combat-" .. tostring(reason or "?")) then
        startDeathWatch()
    end
end

--- True if actor is the local player or their active party Pal.
local function isLocalTrainerSideActor(actor)
    if actor == nil then
        return false
    end
    local function sameActor(a, b)
        if a == nil or b == nil then
            return false
        end
        if a == b then
            return true
        end
        local ok = false
        pcall(function()
            ok = a:GetFullName() == b:GetFullName()
        end)
        return ok == true
    end
    local player = getLocalPlayerCharacter()
    if sameActor(actor, player) then
        return true
    end
    local otomo = getActiveOtomoActor()
    if sameActor(actor, otomo) then
        return true
    end
    return false
end

--- Damage taken by OR dealt by player/party → combat window (no auto-lock).
local function onCombatRelevantDamage(attacker, defender, reasonTag)
    if not isWorldAlive() then
        return
    end
    local took = isLocalTrainerSideActor(defender)
    local dealt = isLocalTrainerSideActor(attacker)
    if not took and not dealt then
        return
    end
    if took and dealt then
        markCombatFromEvent(reasonTag or "damage-both")
    elseif took then
        markCombatFromEvent(reasonTag or "damage-taken")
    else
        markCombatFromEvent(reasonTag or "damage-dealt")
    end
end

local function onProcessDamageForCombat(Context, Info)
    local comp = unwrap(Context)
    local defender = nil
    pcall(function()
        if comp ~= nil and comp.GetOwner ~= nil then
            defender = comp:GetOwner()
        end
    end)
    local info = unwrap(Info)
    local attacker = nil
    pcall(function()
        if info ~= nil then
            attacker = info.Attacker
        end
    end)
    onCombatRelevantDamage(attacker, defender, "ProcessDamage")
end

local function onPlayerBattleModeChanged(isBattle)
    if not isWorldAlive() then
        return
    end
    local wasBattle = State.battleMode == true
    State.battleMode = isBattle == true
    if State.battleMode then
        markCombatFromEvent("battle-mode")
    elseif wasBattle and summonLockOnlyInCombat() then
        if isLocked() and not inCombatWindow() then
            clearLock("left combat")
            pcall(function()
                Hud.NotifyLockEnded("left combat")
            end)
        end
        endCombatSessionIfNeeded("battle-mode-off")
    end
    log(string.format(
        "battle mode=%s combatWindow=%s lockedThisCombat=%s",
        tostring(State.battleMode),
        tostring(inCombatWindow()),
        tostring(State.lockedThisCombat)
    ))
end

local function registerCombatHooks()
    if combatHooksRegistered then
        return
    end
    combatHooksRegistered = true

    -- Hate pulse only while combat window is open (wired even if combat-only lock is off).
    Threat.IsInCombat = function()
        return inCombatWindow()
    end

    if not summonLockOnlyInCombat() then
        log("combat-only summon lock OFF (always lock after summon)")
        return
    end

    local okBattle, errBattle = pcall(function()
        RegisterHook(
            "/Script/Pal.PalPlayerCharacter:OnChangePlayerBattleMode",
            function(Context, IsBattle)
                local battle = unwrap(IsBattle)
                if type(battle) ~= "boolean" then
                    pcall(function()
                        if battle ~= nil and battle.get ~= nil then
                            battle = battle:get()
                        end
                    end)
                end
                onPlayerBattleModeChanged(battle == true)
            end
        )
    end)
    if okBattle then
        log("hooked OnChangePlayerBattleMode (combat-only lock)")
    else
        log("OnChangePlayerBattleMode hook failed: " .. tostring(errBattle))
    end

    pcall(function()
        RegisterHook(
            "/Script/Pal.PalCharacter:OnChangeBattleMode",
            function(Context, bIsBattleMode)
                local char = unwrap(Context)
                local localChar = getLocalPlayerCharacter()
                if char == nil or localChar == nil then
                    return
                end
                local same = false
                pcall(function()
                    same = char:GetFullName() == localChar:GetFullName()
                end)
                if not same then
                    return
                end
                local battle = unwrap(bIsBattleMode)
                onPlayerBattleModeChanged(battle == true)
            end
        )
        log("hooked PalCharacter:OnChangeBattleMode (combat-only lock)")
    end)

    -- Damage taken by OR dealt by player / party Pal.
    local okProc, errProc = pcall(function()
        RegisterHook(
            "/Script/Pal.PalDamageReactionComponent:ProcessDamage_ToServer",
            onProcessDamageForCombat
        )
    end)
    if okProc then
        log("hooked ProcessDamage_ToServer (damage taken/dealt → combat)")
    else
        log("ProcessDamage_ToServer combat hook failed: " .. tostring(errProc))
    end

    local okDmg, errDmg = pcall(function()
        RegisterHook(
            "/Script/Pal.PalPlayerCharacter:OnDamagePlayer_Server",
            function()
                if not isWorldAlive() then
                    return
                end
                markCombatFromEvent("damage-taken")
            end
        )
    end)
    if okDmg then
        log("hooked OnDamagePlayer_Server (damage taken → combat window)")
    else
        log("OnDamagePlayer_Server combat hook failed: " .. tostring(errDmg))
    end

    -- Primary: hostile AI targeting player / party Pal → combat window only (no auto-lock).
    -- NOTE: do NOT arm combat from hate-pulse "ai-engaged" alone — that made
    -- summon → pulse → combat → more pulse. Combat comes from damage / battle mode.
    Threat.OnHostileDetected = function(reason)
        -- Intentionally ignore pulse-sourced engagement for combat window.
        debug("hostile noted (no combat arm from pulse): " .. tostring(reason))
    end

    -- Hate pulse only while our existing combat window is open.
    Threat.IsInCombat = function()
        return inCombatWindow()
    end

    log(string.format(
        "combat-only summon lock ON (memory=%.1fs) — lock on send-out in combat, or combat-start with Pal out",
        getCombatMemorySeconds()
    ))
    startCombatSessionPoll()
end

local function actorNamesEqual(a, b)
    if a == nil or b == nil then
        return false
    end
    if a == b then
        return true
    end
    local same = false
    pcall(function()
        same = a:GetFullName() == b:GetFullName()
    end)
    return same == true
end

local function actorFullName(actor)
    if actor == nil then
        return nil
    end
    local ok, name = pcall(function()
        return actor:GetFullName()
    end)
    if ok and type(name) == "string" then
        return name
    end
    return nil
end

local function getFixedPointLib()
    local ok, lib = pcall(function()
        return StaticFindObject("/Script/Pal.Default__FixedPoint64MathLibrary")
    end)
    if ok and lib ~= nil then
        return lib
    end
    return nil
end

local function fixedPointToNumber(fp)
    if fp == nil then
        return nil
    end
    if type(fp) == "number" then
        return fp
    end
    local lib = getFixedPointLib()
    if lib ~= nil then
        local ok, n = pcall(function()
            return lib:Convert_FixedPoint64ToInt(fp)
        end)
        if ok and type(n) == "number" then
            return n
        end
        ok, n = pcall(function()
            return lib:Convert_FixedPoint64ToFloat(fp)
        end)
        if ok and type(n) == "number" then
            return n
        end
    end
    local ok2, n2 = pcall(function()
        return fp.Value
    end)
    if ok2 and type(n2) == "number" and n2 <= 0 then
        return 0
    end
    return nil
end

local function readActorHp(actor)
    if actor == nil then
        return nil
    end
    local hp = nil
    pcall(function()
        if not actor:IsValid() then
            return
        end
        local param = actor.CharacterParameterComponent
        if param ~= nil and param:IsValid() then
            hp = fixedPointToNumber(param:GetHP())
        end
    end)
    return hp
end

--- Hard death only — never use IsLive() (false positives on fresh summons).
local function isHardDead(actor)
    if actor == nil then
        return true
    end
    local valid = false
    pcall(function()
        valid = actor:IsValid() == true
    end)
    if not valid then
        return true
    end

    local dead = false
    pcall(function()
        local param = actor.CharacterParameterComponent
        if param == nil or not param:IsValid() then
            return
        end
        if param:IsDead() == true then
            dead = true
            return
        end
        local hp = fixedPointToNumber(param:GetHP())
        if hp ~= nil and hp <= 0 then
            dead = true
        end
    end)
    if dead then
        return true
    end
    pcall(function()
        if actor:IsDead() == true then
            dead = true
        end
    end)
    return dead == true
end

local function rememberLiveOtomo(otomo)
    if otomo == nil or not otomo:IsValid() then
        return false
    end
    if isHardDead(otomo) then
        return false
    end
    -- Prefer confirming HP > 0 when readable
    local hp = readActorHp(otomo)
    if hp ~= nil and hp <= 0 then
        return false
    end
    State.sawLiveOtomoThisLock = true
    local name = actorFullName(otomo)
    if name ~= nil then
        State.lockedOtomoName = name
    end
    State.lockedOtomoRef = otomo
    return true
end

--- Only the currently locked / active otomo — NOT any previous dead party Pal.
local function isCurrentLockedOtomo(actor)
    if actor == nil or not actor:IsValid() then
        return false
    end

    local active = getActiveOtomoActor()
    if active ~= nil and actorNamesEqual(actor, active) then
        return true
    end

    if State.lockedOtomoRef ~= nil and actorNamesEqual(actor, State.lockedOtomoRef) then
        return true
    end

    if State.lockedOtomoName ~= nil then
        local name = actorFullName(actor)
        if name ~= nil and name == State.lockedOtomoName then
            return true
        end
    end

    return false
end

local function hasLivingActiveOtomo()
    if MarkStandby ~= nil and MarkStandby.IsRiding ~= nil and MarkStandby.IsRiding() then
        return true
    end
    local otomo = getActiveOtomoActor()
    if otomo == nil then
        return false
    end
    return not isHardDead(otomo)
end

--- True if this death/inactivate should lift the current summon lock.
local function shouldUnlockForDeadActor(selfActor)
    if not isLocked() then
        return false
    end

    if isCurrentLockedOtomo(selfActor) then
        return true
    end

    if hasLivingActiveOtomo() then
        local active = getActiveOtomoActor()
        if active ~= nil and not actorNamesEqual(active, selfActor) then
            return false
        end
    end

    local localChar = getLocalPlayerCharacter()
    if localChar == nil or selfActor == nil then
        return not hasLivingActiveOtomo()
    end

    local valid = false
    pcall(function()
        valid = selfActor:IsValid() == true
    end)
    if not valid then
        return not hasLivingActiveOtomo()
    end

    local isMine = false
    pcall(function()
        local param = selfActor.CharacterParameterComponent
        if param == nil or not param:IsValid() then
            return
        end
        if param:IsOtomo() ~= true then
            return
        end
        local trainer = param.Trainer
        if trainer == nil then
            trainer = param:GetTrainer()
        end
        isMine = actorNamesEqual(trainer, localChar)
    end)
    return isMine
end

--- Lift summon lock + threat state when the active Pal is gone (death / forced inactivate).
local function handleActivePalLost(reason)
    local wasLocked = isLocked() or State.flagsLocked
    local hadSlot = State.activeSlot ~= nil

    if not wasLocked and not hadSlot then
        return
    end

    log("active Pal lost — " .. tostring(reason) .. (wasLocked and " (lifting lock)" or ""))
    if wasLocked then
        clearLock(reason)
        pcall(function()
            Hud.NotifyLockEnded(reason)
        end)
    end
    pcall(function()
        Threat.OnPalRecalled(reason)
    end)
    pcall(function()
        Attack.OnPalRecalled(reason)
    end)
    pcall(function()
        MarkStandby.OnPalRecalled(reason)
    end)
    State.activeSlot = nil
    State.lockedOtomoRef = nil
end

startDeathWatch = function()
    State.deathWatchToken = State.deathWatchToken + 1
    if LoopAsync == nil then
        log("WARNING: LoopAsync missing — death watch unavailable")
        return
    end

    -- Single long-lived loop (do not stack a new LoopAsync per lock / pal swap).
    if State.deathWatchLoopStarted then
        log("death watch armed (reuse loop)")
        return
    end
    State.deathWatchLoopStarted = true
    log("death watch loop started (once)")

    LoopAsync(200, function()
        if not isWorldAlive() then
            return false
        end
        if not isLocked() then
            return false
        end

        local otomo = getActiveOtomoActor()

        -- Spawn grace: capture live actor only, never unlock.
        if State.lockStartedAt ~= nil and (now() - State.lockStartedAt) < 2.5 then
            if otomo ~= nil then
                if rememberLiveOtomo(otomo) then
                    State._otomoMissingSince = nil
                end
            end
            return false
        end

        if otomo ~= nil and not isHardDead(otomo) then
            rememberLiveOtomo(otomo)
            State._otomoMissingSince = nil
            return false
        end

        if not State.sawLiveOtomoThisLock then
            if otomo ~= nil then
                rememberLiveOtomo(otomo)
            end
            return false
        end

        if otomo ~= nil and isHardDead(otomo) then
            handleActivePalLost("otomo hard-dead while locked")
            return false
        end

        if State.lockedOtomoRef ~= nil and isHardDead(State.lockedOtomoRef) then
            handleActivePalLost("locked otomo ref hard-dead")
            return false
        end

        if otomo == nil then
            if State._otomoMissingSince == nil then
                State._otomoMissingSince = now()
                log("death watch: otomo missing…")
                return false
            end
            if (now() - State._otomoMissingSince) >= 0.6 then
                handleActivePalLost("otomo missing while locked")
            end
            return false
        end

        return false
    end)
end

local function announceIfLocked(reason)
    if not Config.Features.SummonLock then
        return false
    end
    if not isLocked() then
        return false
    end

    local left = lockRemaining()
    log(string.format("%s while locked (%.1fs left)", tostring(reason), left))
    pcall(function()
        Hud.NotifyStillLocked(left)
    end)
    return true
end

local function onActivateOtomo(self, SlotId, StartTransform, IsSuccess)
    local slot = unwrap(SlotId)

    -- While suspended (menu / reload), do NOT resume or Find* in this frame.
    -- Save load often fires ActivateOtomo mid-construction → AV if we pulse hate now.
    if not Session.IsAlive() then
        State.pendingActivateSlot = slot
        debug("ActivateOtomo deferred until world settle (slot=" .. tostring(slot) .. ")")
        scheduleSafeResumeProbes("ActivateOtomo")
        return
    end

    if State.lastActivateHandledAt ~= nil and (now() - State.lastActivateHandledAt) < 0.40 then
        debug("ActivateOtomo ignored (debounce)")
        return
    end
    State.lastActivateHandledAt = now()

    if Config.Features.LogOtomoEvents then
        log("ActivateOtomo slot=" .. tostring(slot))
    end

    if Config.Features.SummonLock and announceIfLocked("ActivateOtomo") then
        return
    end

    State.activeSlot = slot
    State.lockedOtomoRef = nil
    State.pendingActivateSlot = nil

    -- Defer Threat/Attack work — unsafe inside ActivateOtomo UFunction.
    local activateSlot = slot
    local function afterActivate()
        if not isWorldAlive() then
            return
        end
        pcall(function()
            Threat.OnPalActivated(activateSlot)
        end)
        pcall(function()
            Attack.OnPalActivated(activateSlot)
        end)
        pcall(function()
            MarkStandby.OnPalActivated(activateSlot)
        end)
        if Config.Features.SummonLock then
            if maybeStartSummonLock("ActivateOtomo") then
                startDeathWatch()
                Session.Defer(500, function()
                    if not isLocked() then
                        return
                    end
                    local otomo = getActiveOtomoActor()
                    if rememberLiveOtomo(otomo) then
                        log("death watch: locked otomo captured hp=" .. tostring(readActorHp(otomo)))
                    end
                end)
                Session.Defer(1500, function()
                    if not isLocked() then
                        return
                    end
                    local otomo = getActiveOtomoActor()
                    if rememberLiveOtomo(otomo) then
                        log("death watch: locked otomo re-captured hp=" .. tostring(readActorHp(otomo)))
                    end
                end)
            end
        end
    end

    Session.Defer(1, afterActivate)
end

local function onInactivateCurrentOtomo(self)
    if not isWorldAlive() then
        return
    end
    if Config.Features.LogOtomoEvents then
        log("InactivateCurrentOtomo")
    end

    -- Riding mounts the active Pal; game may fire inactivate without a real recall.
    if MarkStandby ~= nil and MarkStandby.IsRiding ~= nil and MarkStandby.IsRiding() then
        log("InactivateCurrentOtomo ignored — player is riding")
        return
    end

    if Config.Features.SummonLock and isLocked() then
        -- A delayed inactivate from a previous dead Pal must not clear a new lock
        -- while the replacement Pal is alive.
        if hasLivingActiveOtomo() then
            debug("InactivateCurrentOtomo ignored during lock — living otomo present")
            return
        end
        handleActivePalLost("InactivateCurrentOtomo during lock")
        return
    end

    pcall(function()
        Threat.OnPalRecalled("InactivateCurrentOtomo")
    end)
    pcall(function()
        Attack.OnPalRecalled("InactivateCurrentOtomo")
    end)
    pcall(function()
        MarkStandby.OnPalRecalled("InactivateCurrentOtomo")
    end)
    State.activeSlot = nil
    debug("InactivateCurrentOtomo allowed")
end

local function onOtomoDeadDelegate(Context, DeadInfo)
    if not isWorldAlive() then
        return
    end
    if not Config.Features.SummonLock then
        return
    end
    if not isLocked() and State.activeSlot == nil then
        return
    end

    local info = nil
    pcall(function()
        info = DeadInfo:get()
    end)
    local selfActor = nil
    pcall(function()
        selfActor = info.SelfActor
    end)
    if selfActor == nil then
        pcall(function()
            local comp = unwrap(Context)
            if comp ~= nil then
                selfActor = comp:GetOwner()
            end
        end)
    end

    log("death delegate fired (locked=" .. tostring(isLocked()) .. ")")
    if not shouldUnlockForDeadActor(selfActor) then
        debug("death event ignored (not unlockable for current lock)")
        return
    end

    handleActivePalLost("CallDeadDelegate (otomo death)")
end

local function registerDeathHooks()
    if deathHooked then
        return
    end
    deathHooked = true

    pcall(function()
        RegisterHook("/Script/Pal.PalDamageReactionComponent:CallDeadDelegate_ToALL", onOtomoDeadDelegate)
        log("hooked CallDeadDelegate_ToALL (lift lock on otomo death)")
    end)

    pcall(function()
        RegisterHook("/Script/Pal.PalDamageReactionComponent:ProcessDeath_ToServer", function(Context)
            if not isWorldAlive() then
                return
            end
            if not Config.Features.SummonLock or not isLocked() then
                return
            end
            local owner = nil
            pcall(function()
                local comp = unwrap(Context)
                if comp ~= nil then
                    owner = comp:GetOwner()
                end
            end)
            log("ProcessDeath_ToServer during lock")
            if shouldUnlockForDeadActor(owner) then
                handleActivePalLost("ProcessDeath_ToServer")
            end
        end)
        log("hooked ProcessDeath_ToServer (lift lock on otomo death)")
    end)

    pcall(function()
        RegisterHook("/Script/Pal.PalCharacter:OnInactivatedAsOtomo", function(Context)
            if not isWorldAlive() then
                return
            end
            if not Config.Features.SummonLock or not isLocked() then
                return
            end
            if MarkStandby ~= nil and MarkStandby.IsRiding ~= nil and MarkStandby.IsRiding() then
                debug("OnInactivatedAsOtomo ignored — riding")
                return
            end
            local actor = unwrap(Context)
            log("OnInactivatedAsOtomo during lock")
            if shouldUnlockForDeadActor(actor) then
                handleActivePalLost("OnInactivatedAsOtomo")
            end
        end)
        log("hooked OnInactivatedAsOtomo (lift lock)")
    end)

    pcall(function()
        RegisterHook("/Script/Pal.PalAbilityPassiveSkill:OnInactivatedAsOtomo", function(Context)
            if not isWorldAlive() then
                return
            end
            if not Config.Features.SummonLock or not isLocked() then
                return
            end
            if MarkStandby ~= nil and MarkStandby.IsRiding ~= nil and MarkStandby.IsRiding() then
                debug("AbilityPassive OnInactivatedAsOtomo ignored — riding")
                return
            end
            log("AbilityPassive OnInactivatedAsOtomo during lock")
            handleActivePalLost("AbilityPassive OnInactivatedAsOtomo")
        end)
    end)
end

local function getShoulderFKey()
    if State.cachedShoulderFKey ~= nil then
        return State.cachedShoulderFKey
    end
    local ok, fkey = pcall(function()
        local fname = UEHelpers.FindOrAddFName("Gamepad_LeftShoulder")
        return { KeyName = fname }
    end)
    if ok and fkey ~= nil then
        State.cachedShoulderFKey = fkey
        return fkey
    end
    return nil
end

local function isLeftShoulderDown()
    local pc = getPlayerController()
    if pc == nil then
        return false
    end
    local fkey = getShoulderFKey()
    if fkey == nil then
        return false
    end

    -- Edge-detect held state only. WasInputKeyJustPressed can latch the summon press.
    local ok, down = pcall(function()
        return pc:IsInputKeyDown(fkey)
    end)
    return ok and down == true
end

-- Keyboard throw/recall: E only (RegisterKeyBind has no gamepad support).
local function registerBlockedAttemptKeyBinds()
    if keyBindsRegistered then
        return
    end
    if RegisterKeyBind == nil or Key == nil or Key.E == nil then
        log("WARNING: RegisterKeyBind/Key.E missing — keyboard announce may not work")
        return
    end
    keyBindsRegistered = true

    local ok, err = pcall(function()
        RegisterKeyBind(Key.E, function()
            announceIfLocked("Key.E")
        end)
    end)
    if ok then
        log("blocked-attempt keybind: E")
    else
        log("blocked-attempt keybind E failed: " .. tostring(err))
    end
end

-- Controller throw/recall: L1 / LB = Gamepad_LeftShoulder
local function startGamepadAnnouncePoll()
    if gamepadPollStarted then
        return
    end
    if LoopAsync == nil then
        log("WARNING: LoopAsync missing — controller L1 announce unavailable")
        return
    end
    gamepadPollStarted = true

    LoopAsync(50, function()
        if not isWorldAlive() or not isLocked() then
            State.lastShoulderDown = false
            return false
        end

        local down = isLeftShoulderDown()
        if now() < State.ignoreShoulderUntil then
            -- Keep synced to the summon hold so release→press later can announce.
            State.lastShoulderDown = down
            return false
        end

        if down and not State.lastShoulderDown then
            announceIfLocked("Gamepad_LeftShoulder")
        end
        State.lastShoulderDown = down
        return false
    end)

    log("blocked-attempt poll: Gamepad_LeftShoulder (L1/LB)")
end

local function registerOtomoHooks()
    if otomoHooked then
        return
    end
    otomoHooked = true

    RegisterHook(HOLDER_BP .. ":ActivateOtomo", onActivateOtomo)

    pcall(function()
        RegisterHook(HOLDER_BP .. ":InactivateCurrentOtomo", onInactivateCurrentOtomo)
    end)

    log("otomo hooks registered")
end

--------------------------------------------------
-- Boot
--------------------------------------------------

log("loaded (summon-lock + weapons + threat + attack + mark-standby + logicmod-bridge)")
debug(string.format(
    "SummonLock=%.1fs OnlyInCombat=%s CombatMemory=%.1fs PreferPalAggro=%s AttackScaleBase=%s MarkStandby=%s LogicMod=%s",
    Config.SummonLockSeconds,
    tostring(Config.Features.SummonLockOnlyInCombat == true),
    getCombatMemorySeconds(),
    tostring(Config.Features.PreferPalAggro),
    tostring(Config.AttackScaleBase or 100),
    tostring(Config.Features.MarkStandby == true),
    tostring((Config.MarkStandby and Config.MarkStandby.LogicMod and Config.MarkStandby.LogicMod.Enabled) ~= false)
))

Hud.Register(lockRemaining)
Weapons.Register()
Schematics.Register()
Threat.Register()
Attack.Register()
MarkStandby.Register()
-- Bridge trainer combat notes into summon-lock combat window (Aim+LMB / skills).
MarkStandby.OnCombatNoted = function(reason)
    markCombatFromEvent("trainer-" .. tostring(reason or "note"))
end
registerDeathHooks()
registerCombatHooks()

-- Announce listeners can start at mod load (do not need otomo holder).
registerBlockedAttemptKeyBinds()
startGamepadAnnouncePoll()

local function watchForOtomoHolder(reason)
    debug("watching for otomo holder (" .. reason .. ")")

    -- Boot only: safe to probe once at mod start. Never during ClientRestart.
    if reason == "mod-start" then
        pcall(function()
            local existing = FindFirstOf("BP_OtomoPalHolderComponent_C")
            if existing ~= nil and existing:IsValid() then
                debug("found existing otomo holder")
                registerOtomoHooks()
            end
        end)
    end

    if State.holderWatchStarted then
        return
    end
    State.holderWatchStarted = true
    NotifyOnNewObject(HOLDER_BP, function(Component)
        -- Do NOT resume session here — holder spawn is too early and caused
        -- third-load AVs after combat. Only register hooks, deferred.
        debug("Otomo holder created (deferred hook register)")
        Session.Defer(200, function()
            registerOtomoHooks()
        end)
    end)
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(Context)
    debug("ClientRestart")
    -- Suspend FIRST. Do NOT FindFirstOf/FindAllOf here — that AVs on reload.
    beginWorldSuspend("ClientRestart")
    pcall(function()
        Threat.OnPalRecalled("ClientRestart")
    end)
    pcall(function()
        Attack.OnPalRecalled("ClientRestart")
    end)
    pcall(function()
        MarkStandby.OnPalRecalled("ClientRestart")
    end)
    State.flagsLocked = false
    -- Resume only via settle probes (never immediate ActivateOtomo / Find*).
    scheduleSafeResumeProbes("ClientRestart")
end)

watchForOtomoHolder("mod-start")
