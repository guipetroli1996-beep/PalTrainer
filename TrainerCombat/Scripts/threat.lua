--[[
  TrainerCombat — Phase 2B: prefer active Pal + player damage reduction.

  While local player's Pal is out:
    - Pulse ForceHateUp_ForActiveAndAttackOtomoPal on nearby enemy AI
    - Scale incoming player damage by Config.PlayerDamageTakenMultiplierWithPal

  Cleared on recall / invalid otomo / ClientRestart.
]]

local Config = require("config")
local UEHelpers = require("UEHelpers")
local Session = require("session")
-- Lazy: mark_standby requires hud/session only — safe to require here.
local MarkStandby = nil
local function getMarkStandby()
    if MarkStandby == nil then
        local ok, mod = pcall(require, "mark_standby")
        if ok then
            MarkStandby = mod
        end
    end
    return MarkStandby
end

local Threat = {
    registered = false,
    damageHooked = false,
    aggroHooked = false,
    palActive = false,
    activeSlot = nil,
    pulseToken = 0,
    pulseLoopStarted = false,
    lastHateLogAt = 0,
    lastAggroAssistAt = 0,
    lastDrLogAt = 0,
    lastHostileNotifyAt = 0,
    mutekiOn = false,
    cachedMutekiName = nil,
    -- Set by main.lua: function(reason) for combat-only summon lock.
    OnHostileDetected = nil,
}

local MOD = "[TrainerCombat]"

local function log(msg)
    print(string.format("%s %s", MOD, msg))
end

local function debug(msg)
    if Config.Debug then
        log(msg)
    end
end

local function now()
    return os.clock()
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

local function getLocalPlayerCharacter()
    if not Session.IsAlive() then
        return nil, nil
    end
    local ok, pc = pcall(function()
        return FindFirstOf("PalPlayerController")
    end)
    if not ok or pc == nil or not pc:IsValid() then
        return nil, nil
    end

    local char = nil
    pcall(function()
        char = pc:K2_GetPawn()
    end)
    if char == nil or not char:IsValid() then
        pcall(function()
            char = pc:GetControlledPawn()
        end)
    end
    if char ~= nil and char:IsValid() then
        return char, pc
    end
    return nil, pc
end

local function getActiveOtomoActor(slotHint)
    local char = getLocalPlayerCharacter()
    if char == nil then
        return nil
    end

    -- Preferred: CharacterParameterComponent.OtomoPal
    local otomo = nil
    pcall(function()
        local param = char.CharacterParameterComponent
        if param == nil then
            param = char:GetComponentByClass(StaticFindObject("/Script/Pal.PalCharacterParameterComponent"))
        end
        if param ~= nil and param:IsValid() then
            otomo = param.OtomoPal
        end
    end)
    if otomo ~= nil and otomo:IsValid() then
        return otomo
    end

    -- Fallback: otomo holder by slot
    local slot = slotHint or Threat.activeSlot
    if slot == nil then
        return nil
    end
    pcall(function()
        local holder = FindFirstOf("BP_OtomoPalHolderComponent_C")
        if holder ~= nil and holder:IsValid() then
            otomo = holder:TryGetOtomoActorBySlotIndex(slot)
        end
    end)
    if otomo ~= nil and otomo:IsValid() then
        return otomo
    end
    return nil
end

local function isPalActive()
    if not Threat.palActive then
        return false
    end
    local otomo = getActiveOtomoActor(Threat.activeSlot)
    if otomo == nil then
        return false
    end
    return true
end

local function getDamageMultiplier()
    local m = Config.PlayerDamageTakenMultiplierWithPal
    if type(m) ~= "number" or m < 0 then
        return 0.35
    end
    return m
end

-- DR gate: trust Threat.palActive (aggro already proves this works).
-- Do not require OtomoPal actor lookup here — it can flake mid-hit.
local function drEnabled()
    return Threat.palActive
        and Config.Features
        and Config.Features.PlayerDamageReductionWithPal
end

local function scaleInt(value, mult)
    if type(value) ~= "number" then
        return value, false
    end
    return math.max(0, math.floor(value * mult + 0.5)), true
end

local function tryScaleStructDamage(structObj, fields, mult, label)
    if structObj == nil then
        return false
    end
    local scaled = false
    local before = nil
    local after = nil
    for _, field in ipairs(fields) do
        pcall(function()
            local v = structObj[field]
            if type(v) == "number" then
                before = before or v
                local nv, ok = scaleInt(v, mult)
                if ok then
                    structObj[field] = nv
                    after = nv
                    scaled = true
                end
            end
        end)
    end
    if scaled then
        pcall(function()
            structObj.bApplyNativeDamageValue = true
        end)
        if (now() - Threat.lastDrLogAt) > 1.0 then
            Threat.lastDrLogAt = now()
            log(string.format(
                "player DR %s: %s -> %s (x%.2f)",
                tostring(label),
                tostring(before),
                tostring(after),
                mult
            ))
        end
    end
    return scaled
end

local function getParamFromContext(context)
    local obj = nil
    pcall(function()
        if context ~= nil and context.get ~= nil then
            obj = context:get()
        else
            obj = context
        end
    end)
    return obj
end

local function isLocalPlayerActor(actor)
    if actor == nil then
        return false
    end
    local localChar = getLocalPlayerCharacter()
    if localChar == nil then
        return false
    end
    if actor == localChar then
        return true
    end
    local same = false
    pcall(function()
        same = actor:GetFullName() == localChar:GetFullName()
    end)
    return same == true
end

local function isLocalPlayerDamageContext(context)
    local obj = getParamFromContext(context)
    if obj == nil then
        return false
    end
    if isLocalPlayerActor(obj) then
        return true
    end

    local owner = nil
    pcall(function()
        owner = obj:GetOwner()
    end)
    if isLocalPlayerActor(owner) then
        return true
    end

    -- Outer chain (component -> character)
    local outer = nil
    pcall(function()
        outer = obj:GetOuter()
    end)
    return isLocalPlayerActor(outer)
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

local function toFixedPoint64(n)
    local v = math.floor(tonumber(n) or 0)
    local lib = getFixedPointLib()
    if lib ~= nil then
        local ok, fp = pcall(function()
            return lib:Convert_IntToFixedPoint64(v)
        end)
        if ok and fp ~= nil then
            return fp
        end
        ok, fp = pcall(function()
            return lib:Convert_Int64ToFixedPoint64(v)
        end)
        if ok and fp ~= nil then
            return fp
        end
    end
    return { Value = v }
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
            return lib:Convert_FixedPoint64ToInt64(fp)
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
    if ok2 and type(n2) == "number" then
        return n2
    end
    return nil
end

local function getPlayerParam()
    local char = getLocalPlayerCharacter()
    if char == nil then
        return nil
    end
    local param = nil
    pcall(function()
        param = char.CharacterParameterComponent
    end)
    if param ~= nil and param:IsValid() then
        return param
    end
    pcall(function()
        param = char:GetComponentByClass(
            StaticFindObject("/Script/Pal.PalCharacterParameterComponent")
        )
    end)
    if param ~= nil and param:IsValid() then
        return param
    end
    return nil
end

local function getMutekiName()
    if Threat.cachedMutekiName ~= nil then
        return Threat.cachedMutekiName
    end
    local ok, fname = pcall(function()
        return UEHelpers.FindOrAddFName("TrainerCombatDR")
    end)
    if ok and fname ~= nil then
        Threat.cachedMutekiName = fname
        return fname
    end
    return nil
end

--- Reliable DR for this build: game muteki flag (same FName pattern as throw lock).
--- Always allow CLEARING muteki (enabled=false) so leftover invuln can be fixed
--- even when PlayerDamageReductionWithPal is turned off.
local function setPlayerMuteki(enabled, reason)
    local wantEnable = enabled == true
    if wantEnable then
        if not Config.Features or not Config.Features.PlayerDamageReductionWithPal then
            return false
        end
    end
    local param = getPlayerParam()
    if param == nil then
        return false
    end
    local fname = getMutekiName()
    if fname == nil then
        return false
    end

    local function doSet()
        param:SetMuteki(fname, wantEnable)
    end

    local ok, err = pcall(function()
        if ExecuteInGameThread ~= nil then
            ExecuteInGameThread(doSet)
        else
            doSet()
        end
    end)
    if ok then
        Threat.mutekiOn = wantEnable
        log(string.format(
            "player muteki=%s (%s)",
            tostring(wantEnable),
            tostring(reason)
        ))
        return true
    end
    debug("SetMuteki failed: " .. tostring(err))
    return false
end

local function healPlayerForReducedDamage(fullDamage, mult)
    if type(fullDamage) ~= "number" or fullDamage <= 0 then
        return
    end
    if Threat._lastRefundAt ~= nil and (now() - Threat._lastRefundAt) < 0.08 then
        return
    end

    -- If muteki is active, skip healback (no damage should land).
    if Threat.mutekiOn then
        return
    end

    local refund = fullDamage - math.floor(fullDamage * mult + 0.5)
    if refund <= 0 then
        return
    end

    local param = getPlayerParam()
    if param == nil then
        debug("healback skipped — no CharacterParameterComponent")
        return
    end

    local hpBefore = fixedPointToNumber((function()
        local ok, hp = pcall(function()
            return param:GetHP()
        end)
        if ok then
            return hp
        end
        return nil
    end)())

    local fp = toFixedPoint64(refund)
    local applied = false

    local okAdd = pcall(function()
        param:AddHP(fp)
    end)
    if okAdd then
        applied = true
    end

    if not applied then
        local ind = nil
        pcall(function()
            ind = param:GetIndividualParameter()
        end)
        if ind ~= nil then
            pcall(function()
                ind:AddHP(fp)
                applied = true
            end)
        end
    end

    if not applied then
        local hp = nil
        pcall(function()
            hp = param:GetHP()
        end)
        local cur = fixedPointToNumber(hp) or 0
        local okSet = pcall(function()
            param:SetHP(toFixedPoint64(cur + refund))
        end)
        applied = okSet
    end

    local hpAfter = fixedPointToNumber((function()
        local ok, hp = pcall(function()
            return param:GetHP()
        end)
        if ok then
            return hp
        end
        return nil
    end)())

    local gained = nil
    if hpBefore ~= nil and hpAfter ~= nil then
        gained = hpAfter - hpBefore
    end

    Threat._lastRefundAt = now()

    if gained ~= nil and gained > 0 then
        log(string.format(
            "player DR healback OK +%d (hp %s -> %s, kept x%.2f of %d)",
            refund,
            tostring(hpBefore),
            tostring(hpAfter),
            mult,
            fullDamage
        ))
    else
        log(string.format(
            "player DR healback NO-OP +%d (hpBefore=%s hpAfter=%s) — enabling muteki fallback",
            refund,
            tostring(hpBefore),
            tostring(hpAfter)
        ))
        setPlayerMuteki(true, "healback-noop")
    end
end

--- Read current HP from a character parameter component (or individual param).
local function readHp(param)
    if param == nil then
        return nil
    end
    local ok, hp = pcall(function()
        return param:GetHP()
    end)
    if not ok then
        return nil
    end
    return fixedPointToNumber(hp)
end

local function getOtomoParam(otomo)
    if otomo == nil or not otomo:IsValid() then
        return nil
    end
    local param = nil
    pcall(function()
        param = otomo.CharacterParameterComponent
    end)
    if param ~= nil and param:IsValid() then
        return param
    end
    pcall(function()
        param = otomo:GetComponentByClass(
            StaticFindObject("/Script/Pal.PalCharacterParameterComponent")
        )
    end)
    if param ~= nil and param:IsValid() then
        return param
    end
    return nil
end

local function getOtomoDamageReaction(otomo)
    if otomo == nil or not otomo:IsValid() then
        return nil
    end
    local comp = nil
    pcall(function()
        comp = otomo.DamageReactionComponent
    end)
    if comp ~= nil and comp:IsValid() then
        return comp
    end
    pcall(function()
        comp = otomo:GetComponentByClass(
            StaticFindObject("/Script/Pal.PalDamageReactionComponent")
        )
    end)
    if comp ~= nil and comp:IsValid() then
        return comp
    end
    return nil
end

--- Apply damage the player would have taken onto the active Pal instead.
--- SlipDamage alone is a false positive on this build (pcall OK, HP unchanged),
--- so we always verify HP dropped — same lesson as player AddHP FixedPoint.
local function transferDamageToActivePal(amount, reason)
    if not Config.Features or not Config.Features.TransferPlayerDamageToPal then
        return false
    end
    if type(amount) ~= "number" or amount <= 0 then
        return false
    end
    if Threat._lastTransferAt ~= nil and (now() - Threat._lastTransferAt) < 0.08 then
        return false
    end

    local otomo = getActiveOtomoActor(Threat.activeSlot)
    if otomo == nil then
        debug("transfer skip — no active otomo")
        return false
    end

    local param = getOtomoParam(otomo)
    if param == nil then
        debug("transfer skip — no Pal CharacterParameterComponent")
        return false
    end

    local dmg = math.floor(amount + 0.5)
    local hpBefore = readHp(param)
    if hpBefore == nil then
        debug("transfer skip — could not read Pal HP")
        return false
    end

    local method = nil
    local targetHp = math.max(0, hpBefore - dmg)

    local function hpDropped()
        local hp = readHp(param)
        return hp ~= nil and hp < hpBefore - 0.5
    end

    -- 1) Direct SetHP (most reliable — same FixedPoint path as player healback)
    -- Call synchronously first; ExecuteInGameThread is async and would race HP verify.
    local okSet = pcall(function()
        param:SetHP(toFixedPoint64(targetHp))
    end)
    if okSet and hpDropped() then
        method = "SetHP"
    end

    -- 1b) Same SetHP deferred on game thread (some builds only accept it there)
    if method == nil and ExecuteInGameThread ~= nil then
        pcall(function()
            ExecuteInGameThread(function()
                param:SetHP(toFixedPoint64(targetHp))
            end)
        end)
        -- Brief spin: game-thread queue usually runs before next Lua tick, but
        -- verify immediately; if still unchanged we'll try other methods.
        if hpDropped() then
            method = "SetHP-GT"
        end
    end

    -- 2) Negative AddHP on individual parameter
    if method == nil then
        local ind = nil
        pcall(function()
            ind = param:GetIndividualParameter()
        end)
        if ind ~= nil then
            local okAdd = pcall(function()
                ind:AddHP(toFixedPoint64(-dmg))
            end)
            if okAdd and hpDropped() then
                method = "Ind.AddHP"
            end
        end
    end

    -- 3) Parameter OnSlipDamage (int path used by the game for DOT)
    if method == nil then
        local okSlip = pcall(function()
            param:OnSlipDamage(dmg)
        end)
        if okSlip and hpDropped() then
            method = "OnSlipDamage"
        end
    end

    -- 4) DamageReaction SlipDamage — only count if HP actually drops
    if method == nil then
        local react = getOtomoDamageReaction(otomo)
        if react ~= nil then
            pcall(function()
                react:SlipDamage(dmg, true)
            end)
            if hpDropped() then
                method = "SlipDamage"
            else
                pcall(function()
                    react:SlipDamage(dmg, false)
                end)
                if hpDropped() then
                    method = "SlipDamage"
                end
            end
            -- Optional floating number over Pal (visual only)
            if method ~= nil then
                pcall(function()
                    react:PopupDamageBySlipDamage_ToALL(dmg)
                end)
            end
        end
    end

    -- 5) Last resort: SetHP again without game-thread wrapper
    if method == nil then
        local ok = pcall(function()
            param:SetHP(toFixedPoint64(targetHp))
        end)
        if ok and hpDropped() then
            method = "SetHP-retry"
        end
    end

    local hpAfter = readHp(param)
    Threat._lastTransferAt = now()

    if method ~= nil then
        log(string.format(
            "player hit -> Pal transfer OK -%d via %s (hp %s -> %s) (%s)",
            dmg,
            method,
            tostring(hpBefore),
            tostring(hpAfter),
            tostring(reason)
        ))
        return true
    end

    log(string.format(
        "player hit -> Pal transfer NO-OP -%d (hp %s -> %s) (%s)",
        dmg,
        tostring(hpBefore),
        tostring(hpAfter),
        tostring(reason)
    ))
    return false
end

local function handlePlayerHitForTransferOrDr(fullDamage, reason)
    if not drEnabled() then
        return
    end

    local amount = fullDamage
    if (type(amount) ~= "number" or amount <= 0)
        and type(Threat._pendingHitDamage) == "number"
        and Threat._pendingHitDamage > 0
    then
        amount = Threat._pendingHitDamage
    end
    Threat._pendingHitDamage = nil

    if type(amount) ~= "number" or amount <= 0 then
        return
    end

    if Config.Features and Config.Features.TransferPlayerDamageToPal then
        transferDamageToActivePal(amount, reason)
        -- Fully refund the player (Pal took the hit instead).
        healPlayerForReducedDamage(amount, 0.0)
        return
    end

    healPlayerForReducedDamage(amount, getDamageMultiplier())
end

local function actorsEqual(a, b)
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

local function getCombatAction(ai)
    local action = nil
    pcall(function()
        local comp = ai:GetAIActionComponent()
        if comp == nil or not comp:IsValid() then
            return
        end
        action = comp:GetCurrentAction_BP()
    end)
    if action ~= nil and action:IsValid() then
        return action
    end
    return nil
end

--- Enemy AI already engaged with the player or the active Pal.
local function isEngagedWithTrainer(ai, player, otomo)
    local engaged = false

    pcall(function()
        local hate = ai:GetHateSystem()
        if hate ~= nil and hate:IsValid() then
            local most = hate:FindMostHateTarget()
            if actorsEqual(most, player) or actorsEqual(most, otomo) then
                engaged = true
            end
        end
    end)
    if engaged then
        return true
    end

    pcall(function()
        local action = getCombatAction(ai)
        if action ~= nil and action.GetTargetActor ~= nil then
            local t = action:GetTargetActor()
            if actorsEqual(t, player) or actorsEqual(t, otomo) then
                engaged = true
            end
        end
    end)
    if engaged then
        return true
    end

    pcall(function()
        local targets = ai.TargetPlayers
        if targets == nil then
            return
        end
        local len = #targets
        for i = 1, len do
            local t = targets[i]
            if actorsEqual(t, player) or actorsEqual(t, otomo) then
                engaged = true
                return
            end
        end
    end)

    return engaged
end

local function notifyHostileDetected(reason)
    if Threat.OnHostileDetected == nil then
        return
    end
    if (now() - (Threat.lastHostileNotifyAt or 0)) < 1.0 then
        return
    end
    Threat.lastHostileNotifyAt = now()
    pcall(function()
        Threat.OnHostileDetected(reason or "ai-hostile")
    end)
end

local function dumpPlayerHate(hate, player)
    if hate == nil or player == nil then
        return
    end
    -- Best-effort: dump player hate so otomo stays top target.
    pcall(function()
        hate:ChangeHate(player, -1000000000.0)
    end)
    pcall(function()
        if hate.ClearHate ~= nil then
            hate:ClearHate(player)
        end
    end)
    pcall(function()
        if hate.RemoveHateTarget ~= nil then
            hate:RemoveHateTarget(player)
        end
    end)
    pcall(function()
        if hate.SetHate ~= nil then
            hate:SetHate(player, 0.0)
        end
    end)
end

local function redirectAiToOtomo(ai, player, otomo)
    local mostIsPlayer = false
    local mostIsOtomo = false
    pcall(function()
        local hate = ai:GetHateSystem()
        if hate == nil or not hate:IsValid() then
            return
        end
        local most = hate:FindMostHateTarget()
        mostIsPlayer = actorsEqual(most, player)
        mostIsOtomo = actorsEqual(most, otomo)
    end)

    local engaged = isEngagedWithTrainer(ai, player, otomo)

    -- Soft: always dump player hate + boost otomo when API exists.
    pcall(function()
        local hate = ai:GetHateSystem()
        if hate == nil or not hate:IsValid() then
            return
        end
        dumpPlayerHate(hate, player)
        hate:ForceHateUp_ForActiveAndAttackOtomoPal(otomo)
        pcall(function()
            hate:ChangeHate(otomo, 1000000000.0)
        end)
    end)

    -- Hard retarget when fighting trainer pair OR player is currently top hate.
    if not engaged and not mostIsPlayer then
        return false
    end

    pcall(function()
        ai:AddTargetPlayer_ForEnemy(otomo)
    end)

    pcall(function()
        if ai.RemoveTargetPlayer_ForEnemy ~= nil then
            ai:RemoveTargetPlayer_ForEnemy(player)
        end
    end)

    pcall(function()
        local action = getCombatAction(ai)
        if action ~= nil and action.SetTargetAndNextAction ~= nil then
            action:SetTargetAndNextAction(otomo)
        end
    end)

    pcall(function()
        ai:K2_SetFocus(otomo)
    end)

    pcall(function()
        ai.R1AttackTarget = otomo
    end)

    -- Second hate dump after retarget (some AIs re-score mid-frame).
    pcall(function()
        local hate = ai:GetHateSystem()
        if hate == nil or not hate:IsValid() then
            return
        end
        dumpPlayerHate(hate, player)
        hate:ChangeHate(otomo, 1000000000.0)
    end)

    return true
end

local function pulseHateTowardOtomo()
    if not Session.IsAlive() then
        return
    end
    if not Config.Features or not Config.Features.PreferPalAggro then
        return
    end
    if not isPalActive() then
        return
    end

    -- Only after real combat engagement (damage / battle mode from main.lua).
    -- Never pulse on mere Pal summon — that yanks wilds onto the otomo.
    if Threat.IsInCombat == nil or Threat.IsInCombat() ~= true then
        return
    end

    -- Manual trainer mode: no game reticle target → do not pull aggro.
    local mark = getMarkStandby()
    if mark ~= nil and mark.ShouldSuppressFreeCombat ~= nil and mark.ShouldSuppressFreeCombat() then
        return
    end

    local player = getLocalPlayerCharacter()
    if player == nil then
        return
    end

    local otomo = getActiveOtomoActor(Threat.activeSlot)
    if otomo == nil then
        return
    end

    local pulsed = 0
    local redirected = 0
    local okAll, controllers = pcall(function()
        return FindAllOf("PalAIController")
    end)
    if not okAll or controllers == nil then
        return
    end

    for _, ai in pairs(controllers) do
        pcall(function()
            if ai == nil or not ai:IsValid() then
                return
            end
            -- Skip player's own Pal controller if present
            local pawn = nil
            pcall(function()
                pawn = ai:K2_GetPawn()
            end)
            if actorsEqual(pawn, otomo) or actorsEqual(pawn, player) then
                return
            end

            local hate = nil
            pcall(function()
                hate = ai:GetHateSystem()
            end)
            if hate == nil or not hate:IsValid() then
                return
            end

            -- Hostile toward player or party Pal → combat window for summon lock.
            if isEngagedWithTrainer(ai, player, otomo) then
                notifyHostileDetected("ai-engaged")
            end

            if redirectAiToOtomo(ai, player, otomo) then
                redirected = redirected + 1
            end
            pulsed = pulsed + 1
        end)
    end

    if pulsed > 0 and (now() - Threat.lastHateLogAt) > 3.0 then
        Threat.lastHateLogAt = now()
        debug(string.format(
            "hate pulse toward otomo (controllers=%d redirected=%d)",
            pulsed,
            redirected
        ))
    end
end

--- Public: force a retarget pulse (e.g. player just got hit).
--- Throttled — multihit moves must not FindAllOf every damage tick.
function Threat.PulseAggroNow(reason)
    if not Session.IsAlive() then
        return
    end
    if not Config.Features or not Config.Features.PreferPalAggro then
        return
    end
    if not Threat.palActive then
        return
    end
    if Threat.IsInCombat == nil or Threat.IsInCombat() ~= true then
        return
    end

    local cd = Config.AggroAssistCooldownSeconds
    if type(cd) ~= "number" or cd < 0 then
        cd = 2.5
    end
    local t = now()
    if (t - (Threat.lastAggroAssistAt or 0)) < cd then
        return
    end
    Threat.lastAggroAssistAt = t

    pcall(pulseHateTowardOtomo)
    debug("aggro pulse now (" .. tostring(reason) .. ")")
end

local function startHatePulse()
    if not Config.Features or not Config.Features.PreferPalAggro then
        return
    end

    -- One LoopAsync for the whole mod lifetime — recreating per ActivateOtomo
    -- stacks loops and contributes to third-load crashes after many swaps.
    if Threat.pulseLoopStarted then
        -- Do not force an immediate pulse on re-activate — wait for combat.
        return
    end
    if LoopAsync == nil then
        debug("LoopAsync missing — hate pulse unavailable until combat check")
        return
    end

    Threat.pulseLoopStarted = true
    Threat.pulseToken = Threat.pulseToken + 1
    local interval = Config.HatePulseIntervalMs or 400

    LoopAsync(interval, function()
        if not Session.IsAlive() then
            return false
        end
        if Threat.palActive then
            pcall(pulseHateTowardOtomo)
        end
        return false -- never stop — Session/palActive/IsInCombat gate the work
    end)
    debug("hate pulse loop armed (fires only while Threat.IsInCombat)")
end

local function stopHatePulse(reason)
    Threat.pulseToken = Threat.pulseToken + 1
    Threat.palActive = false
    debug("hate pulse idle (" .. tostring(reason) .. ")")
end

local function registerAggroAssistHooks()
    if Threat.aggroHooked then
        return
    end
    if not Config.Features or not Config.Features.PreferPalAggro then
        return
    end
    Threat.aggroHooked = true

    -- When the player is hit while Pal is out, immediately yank aggro to the Pal.
    pcall(function()
        RegisterHook("/Script/Pal.PalPlayerCharacter:OnDamagePlayer_Server", function(Context)
            if not Session.IsAlive() then
                return
            end
            if not Threat.palActive then
                return
            end
            if not isLocalPlayerDamageContext(Context) then
                return
            end
            Threat.PulseAggroNow("player-hit")
        end)
        log("hooked OnDamagePlayer_Server (aggro assist)")
    end)
end

local function registerDamageHooks()
    if Threat.damageHooked then
        return
    end
    if not Config.Features or not Config.Features.PlayerDamageReductionWithPal then
        log("player DR disabled (PlayerDamageReductionWithPal=false)")
        return
    end

    Threat.damageHooked = true
    local mult = getDamageMultiplier()

    -- 1) ProcessDamage_ToServer — capture amount for Pal transfer; zero player damage when possible
    pcall(function()
        RegisterHook("/Script/Pal.PalDamageReactionComponent:ProcessDamage_ToServer", function(Context, Info)
            if not drEnabled() then
                return
            end
            if not isLocalPlayerDamageContext(Context) then
                return
            end
            local info = nil
            pcall(function()
                info = Info:get()
            end)
            if info == nil then
                return
            end

            local full = nil
            pcall(function()
                full = info.NativeDamageValue
            end)

            if Config.Features and Config.Features.TransferPlayerDamageToPal then
                -- Capture before zeroing — later hooks may see Damage=0.
                if type(full) == "number" and full > 0 then
                    Threat._pendingHitDamage = full
                end
                tryScaleStructDamage(info, { "NativeDamageValue" }, 0.0, "ProcessDamage-zero")
            else
                tryScaleStructDamage(info, { "NativeDamageValue" }, getDamageMultiplier(), "ProcessDamage")
            end
        end)
        log("hooked ProcessDamage_ToServer (player DR/transfer)")
    end)

    -- 2) ApplyDamageForHP — transfer + refund path
    pcall(function()
        RegisterHook(
            "/Script/Pal.PalDamageReactionComponent:ApplyDamageForHP",
            function(Context, DamageResult)
                if not drEnabled() then
                    Threat._pendingRefund = nil
                    return
                end
                if not isLocalPlayerDamageContext(Context) then
                    local result = nil
                    pcall(function()
                        result = DamageResult:get()
                    end)
                    local defenderOk = false
                    pcall(function()
                        defenderOk = isLocalPlayerActor(result.Defender)
                    end)
                    if not defenderOk then
                        Threat._pendingRefund = nil
                        return
                    end
                end

                local result = nil
                pcall(function()
                    result = DamageResult:get()
                end)
                if result == nil then
                    return
                end

                local full = nil
                pcall(function()
                    full = result.Damage
                end)
                Threat._pendingRefund = full
                Threat._needHealback = true

                if Config.Features and Config.Features.TransferPlayerDamageToPal then
                    if type(full) == "number" and full > 0 then
                        Threat._pendingHitDamage = full
                    end
                    tryScaleStructDamage(result, { "Damage" }, 0.0, "ApplyDamageForHP-zero")
                else
                    local m = getDamageMultiplier()
                    if tryScaleStructDamage(result, { "Damage" }, m, "ApplyDamageForHP") then
                        Threat._needHealback = false
                    end
                end
            end,
            function(Context, DamageResult)
                if not Threat._needHealback then
                    Threat._pendingRefund = nil
                    return
                end
                if not drEnabled() then
                    Threat._pendingRefund = nil
                    Threat._needHealback = false
                    return
                end
                local full = Threat._pendingRefund
                Threat._pendingRefund = nil
                Threat._needHealback = false
                handlePlayerHitForTransferOrDr(full, "ApplyDamageForHP-post")
            end
        )
        log("hooked ApplyDamageForHP (player DR/transfer)")
    end)

    -- 3) OnDamagePlayer_Server — primary transfer + refund
    pcall(function()
        RegisterHook("/Script/Pal.PalPlayerCharacter:OnDamagePlayer_Server", function(Context, DamageResult)
            if not drEnabled() then
                return
            end
            if not isLocalPlayerDamageContext(Context) then
                return
            end
            local result = nil
            pcall(function()
                result = DamageResult:get()
            end)
            local full = nil
            pcall(function()
                full = result.Damage
            end)
            handlePlayerHitForTransferOrDr(full, "OnDamagePlayer")
        end)
        log("hooked OnDamagePlayer_Server (player DR/transfer)")
    end)

    -- 4) Controller OnDamage — secondary path
    pcall(function()
        RegisterHook("/Script/Pal.PalPlayerController:OnDamage", function(Context, DamageResult)
            if not drEnabled() then
                return
            end
            local result = nil
            pcall(function()
                result = DamageResult:get()
            end)
            local full = nil
            pcall(function()
                full = result.Damage
            end)
            handlePlayerHitForTransferOrDr(full, "Controller.OnDamage")
        end)
        log("hooked PalPlayerController:OnDamage (player DR/transfer)")
    end)

    log(string.format(
        "player DR/transfer hooks ready (transfer=%s x%.2f)",
        tostring(Config.Features.TransferPlayerDamageToPal),
        mult
    ))
end

function Threat.OnPalActivated(slot)
    Threat.palActive = true
    Threat.activeSlot = slot
    log(string.format(
        "threat: Pal active (slot=%s) aggro=%s DR=%s (hate pulse waits for combat)",
        tostring(slot),
        tostring(Config.Features and Config.Features.PreferPalAggro),
        tostring(Config.Features and Config.Features.PlayerDamageReductionWithPal)
    ))
    -- Ensure leftover muteki from older DR tests is never left on.
    setPlayerMuteki(false, "pal-active-clear-muteki")
    if Config.Features and Config.Features.PlayerDamageReductionWithPal then
        if not Config.Features.TransferPlayerDamageToPal and getDamageMultiplier() <= 0.05 then
            setPlayerMuteki(true, "pal-active-low-mult")
        end
    end
    -- Start the loop, but pulseHateTowardOtomo no-ops until Threat.IsInCombat().
    startHatePulse()
end

function Threat.OnPalRecalled(reason)
    if reason == "ClientRestart" then
        Threat.palActive = false
        Threat.activeSlot = nil
        debug("threat: suspended for ClientRestart")
        return
    end
    if not Threat.palActive then
        if reason ~= "ClientRestart" then
            setPlayerMuteki(false, reason or "recall-idle")
        end
        return
    end
    Threat.palActive = false
    Threat.activeSlot = nil
    stopHatePulse(reason or "recall")
    setPlayerMuteki(false, reason or "recall")
    log("threat: Pal inactive — aggro off (" .. tostring(reason or "recall") .. ")")
end

function Threat.Register()
    if Threat.registered then
        return
    end
    Threat.registered = true

    local wantAggro = Config.Features and Config.Features.PreferPalAggro
    local wantDr = Config.Features and Config.Features.PlayerDamageReductionWithPal
    if not wantAggro and not wantDr then
        log("threat module idle (PreferPalAggro/PlayerDamageReductionWithPal both false)")
        return
    end

    -- Clear stuck invulnerability from previous DR/muteki experiments.
    setPlayerMuteki(false, "boot-clear")

    registerAggroAssistHooks()
    registerDamageHooks()
    log(string.format(
        "threat module registered (Phase 2B) aggro=%s DR=%s transfer=%s",
        tostring(wantAggro),
        tostring(wantDr),
        tostring(Config.Features and Config.Features.TransferPlayerDamageToPal)
    ))
end

return Threat
