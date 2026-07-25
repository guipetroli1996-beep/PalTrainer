--[[
  TrainerCombat — Controlled Pal (Phase 3)

  Unmarked: LogicMod / NotCombat standby (no free AI combat).
  Aim+MMB on a hostile → sticky mark + release engage (vanilla Pal combat AI).
  Aim+MMB the same target again (or lost target) → clear mark and re-arm standby.
  Aim+LMB filler / Aim+1/2/3 skill orders live on archive/aim-lmb-skills only.
]]

local Config = require("config")
local Session = require("session")
local Hud = require("hud")
local UEHelpers = require("UEHelpers")
local BpBridge = require("bp_bridge")
-- Aim skill HUD parked (archive/aim-lmb-skills). Stub so leftover call sites are safe.
local AimSkillHud = {
    Register = function() end,
    Hide = function() end,
    Show = function() end,
    Update = function() end,
    IsVisible = function()
        return false
    end,
}

local MarkStandby = {
    hooked = false,
    palOut = false,
    -- True while local player is mounted (trainer features paused).
    riding = false,
    -- Re-arm ManualStandby/NotCombat after ClientRestart (ride often triggers it).
    pendingTrainerRestore = false,
    lastAnnounceAt = 0,
    lastStandbyLogAt = 0,
    lastSoftFollowAt = 0,
    lastActionProbeAt = 0,
    lastDamageBlockLogAt = 0,
    lastNotCombatAt = 0,
    playerBattleMode = false,
    lastCombatAt = 0,
    lastWorkSuppressLogAt = 0,
    stickyMark = nil,
    stickyMarkName = nil,
    stickyMarkDisplayName = nil,
    ignoreReticleUntil = 0,
    standbyLoopStarted = false,
    loggedReticleDisable = false,
    damageHooked = false,
    playerAiming = false,
    rmbAimUntil = 0,
    lastAimMarkAnnounceAt = 0,
    lastDefaultAttackAt = 0,
    attackWindowUntil = 0,
    fillerInFlight = false,
    fillerToken = 0,
    fillerFired = false,
    activeSlot = nil,
    aimAttackBusy = false,
    lastAimAttackAt = 0,
    blockPlaySkillUntil = 0,
    lastSkillOrderAt = 0,
    lastSkillBusyLogAt = 0,
    loggedEquipWazaDump = false,
    -- Per ActiveSkill slot: local cast clock (game CD APIs are flaky in NotCombat).
    skillSlotCdUntil = {},
    -- Waza id we ordered this oneshot (for diagnostics / free-AI checks).
    orderedWazaId = nil,
    -- Set during orderDefaultAttack; ProcessDamage / PlayAction call these once.
    onFillerOtomoDamage = nil,
    onFillerOtomoAction = nil,
    suppressPlayerAttackUntil = 0,
    markShootFlagOn = false,
    cachedMarkShootFlagName = nil,
    aimSkillKeysBlocked = false,
    cachedAimSkillBlockFlagName = nil,
    -- While aiming: temporarily unbind vanilla actions for keys 1/2/3.
    aimActionsUnbound = false,
    savedAimActionKeys = nil,
}

local MOD = "[TrainerCombat]"

-- EPalOtomoPalOrderType: Default=0, Warlike=1, NotCombat=2
local OTOMO_ORDER_DEFAULT = 0
local OTOMO_ORDER_WARLIKE = 1
local OTOMO_ORDER_NOT_COMBAT = 2

-- EPalWazaID — neutral/generic (last-resort only; not preferred elemental fillers)
local WAZA_ENERGY_SHOT = 5
local WAZA_POWER_SHOT = 11
local WAZA_POWER_BALL = 12
local WAZA_AIR_CANON = 22
-- Common weak elemental shots (most common filler per element)
local WAZA_FIRE_BLAST = 40      -- Ignis Blast
local WAZA_WATER_GUN = 57       -- Aqua Gun
local WAZA_WIND_CUTTER = 85     -- Wind Cutter (Grass/Leaf)
local WAZA_SPREAD_PULSE = 104   -- Spark Blast
local WAZA_ICE_MISSILE = 113
local WAZA_MUD_SHOT = 124       -- Sand Blast
local WAZA_DRAGON_CANON = 148   -- Dragon Cannon
local WAZA_DARK_BALL = 159
-- EPalActionType field-work / gather actions (not combat skills).
-- CommonWork=25 … Harvest=33, plus energy/cooking nearby.
local FIELD_WORK_ACTION_TYPE = {
    [25] = true, -- CommonWork
    [26] = true, -- Architecture
    [27] = true, -- Deforest (cut trees)
    [28] = true, -- Mining
    [29] = true, -- Feeding
    [30] = true, -- GrowupPromotion
    [31] = true, -- Watering
    [32] = true, -- WateringOneshot
    [33] = true, -- Harvest
    [34] = true, -- GenerateEnergy
    [35] = true, -- GenerateEnergyFire
    [36] = true, -- GenerateEnergyElectric
    [37] = true, -- Cooking
}

-- EPalElementType → most common weak elemental ranged filler
local ELEMENT_FILLER_WAZA = {
    [1] = WAZA_AIR_CANON,     -- Normal
    [2] = WAZA_FIRE_BLAST,    -- Fire
    [3] = WAZA_WATER_GUN,     -- Water
    [4] = WAZA_WIND_CUTTER,   -- Leaf (Grass)
    [5] = WAZA_SPREAD_PULSE,  -- Electricity
    [6] = WAZA_ICE_MISSILE,   -- Ice
    [7] = WAZA_MUD_SHOT,      -- Earth
    [8] = WAZA_DARK_BALL,     -- Dark
    [9] = WAZA_DRAGON_CANON,  -- Dragon
}

local ELEMENT_NAMES = {
    [0] = "None",
    [1] = "Normal",
    [2] = "Fire",
    [3] = "Water",
    [4] = "Leaf",
    [5] = "Electricity",
    [6] = "Ice",
    [7] = "Earth",
    [8] = "Dark",
    [9] = "Dragon",
}

local ELEMENT_NAME_TO_ID = {
    none = 0,
    normal = 1,
    fire = 2,
    water = 3,
    leaf = 4,
    grass = 4,
    electricity = 5,
    electric = 5,
    ice = 6,
    earth = 7,
    ground = 7,
    dark = 8,
    dragon = 9,
}

local WAZA_NAMES = require("waza_names")

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

local function featureOn()
    return Config.Features ~= nil and Config.Features.MarkStandby == true
end

local function cfg()
    return Config.MarkStandby or {}
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
    if ok then
        return val
    end
    return param
end

local function objectName(obj)
    if obj == nil then
        return nil
    end
    local n = nil
    pcall(function()
        n = obj:GetFullName()
    end)
    return n
end

--- kind: "mark" | "attack" | "skill" | "skill_cd" (other kinds log only).
local function announce(kind, text)
    if cfg().AnnounceOrders == false then
        return
    end
    if kind == "mark" then
        if cfg().AnnounceMark == false then
            log(tostring(text))
            return
        end
    elseif kind == "attack" then
        if cfg().AnnounceAttackCommands == false then
            return
        end
    elseif kind == "skill" then
        if cfg().AnnounceSkillCommands == false then
            return
        end
    elseif kind == "skill_cd" then
        if cfg().AnnounceSkillCooldown == false then
            return
        end
    else
        -- Standby / too-far / empty-slot / etc. — intentionally silent.
        log(tostring(text))
        return
    end
    if (now() - MarkStandby.lastAnnounceAt) < 0.6 then
        return
    end
    MarkStandby.lastAnnounceAt = now()
    pcall(function()
        Hud.Announce(text)
    end)
    log(text)
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

local function findOtomoHolder()
    local ok, holder = pcall(function()
        return FindFirstOf("BP_OtomoPalHolderComponent_C")
    end)
    if ok and holder ~= nil then
        local valid = false
        pcall(function()
            valid = holder:IsValid() == true
        end)
        if valid then
            return holder
        end
    end
    ok, holder = pcall(function()
        return FindFirstOf("PalOtomoHolderComponentBase")
    end)
    if ok and holder ~= nil then
        local valid = false
        pcall(function()
            valid = holder:IsValid() == true
        end)
        if valid then
            return holder
        end
    end
    return nil
end

local function getActiveOtomoActor()
    -- 1) Holder by remembered slot (same pattern as main.lua)
    local slot = MarkStandby.activeSlot
    if slot ~= nil then
        local fromSlot = nil
        pcall(function()
            local holder = findOtomoHolder()
            if holder ~= nil and holder.TryGetOtomoActorBySlotIndex ~= nil then
                fromSlot = holder:TryGetOtomoActorBySlotIndex(slot)
            end
        end)
        fromSlot = unwrap(fromSlot)
        if fromSlot ~= nil then
            local ok = false
            pcall(function()
                ok = fromSlot:IsValid() == true
            end)
            if ok then
                return fromSlot
            end
        end
    end

    -- 2) Currently selected otomo on holder
    local fromSelect = nil
    pcall(function()
        local holder = findOtomoHolder()
        if holder ~= nil and holder.TryGetCurrentSelectPalActor ~= nil then
            fromSelect = holder:TryGetCurrentSelectPalActor()
        end
    end)
    fromSelect = unwrap(fromSelect)
    if fromSelect ~= nil then
        local ok = false
        pcall(function()
            ok = fromSelect:IsValid() == true
        end)
        if ok then
            return fromSelect
        end
    end

    -- 3) Fallback: player CharacterParameterComponent.OtomoPal (must :get())
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
    otomo = unwrap(otomo)
    if otomo ~= nil then
        local ok = false
        pcall(function()
            ok = otomo:IsValid() == true
        end)
        if ok then
            return otomo
        end
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
    return nil
end

local function getOtomoHolder()
    return findOtomoHolder()
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

local function resolveWeakActor(weak)
    if weak == nil then
        return nil
    end
    local actor = nil
    pcall(function()
        if weak.Get ~= nil then
            actor = weak:Get()
        elseif weak.GetObject ~= nil then
            actor = weak:GetObject()
        elseif weak.get ~= nil then
            actor = weak:get()
        else
            actor = weak
        end
    end)
    if actor ~= nil then
        local ok = false
        pcall(function()
            ok = actor:IsValid() == true
        end)
        if ok then
            return actor
        end
    end
    return nil
end

local function isActorAlive(actor)
    if actor == nil then
        return false
    end
    local ok = false
    pcall(function()
        ok = actor:IsValid() == true
    end)
    if not ok then
        return false
    end
    local dead = false
    pcall(function()
        if actor.IsDead ~= nil then
            dead = actor:IsDead() == true
        end
    end)
    if dead then
        return false
    end
    pcall(function()
        local param = actor.CharacterParameterComponent
        if param ~= nil and param.IsDead ~= nil then
            dead = param:IsDead() == true
        end
    end)
    return not dead
end

local function isCharacterLikeTarget(actor)
    if actor == nil then
        return false
    end
    local name = string.lower(objectName(actor) or "")
    if string.find(name, "landscape", 1, true)
        or string.find(name, "streamingproxy", 1, true)
        or string.find(name, "brush", 1, true)
        or string.find(name, "staticmesh", 1, true)
        or string.find(name, "instancedfoliage", 1, true)
        or string.find(name, "foliage", 1, true)
        or string.find(name, "mapobject", 1, true)
        or string.find(name, "buildobject", 1, true) then
        return false
    end
    local hasParam = false
    pcall(function()
        hasParam = actor.CharacterParameterComponent ~= nil
            and actor.CharacterParameterComponent:IsValid() == true
    end)
    if hasParam then
        return true
    end
    if string.find(name, "palcharacter", 1, true)
        or string.find(name, "monster", 1, true)
        or string.find(name, "npc", 1, true)
        or string.find(name, "enemy", 1, true)
        or string.find(name, "bp_", 1, true) then
        return true
    end
    return false
end

local function isHostileTarget(actor, player, otomo)
    if actor == nil or not isActorAlive(actor) then
        return false
    end
    if actorsEqual(actor, player) or actorsEqual(actor, otomo) then
        return false
    end
    return isCharacterLikeTarget(actor)
end

local function clearStickyMark(reason)
    if MarkStandby.stickyMark ~= nil or MarkStandby.stickyMarkName ~= nil then
        log("mark: clear sticky (" .. tostring(reason) .. ")")
    end
    MarkStandby.stickyMark = nil
    MarkStandby.stickyMarkName = nil
    MarkStandby.stickyMarkDisplayName = nil
end

local function setStickyMark(actor, reason, displayName)
    if actor == nil or not isActorAlive(actor) then
        return false
    end
    MarkStandby.stickyMark = actor
    MarkStandby.stickyMarkName = objectName(actor)
    local label = displayName
    if label == nil or label == "" then
        pcall(function()
            label = actor:GetName()
        end)
    end
    if label == nil or label == "" then
        label = MarkStandby.stickyMarkName or "?"
    end
    MarkStandby.stickyMarkDisplayName = label
    log("mark: STICKY (" .. tostring(reason) .. "): " .. tostring(label))
    return true
end

local function getStickyMark()
    local t = MarkStandby.stickyMark
    if t ~= nil and isActorAlive(t) then
        return t
    end
    if MarkStandby.stickyMark ~= nil then
        clearStickyMark("target-dead")
    end
    return nil
end

function MarkStandby.HasMarkedTarget()
    return getStickyMark() ~= nil
end

--- Live mount check (engine only — do not trust MarkStandby.riding alone).
local function probePlayerMounted()
    local char = select(1, getLocalPlayerCharacter())
    if char == nil then
        return false
    end
    local riding = false
    pcall(function()
        local rider = char.RiderComponent
        if rider ~= nil and rider.IsRiding ~= nil then
            riding = rider:IsRiding() == true
        end
    end)
    if riding then
        return true
    end
    pcall(function()
        local util = StaticFindObject("/Script/Pal.Default__PalUtility")
        if util ~= nil and util.GetRidePal ~= nil then
            local pal = util:GetRidePal(char)
            if pal ~= nil then
                local ok = false
                pcall(function()
                    ok = pal:IsValid() == true
                end)
                riding = ok
            end
        end
    end)
    return riding == true
end

function MarkStandby.IsRiding()
    -- Trust the flag during ClientRestart — rider probe often fails mid-teardown.
    if MarkStandby.riding == true then
        return true
    end
    return probePlayerMounted()
end

function MarkStandby.IsManualMode()
    if probePlayerMounted() then
        return false
    end
    return featureOn() and cfg().ManualAttackOnly ~= false and MarkStandby.palOut == true
end

function MarkStandby.NoteCombat(reason)
    MarkStandby.lastCombatAt = now()
    debug("mark: combat noted (" .. tostring(reason) .. ")")
    -- Notify main.lua so summon-lock combat window sees mark/engage.
    if MarkStandby.OnCombatNoted ~= nil then
        pcall(MarkStandby.OnCombatNoted, reason)
    end
end

--- Player battle mode, or recent combat/filler within suppress memory.
function MarkStandby.IsPlayerInCombat()
    if not featureOn() then
        return false
    end
    if MarkStandby.playerBattleMode == true then
        return true
    end
    local mem = cfg().CombatWorkSuppressSeconds
    if mem == nil then
        mem = Config.CombatMemorySeconds or 12.0
    end
    local last = MarkStandby.lastCombatAt or 0
    if last > 0 and (now() - last) <= mem then
        return true
    end
    return false
end

function MarkStandby.ShouldSuppressOtomoWork()
    if cfg().SuppressOtomoWorkInCombat == false then
        return false
    end
    if not MarkStandby.IsManualMode() then
        return false
    end
    return MarkStandby.IsPlayerInCombat()
end

function MarkStandby.ShouldSuppressFreeCombat()
    if not featureOn() then
        return false
    end
    if MarkStandby.IsRiding() then
        return false
    end
    if cfg().ManualAttackOnly == false then
        return false
    end
    -- Marked = engage: allow vanilla combat AI + threat aggro assist.
    if MarkStandby.HasMarkedTarget() then
        return false
    end
    return MarkStandby.palOut == true
end

function MarkStandby.ShouldBlockOtomoDamage()
    if not MarkStandby.IsManualMode() then
        return false
    end
    if cfg().BlockOtomoDamage == false then
        return false
    end
    -- Marked / engage: Pal may deal damage. Unmarked standby: zero outgoing damage.
    if MarkStandby.HasMarkedTarget() then
        return false
    end
    return true
end

local function defaultAttackCfg()
    return cfg().DefaultAttack or {}
end

local function isDefaultAttackEnabled()
    return defaultAttackCfg().Enabled ~= false
end

local function fillerCooldownSeconds()
    local dac = defaultAttackCfg()
    return dac.CooldownSeconds or dac.DebounceSeconds or 2.0
end

local function fillerCooldownRemaining()
    local cd = fillerCooldownSeconds()
    local elapsed = now() - (MarkStandby.lastDefaultAttackAt or 0)
    if elapsed >= cd then
        return 0
    end
    return cd - elapsed
end

local function inAttackWindow()
    return now() < (MarkStandby.attackWindowUntil or 0)
end

local function getPalUtility()
    local ok, util = pcall(function()
        return StaticFindObject("/Script/Pal.Default__PalUtility")
    end)
    if ok and util ~= nil then
        return util
    end
    return nil
end

local function getOtomoController(otomo)
    if otomo == nil then
        return nil
    end
    local ctrl = nil
    pcall(function()
        ctrl = otomo:GetController()
    end)
    if ctrl ~= nil and ctrl:IsValid() then
        return ctrl
    end
    pcall(function()
        ctrl = otomo:GetAIController()
    end)
    if ctrl ~= nil and ctrl:IsValid() then
        return ctrl
    end
    return nil
end

local function getOtomoSkillSlot(otomo)
    local ctrl = getOtomoController(otomo)
    if ctrl ~= nil then
        local skillSlot = nil
        pcall(function()
            skillSlot = ctrl.SkillSlot
        end)
        if skillSlot ~= nil and skillSlot:IsValid() then
            return skillSlot
        end
    end
    local skillSlot = nil
    pcall(function()
        if otomo.GetSkillSlotRef ~= nil then
            skillSlot = otomo:GetSkillSlotRef()
        end
    end)
    if skillSlot ~= nil and skillSlot:IsValid() then
        return skillSlot
    end
    pcall(function()
        skillSlot = otomo.SkillSlot
    end)
    if skillSlot ~= nil and skillSlot:IsValid() then
        return skillSlot
    end
    return nil
end

local function tryForceFollow(otomo)
    local ctrl = getOtomoController(otomo)
    if ctrl == nil then
        return
    end
    pcall(function()
        local comp = ctrl:GetAIActionComponent()
        if comp == nil then
            return
        end
        local root = nil
        if comp.GetCurrentTopParentAction_BP ~= nil then
            root = comp:GetCurrentTopParentAction_BP()
        end
        if root ~= nil and root.SetOtomoFollowAction ~= nil then
            root:SetOtomoFollowAction()
        end
        local action = nil
        if comp.GetCurrentAction_BP ~= nil then
            action = comp:GetCurrentAction_BP()
        end
        if action ~= nil and action.SetOtomoFollowAction ~= nil then
            action:SetOtomoFollowAction()
        end
        if action ~= nil and action.ClearTargetCharacter ~= nil then
            action:ClearTargetCharacter()
        end
    end)
end

--- Hard-stop field work (deforest / mine / gather). Needed so filler can fire.
local function cancelOtomoFieldWork(otomo, reason)
    if otomo == nil then
        return false
    end

    -- Cancel work montages / pushed AI (tree chopping lives here).
    local ctrl = getOtomoController(otomo)
    if ctrl ~= nil then
        pcall(function()
            local aic = ctrl:GetAIActionComponent()
            if aic == nil then
                return
            end
            if aic.AllCancelPushedAction ~= nil then
                aic:AllCancelPushedAction(otomo)
            end
            -- Unregister fixed work assign if the composite worker exposes it.
            local root = nil
            if aic.GetCurrentTopParentAction_BP ~= nil then
                root = aic:GetCurrentTopParentAction_BP()
            end
            if root ~= nil and root.UnregisterFixAssignWork ~= nil then
                root:UnregisterFixAssignWork()
            end
            local action = nil
            if aic.GetCurrentAction_BP ~= nil then
                action = aic:GetCurrentAction_BP()
            end
            if action ~= nil and action.UnregisterFixAssignWork ~= nil then
                action:UnregisterFixAssignWork()
            end
        end)
    end

    pcall(function()
        local ac = otomo.ActionComponent
        if ac ~= nil and ac:IsValid() and ac.CancelAllAction ~= nil then
            ac:CancelAllAction()
        end
    end)

    tryForceFollow(otomo)

    local t = now()
    if (t - (MarkStandby.lastWorkSuppressLogAt or 0)) > 1.5 then
        MarkStandby.lastWorkSuppressLogAt = t
        log("mark: cancel field work (" .. tostring(reason) .. ")")
    end
    return true
end

--- While player is in combat: keep active Pal off trees/rocks/gather jobs.
local function suppressOtomoWork(otomo, reason)
    if not MarkStandby.ShouldSuppressOtomoWork() then
        return false
    end
    return cancelOtomoFieldWork(otomo, reason)
end

local function softCancelCombat(otomo)
    if otomo == nil then
        return
    end
    local ctrl = getOtomoController(otomo)
    if ctrl ~= nil then
        pcall(function()
            local aic = ctrl:GetAIActionComponent()
            if aic == nil then
                return
            end
            if aic.AllCancelPushedAction ~= nil then
                aic:AllCancelPushedAction(otomo)
            end
        end)
    end
    pcall(function()
        local ac = otomo.ActionComponent
        if ac ~= nil and ac:IsValid() and ac.CancelAllAction ~= nil then
            ac:CancelAllAction()
        end
    end)
    tryForceFollow(otomo)
end

--- Clear free-combat AI intent without CancelAllAction (keeps our PlayAction montage).
local function clearOtomoAiCombatIntent(otomo, reason)
    if otomo == nil then
        return
    end
    local ctrl = getOtomoController(otomo)
    if ctrl ~= nil then
        pcall(function()
            local aic = ctrl:GetAIActionComponent()
            if aic ~= nil and aic.AllCancelPushedAction ~= nil then
                aic:AllCancelPushedAction(otomo)
            end
        end)
    end
    tryForceFollow(otomo)
    debug("mark: cleared AI combat intent (" .. tostring(reason) .. ")")
end

--- Native game order: NotCombat (preferred Lua fallback when LogicMod missing).
local function requestNotCombatOrder(reason)
    local t = now()
    if (t - (MarkStandby.lastNotCombatAt or 0)) < 0.35 then
        return false
    end
    MarkStandby.lastNotCombatAt = t

    local holder = getOtomoHolder()
    if holder == nil or holder.RequestSetOtomoOrder == nil then
        return false
    end
    local ok = pcall(function()
        holder:RequestSetOtomoOrder(OTOMO_ORDER_NOT_COMBAT)
    end)
    if ok then
        local logGap = (t - (MarkStandby.lastStandbyLogAt or 0)) > 2.0
        if logGap then
            MarkStandby.lastStandbyLogAt = t
            log("mark: RequestSetOtomoOrder(NotCombat) (" .. tostring(reason) .. ")")
        end
    end
    return ok
end

local function requestDefaultOrder(reason)
    local holder = getOtomoHolder()
    if holder == nil or holder.RequestSetOtomoOrder == nil then
        return false
    end
    local ok = pcall(function()
        holder:RequestSetOtomoOrder(OTOMO_ORDER_DEFAULT)
    end)
    if ok then
        log("mark: RequestSetOtomoOrder(Default) (" .. tostring(reason) .. ")")
    end
    return ok
end

local function requestWarlikeOrder(reason)
    local holder = getOtomoHolder()
    if holder == nil or holder.RequestSetOtomoOrder == nil then
        return false
    end
    local ok = pcall(function()
        holder:RequestSetOtomoOrder(OTOMO_ORDER_WARLIKE)
    end)
    if ok then
        log("mark: RequestSetOtomoOrder(Warlike) (" .. tostring(reason) .. ")")
    end
    return ok
end

local function setDirectOrderTarget(target)
    -- Only set a real actor. Never pass nil (UE4SS weak-ptr/nil UFunction args crash).
    if target == nil then
        return false
    end
    local holder = getOtomoHolder()
    if holder == nil then
        return false
    end
    local ok = pcall(function()
        if holder.SetDirectOrderTarget_ToServer ~= nil then
            holder:SetDirectOrderTarget_ToServer(target)
        end
    end)
    return ok == true
end

--- UE4SS cannot clear TWeakObjectPtr / pass nil into many target setters.
--- Calling Set*(nil) or Prop = nil logs push_weakobjectproperty and can crash.
local function clearDirectOrderTarget(reason)
    debug("mark: skip DirectOrder clear (unsafe nil under UE4SS) (" .. tostring(reason) .. ")")
    return false
end

--- Soft-disable auto reticle combat. Do NOT assign ReticleTargetActor / call SetReticle*(nil).
local function clearReticleTargetOn(actor, reason)
    if actor == nil then
        return
    end
    local param = nil
    pcall(function()
        param = actor.CharacterParameterComponent
    end)
    param = unwrap(param)
    if param == nil then
        return
    end
    pcall(function()
        param.bIsEnableSendReticleTarget = false
    end)
    pcall(function()
        if param.SetEnableSendReticleTarget ~= nil then
            local fname = nil
            if UEHelpers ~= nil and UEHelpers.FindOrAddFName ~= nil then
                fname = UEHelpers.FindOrAddFName("TrainerCombat_NoAutoReticle")
            elseif FName ~= nil then
                fname = FName("TrainerCombat_NoAutoReticle")
            end
            if fname ~= nil then
                param:SetEnableSendReticleTarget(fname, false)
            end
        end
    end)
end

local function clearAimReticleForOrder(reason)
    -- Ignore MMB/reticle hooks briefly (avoids adoptMark side-effects).
    MarkStandby.ignoreReticleUntil = now() + 1.25

    local player = select(1, getLocalPlayerCharacter())
    local otomo = getActiveOtomoActor()
    -- Safe: bool flags only. Never nil-out weak object targets (crashes this UE4SS build).
    clearReticleTargetOn(player, reason)
    clearReticleTargetOn(otomo, reason)
    debug("mark: soft-disabled reticle send for order (" .. tostring(reason) .. ")")
end

-- Forward decl: orderDefaultAttack calls this after the attack window.
local forceStandby

--- Prefer LogicMod; else NotCombat + soft cancel (no SetActiveAI thrash).
forceStandby = function(otomo, reason)
    if inAttackWindow() then
        return
    end

    BpBridge.WarnIfMissing()

    -- Always apply Lua NotCombat — BP UFunction calls are unreliable on this build.
    requestNotCombatOrder(reason)
    BpBridge.SetManualStandby(true)
    BpBridge.ForceOtomoStandby(reason)

    if otomo ~= nil then
        softCancelCombat(otomo)
    end
end

--- Aim+MMB mark: lift LogicMod standby and let vanilla Pal combat AI engage.
local function releaseToEngage(otomo, reason, target)
    MarkStandby.NoteCombat("engage-" .. tostring(reason))
    BpBridge.SetManualStandby(false)
    requestDefaultOrder(reason)
    if target ~= nil then
        setDirectOrderTarget(target)
    end
    log("mark: ENGAGE (" .. tostring(reason) .. ") → " .. tostring(MarkStandby.stickyMarkDisplayName or "?"))
    if otomo ~= nil then
        debug("mark: engage otomo=" .. tostring(objectName(otomo)))
    end
end

local function normalizeElementType(raw)
    if raw == nil then
        return nil
    end
    -- UE4SS property wrappers need :get()
    if type(raw) == "userdata" or type(raw) == "table" then
        local okGet, got = pcall(function()
            if raw.get ~= nil then
                return raw:get()
            end
            return nil
        end)
        if okGet and got ~= nil and got ~= raw then
            raw = got
        end
    end
    if type(raw) == "number" then
        if raw >= 0 and raw <= 9 then
            return raw
        end
        return nil
    end
    if type(raw) == "table" then
        if type(raw.Value) == "number" then
            return normalizeElementType(raw.Value)
        end
        if type(raw.value) == "number" then
            return normalizeElementType(raw.value)
        end
    end
    local s = tostring(raw)
    if s == nil or s == "" then
        return nil
    end
    if s:find("userdata", 1, true) or s:find("UObject", 1, true) then
        return nil
    end
    local asNum = tonumber(s)
    if asNum ~= nil and asNum >= 0 and asNum <= 9 then
        return asNum
    end
    local lower = string.lower(s)
    local bare = lower:match("::([%w_]+)$") or lower:match("([%w_]+)$") or lower
    return ELEMENT_NAME_TO_ID[bare]
end

-- Assigned after getCharacterId / getCharacterDb (CharacterID DB is authoritative).
local resolveOtomoElement
-- Assigned later (nickname / localized CharacterID).
local displayNameForTarget
local getNickname
-- Assigned later (PalUIUtility:GetWazaName).
local tryGetLocalizedWazaName

local function formatEnumWazaName(enumName)
    if type(enumName) ~= "string" or enumName == "" or enumName == "None" then
        return nil
    end
    local bare = enumName
    -- Unique_Deer_PushupHorn → PushupHorn; Unique_KingWhale_AquaBlade → AquaBlade
    if bare:match("^Unique_") then
        bare = bare:match("^Unique_[^_]+_(.+)$") or bare:gsub("^Unique_", "")
    end
    bare = bare:gsub("_", " ")
    bare = bare:gsub("([a-z])([A-Z0-9])", "%1 %2")
    bare = bare:gsub("([A-Z]+)([A-Z][a-z])", "%1 %2")
    bare = bare:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return bare
end

local function wazaLabel(id)
    local name = WAZA_NAMES[id]
    if name ~= nil then
        return string.format("%s(%d)", name, id)
    end
    return tostring(id)
end

local wazaDisplayCache = {}

--- Player-facing skill name (localized when possible).
local function wazaDisplayName(id)
    if type(id) ~= "number" then
        return "Skill"
    end
    local cached = wazaDisplayCache[id]
    if cached ~= nil then
        return cached
    end
    if tryGetLocalizedWazaName ~= nil then
        local loc = tryGetLocalizedWazaName(id)
        if type(loc) == "string" and loc ~= "" then
            wazaDisplayCache[id] = loc
            return loc
        end
    end
    local formatted = formatEnumWazaName(WAZA_NAMES[id])
    if formatted ~= nil then
        wazaDisplayCache[id] = formatted
        return formatted
    end
    return "Skill " .. tostring(id)
end

local function actorLabelForAnnounce(actor, fallback)
    if displayNameForTarget ~= nil and actor ~= nil then
        local ok, name = pcall(displayNameForTarget, actor)
        if ok and type(name) == "string" and name ~= "" then
            return name
        end
    end
    if type(fallback) == "string" and fallback ~= "" then
        return fallback
    end
    return "Unknown"
end

--- Own Pal in announces: prefer custom NickName over species name.
local function palAnnounceName(actor, fallback)
    if actor ~= nil and getNickname ~= nil then
        local ok, nick = pcall(getNickname, actor)
        if ok and type(nick) == "string" then
            nick = nick:match("^%s*(.-)%s*$") or nick
            if nick ~= "" and string.lower(nick) ~= "none" then
                return nick
            end
        end
    end
    return actorLabelForAnnounce(actor, fallback)
end

local function playFillerWaza(otomo, target, wazaId)
    local util = getPalUtility()
    if util == nil or util.PlayActionByWazaID == nil then
        return false
    end
    local okCall, ret = pcall(function()
        return util:PlayActionByWazaID(otomo, target, wazaId)
    end)
    return okCall and ret == true
end

local function playShootSkillAction(otomo, target)
    local util = getPalUtility()
    if util == nil or util.PlayAction == nil then
        return false
    end
    local okCall, ret = pcall(function()
        return util:PlayAction(otomo, target, ACTION_SHOOT_SKILL)
    end)
    return okCall and ret == true
end

--- Best-effort: element → OtomoBoringTimeWazaID (game's filler map).
local function tryGetBoringRangedWazaId(otomo, element)
    if otomo == nil or element == nil then
        return nil
    end

    local db = nil
    pcall(function()
        db = FindFirstOf("PalWazaDatabase")
    end)
    if db == nil then
        pcall(function()
            db = StaticFindObject("/Script/Pal.Default__PalWazaDatabase")
        end)
    end
    if db == nil then
        return nil
    end

    local waza = nil
    pcall(function()
        local map = db.OtomoBoringTimeWazaID
        if map == nil then
            return
        end
        if map.Get ~= nil then
            waza = map:Get(element)
        elseif map.Find ~= nil then
            waza = map:Find(element)
        elseif map[element] ~= nil then
            waza = map[element]
        end
    end)
    if type(waza) == "userdata" or type(waza) == "table" then
        local okGet, got = pcall(function()
            if waza.get ~= nil then
                return waza:get()
            end
            return nil
        end)
        if okGet and got ~= nil then
            waza = got
        end
    end
    if type(waza) == "number" and waza > 0 then
        return waza
    end
    return nil
end

--- Elemental common filler first, then neutral fallbacks (PowerShot last — sky drop).
local function buildRangedWazaList(otomo, dac)
    local element, elName, charId, source = nil, "?", nil, "none"
    if resolveOtomoElement ~= nil then
        element, elName, charId, source = resolveOtomoElement(otomo)
    end
    elName = elName or (ELEMENT_NAMES[element or -1] or tostring(element))

    local list = {}
    local seen = {}
    local function push(id)
        if type(id) ~= "number" then
            return
        end
        if id == 2 or id == 4 then
            return
        end
        if seen[id] then
            return
        end
        seen[id] = true
        table.insert(list, id)
    end

    log(string.format(
        "mark: filler element resolve charId=%s element=%s source=%s",
        tostring(charId),
        tostring(elName),
        tostring(source)
    ))

    local boring = tryGetBoringRangedWazaId(otomo, element)
    if boring ~= nil then
        push(boring)
        log(string.format(
            "mark: filler #1 OtomoBoringTimeWazaID → %s",
            wazaLabel(boring)
        ))
    end

    local elemental = nil
    if element ~= nil then
        elemental = ELEMENT_FILLER_WAZA[element]
    end
    if type(dac.ElementFillerByElement) == "table" and element ~= nil then
        local override = dac.ElementFillerByElement[element]
            or dac.ElementFillerByElement[elName]
        if type(override) == "number" then
            elemental = override
        end
    end
    if elemental ~= nil then
        local before = #list
        push(elemental)
        if #list > before then
            log(string.format(
                "mark: filler elemental priority element=%s → %s",
                elName,
                wazaLabel(elemental)
            ))
        end
    else
        log("mark: filler elemental unknown (element=" .. tostring(elName) .. ")")
    end

    local extras = dac.RangedWazaIds
    if type(extras) ~= "table" or #extras == 0 then
        extras = { WAZA_AIR_CANON, WAZA_ENERGY_SHOT, WAZA_POWER_BALL, WAZA_POWER_SHOT }
    end
    for _, id in ipairs(extras) do
        push(id)
    end

    return list, element, elName
end

--- One ranged filler attack, then standby.
--- Prefers the Pal's elemental common shot (e.g. Wind Cutter for Grass).
local function orderDefaultAttack(target)
    if not isDefaultAttackEnabled() then
        return false
    end
    if target == nil or not isActorAlive(target) then
        return false
    end
    if MarkStandby.fillerInFlight then
        debug("mark: filler order already in flight — ignore")
        return true
    end

    local otomo = getActiveOtomoActor()
    if otomo == nil then
        return false
    end
    local otomoOk = false
    pcall(function()
        local param = otomo.CharacterParameterComponent
        if param ~= nil and param.IsOtomo ~= nil then
            otomoOk = param:IsOtomo() == true
        end
    end)
    if not otomoOk then
        log("mark: filler aborted — active actor is not our otomo")
        return false
    end

    local dac = defaultAttackCfg()
    local t = now()
    local remain = fillerCooldownRemaining()
    if remain > 0 then
        local whole = math.ceil(remain - 0.0001)
        if whole < 1 then
            whole = 1
        end
        announce("skill_cd", "Attack cooling down: " .. tostring(whole) .. "s left")
        debug(string.format("mark: filler CD %.2fs remaining", remain))
        return true
    end
    MarkStandby.lastDefaultAttackAt = t
    MarkStandby.NoteCombat("filler-order")

    -- Tree/rock jobs block PlayActionByWazaID — always clear field work first.
    cancelOtomoFieldWork(otomo, "pre-filler")
    -- Drop game reticle lock so otomo does not free-fight via base combat AI.
    clearAimReticleForOrder("filler-order")

    local timeout = dac.ApproachTimeoutSeconds or 6.0
    local retryMs = dac.RetryIntervalMs or 250
    local afterFireMs = dac.AfterFireStandbyMs or 1000
    local useDirect = dac.UseDirectOrder == true
    local wazaList, element, elName = buildRangedWazaList(otomo, dac)

    MarkStandby.fillerInFlight = true
    MarkStandby.fillerFired = false
    MarkStandby.fillerToken = (MarkStandby.fillerToken or 0) + 1
    local token = MarkStandby.fillerToken
    MarkStandby.attackWindowUntil = t + timeout + (afterFireMs / 1000) + 0.5

    -- Leave NotCombat so PlayActionByWazaID can start. No DirectOrder (melee).
    BpBridge.SetManualStandby(false)
    requestDefaultOrder("filler-order-ranged")

    if useDirect then
        setDirectOrderTarget(target)
        local holder = getOtomoHolder()
        if holder ~= nil and holder.TryExecuteDirectAttackOrder ~= nil then
            pcall(function()
                holder:TryExecuteDirectAttackOrder()
            end)
        end
    end

    local label = MarkStandby.stickyMarkDisplayName or displayNameForTarget(target)
    local palName = palAnnounceName(otomo, "Pal")
    local tgtName = actorLabelForAnnounce(target, label)
    announce("attack", string.format("%s attack %s", tostring(palName), tostring(tgtName)))
    local labeled = {}
    for _, id in ipairs(wazaList) do
        table.insert(labeled, wazaLabel(id))
    end
    log(string.format(
        "mark: filler RANGED start pal=%s → %s element=%s priority=[%s] timeout=%.1fs",
        tostring(palName),
        tostring(tgtName),
        tostring(elName),
        table.concat(labeled, ", "),
        timeout
    ))

    local function finishOrder(reason)
        if MarkStandby.fillerToken ~= token then
            return
        end
        MarkStandby.fillerInFlight = false
        MarkStandby.fillerFired = false
        MarkStandby.onFillerOtomoDamage = nil
        MarkStandby.onFillerOtomoAction = nil
        MarkStandby.attackWindowUntil = 0
        BpBridge.SetManualStandby(true)
        MarkStandby.lastNotCombatAt = 0
        requestNotCombatOrder(reason)
        forceStandby(getActiveOtomoActor(), reason)
        log("mark: filler order end (" .. tostring(reason) .. ")")
    end

    local function consumeOneShot(reason)
        if MarkStandby.fillerToken ~= token then
            return
        end
        if MarkStandby.fillerFired then
            return
        end
        MarkStandby.fillerFired = true
        log("mark: filler ONE-SHOT consumed (" .. tostring(reason) .. ")")
        Session.Defer(afterFireMs, function()
            finishOrder("post-filler-oneshot")
        end)
    end

    -- Only trust ProcessDamage if DirectOrder is enabled; otherwise melee free-hits
    -- would steal the oneshot before a ranged PlayAction lands.
    MarkStandby.onFillerOtomoDamage = function(reason)
        if not useDirect then
            return
        end
        if not MarkStandby.fillerInFlight or MarkStandby.fillerToken ~= token then
            return
        end
        consumeOneShot(reason or "otomo-damage")
    end

    MarkStandby.onFillerOtomoAction = nil

    local loggedFail = false
    local function tryFireOnce()
        if MarkStandby.fillerToken ~= token then
            return
        end
        if not Session.IsAlive() or not MarkStandby.palOut then
            finishOrder("filler-session-dead")
            return
        end
        if MarkStandby.fillerFired then
            return
        end
        if not isActorAlive(target) then
            finishOrder("filler-target-dead")
            return
        end

        local o = getActiveOtomoActor()
        if o == nil then
            finishOrder("filler-no-otomo")
            return
        end

        -- Face / close a bit without enabling melee combat AI.
        local ctrl = getOtomoController(o)
        if ctrl ~= nil then
            pcall(function()
                if ctrl.SimpleMoveToActorWithLineTraceGround ~= nil then
                    ctrl:SimpleMoveToActorWithLineTraceGround(target)
                end
            end)
        end

        for _, wazaId in ipairs(wazaList) do
            if playFillerWaza(o, target, wazaId) then
                log(string.format(
                    "mark: PlayActionByWazaID RANGED SUCCESS %s → %s",
                    wazaLabel(wazaId),
                    tostring(label)
                ))
                consumeOneShot("PlayActionByWazaID:" .. tostring(wazaId))
                return
            end
        end

        if playShootSkillAction(o, target) then
            log("mark: PlayAction(ShootSkill) SUCCESS → " .. tostring(label))
            consumeOneShot("PlayAction:ShootSkill")
            return
        end

        if not loggedFail then
            loggedFail = true
            log("mark: elemental/ranged PlayAction not ready yet — retrying")
        end

        if (now() - t) >= timeout then
            log("mark: filler timeout — ranged PlayAction never succeeded")
            finishOrder("filler-timeout")
            return
        end

        Session.Defer(retryMs, tryFireOnce)
    end

    tryFireOnce()
    return true
end

local function skillOrderCfg()
    return cfg().SkillOrder or {}
end

local function isSkillOrderEnabled()
    if Config.Features == nil or Config.Features.AimSkillKeyProbe ~= true then
        return false
    end
    return skillOrderCfg().Enabled ~= false
end

local function skillSlotIdForKey(keyNum)
    local ids = skillOrderCfg().SlotIds or { 0, 1, 2 }
    if type(keyNum) ~= "number" then
        keyNum = tonumber(keyNum)
    end
    if type(keyNum) ~= "number" then
        return nil
    end
    return ids[keyNum]
end

local function skillOrderDebounceRemaining()
    local cd = skillOrderCfg().DebounceSeconds or 0.35
    local elapsed = now() - (MarkStandby.lastSkillOrderAt or 0)
    if elapsed >= cd then
        return 0
    end
    return cd - elapsed
end

--- EPalWazaID often arrives as userdata/enum, not a plain Lua number.
local function coerceWazaId(raw)
    if raw == nil then
        return nil
    end
    if type(raw) == "number" then
        if raw > 0 then
            return math.floor(raw)
        end
        return nil
    end
    local v = nil
    pcall(function()
        v = unwrap(raw)
    end)
    if type(v) == "number" and v > 0 then
        return math.floor(v)
    end
    pcall(function()
        if raw.get ~= nil then
            v = raw:get()
        end
    end)
    if type(v) == "number" and v > 0 then
        return math.floor(v)
    end
    local s = nil
    pcall(function()
        s = tostring(raw)
    end)
    if type(s) == "string" and s ~= "" then
        local n = tonumber(s)
        if n ~= nil and n > 0 then
            return math.floor(n)
        end
        local fromEnum = s:match("::(%d+)%s*$") or s:match("(%d+)%s*$")
        n = tonumber(fromEnum)
        if n ~= nil and n > 0 then
            return math.floor(n)
        end
        -- "EPalWazaID::WindCutter" → match known filler names (best-effort).
        local bare = s:match("::([%w_]+)%s*$") or s
        if type(bare) == "string" then
            local lower = string.lower(bare)
            for id, name in pairs(WAZA_NAMES) do
                if string.find(string.lower(name), lower, 1, true)
                    or string.find(lower, string.lower(tostring(name):match("^[^/]+") or name), 1, true)
                then
                    return id
                end
            end
        end
    end
    return nil
end

--- EPalWazaID is uint16. UE4SS EnumProperty TArray Get/ForEach often repeats slot-0.
local function u16Low(n)
    if type(n) ~= "number" then
        return nil
    end
    n = math.floor(n)
    if n < 0 then
        n = n + 4294967296
    end
    return n % 65536
end

local function listLooksDuplicated(list)
    local first = nil
    local count = 0
    for _, w in ipairs(list) do
        if type(w) == "number" and w > 0 then
            count = count + 1
            if first == nil then
                first = w
            elseif w ~= first then
                return false
            end
        end
    end
    return count > 1
end

local function readTArrayWazaListRawUint16(arr)
    local out = {}
    if arr == nil or DerefToInt32 == nil then
        return out
    end
    local n = nil
    local data = nil
    pcall(function()
        if arr.GetArrayNum ~= nil then
            n = arr:GetArrayNum()
        end
        if arr.GetArrayDataAddress ~= nil then
            data = arr:GetArrayDataAddress()
        end
    end)
    if type(n) ~= "number" or n <= 0 or type(data) ~= "number" or data == 0 then
        return out
    end
    -- Cap: pals equip at most 3 active skills.
    if n > 8 then
        n = 8
    end
    for i = 0, n - 1 do
        local packed = nil
        pcall(function()
            packed = DerefToInt32(data + (i * 2))
        end)
        local w = u16Low(packed)
        if type(w) == "number" and w > 0 then
            table.insert(out, w)
        else
            table.insert(out, nil)
        end
    end
    return out
end

local function readTArrayWazaList(arr)
    local out = {}
    if arr == nil then
        return out
    end

    -- 1) Raw uint16 dump — only reliable path for EquipWaza under UE4SS.
    local raw = readTArrayWazaListRawUint16(arr)
    if #raw > 0 and not listLooksDuplicated(raw) then
        return raw
    end
    if #raw > 0 then
        -- Still use raw even if all same (Pal may truly have one skill twice).
        out = raw
    end

    -- 2) ForEach with elem:get() (1-based index from UE4SS).
    local fe = {}
    pcall(function()
        if arr.ForEach == nil then
            return
        end
        arr:ForEach(function(index, elem)
            local w = nil
            if elem ~= nil then
                w = coerceWazaId(elem)
                if w == nil then
                    pcall(function()
                        if elem.get ~= nil then
                            w = coerceWazaId(elem:get())
                        end
                    end)
                end
            end
            if w == nil then
                w = coerceWazaId(index)
            end
            table.insert(fe, w)
        end)
    end)
    if #fe > 0 and not listLooksDuplicated(fe) then
        return fe
    end
    if #out == 0 and #fe > 0 then
        out = fe
    end

    -- 3) 1-based __index (UE4SS TArray is 1-based).
    local n = 0
    pcall(function()
        if arr.GetArrayNum ~= nil then
            n = arr:GetArrayNum()
        elseif arr.Num ~= nil then
            n = arr:Num()
        else
            n = #arr
        end
    end)
    if type(n) == "number" and n > 0 then
        local indexed = {}
        for i = 1, n do
            local v = nil
            pcall(function()
                v = arr[i]
            end)
            table.insert(indexed, coerceWazaId(v))
        end
        if #indexed > 0 and not listLooksDuplicated(indexed) then
            return indexed
        end
        if #out == 0 then
            out = indexed
        end
    end

    return out
end

local function getOtomoIndividualParameter(otomo)
    if otomo == nil then
        return nil
    end
    local cpc = nil
    pcall(function()
        cpc = otomo.CharacterParameterComponent
    end)
    cpc = unwrap(cpc)
    if cpc ~= nil then
        local ind = nil
        pcall(function()
            if cpc.GetIndividualParameter ~= nil then
                ind = cpc:GetIndividualParameter()
            end
        end)
        if ind == nil then
            pcall(function()
                ind = cpc.IndividualParameter
            end)
        end
        ind = unwrap(ind)
        if ind ~= nil then
            return ind
        end
    end
    -- Fallback: holder handle → individual parameter (more reliable while standby).
    local holder = findOtomoHolder()
    if holder == nil then
        return nil
    end
    local ind = nil
    pcall(function()
        local handle = nil
        if holder.GetSelectedOtomoID ~= nil and holder.GetOtomoIndividualHandle ~= nil then
            local sid = holder:GetSelectedOtomoID()
            handle = holder:GetOtomoIndividualHandle(sid)
        end
        if handle == nil and holder.TryGetCurrentSelectPalActor ~= nil then
            -- keep nil
        end
        if handle ~= nil and handle.TryGetIndividualParameter ~= nil then
            ind = handle:TryGetIndividualParameter()
        end
    end)
    return unwrap(ind)
end

local function getEquipWazaList(otomo)
    local ind = getOtomoIndividualParameter(otomo)
    if ind == nil then
        return {}
    end
    -- SaveParameter.EquipWaza is the party UI source of truth.
    local out = {}
    pcall(function()
        local save = ind.SaveParameter
        if save == nil and ind.GetSaveParameter ~= nil then
            save = ind:GetSaveParameter()
        end
        if save ~= nil then
            out = readTArrayWazaList(save.EquipWaza)
        end
    end)
    local hasAny = false
    local allSame = true
    local first = nil
    for _, w in ipairs(out) do
        if w ~= nil then
            hasAny = true
            if first == nil then
                first = w
            elseif w ~= first then
                allSame = false
            end
        end
    end
    if hasAny and not (allSame and #out > 1) then
        return out
    end
    -- Fallback / if SaveParameter looked duplicated, try GetEquipWaza().
    local list = nil
    pcall(function()
        list = ind:GetEquipWaza()
    end)
    local alt = readTArrayWazaList(list)
    if #alt > 0 then
        return alt
    end
    return out
end

local function readSkillObjectWaza(skill)
    if skill == nil then
        return nil
    end
    local waza = nil
    pcall(function()
        waza = coerceWazaId(skill.WazaType)
    end)
    if waza == nil then
        pcall(function()
            if skill.GetWazaType ~= nil then
                waza = coerceWazaId(skill:GetWazaType())
            end
        end)
    end
    return waza
end

local function getSkillObjectFromMap(skillSlot, slotId)
    if skillSlot == nil or type(slotId) ~= "number" then
        return nil
    end
    local skill = nil
    pcall(function()
        local map = skillSlot:GetSkillMap()
        if map == nil then
            return
        end
        pcall(function()
            skill = map[slotId]
        end)
        if skill == nil then
            pcall(function()
                if map.Get ~= nil then
                    skill = map:Get(slotId)
                end
            end)
        end
        if skill == nil and map.ForEach ~= nil then
            pcall(function()
                map:ForEach(function(key, value)
                    local k = unwrap(key)
                    if type(k) ~= "number" and key ~= nil and key.get ~= nil then
                        k = key:get()
                    end
                    if k == slotId then
                        skill = unwrap(value) or value
                    end
                end)
            end)
        end
    end)
    if skill ~= nil then
        local ok = true
        pcall(function()
            if skill.IsValid ~= nil then
                ok = skill:IsValid()
            end
        end)
        if ok then
            return skill
        end
    end
    return nil
end

local function readSkillMapBySlot(skillSlot)
    local bySlot = {}
    if skillSlot == nil then
        return bySlot
    end
    -- Prefer UPalActiveSkill objects (WazaType on UObject) — not GetWazaType alone
    -- (that can also sticky-return slot 0 under bad SkillSlot sync).
    for sid = 0, 3 do
        local skill = getSkillObjectFromMap(skillSlot, sid)
        local waza = readSkillObjectWaza(skill)
        if type(waza) ~= "number" or waza <= 0 then
            pcall(function()
                waza = coerceWazaId(skillSlot:GetWazaType(sid))
            end)
        end
        if type(waza) == "number" and waza > 0 then
            bySlot[sid] = waza
        end
    end
    return bySlot
end

local function dumpEquipWazaOnce(otomo, skillSlot)
    if MarkStandby.loggedEquipWazaDump then
        return
    end
    MarkStandby.loggedEquipWazaDump = true
    log(string.format(
        "mark: EquipWaza reader DerefToInt32=%s",
        tostring(DerefToInt32 ~= nil)
    ))
    local parts = {}
    local list = getEquipWazaList(otomo)
    for i, w in ipairs(list) do
        table.insert(parts, string.format("[%d]=%s", i - 1, wazaLabel(w)))
    end
    log("mark: EquipWaza dump → " .. (table.concat(parts, ", ") ~= "" and table.concat(parts, ", ") or "(empty)")
        .. (listLooksDuplicated(list) and " [DUPLICATED?]" or ""))

    local map = readSkillMapBySlot(skillSlot)
    local mapParts = {}
    local mapVals = {}
    for sid, waza in pairs(map) do
        table.insert(mapParts, string.format("slot=%s waza=%s", tostring(sid), wazaLabel(waza)))
        table.insert(mapVals, waza)
    end
    table.sort(mapParts)
    if skillSlot == nil then
        log("mark: SkillSlot missing on otomo controller")
    else
        log("mark: SkillMap dump → " .. (table.concat(mapParts, ", ") ~= "" and table.concat(mapParts, ", ") or "(empty)")
            .. (listLooksDuplicated(mapVals) and " [DUPLICATED?]" or ""))
        for sid = 0, 2 do
            local finished = nil
            pcall(function()
                finished = skillSlot:IsCoolTimeFinish(sid)
            end)
            log(string.format(
                "mark: CD probe slot=%s IsCoolTimeFinish=%s (%s)",
                tostring(sid),
                tostring(finished),
                type(finished)
            ))
        end
    end
end

local function readEquipWazaAtIndex(otomo, index0)
    local list = getEquipWazaList(otomo)
    if type(index0) ~= "number" then
        return nil
    end
    local w = list[index0 + 1]
    if type(w) == "number" and w > 0 then
        return w
    end
    return nil
end

--- Only treat as cooling when evidence is explicit.
--- Prefer local cast clock — IsCoolTimeFinish is unreliable while NotCombat.
local function isLocalSkillSlotCooling(slotId)
    if type(slotId) ~= "number" then
        return false
    end
    local untilT = MarkStandby.skillSlotCdUntil[slotId]
    return type(untilT) == "number" and now() < untilT
end

local function markSkillSlotOnCooldown(slotId, skillSlot, seconds)
    if type(slotId) ~= "number" then
        return
    end
    local dur = seconds
    if type(dur) ~= "number" or dur < 0.75 then
        dur = nil
        if skillSlot ~= nil then
            pcall(function()
                if skillSlot.GetCoolTime ~= nil then
                    dur = skillSlot:GetCoolTime(slotId)
                end
            end)
            if type(dur) ~= "number" then
                dur = unwrap(dur)
            end
            if (type(dur) ~= "number" or dur < 0.75) and getSkillObjectFromMap ~= nil then
                local skill = getSkillObjectFromMap(skillSlot, slotId)
                if skill ~= nil then
                    pcall(function()
                        dur = skill.DatabaseCoolTime or skill.CoolDownTimeMax
                    end)
                    if type(dur) ~= "number" then
                        dur = unwrap(dur)
                    end
                end
            end
        end
    end
    if type(dur) ~= "number" or dur < 0.75 then
        dur = (skillOrderCfg().FallbackCooldownSeconds) or 8.0
    end
    -- Cap absurd values from bad reads.
    if dur > 120 then
        dur = (skillOrderCfg().FallbackCooldownSeconds) or 8.0
    end
    MarkStandby.skillSlotCdUntil[slotId] = now() + dur
    log(string.format(
        "mark: skill slot %s local CD %.1fs",
        tostring(slotId),
        dur
    ))
end

--- Game IsCoolTimeFinish / IsCooling are unreliable while ManualStandby/NotCombat
--- (often report every slot as cooling). Skill-order gates use LOCAL cast clock only.
local function isSkillSlotCooling(skillSlot, slotId, wazaId)
    return isLocalSkillSlotCooling(slotId)
end

local function resolveSkillWaza(otomo, slotId)
    local skillSlot = getOtomoSkillSlot(otomo)
    dumpEquipWazaOnce(otomo, skillSlot)

    local map = readSkillMapBySlot(skillSlot)
    local mapWaza = map[slotId]
    local equipList = getEquipWazaList(otomo)
    local equipWaza = nil
    if type(slotId) == "number" then
        equipWaza = equipList[slotId + 1]
    end

    local mapDup = false
    do
        local vals = {}
        for _, w in pairs(map) do
            table.insert(vals, w)
        end
        mapDup = listLooksDuplicated(vals)
    end
    local equipDup = listLooksDuplicated(equipList)

    -- Prefer the source that actually differs across slots.
    -- EquipWaza (raw uint16) = party UI order. SkillMap = runtime ActiveSkill objects.
    local waza = nil
    local src = "none"
    if type(equipWaza) == "number" and equipWaza > 0 and not equipDup then
        waza = equipWaza
        src = "equip"
    elseif type(mapWaza) == "number" and mapWaza > 0 and not mapDup then
        waza = mapWaza
        src = "skillmap"
    elseif type(equipWaza) == "number" and equipWaza > 0 then
        waza = equipWaza
        src = "equip-dup?"
    elseif type(mapWaza) == "number" and mapWaza > 0 then
        waza = mapWaza
        src = "skillmap-dup?"
    end

    if type(waza) == "number" and waza > 0 then
        -- Early resolve: local cast clock only. Game IsCoolTimeFinish is flaky in NotCombat.
        local cooling = isLocalSkillSlotCooling(slotId)
        return waza, skillSlot, cooling, map, src
    end
    return nil, skillSlot, false, map, src
end

local function getActorLocation(actor)
    if actor == nil then
        return nil
    end
    local loc = nil
    pcall(function()
        loc = actor:K2_GetActorLocation()
    end)
    return loc
end

local function distanceBetweenActors(a, b)
    local la = getActorLocation(a)
    local lb = getActorLocation(b)
    if la == nil or lb == nil then
        return nil
    end
    local dx, dy, dz = 0, 0, 0
    pcall(function()
        dx = (la.X or 0) - (lb.X or 0)
        dy = (la.Y or 0) - (lb.Y or 0)
        dz = (la.Z or 0) - (lb.Z or 0)
    end)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function lookupWazaDbMaxRange(wazaId)
    -- FindWazaForBP out-struct via Lua table is unreliable/crashy on this UE4SS build.
    -- Prefer IsNearMaxRange / InWazaMaxRange / distance fallbacks instead.
    return nil
end

--- true = in range, false = too far (announce + abort). Never nil for skill orders.
--- Do NOT use CanUse — false forever after clearing reticle/DirectOrder.
--- Ignore SkillSlot:GetMaxRange when it returns junk (~1.0).
local function skillSeemsInRange(skillSlot, slotId, otomo, target, wazaId)
    local dist = distanceBetweenActors(otomo, target)
    local closeUU = (skillOrderCfg().InRangeDistanceUU) or 2200
    local farUU = (skillOrderCfg().TooFarDistanceUU) or 4500

    local near = nil
    if skillSlot ~= nil and type(slotId) == "number" and target ~= nil then
        pcall(function()
            if skillSlot.IsNearMaxRange ~= nil then
                near = skillSlot:IsNearMaxRange(slotId, target)
            end
        end)
        if type(near) ~= "boolean" then
            near = unwrap(near)
        end
        if near == true then
            return true, dist, "IsNearMaxRange"
        end
    end

    local util = getPalUtility()
    local loc = getActorLocation(target)
    local inRange = nil
    if util ~= nil and util.InWazaMaxRange ~= nil and loc ~= nil and otomo ~= nil and wazaId ~= nil then
        pcall(function()
            inRange = util:InWazaMaxRange(otomo, wazaId, loc, 120.0)
        end)
        if type(inRange) ~= "boolean" then
            inRange = unwrap(inRange)
        end
        if inRange == true then
            return true, dist, "InWazaMaxRange"
        end
    end

    local dbMax = lookupWazaDbMaxRange(wazaId)
    if type(dbMax) == "number" and type(dist) == "number" then
        if dist <= (dbMax * 1.05) then
            return true, dist, "WazaDB.MaxRange"
        end
        return false, dist, "WazaDB.MaxRange"
    end

    local slotMax = nil
    if skillSlot ~= nil and type(slotId) == "number" then
        pcall(function()
            if skillSlot.GetMaxRange ~= nil then
                slotMax = skillSlot:GetMaxRange(slotId)
            end
        end)
        if type(slotMax) ~= "number" then
            slotMax = unwrap(slotMax)
        end
        -- GetMaxRange often returns ~1.0 under UE4SS — ignore junk.
        if type(slotMax) == "number" and slotMax >= 50 and type(dist) == "number" then
            if dist <= (slotMax * 1.05) then
                return true, dist, "GetMaxRange"
            end
            return false, dist, "GetMaxRange"
        end
    end

    if near == false or inRange == false then
        return false, dist, "flag-false"
    end
    if type(dist) == "number" and dist <= closeUU then
        return true, dist, "close-fallback"
    end
    if type(dist) == "number" and dist > farUU then
        return false, dist, "far-fallback"
    end
    -- Medium / unknown: treat as too far (no approach-then-fire).
    return false, dist, "unknown-far"
end

--- Aim+1/2/3: play equipped active skill for that slot at aim target, then standby.
local function orderSkillAttack(keyNum, target)
    if not featureOn() or not Session.IsAlive() then
        return false
    end
    if not isSkillOrderEnabled() then
        return false
    end
    if target == nil or not isActorAlive(target) then
        return false
    end
    if MarkStandby.fillerInFlight then
        debug("mark: skill order ignored — attack already in flight")
        return true
    end
    local remain = skillOrderDebounceRemaining()
    if remain > 0 then
        debug(string.format("mark: skill order debounce %.2fs", remain))
        return true
    end

    local slotId = skillSlotIdForKey(keyNum)
    if slotId == nil then
        log("mark: skill order — no SlotId mapping for key " .. tostring(keyNum))
        return false
    end

    local otomo = getActiveOtomoActor()
    if otomo == nil then
        return false
    end

    local wazaId, skillSlot, cooling, _map, wazaSrc = resolveSkillWaza(otomo, slotId)
    if wazaId == nil then
        log(string.format(
            "mark: skill order key=%s slotId=%s — empty (equip=%s)",
            tostring(keyNum),
            tostring(slotId),
            (function()
                local parts = {}
                for i, w in ipairs(getEquipWazaList(otomo)) do
                    table.insert(parts, tostring(wazaLabel(w)))
                end
                return table.concat(parts, ",")
            end)()
        ))
        return true
    end
    if cooling then
        announce("skill_cd", string.format("%s is cooling down", wazaDisplayName(wazaId)))
        log(string.format(
            "mark: skill order key=%s slotId=%s waza=%s — cooling (no Default / no free cast)",
            tostring(keyNum),
            tostring(slotId),
            wazaLabel(wazaId)
        ))
        return true
    end

    local soc = skillOrderCfg()
    local t = now()
    MarkStandby.lastSkillOrderAt = t
    MarkStandby.NoteCombat("skill-order")
    cancelOtomoFieldWork(otomo, "pre-skill-order")
    -- Drop game reticle send so otomo does not free-fight via base combat AI.
    clearAimReticleForOrder("skill-order")

    local timeout = soc.ApproachTimeoutSeconds or 8.0
    local retryMs = soc.RetryIntervalMs or 250
    local afterFireMs = soc.AfterFireStandbyMs or 1200
    local postAcceptNotCombatMs = soc.PostAcceptNotCombatMs or 400
    local prePlaySettleMs = soc.PrePlayActionSettleMs or 16
    -- Equip-resolved skills don't need SkillMap sync; long sync = free-AI cast window.
    local syncMs = soc.SkillSlotSyncMs or 50
    if wazaSrc == "equip" or wazaSrc == "equip-dup?" then
        syncMs = soc.EquipReadySyncMs or 0
    end

    MarkStandby.fillerInFlight = true
    MarkStandby.fillerFired = false
    MarkStandby.fillerToken = (MarkStandby.fillerToken or 0) + 1
    local token = MarkStandby.fillerToken
    MarkStandby.orderedWazaId = wazaId
    MarkStandby.attackWindowUntil = t + timeout + (afterFireMs / 1000) + 1.0

    -- Stay locked until the fire frame. Opening Default early lets free AI pick another skill.
    BpBridge.SetManualStandby(true)

    local targetLabel = MarkStandby.stickyMarkDisplayName or "target"
    local equipDump = {}
    for i, w in ipairs(getEquipWazaList(otomo)) do
        table.insert(equipDump, string.format("%d=%s", i - 1, wazaLabel(w)))
    end
    log(string.format(
        "mark: skill order start key=%s slotId=%s waza=%s src=%s → %s sync=%sms equip=[%s]",
        tostring(keyNum),
        tostring(slotId),
        wazaLabel(wazaId),
        tostring(wazaSrc or "?"),
        tostring(targetLabel),
        tostring(syncMs),
        table.concat(equipDump, ", ")
    ))

    local function finishOrder(reason)
        if MarkStandby.fillerToken ~= token then
            return
        end
        MarkStandby.fillerInFlight = false
        MarkStandby.fillerFired = false
        MarkStandby.onFillerOtomoDamage = nil
        MarkStandby.onFillerOtomoAction = nil
        MarkStandby.orderedWazaId = nil
        MarkStandby.attackWindowUntil = 0
        BpBridge.SetManualStandby(true)
        MarkStandby.lastNotCombatAt = 0
        requestNotCombatOrder(reason)
        forceStandby(getActiveOtomoActor(), reason)
        log("mark: skill order end (" .. tostring(reason) .. ")")
    end

    local function consumeOneShot(reason)
        if MarkStandby.fillerToken ~= token then
            return
        end
        if MarkStandby.fillerFired then
            return
        end
        MarkStandby.fillerFired = true
        markSkillSlotOnCooldown(slotId, skillSlot, nil)
        log("mark: skill order CAST confirmed (" .. tostring(reason) .. ")")
        Session.Defer(afterFireMs, function()
            finishOrder("post-skill-cast")
        end)
    end

    --- Lock AI immediately after PlayAction — any Default window lets free AI cast other skills.
    local function lockAiAfterAccept()
        if MarkStandby.fillerToken ~= token then
            return
        end
        BpBridge.SetManualStandby(true)
        clearOtomoAiCombatIntent(getActiveOtomoActor(), "post-accept")
        log("mark: skill AI locked post-accept (immediate)")
        Session.Defer(postAcceptNotCombatMs, function()
            if MarkStandby.fillerToken ~= token then
                return
            end
            if MarkStandby.fillerFired then
                return
            end
            MarkStandby.lastNotCombatAt = 0
            requestNotCombatOrder("skill-post-accept-notcombat")
            consumeOneShot("skill-post-accept-lock")
        end)
    end

    MarkStandby.onFillerOtomoDamage = function(reason)
        if not MarkStandby.fillerInFlight or MarkStandby.fillerToken ~= token then
            return
        end
        consumeOneShot(reason or "otomo-damage")
    end
    MarkStandby.onFillerOtomoAction = nil

    local actionAccepted = false
    local playAttempted = false
    local coolingAtAccept = false
    local rangeChecked = false
    local announced = false

    local function tryFireOnce()
        if MarkStandby.fillerToken ~= token then
            return
        end
        if not Session.IsAlive() or not MarkStandby.palOut then
            finishOrder("skill-session-dead")
            return
        end
        if MarkStandby.fillerFired then
            return
        end
        if not isActorAlive(target) then
            finishOrder("skill-target-dead")
            return
        end

        local o = getActiveOtomoActor()
        if o == nil then
            finishOrder("skill-no-otomo")
            return
        end

        local resolved, ss = resolveSkillWaza(o, slotId)
        if ss ~= nil then
            skillSlot = ss
        end
        if type(resolved) == "number" and resolved > 0 and resolved ~= wazaId then
            log(string.format(
                "mark: skill waza corrected %s → %s (slotId=%s)",
                wazaLabel(wazaId),
                wazaLabel(resolved),
                tostring(slotId)
            ))
            wazaId = resolved
            MarkStandby.orderedWazaId = wazaId
        end

        if actionAccepted and (not coolingAtAccept) and isSkillSlotCooling(skillSlot, slotId, wazaId) then
            consumeOneShot("skill-cd-started")
            return
        end

        -- Never reassert Default after PlayAction — that re-enables free skill AI.
        if actionAccepted or playAttempted then
            if (now() - t) >= timeout then
                if actionAccepted then
                    consumeOneShot("skill-timeout-after-accept")
                else
                    finishOrder("skill-timeout")
                end
                return
            end
            Session.Defer(retryMs, tryFireOnce)
            return
        end

        if isSkillSlotCooling(skillSlot, slotId, wazaId) then
            local left = (MarkStandby.skillSlotCdUntil[slotId] or 0) - now()
            announce("skill_cd", string.format("%s is cooling down", wazaDisplayName(wazaId)))
            log(string.format(
                "mark: skill aborted pre-fire — local CD waza=%s slotId=%s left=%.1fs",
                wazaLabel(wazaId),
                tostring(slotId),
                left
            ))
            finishOrder("skill-cooling")
            return
        end

        local inRange, dist, rangeSrc = skillSeemsInRange(skillSlot, slotId, o, target, wazaId)
        if not rangeChecked then
            rangeChecked = true
            log(string.format(
                "mark: skill range check waza=%s inRange=%s dist=%s via=%s",
                wazaLabel(wazaId),
                tostring(inRange),
                tostring(dist),
                tostring(rangeSrc)
            ))
        end
        if inRange ~= true then
            local tgtName = actorLabelForAnnounce(target, targetLabel)
            log(string.format(
                "mark: skill aborted — too far skill=%s target=%s dist=%s via=%s",
                wazaDisplayName(wazaId),
                tostring(tgtName),
                tostring(dist),
                tostring(rangeSrc)
            ))
            finishOrder("skill-too-far")
            return
        end

        -- Fire frame: open Default only long enough for PlayAction, after clearing AI intent.
        playAttempted = true
        clearOtomoAiCombatIntent(o, "pre-play")
        BpBridge.SetManualStandby(false)
        requestDefaultOrder("skill-order-fire")

        local function doPlay()
            if MarkStandby.fillerToken ~= token or MarkStandby.fillerFired then
                return
            end
            local o2 = getActiveOtomoActor()
            if o2 == nil then
                finishOrder("skill-no-otomo")
                return
            end
            if isSkillSlotCooling(skillSlot, slotId, wazaId) then
                announce("skill_cd", string.format("%s is cooling down", wazaDisplayName(wazaId)))
                finishOrder("skill-cooling")
                return
            end

            clearOtomoAiCombatIntent(o2, "pre-play-2")
            local okCall, playRet = pcall(function()
                return playFillerWaza(o2, target, wazaId)
            end)
            if okCall and playRet == true then
                actionAccepted = true
                coolingAtAccept = isSkillSlotCooling(skillSlot, slotId, wazaId)
                local palName = palAnnounceName(o2, "Pal")
                local skillName = wazaDisplayName(wazaId)
                local tgtName = actorLabelForAnnounce(target, targetLabel)
                if not announced then
                    announced = true
                    announce("skill", string.format(
                        "%s use %s on %s",
                        tostring(palName),
                        tostring(skillName),
                        tostring(tgtName)
                    ))
                end
                log(string.format(
                    "mark: PlayActionByWazaID SKILL ACCEPTED %s → %s (oneshot — no re-fire)",
                    wazaLabel(wazaId),
                    tostring(tgtName)
                ))
                markSkillSlotOnCooldown(slotId, skillSlot, nil)
                lockAiAfterAccept()
            else
                log(string.format(
                    "mark: PlayActionByWazaID failed waza=%s ok=%s ret=%s — no retry PlayAction",
                    wazaLabel(wazaId),
                    tostring(okCall),
                    tostring(playRet)
                ))
                finishOrder("skill-play-failed")
            end
        end

        if prePlaySettleMs > 0 then
            Session.Defer(prePlaySettleMs, doPlay)
        else
            doPlay()
        end
    end

    local function afterSync()
        if MarkStandby.fillerToken ~= token then
            return
        end
        local o = getActiveOtomoActor()
        if o == nil then
            finishOrder("skill-no-otomo")
            return
        end
        local resolved, ss, coolingAfterSync, _map, src = resolveSkillWaza(o, slotId)
        if ss ~= nil then
            skillSlot = ss
        end
        if type(resolved) == "number" and resolved > 0 then
            wazaId = resolved
            MarkStandby.orderedWazaId = wazaId
            log(string.format(
                "mark: skill resolved after sync key=%s slotId=%s waza=%s src=%s",
                tostring(keyNum),
                tostring(slotId),
                wazaLabel(wazaId),
                tostring(src or "?")
            ))
        end
        if coolingAfterSync or isLocalSkillSlotCooling(slotId) then
            local left = (MarkStandby.skillSlotCdUntil[slotId] or 0) - now()
            announce("skill_cd", string.format("%s is cooling down", wazaDisplayName(wazaId)))
            log(string.format(
                "mark: skill aborted after sync — local CD waza=%s left=%.1fs",
                wazaLabel(wazaId),
                left
            ))
            finishOrder("skill-cooling")
            return
        end
        tryFireOnce()
    end

    if syncMs > 0 then
        Session.Defer(syncMs, afterSync)
    else
        afterSync()
    end

    return true
end

local function disableOtomoAutoReticleCombat()
    local param = getPlayerParam()
    if param == nil then
        return
    end
    pcall(function()
        param.bIsEnableSendReticleTarget = false
    end)
    pcall(function()
        if param.SetEnableSendReticleTarget == nil then
            return
        end
        local fname = nil
        if UEHelpers ~= nil and UEHelpers.FindOrAddFName ~= nil then
            fname = UEHelpers.FindOrAddFName("TrainerCombat_NoAutoReticle")
        elseif FName ~= nil then
            fname = FName("TrainerCombat_NoAutoReticle")
        end
        if fname ~= nil then
            param:SetEnableSendReticleTarget(fname, false)
        end
    end)
    if not MarkStandby.loggedReticleDisable then
        MarkStandby.loggedReticleDisable = true
        log("mark: disabled otomo auto-reticle combat")
    end
end

local function isOtomoCharacter(actor)
    if actor == nil then
        return false
    end
    local param = nil
    pcall(function()
        param = actor.CharacterParameterComponent
    end)
    if param ~= nil then
        local isOtomo = false
        pcall(function()
            isOtomo = param:IsOtomo() == true
        end)
        if isOtomo then
            return true
        end
    end
    local name = objectName(actor)
    if name ~= nil then
        local lower = string.lower(name)
        if string.find(lower, "otomo", 1, true) then
            return true
        end
    end
    return false
end

local function isOurOtomoAttacker(attacker)
    if attacker == nil then
        return false
    end
    local otomo = getActiveOtomoActor()
    if otomo ~= nil then
        if actorsEqual(attacker, otomo) then
            return true
        end
        local owner = nil
        pcall(function()
            owner = attacker:GetOwner()
        end)
        if actorsEqual(owner, otomo) then
            return true
        end
        local inst = nil
        pcall(function()
            inst = attacker:GetInstigator()
        end)
        if actorsEqual(inst, otomo) then
            return true
        end
    end
    if isOtomoCharacter(attacker) then
        local player = select(1, getLocalPlayerCharacter())
        if player ~= nil and not actorsEqual(attacker, player) then
            return true
        end
    end
    return false
end

local function getContextOwner(Context)
    local self = unwrap(Context)
    if self == nil then
        return nil
    end
    local owner = nil
    pcall(function()
        if self.GetOwner ~= nil then
            owner = self:GetOwner()
        end
    end)
    if owner ~= nil and owner:IsValid() then
        return owner
    end
    return nil
end

local function toFixedPoint64(n)
    local v = math.floor(tonumber(n) or 0)
    local ok, fp = pcall(function()
        local lib = StaticFindObject("/Script/Pal.Default__FixedPoint64MathLibrary")
        if lib ~= nil and lib.Convert_IntToFixedPoint64 ~= nil then
            return lib:Convert_IntToFixedPoint64(v)
        end
        if lib ~= nil and lib.Convert_Int64ToFixedPoint64 ~= nil then
            return lib:Convert_Int64ToFixedPoint64(v)
        end
        return nil
    end)
    if ok and fp ~= nil then
        return fp
    end
    return { Value = v }
end

local function healActorHp(actor, amount)
    if actor == nil or type(amount) ~= "number" or amount <= 0 then
        return false
    end
    local param = nil
    pcall(function()
        param = actor.CharacterParameterComponent
    end)
    if param == nil or not param:IsValid() then
        return false
    end
    local fp = toFixedPoint64(amount)
    local ok = pcall(function()
        param:AddHP(fp)
    end)
    if ok then
        return true
    end
    pcall(function()
        local ind = param:GetIndividualParameter()
        if ind ~= nil then
            ind:AddHP(fp)
        end
    end)
    return true
end

local function zeroOtomoDamageInfo(info)
    if info == nil then
        return false
    end
    local before = nil
    pcall(function()
        before = info.NativeDamageValue
    end)
    pcall(function()
        info.NativeDamageValue = 0
    end)
    pcall(function()
        info.NoDamage = true
    end)
    pcall(function()
        info.bApplyNativeDamageValue = true
    end)
    local after = nil
    pcall(function()
        after = info.NativeDamageValue
    end)
    return true, before, after
end

local function shouldBlockDamage(attacker, defender)
    if not MarkStandby.ShouldBlockOtomoDamage() then
        return false
    end
    if isOurOtomoAttacker(attacker) then
        return true
    end
    if MarkStandby.HasMarkedTarget() and actorsEqual(defender, getStickyMark()) then
        local player = select(1, getLocalPlayerCharacter())
        if player ~= nil and actorsEqual(attacker, player) then
            return false
        end
        if attacker == nil or isOtomoCharacter(attacker) or isOurOtomoAttacker(attacker) then
            return true
        end
        local name = objectName(attacker)
        if name ~= nil then
            local lower = string.lower(name)
            if string.find(lower, "palcharacter", 1, true)
                or string.find(lower, "monstercharacter", 1, true)
                or string.find(lower, "bp_pal", 1, true)
            then
                return true
            end
        end
    end
    return false
end

local function tryBlockOutgoingOtomoDamage(Context, Info, label)
    if not MarkStandby.ShouldBlockOtomoDamage() then
        return
    end
    local info = unwrap(Info)
    local defender = getContextOwner(Context)
    local attacker = nil
    pcall(function()
        if info ~= nil then
            attacker = info.Attacker
        end
    end)

    if not shouldBlockDamage(attacker, defender) then
        return
    end

    local full = 0
    pcall(function()
        if info ~= nil and type(info.NativeDamageValue) == "number" then
            full = info.NativeDamageValue
        end
    end)

    local _, before, after = zeroOtomoDamageInfo(info)
    if defender ~= nil and full > 0 then
        Session.Defer(1, function()
            healActorHp(defender, full)
        end)
    end

    local t = now()
    if (t - (MarkStandby.lastDamageBlockLogAt or 0)) > 0.5 then
        MarkStandby.lastDamageBlockLogAt = t
        log(string.format(
            "mark: blocked otomo damage (%s) before=%s after=%s heal=%s",
            tostring(label),
            tostring(before),
            tostring(after),
            tostring(full)
        ))
    end
    local otomo = getActiveOtomoActor()
    forceStandby(otomo, "dmg-block-" .. tostring(label))
end

local function clearMarkAndStandby(reason)
    clearStickyMark(reason)
    MarkStandby.ignoreReticleUntil = now() + 0.35
    Session.Defer(1, function()
        local o = getActiveOtomoActor()
        forceStandby(o, reason)
    end)
    log("mark: cleared (" .. tostring(reason) .. ")")
end

local function adoptMark(actor, reason, displayName)
    -- Toggle: Aim+MMB the current mark again → clear and standby.
    local current = getStickyMark()
    if current ~= nil and actorsEqual(current, actor) then
        announce("mark", "Mark cleared")
        clearMarkAndStandby("toggle-" .. tostring(reason))
        return false
    end
    if not setStickyMark(actor, reason, displayName) then
        return false
    end
    local label = MarkStandby.stickyMarkDisplayName or displayName or "?"
    announce("mark", "Marked: " .. tostring(label))
    local otomo = getActiveOtomoActor()
    releaseToEngage(otomo, "mark-" .. tostring(reason), actor)
    return true
end

local function fnameToString(fname)
    if fname == nil then
        return nil
    end
    fname = unwrap(fname)
    if type(fname) == "string" then
        if fname == "" or fname == "None" then
            return nil
        end
        return fname
    end
    local ok, s = pcall(function()
        if fname.ToString ~= nil then
            return fname:ToString()
        end
        return nil
    end)
    if ok and type(s) == "string" and s ~= "" and s ~= "None" then
        return s
    end
    -- Nested FName wrappers (UE4SS)
    ok, s = pcall(function()
        if fname.get ~= nil then
            local inner = fname:get()
            if inner ~= nil and inner.ToString ~= nil then
                return inner:ToString()
            end
        end
        return nil
    end)
    if ok and type(s) == "string" and s ~= "" and s ~= "None" then
        return s
    end
    return nil
end

local function valueToString(v)
    if v == nil then
        return nil
    end
    if type(v) == "string" then
        if v == "" then
            return nil
        end
        return v
    end
    local ok, s = pcall(function()
        if v.ToString ~= nil then
            return v:ToString()
        end
        return tostring(v)
    end)
    if ok and type(s) == "string" and s ~= "" then
        return s
    end
    return nil
end

local function readOutParam(outTable, preferredKeys)
    if type(outTable) ~= "table" then
        return nil
    end
    if preferredKeys ~= nil then
        for _, key in ipairs(preferredKeys) do
            local s = valueToString(outTable[key])
            if s ~= nil then
                return s
            end
        end
    end
    for _, v in pairs(outTable) do
        local s = valueToString(v)
        if s ~= nil then
            return s
        end
    end
    return nil
end

local function getCharacterParam(actor)
    if actor == nil then
        return nil
    end
    local param = nil
    pcall(function()
        param = actor.CharacterParameterComponent
    end)
    param = unwrap(param)
    if param ~= nil then
        local ok = false
        pcall(function()
            ok = param:IsValid() == true
        end)
        if ok then
            return param
        end
    end
    return nil
end

local function getIndividualParam(actor)
    local param = getCharacterParam(actor)
    if param == nil then
        return nil
    end
    local ind = nil
    pcall(function()
        ind = param:GetIndividualParameter()
    end)
    ind = unwrap(ind)
    if ind ~= nil then
        local ok = false
        pcall(function()
            ok = ind:IsValid() == true
        end)
        if ok then
            return ind
        end
    end
    return nil
end

--- Prefer BP class (BP_LeafMomonga_C → LeafMomonga). GetCharacterID alone was
--- returning stale/wrong IDs (e.g. Deer) for every Pal.
local function characterIdFromActorClass(actor)
    local full = objectName(actor)
    if full == nil then
        return nil
    end
    -- "...BP_LeafMomonga_C_..." or ends with BP_FoxMage_C
    local id = full:match("BP_([%w]+)_C")
    if id ~= nil and id ~= "" and id ~= "Pal" then
        return id
    end
    return nil
end

local function getCharacterId(actor)
    local fromBp = characterIdFromActorClass(actor)
    local fromApi = nil
    local fromApiFName = nil

    local ind = getIndividualParam(actor)
    if ind ~= nil then
        local id = nil
        pcall(function()
            id = ind:GetCharacterID()
        end)
        fromApi = fnameToString(id)
        fromApiFName = id
        if fromApi == nil then
            pcall(function()
                local save = ind:GetSaveParameter()
                if save ~= nil then
                    id = save.CharacterID
                    if id ~= nil then
                        id = unwrap(id)
                    end
                end
            end)
            fromApi = fnameToString(id)
            fromApiFName = id
        end
    end

    if fromApi == nil then
        local param = getCharacterParam(actor)
        if param ~= nil then
            local id = nil
            pcall(function()
                if param.GetCharacterID ~= nil then
                    id = param:GetCharacterID()
                end
            end)
            fromApi = fnameToString(id)
            fromApiFName = id
        end
    end

    -- Prefer BP class when API ID is missing or obviously mismatched (case-insensitive).
    if fromBp ~= nil then
        if fromApi == nil or fromApi == "None" then
            return fromBp, nil
        end
        if string.lower(fromApi) == string.lower(fromBp) then
            -- Same id, different casing (Sheepball vs SheepBall) — keep API FName.
            return fromApi, fromApiFName
        end
        if not string.find(string.lower(fromApi), string.lower(fromBp), 1, true)
            and not string.find(string.lower(fromBp), string.lower(fromApi), 1, true)
        then
            debug(string.format(
                "mark: CharacterID mismatch api=%s bp=%s — using BP class",
                tostring(fromApi),
                tostring(fromBp)
            ))
            return fromBp, nil
        end
    end

    if fromApi ~= nil then
        return fromApi, fromApiFName
    end
    return fromBp, nil
end

local function getCharacterDb()
    local ok, db = pcall(function()
        return FindFirstOf("PalDatabaseCharacterParameter")
    end)
    if ok and db ~= nil and db:IsValid() then
        return db
    end
    ok, db = pcall(function()
        return StaticFindObject("/Script/Pal.Default__PalDatabaseCharacterParameter")
    end)
    if ok and db ~= nil then
        return db
    end
    return nil
end

local function toCharacterIdFName(id)
    if id == nil then
        return nil
    end
    if type(id) ~= "string" then
        local un = unwrap(id)
        if type(un) ~= "string" then
            return un
        end
        id = un
    end
    if id == "" or id == "None" then
        return nil
    end
    -- Never pass a raw Lua string into UFunctions that expect FName — that can native-crash.
    local fname = nil
    pcall(function()
        if UEHelpers ~= nil and UEHelpers.FindOrAddFName ~= nil then
            fname = UEHelpers.FindOrAddFName(id)
        elseif FName ~= nil then
            fname = FName(id)
        end
    end)
    return fname
end

resolveOtomoElement = function(otomo)
    if otomo == nil then
        return nil, "?", nil, "none"
    end

    local charIdStr, charIdFName = getCharacterId(otomo)
    local actorShort = nil
    pcall(function()
        local full = objectName(otomo)
        if full ~= nil then
            actorShort = full:match("([^%.]+)$") or full
        end
    end)

    -- Build FName for DB lookup when we only have a string (BP class path).
    if charIdFName == nil and charIdStr ~= nil and charIdStr ~= "" then
        charIdFName = toCharacterIdFName(charIdStr)
    end

    -- 1) Authoritative: CharacterID → PalDatabaseCharacterParameter:GetElementType
    if charIdFName ~= nil or (charIdStr ~= nil and charIdStr ~= "") then
        local db = getCharacterDb()
        if db ~= nil and db.GetElementType ~= nil then
            local e1Out, e2Out = {}, {}
            local okCall = pcall(function()
                local key = charIdFName or toCharacterIdFName(charIdStr)
                if key ~= nil then
                    db:GetElementType(key, e1Out, e2Out)
                end
            end)
            if okCall then
                local e1 = normalizeElementType(readOutParam(e1Out, {
                    "Element1", "OutElement1", "ReturnValue", "Value"
                }))
                if e1 == nil then
                    e1 = normalizeElementType(e1Out)
                end
                if e1 == nil then
                    e1 = normalizeElementType(e1Out[1] or e1Out[0])
                end
                if e1 ~= nil then
                    local name = ELEMENT_NAMES[e1] or tostring(e1)
                    log(string.format(
                        "mark: element DB ok actor=%s charId=%s → %s",
                        tostring(actorShort),
                        tostring(charIdStr),
                        name
                    ))
                    return e1, name, charIdStr, "CharacterDB"
                end
            end
        end
    end

    -- 2) Component ElementType1 (with :get()). Avoid SetElementTypeFromDatabase — native crash risk.
    local param = getCharacterParam(otomo)
    if param ~= nil then
        local raw = nil
        pcall(function()
            raw = param.ElementType1
        end)
        local e1 = normalizeElementType(raw)
        if e1 ~= nil then
            local name = ELEMENT_NAMES[e1] or tostring(e1)
            return e1, name, charIdStr, "Component.ElementType1"
        end
    end

    -- 3) Heuristic from CharacterID / actor name (Herbil = LeafMomonga)
    local hay = string.lower(tostring(charIdStr or "") .. " " .. tostring(objectName(otomo) or ""))
    local heur = nil
    if hay:find("leaf", 1, true) or hay:find("grass", 1, true) or hay:find("plant", 1, true)
        or hay:find("flower", 1, true) or hay:find("herbil", 1, true) or hay:find("momonga", 1, true)
    then
        heur = 4 -- Leaf
    elseif hay:find("fire", 1, true) or hay:find("flame", 1, true) or hay:find("ignis", 1, true)
        or hay:find("foxparks", 1, true) or hay:find("kitsun", 1, true) or hay:find("rooby", 1, true)
    then
        heur = 2
    elseif hay:find("water", 1, true) or hay:find("aqua", 1, true) then
        heur = 3
    elseif hay:find("elec", 1, true) or hay:find("thunder", 1, true) then
        heur = 5
    elseif hay:find("ice", 1, true) or hay:find("snow", 1, true) then
        heur = 6
    elseif hay:find("earth", 1, true) or hay:find("ground", 1, true) or hay:find("sand", 1, true) then
        heur = 7
    elseif hay:find("dark", 1, true) or hay:find("ghost", 1, true) then
        heur = 8
    elseif hay:find("dragon", 1, true) then
        heur = 9
    end
    if heur ~= nil then
        local name = ELEMENT_NAMES[heur] or tostring(heur)
        return heur, name, charIdStr, "CharacterID-heuristic"
    end

    return nil, "?", charIdStr, "unresolved"
end


local function getLocalizedCharacterName(characterId)
    if characterId == nil then
        return nil
    end
    local db = getCharacterDb()
    if db == nil or db.GetLocalizedCharacterName == nil then
        return nil
    end
    local key = characterId
    if type(key) == "string" then
        key = toCharacterIdFName(key)
    else
        key = unwrap(key)
    end
    if key == nil then
        return nil
    end
    local out = {}
    local ok = pcall(function()
        db:GetLocalizedCharacterName(key, out)
    end)
    if not ok then
        return nil
    end
    return readOutParam(out, { "OutText", "outText", "OutName", "ReturnValue" })
end

--- Official in-game skill title (Ignis Blast, Sand Blast, …). Safe FText out only.
tryGetLocalizedWazaName = function(wazaId)
    if type(wazaId) ~= "number" or wazaId <= 0 then
        return nil
    end
    local worldCtx = nil
    pcall(function()
        worldCtx = select(1, getLocalPlayerCharacter())
    end)
    if worldCtx == nil then
        pcall(function()
            if UEHelpers ~= nil and UEHelpers.GetWorld ~= nil then
                worldCtx = UEHelpers.GetWorld()
            end
        end)
    end
    if worldCtx == nil then
        return nil
    end
    local util = nil
    pcall(function()
        util = StaticFindObject("/Script/Pal.Default__PalUIUtility")
    end)
    if util == nil then
        pcall(function()
            util = FindFirstOf("PalUIUtility")
        end)
    end
    if util == nil or util.GetWazaName == nil then
        return nil
    end
    local out = {}
    local ok = pcall(function()
        util:GetWazaName(worldCtx, wazaId, out)
    end)
    if not ok then
        return nil
    end
    local name = readOutParam(out, { "outName", "OutName", "OutText", "ReturnValue" })
    if type(name) ~= "string" or name == "" then
        return nil
    end
    -- Drop empty / raw enum dumps.
    if name == "None" or name:match("^EPalWazaID") then
        return nil
    end
    return name
end

getNickname = function(actor)
    local ind = getIndividualParam(actor)
    if ind ~= nil then
        local out = {}
        local ok = pcall(function()
            ind:GetNickname(out)
        end)
        if ok then
            local n = readOutParam(out, { "outName", "OutName", "Nickname", "NickName" })
            if n ~= nil then
                return n
            end
        end
        local prop = nil
        pcall(function()
            local save = ind:GetSaveParameter()
            if save ~= nil then
                prop = save.NickName
            end
        end)
        local s = valueToString(prop)
        if s ~= nil then
            return s
        end
    end

    local param = getCharacterParam(actor)
    if param ~= nil and param.GetNickname ~= nil then
        local out = {}
        local ok = pcall(function()
            param:GetNickname(out)
        end)
        if ok then
            return readOutParam(out, { "outName", "OutName", "Nickname", "NickName" })
        end
    end
    return nil
end

local function cleanBlueprintName(actor)
    local n = nil
    pcall(function()
        n = actor:GetName()
    end)
    if type(n) ~= "string" or n == "" then
        return nil
    end
    n = string.gsub(n, "^BP_", "")
    n = string.gsub(n, "_C_%d+$", "")
    n = string.gsub(n, "_C$", "")
    if n == "" then
        return nil
    end
    return n
end

displayNameForTarget = function(actor)
    if actor == nil then
        return "Unknown"
    end

    local idStr, idFName = getCharacterId(actor)
    -- Prefer real FName; convert string safely (never pass bare string into native FName APIs).
    local localized = getLocalizedCharacterName(idFName or idStr)
    if localized ~= nil then
        return localized
    end

    local nick = getNickname(actor)
    if nick ~= nil and idStr ~= nil and string.lower(nick) ~= string.lower(idStr) then
        return nick
    end
    if nick ~= nil and idStr == nil then
        return nick
    end

    if idStr ~= nil then
        return idStr
    end

    return cleanBlueprintName(actor) or "Unknown"
end

local function shortActorName(actor)
    if actor == nil then
        return nil
    end
    local n = nil
    pcall(function()
        n = actor:GetName()
    end)
    if n == nil or n == "" then
        n = objectName(actor)
    end
    return n
end

local function getLocalShooter()
    local char = select(1, getLocalPlayerCharacter())
    if char == nil then
        return nil
    end
    local shooter = nil
    pcall(function()
        shooter = char.ShooterComponent
    end)
    if shooter ~= nil and shooter:IsValid() then
        return shooter
    end
    return nil
end

local function getMarkShootFlagName()
    if MarkStandby.cachedMarkShootFlagName ~= nil then
        return MarkStandby.cachedMarkShootFlagName
    end
    local fname = nil
    pcall(function()
        if UEHelpers ~= nil and UEHelpers.FindOrAddFName ~= nil then
            fname = UEHelpers.FindOrAddFName("TrainerCombat_MarkNoShoot")
        elseif FName ~= nil then
            fname = FName("TrainerCombat_MarkNoShoot")
        end
    end)
    MarkStandby.cachedMarkShootFlagName = fname
    return fname
end

local function setMarkShootDisabled(disabled, reason)
    local shooter = getLocalShooter()
    local fname = getMarkShootFlagName()
    if shooter == nil or fname == nil then
        return false
    end
    local want = disabled == true
    local ok = pcall(function()
        shooter:SetDisableShootFlag(fname, want)
    end)
    if ok then
        MarkStandby.markShootFlagOn = want
        debug(string.format(
            "mark: shootDisabled=%s (%s)",
            tostring(want),
            tostring(reason)
        ))
    end
    return ok
end

-- Vanilla 1/2/3 (DefaultInput.ini):
--   One   → OtomoChangeDecrement
--   Two   → SphereChange
--   Three → OtomoChangeIncrement
-- UE4SS RegisterKeyBind cannot consume input. Real suppress = temporarily unbind
-- those actions on PalPlayerInput while aiming, then restore.
local AIM_SUPPRESS_ACTIONS = {
    "OtomoChangeDecrement", -- key 1
    "SphereChange",         -- key 2
    "OtomoChangeIncrement", -- key 3
}
local KEYCAT_MOUSE_KEYBOARD = 0 -- EPalKeyConfigCategory::MouseAndKeyboard

local function getAimSkillBlockFlagName()
    if MarkStandby.cachedAimSkillBlockFlagName ~= nil then
        return MarkStandby.cachedAimSkillBlockFlagName
    end
    local fname = nil
    pcall(function()
        if UEHelpers ~= nil and UEHelpers.FindOrAddFName ~= nil then
            fname = UEHelpers.FindOrAddFName("TrainerCombat_AimSkillProbe")
        elseif FName ~= nil then
            fname = FName("TrainerCombat_AimSkillProbe")
        end
    end)
    MarkStandby.cachedAimSkillBlockFlagName = fname
    return fname
end

local function aimSkillProbeEnabled()
    return Config.Features ~= nil and Config.Features.AimSkillKeyProbe == true
end

local function isPlayerAiming()
    if MarkStandby.playerAiming then
        return true
    end
    if now() < (MarkStandby.rmbAimUntil or 0) then
        return true
    end
    return false
end

local function toActionFName(actionName)
    local fname = nil
    pcall(function()
        if UEHelpers ~= nil and UEHelpers.FindOrAddFName ~= nil then
            fname = UEHelpers.FindOrAddFName(actionName)
        elseif FName ~= nil then
            fname = FName(actionName)
        end
    end)
    return fname
end

local function makeNoneFKey()
    -- Empty / unbound FKey (same shape used for IsInputKeyDown elsewhere).
    local ok, fkey = pcall(function()
        local fname = UEHelpers.FindOrAddFName("None")
        return { KeyName = fname }
    end)
    if ok then
        return fkey
    end
    return { KeyName = nil }
end

local function getPalPlayerInput()
    if not Session.IsAlive() then
        return nil
    end
    local _, pc = getLocalPlayerCharacter()
    local pi = nil
    if pc ~= nil then
        pcall(function()
            pi = pc.PlayerInput
        end)
        if pi ~= nil and pi:IsValid() then
            return pi
        end
    end
    local ok, found = pcall(function()
        return FindFirstOf("PalPlayerInput")
    end)
    if ok and found ~= nil and found:IsValid() then
        return found
    end
    return nil
end

local function copyKeyConfigKeys(cfg)
    if cfg == nil then
        return nil
    end
    local out = { MainKey = nil, SecondaryKey = nil }
    pcall(function()
        out.MainKey = cfg.MainKey
        out.SecondaryKey = cfg.SecondaryKey
    end)
    return out
end

local function restoreAimActionBindings(reason)
    if not MarkStandby.aimActionsUnbound then
        return false
    end
    local pi = getPalPlayerInput()
    local saved = MarkStandby.savedAimActionKeys or {}
    if pi == nil then
        MarkStandby.aimActionsUnbound = false
        MarkStandby.savedAimActionKeys = nil
        log("mark: aim action restore skipped — no PalPlayerInput (" .. tostring(reason) .. ")")
        return false
    end
    local okCount = 0
    for _, action in ipairs(AIM_SUPPRESS_ACTIONS) do
        local aname = toActionFName(action)
        if aname ~= nil then
            local cfg = saved[action]
            local ok = false
            if cfg ~= nil then
                ok = pcall(function()
                    pi:UpdateActionMapping(aname, cfg, KEYCAT_MOUSE_KEYBOARD)
                end)
            end
            if not ok then
                ok = pcall(function()
                    pi:ResetActionKey(aname, KEYCAT_MOUSE_KEYBOARD)
                end)
            end
            if ok then
                okCount = okCount + 1
            end
        end
    end
    MarkStandby.aimActionsUnbound = false
    MarkStandby.savedAimActionKeys = nil
    log(string.format(
        "mark: restored aim actions %d/%d (%s)",
        okCount,
        #AIM_SUPPRESS_ACTIONS,
        tostring(reason)
    ))
    return okCount > 0
end

local function unbindAimActionBindings(reason)
    if not aimSkillProbeEnabled() then
        return false
    end
    if MarkStandby.aimActionsUnbound then
        return true
    end
    local pi = getPalPlayerInput()
    if pi == nil then
        log("mark: aim action unbind skipped — no PalPlayerInput (" .. tostring(reason) .. ")")
        return false
    end
    local noneKey = makeNoneFKey()
    local emptyCfg = { MainKey = noneKey, SecondaryKey = noneKey }
    local saved = {}
    local okCount = 0
    for _, action in ipairs(AIM_SUPPRESS_ACTIONS) do
        local aname = toActionFName(action)
        if aname ~= nil then
            local cfg = nil
            pcall(function()
                cfg = pi:GetActionConfigKeys(aname, KEYCAT_MOUSE_KEYBOARD)
            end)
            saved[action] = copyKeyConfigKeys(cfg)
            local ok = pcall(function()
                pi:UpdateActionMapping(aname, emptyCfg, KEYCAT_MOUSE_KEYBOARD)
            end)
            if ok then
                okCount = okCount + 1
            end
            debug(string.format(
                "mark: unbind action=%s ok=%s (%s)",
                tostring(action),
                tostring(ok),
                tostring(reason)
            ))
        end
    end
    MarkStandby.savedAimActionKeys = saved
    MarkStandby.aimActionsUnbound = okCount > 0
    log(string.format(
        "mark: unbound aim actions %d/%d (%s)",
        okCount,
        #AIM_SUPPRESS_ACTIONS,
        tostring(reason)
    ))
    return MarkStandby.aimActionsUnbound
end

local function setAimSkillDefaultKeysBlocked(disabled, reason)
    if not aimSkillProbeEnabled() then
        return false
    end
    local want = disabled == true

    local function doApply()
        if want then
            if not isPlayerAiming() then
                return
            end
            unbindAimActionBindings(reason or "aim-block")
        else
            restoreAimActionBindings(reason or "aim-unblock")
        end

        -- Keep layered disable flags as a secondary gate (throw/swap / bullet UI).
        local fname = getAimSkillBlockFlagName()
        if fname == nil then
            return
        end
        local _, pc = getLocalPlayerCharacter()
        local shooter = getLocalShooter()
        local okSwitch, okBullet, okWeapon = false, false, false
        if pc ~= nil and pc:IsValid() then
            okSwitch = pcall(function()
                pc:SetDisableSwitchPalFlag(fname, want)
            end)
            okBullet = pcall(function()
                pc:SetDisableSelectingBulletFlag(fname, want)
            end)
        end
        if shooter ~= nil then
            okWeapon = pcall(function()
                shooter:SetDisableChangeWeaponFlag(fname, want)
            end)
        end
        MarkStandby.aimSkillKeysBlocked = want
        debug(string.format(
            "mark: aimKeysBlocked=%s switch=%s bullet=%s weapon=%s (%s)",
            tostring(want),
            tostring(okSwitch),
            tostring(okBullet),
            tostring(okWeapon),
            tostring(reason)
        ))
    end

    -- Defer like summon lock — safer outside native aim/input stacks.
    if ExecuteWithDelay ~= nil then
        ExecuteWithDelay(1, function()
            pcall(doApply)
        end)
    else
        pcall(doApply)
    end
    return true
end

local function stopPullTriggerAnime(reason)
    local shooter = getLocalShooter()
    if shooter == nil then
        return
    end
    pcall(function()
        if shooter.StopPullTriggerAnime_forBP ~= nil then
            shooter:StopPullTriggerAnime_forBP()
        end
    end)
    pcall(function()
        shooter.bIsRequestPullTrigger = false
        shooter.bIsShooting = false
        shooter.bIsHoldTrigger = false
    end)
    debug("mark: StopPullTriggerAnime (" .. tostring(reason) .. ")")
end

local function buildAimSkillHudSlots(otomo)
    local soc = (cfg().SkillOrder) or {}
    local slotIds = soc.SlotIds or { 0, 1, 2 }
    local fallbackCd = soc.FallbackCooldownSeconds or 8.0
    local slots = {}
    for i = 1, 3 do
        local sid = slotIds[i]
        if type(sid) ~= "number" then
            sid = i - 1
        end
        local wazaId = nil
        if otomo ~= nil then
            wazaId = readEquipWazaAtIndex(otomo, sid)
        end
        local enabled = type(wazaId) == "number" and wazaId > 0
        local name = enabled and wazaDisplayName(wazaId) or "—"
        local untilT = MarkStandby.skillSlotCdUntil[sid]
        local remain = 0
        if type(untilT) == "number" then
            remain = untilT - now()
            if remain < 0 then
                remain = 0
            end
        end
        local coolMax = fallbackCd
        if remain > coolMax then
            coolMax = remain
        end
        slots[i] = {
            key = i,
            slotId = sid,
            wazaId = wazaId,
            name = name,
            coolRemain = remain,
            coolMax = coolMax,
            enabled = enabled,
        }
    end
    return slots
end

local function refreshAimSkillHud(reason)
    if Config.Hud == nil or Config.Hud.UseAimSkillHud == false then
        AimSkillHud.Hide("disabled")
        return
    end
    if not isPlayerAiming() then
        AimSkillHud.Hide(reason or "not-aiming")
        return
    end
    if probePlayerMounted() or MarkStandby.IsRiding() then
        AimSkillHud.Hide(reason or "riding")
        return
    end
    if not MarkStandby.IsManualMode() then
        AimSkillHud.Hide(reason or "not-manual")
        return
    end
    local otomo = getActiveOtomoActor()
    if otomo == nil then
        AimSkillHud.Hide(reason or "no-otomo")
        return
    end
    local slots = buildAimSkillHudSlots(otomo)
    if AimSkillHud.IsVisible() then
        AimSkillHud.Update(slots, reason)
    else
        AimSkillHud.Show(slots, reason)
    end
end

local function setPlayerAiming(on, reason)
    local nextVal = on == true
    if MarkStandby.playerAiming == nextVal then
        return
    end
    MarkStandby.playerAiming = nextVal
    debug("mark: aiming=" .. tostring(nextVal) .. " (" .. tostring(reason) .. ")")
    -- Do not disable shoot / unbind 1/2/3 — Aim+LMB/skills archived.
end

local function getAimMarkCandidate()
    local player, pc = getLocalPlayerCharacter()
    local otomo = getActiveOtomoActor()
    local param = getPlayerParam()
    local actor = nil

    if param ~= nil then
        pcall(function()
            actor = resolveWeakActor(param.ReticleTargetActor)
        end)
    end

    if actor == nil and pc ~= nil then
        pcall(function()
            actor = pc.AutoAimTarget
        end)
        if actor ~= nil and (not actor:IsValid()) then
            actor = nil
        end
    end

    if actor == nil and otomo ~= nil then
        pcall(function()
            local op = otomo.CharacterParameterComponent
            if op ~= nil and op:IsValid() then
                actor = resolveWeakActor(op.ReticleTargetActor)
            end
        end)
    end

    if actor == nil or not isHostileTarget(actor, player, otomo) then
        return nil
    end
    return actor
end

local function cancelLocalPlayerAttack(weapon, reason)
    stopPullTriggerAnime(reason)
    if isPlayerAiming() then
        setMarkShootDisabled(true, "reassert-" .. tostring(reason))
    end

    pcall(function()
        if weapon ~= nil and weapon:IsValid() and weapon.OnPullCancel ~= nil then
            weapon:OnPullCancel()
        end
    end)
    pcall(function()
        if weapon ~= nil and weapon:IsValid() and weapon.OnReleaseTrigger ~= nil then
            weapon:OnReleaseTrigger()
        end
    end)

    local char = select(1, getLocalPlayerCharacter())
    pcall(function()
        if char == nil or not char:IsValid() then
            return
        end
        local ac = char.ActionComponent
        if ac ~= nil and ac:IsValid() and ac.CancelAllAction ~= nil then
            ac:CancelAllAction()
        end
    end)

    Session.Defer(1, function()
        stopPullTriggerAnime(tostring(reason) .. "+1ms")
    end)

    MarkStandby.suppressPlayerAttackUntil = now() + 0.25
    log("mark: blocked player attack anim (" .. tostring(reason) .. ")")
end

local function tryAimLmbMark(weapon)
    if not featureOn() or not Session.IsAlive() then
        return false
    end
    if not isPlayerAiming() then
        return false
    end
    if not isDefaultAttackEnabled() then
        return false
    end
    -- Re-entrancy / shared filler CD (OnPullTrigger + LMB keybind can both fire).
    if MarkStandby.aimAttackBusy or MarkStandby.fillerInFlight then
        debug("mark: Aim+LMB ignored — attack busy")
        cancelLocalPlayerAttack(weapon, "Aim+LMB-busy")
        return true
    end
    local remain = fillerCooldownRemaining()
    if remain > 0 then
        local whole = math.ceil(remain - 0.0001)
        if whole < 1 then
            whole = 1
        end
        announce("skill_cd", "Attack cooling down: " .. tostring(whole) .. "s left")
        debug(string.format("mark: Aim+LMB filler CD %.2fs", remain))
        cancelLocalPlayerAttack(weapon, "Aim+LMB-cd")
        return true
    end

    local actor = getAimMarkCandidate()
    if actor == nil then
        debug("mark: Aim+LMB — no valid actor under aim")
        return false
    end

    MarkStandby.lastAimAttackAt = now()
    MarkStandby.aimAttackBusy = true
    cancelLocalPlayerAttack(weapon, "Aim+LMB-filler-attack")

    local okOrder, errOrder = pcall(function()
        -- Soft-track target for logs; attack does not require a prior mark.
        local name = displayNameForTarget(actor)
        MarkStandby.stickyMark = actor
        MarkStandby.stickyMarkName = objectName(actor)
        MarkStandby.stickyMarkDisplayName = name

        log(string.format(
            "mark: Aim+LMB filler → %s (actor=%s)",
            tostring(name),
            tostring(shortActorName(actor))
        ))
        orderDefaultAttack(actor)
    end)
    MarkStandby.aimAttackBusy = false
    if not okOrder then
        log("mark: Aim+LMB filler error — " .. tostring(errOrder))
    end
    return true
end

local function tryAimSkillOrder(keyNum)
    if not featureOn() or not Session.IsAlive() then
        return false
    end
    if not isPlayerAiming() then
        return false
    end
    if not isSkillOrderEnabled() then
        return false
    end
    if not MarkStandby.IsManualMode() then
        return false
    end
    if MarkStandby.aimAttackBusy or MarkStandby.fillerInFlight then
        -- Debounce: key-repeat while order is in flight flooded the console.
        if (now() - (MarkStandby.lastSkillBusyLogAt or 0)) > 1.0 then
            MarkStandby.lastSkillBusyLogAt = now()
            debug("mark: Aim+skill ignored — order already in flight")
        end
        return true
    end

    local actor = getAimMarkCandidate()
    if actor == nil then
        debug("mark: Aim+skill — no valid actor under aim")
        return false
    end

    MarkStandby.aimAttackBusy = true
    local okOrder, errOrder = pcall(function()
        local name = displayNameForTarget(actor)
        MarkStandby.stickyMark = actor
        MarkStandby.stickyMarkName = objectName(actor)
        MarkStandby.stickyMarkDisplayName = name
        log(string.format(
            "mark: Aim+skill key=%s → %s (actor=%s)",
            tostring(keyNum),
            tostring(name),
            tostring(shortActorName(actor))
        ))
        orderSkillAttack(keyNum, actor)
    end)
    MarkStandby.aimAttackBusy = false
    if not okOrder then
        log("mark: Aim+skill error — " .. tostring(errOrder))
    end
    return true
end

local function onReticleTargetSet(Context, Actor)
    if not featureOn() or not Session.IsAlive() then
        return
    end
    if not MarkStandby.IsManualMode() then
        return
    end
    if now() < (MarkStandby.ignoreReticleUntil or 0) then
        return
    end
    -- Base-game Aim+MMB path: only adopt while aiming.
    if not isPlayerAiming() then
        return
    end

    local comp = unwrap(Context)
    local player = select(1, getLocalPlayerCharacter())
    local otomo = getActiveOtomoActor()
    local isOurs = false
    pcall(function()
        if player ~= nil and player.CharacterParameterComponent ~= nil and comp ~= nil then
            isOurs = player.CharacterParameterComponent:GetFullName() == comp:GetFullName()
        end
    end)
    if not isOurs and otomo ~= nil then
        pcall(function()
            local op = otomo.CharacterParameterComponent
            if op ~= nil and comp ~= nil then
                isOurs = op:GetFullName() == comp:GetFullName()
            end
        end)
    end
    if not isOurs then
        return
    end

    local actor = unwrap(Actor)
    if actor == nil or not isHostileTarget(actor, player, otomo) then
        return
    end

    local name = displayNameForTarget(actor)
    adoptMark(actor, "MMB", name)
end

local function startStandbyLoop()
    if MarkStandby.standbyLoopStarted or LoopAsync == nil then
        return
    end
    MarkStandby.standbyLoopStarted = true
    -- LogicMod timer owns hard enforcement; Lua poll is a light reassert only.
    local interval = cfg().StandbyIntervalMs or 350

    LoopAsync(interval, function()
        if not Session.IsAlive() or not featureOn() then
            return false
        end

        -- GetOff hooks are flaky; poll mount state every tick.
        syncRideStateFromProbe("standby-loop")

        if not MarkStandby.IsManualMode() then
            return false
        end

        local otomo = getActiveOtomoActor()
        if otomo == nil then
            -- While riding, holder often reports no otomo — do NOT clear palOut.
            if probePlayerMounted() then
                return false
            end
            MarkStandby.palOut = false
            return false
        end
        MarkStandby.palOut = true

        if probePlayerMounted() then
            return false
        end

        -- Marked target died / despawned → back to standby.
        if MarkStandby.stickyMark ~= nil and getStickyMark() == nil then
            clearMarkAndStandby("target-lost")
            return false
        end

        -- Marked = engage: do not yank Pal back to NotCombat.
        if MarkStandby.HasMarkedTarget() then
            if MarkStandby.ShouldSuppressOtomoWork() then
                suppressOtomoWork(otomo, "engage-loop-combat")
            end
            return false
        end

        -- Unmarked standby.
        disableOtomoAutoReticleCombat()
        if MarkStandby.ShouldSuppressOtomoWork() then
            suppressOtomoWork(otomo, "standby-loop-combat")
        end
        local reason
        if MarkStandby.IsPlayerInCombat() then
            reason = "follow-combat"
        else
            reason = "follow-unmarked"
        end
        forceStandby(otomo, reason)
        return false
    end)
end

function MarkStandby.OnPalActivated(slot)
    if not featureOn() then
        return
    end
    MarkStandby.palOut = true
    MarkStandby.activeSlot = slot
    -- Keep sticky Aim+MMB mark across switches so combat lock + engage survive.
    disableOtomoAutoReticleCombat()

    local otomo = getActiveOtomoActor()
    local marked = getStickyMark()
    local armed
    if marked ~= nil then
        armed = BpBridge.SetManualStandby(false)
        releaseToEngage(otomo, "ActivateOtomo-keep-mark", marked)
    else
        armed = BpBridge.SetManualStandby(true)
        forceStandby(otomo, "ActivateOtomo")
    end

    local charId = nil
    pcall(function()
        charId = select(1, getCharacterId(otomo))
    end)
    log(string.format(
        "mark: Pal out slot=%s actor=%s charId=%s marked=%s",
        tostring(slot),
        tostring(shortActorName(otomo)),
        tostring(charId),
        tostring(marked ~= nil)
    ))

    if marked == nil then
        Session.Defer(200, disableOtomoAutoReticleCombat)
        Session.Defer(800, function()
            disableOtomoAutoReticleCombat()
            BpBridge.SetManualStandby(true)
            forceStandby(getActiveOtomoActor(), "ActivateOtomo+800ms")
        end)
    end

    MarkStandby.loggedEquipWazaDump = false
    MarkStandby.skillSlotCdUntil = {}

    if marked ~= nil then
        log("mark: Pal out — keep mark engage (slot=" .. tostring(slot) .. ")")
    elseif armed then
        log("mark: Pal out — LogicMod standby (slot=" .. tostring(slot) .. ")")
    else
        log("mark: Pal out — Lua NotCombat fallback (slot=" .. tostring(slot) .. ")")
    end
end

local function clearInFlightAttackState()
    MarkStandby.attackWindowUntil = 0
    MarkStandby.fillerInFlight = false
    MarkStandby.fillerFired = false
    MarkStandby.aimAttackBusy = false
    MarkStandby.onFillerOtomoDamage = nil
    MarkStandby.onFillerOtomoAction = nil
    MarkStandby.fillerToken = (MarkStandby.fillerToken or 0) + 1
    MarkStandby.loggedEquipWazaDump = false
    MarkStandby.skillSlotCdUntil = {}
    MarkStandby.ignoreReticleUntil = 0
    MarkStandby.playerAiming = false
    MarkStandby.rmbAimUntil = 0
    setMarkShootDisabled(false, "suspend")
    setAimSkillDefaultKeysBlocked(false, "suspend")
end

function MarkStandby.OnPalRecalled(reason)
    -- Ride mount often fires ClientRestart mid-teardown; probe fails → must soft-suspend.
    if reason == "ClientRestart" then
        MarkStandby.pendingTrainerRestore =
            MarkStandby.palOut == true
            or MarkStandby.riding == true
            or MarkStandby.pendingTrainerRestore == true
        clearInFlightAttackState()
        clearStickyMark("ClientRestart")
        AimSkillHud.Hide("ClientRestart")
        log("mark: OnPalRecalled soft (ClientRestart) pendingRestore="
            .. tostring(MarkStandby.pendingTrainerRestore))
        return
    end
    -- Ride mount/dismount can fire inactivate paths — never treat that as a real recall.
    if MarkStandby.IsRiding() or reason == "ride" or reason == "Ride" then
        log("mark: OnPalRecalled ignored while riding (" .. tostring(reason) .. ")")
        return
    end
    -- Pal swap fires Inactivate then Activate — keep sticky mark for the next Pal.
    if reason == "InactivateCurrentOtomo" then
        MarkStandby.palOut = false
        MarkStandby.activeSlot = nil
        log("mark: OnPalRecalled soft (InactivateCurrentOtomo) — keep mark="
            .. tostring(MarkStandby.HasMarkedTarget()))
        return
    end
    MarkStandby.palOut = false
    MarkStandby.activeSlot = nil
    MarkStandby.riding = false
    MarkStandby.pendingTrainerRestore = false
    BpBridge.SetManualStandby(false)
    requestDefaultOrder(reason or "recall")
    clearStickyMark(reason or "recall")
    AimSkillHud.Hide(reason or "recall")
end

--- Re-apply trainer standby after dismount / ClientRestart resume.
function MarkStandby.RestoreTrainerStandby(reason)
    if not featureOn() then
        return
    end
    if probePlayerMounted() then
        MarkStandby.riding = true
        MarkStandby.pendingTrainerRestore = true
        return
    end
    MarkStandby.riding = false
    MarkStandby.palOut = true
    MarkStandby.pendingTrainerRestore = false
    local t = now()
    local quiet = (t - (MarkStandby.lastRideRestoreAt or 0)) < 1.5
    MarkStandby.lastRideRestoreAt = t
    local why = reason or "restore"
    if not quiet then
        log("mark: restoring trainer standby (" .. tostring(why) .. ")")
    else
        debug("mark: restore reassert (" .. tostring(why) .. ")")
    end
    -- Combat dismount / ClientRestart often leaves Default AI — force NotCombat hard.
    disableOtomoAutoReticleCombat()
    BpBridge.SetManualStandby(true)
    MarkStandby.lastNotCombatAt = 0
    requestNotCombatOrder(why)
    forceStandby(getActiveOtomoActor(), why)
    Session.Defer(100, function()
        if probePlayerMounted() then
            return
        end
        BpBridge.SetManualStandby(true)
        MarkStandby.lastNotCombatAt = 0
        requestNotCombatOrder(tostring(why) .. "+100ms")
        forceStandby(getActiveOtomoActor(), tostring(why) .. "+100ms")
    end)
    Session.Defer(400, function()
        if probePlayerMounted() then
            return
        end
        disableOtomoAutoReticleCombat()
        BpBridge.SetManualStandby(true)
        MarkStandby.lastNotCombatAt = 0
        requestNotCombatOrder(tostring(why) .. "+400ms")
        forceStandby(getActiveOtomoActor(), tostring(why) .. "+400ms")
    end)
    Session.Defer(900, function()
        if probePlayerMounted() then
            return
        end
        BpBridge.SetManualStandby(true)
        MarkStandby.lastNotCombatAt = 0
        requestNotCombatOrder(tostring(why) .. "+900ms")
        forceStandby(getActiveOtomoActor(), tostring(why) .. "+900ms")
    end)
    if not quiet then
        log("mark: RestoreTrainerStandby (" .. tostring(why) .. ")")
    end
end

--- Re-apply trainer standby after dismount (ride does not re-fire ActivateOtomo).
function MarkStandby.OnRideEnded(reason)
    MarkStandby.RestoreTrainerStandby(reason or "ride-end")
end

function MarkStandby.OnRideStarted(reason)
    MarkStandby.riding = true
    MarkStandby.pendingTrainerRestore = true
    if MarkStandby.palOut ~= true then
        MarkStandby.palOut = true
    end
    AimSkillHud.Hide(reason or "ride-start")
    log("mark: ride started — trainer features paused (" .. tostring(reason) .. ")")
end

function MarkStandby.OnSessionResume(reason)
    if not featureOn() then
        return
    end
    local mounted = probePlayerMounted()
    if mounted then
        MarkStandby.riding = true
        MarkStandby.pendingTrainerRestore = true
        if MarkStandby.palOut ~= true then
            MarkStandby.palOut = true
        end
        log("mark: session resume while riding — defer restore (" .. tostring(reason) .. ")")
        return
    end
    -- Dismount may have happened during suspend with no GetOff hook.
    if MarkStandby.riding == true then
        log("mark: session resume — ride ended during suspend (" .. tostring(reason) .. ")")
        MarkStandby.RestoreTrainerStandby(reason or "session-resume-dismount")
        return
    end
    if MarkStandby.pendingTrainerRestore or MarkStandby.palOut then
        MarkStandby.RestoreTrainerStandby(reason or "session-resume")
    end
end

local function syncRideStateFromProbe(reason)
    local mounted = probePlayerMounted()
    if mounted and not MarkStandby.riding then
        MarkStandby.OnRideStarted(reason or "ride-poll-on")
    elseif (not mounted) and MarkStandby.riding then
        MarkStandby.OnRideEnded(reason or "ride-poll-off")
    elseif (not mounted) and MarkStandby.pendingTrainerRestore and MarkStandby.palOut then
        -- ClientRestart cleared ride flag / missed GetOff — still need standby.
        MarkStandby.RestoreTrainerStandby(reason or "ride-poll-pending")
    end
    MarkStandby.riding = mounted
end

Session.OnSuspend(function(reason)
    clearInFlightAttackState()
    clearStickyMark("suspend")
    AimSkillHud.Hide("suspend")

    -- Ride / spawn often triggers ClientRestart. Hard-clearing here leaves Default AI
    -- forever (resume never re-arms). Soft-suspend: keep palOut/riding intent.
    if reason == "ClientRestart" then
        MarkStandby.pendingTrainerRestore =
            MarkStandby.palOut == true
            or MarkStandby.riding == true
            or MarkStandby.pendingTrainerRestore == true
        log("mark: soft suspend (ClientRestart) pendingRestore="
            .. tostring(MarkStandby.pendingTrainerRestore)
            .. " riding=" .. tostring(MarkStandby.riding)
            .. " palOut=" .. tostring(MarkStandby.palOut))
        return
    end

    MarkStandby.palOut = false
    MarkStandby.activeSlot = nil
    MarkStandby.riding = false
    MarkStandby.pendingTrainerRestore = false
    BpBridge.SetManualStandby(false)
end)

Session.OnResume(function(reason)
    MarkStandby.OnSessionResume(reason)
end)

function MarkStandby.Register()
    if MarkStandby.hooked then
        return
    end
    if not featureOn() then
        log("mark standby disabled (MarkStandby=false)")
        return
    end
    MarkStandby.hooked = true

    BpBridge.Register()

    -- Ride: pause trainer mode; GetOff: restore standby (ActivateOtomo does not re-fire).
    -- Also poll in standby loop — GetOff/Dettach hooks often miss combat dismounts.
    pcall(function()
        local function onRideBegin(_Context)
            MarkStandby.OnRideStarted("Rider.Ride")
        end
        local function onRideEnd(_Context)
            MarkStandby.riding = false
            Session.Defer(1, function()
                syncRideStateFromProbe("Rider.GetOff-hook")
            end)
            Session.Defer(50, function()
                MarkStandby.OnRideEnded("Rider.GetOff")
            end)
            Session.Defer(250, function()
                if not probePlayerMounted() then
                    MarkStandby.OnRideEnded("Rider.GetOff+250ms")
                end
            end)
        end
        RegisterHook("/Script/Pal.PalRiderComponent:Ride", onRideBegin)
        RegisterHook("/Script/Pal.PalRiderComponent:GetOff", onRideEnd)
        RegisterHook("/Script/Pal.PalRiderComponent:DettachRider", onRideEnd)
        RegisterHook("/Script/Pal.PalRiderComponent:DettachRiderNoAnimation", onRideEnd)
        RegisterHook("/Script/Pal.PalRiderComponent:DettachRider_ToALL", onRideEnd)
        RegisterHook("/Script/Pal.PalRiderComponent:DettachRiderNoAnimation_ToALL", onRideEnd)
        RegisterHook("/Script/Pal.PalRiderComponent:SetRideMarker_Internal", function(_Context, Marker)
            local m = unwrap(Marker)
            if m == nil then
                onRideEnd(_Context)
            else
                -- Marker set can be mount OR update; probe after a tick.
                Session.Defer(1, function()
                    syncRideStateFromProbe("SetRideMarker_Internal")
                end)
            end
        end)
        log("mark: hooked PalRiderComponent Ride/GetOff (+ poll fallback)")
    end)

    pcall(function()
        RegisterHook(
            "/Script/Pal.PalCharacterParameterComponent:SetReticleTarget_ToServer",
            onReticleTargetSet
        )
        RegisterHook(
            "/Script/Pal.PalCharacterParameterComponent:SetReticleTarget",
            onReticleTargetSet
        )
        log("mark: hooked SetReticleTarget (Aim+MMB mark → engage)")
    end)

    pcall(function()
        RegisterHook("/Script/Pal.PalPlayerController:OnStartAim", function()
            setPlayerAiming(true, "PC.OnStartAim")
        end)
        RegisterHook("/Script/Pal.PalPlayerController:OnEndAim", function()
            setPlayerAiming(false, "PC.OnEndAim")
        end)
        log("mark: hooked PalPlayerController OnStartAim/OnEndAim")
    end)
    pcall(function()
        RegisterHook("/Script/Pal.PalWeaponBase:OnStartAim", function()
            setPlayerAiming(true, "Weapon.OnStartAim")
        end)
        RegisterHook("/Script/Pal.PalWeaponBase:OnEndAim", function()
            setPlayerAiming(false, "Weapon.OnEndAim")
        end)
        log("mark: hooked PalWeaponBase OnStartAim/OnEndAim")
    end)

    pcall(function()
        RegisterHook("/Script/Pal.PalPlayerCharacter:OnChangePlayerBattleMode", function(_Context, IsBattle)
            local battle = unwrap(IsBattle)
            if type(battle) ~= "boolean" then
                pcall(function()
                    if battle ~= nil and battle.get ~= nil then
                        battle = battle:get()
                    end
                end)
            end
            MarkStandby.playerBattleMode = battle == true
            debug("mark: playerBattleMode=" .. tostring(MarkStandby.playerBattleMode))
            if battle == true then
                MarkStandby.NoteCombat("battle-mode")
                Session.Defer(1, function()
                    local o = getActiveOtomoActor()
                    suppressOtomoWork(o, "battle-mode-on")
                    -- Only yank to standby when unmarked; marked = engage.
                    if o ~= nil and not MarkStandby.HasMarkedTarget() and not inAttackWindow() then
                        forceStandby(o, "battle-mode-on")
                    end
                end)
            end
        end)
        log("mark: hooked OnChangePlayerBattleMode")
    end)

    -- Block field work (deforest/mine/gather) + base-camp work while fighting.
    pcall(function()
        local function undoWorkAction(Context, reason)
            if not MarkStandby.ShouldSuppressOtomoWork() then
                return
            end
            local self = unwrap(Context)
            pcall(function()
                if self ~= nil and self.SetOtomoFollowAction ~= nil then
                    self:SetOtomoFollowAction()
                end
            end)
            suppressOtomoWork(getActiveOtomoActor(), reason)
        end
        RegisterHook(
            "/Script/Pal.PalAIActionOtomoDefault:SetOtomoBaseCampAction",
            function(Context)
                undoWorkAction(Context, "SetOtomoBaseCampAction")
            end
        )
        RegisterHook(
            "/Script/Pal.PalAIActionOtomoDefault:SetOtomoWorkAction",
            function(Context)
                undoWorkAction(Context, "SetOtomoWorkAction")
            end
        )
        RegisterHook(
            "/Script/Pal.PalAIActionOtomoDefault:SetOtomoWorkActionFixedAssign",
            function(Context)
                undoWorkAction(Context, "SetOtomoWorkActionFixedAssign")
            end,
            function(_Context)
                -- Post: assignment may already have started chopping — hard cancel.
                if MarkStandby.ShouldSuppressOtomoWork() then
                    suppressOtomoWork(getActiveOtomoActor(), "post-WorkActionFixedAssign")
                end
            end
        )
        log("mark: hooked otomo work/basecamp → cancel while in combat")
    end)

    local function hookFixAssignNearestWork(path)
        pcall(function()
            RegisterHook(
                path,
                function(_Context)
                    if MarkStandby.ShouldSuppressOtomoWork() then
                        -- Immediate cancel; deferred alone was too late for tree jobs.
                        suppressOtomoWork(getActiveOtomoActor(), "TryFixAssignNearestWork")
                        Session.Defer(1, function()
                            suppressOtomoWork(getActiveOtomoActor(), "TryFixAssignNearestWork+1ms")
                        end)
                        Session.Defer(100, function()
                            suppressOtomoWork(getActiveOtomoActor(), "TryFixAssignNearestWork+100ms")
                        end)
                    end
                end
            )
            log("mark: hooked " .. tostring(path))
        end)
    end
    hookFixAssignNearestWork("/Script/Pal.PalOtomoHolderComponentBase:TryFixAssignNearestWorkSelectedOtomo")
    hookFixAssignNearestWork(
        "/Game/Pal/Blueprint/Component/OtomoHolder/BP_OtomoPalHolderComponent.BP_OtomoPalHolderComponent_C:TryFixAssignNearestWorkSelectedOtomo"
    )

    -- Aim+LMB filler / Aim+1/2/3 skill orders removed (see archive/aim-lmb-skills).

    pcall(function()
        RegisterHook("/Script/Pal.PalActionComponent:PlayActionByType", function(Context, _ActionTarget, ActionType)
            local owner = getContextOwner(Context)

            -- Cancel field-work montages on our Pal while player is in combat.
            if MarkStandby.ShouldSuppressOtomoWork() then
                local otomo = getActiveOtomoActor()
                if otomo ~= nil and actorsEqual(owner, otomo) then
                    local typ = unwrap(ActionType)
                    if type(typ) ~= "number" then
                        pcall(function()
                            if typ ~= nil and typ.get ~= nil then
                                typ = typ:get()
                            end
                        end)
                    end
                    if type(typ) == "number" and FIELD_WORK_ACTION_TYPE[typ] then
                        Session.Defer(1, function()
                            cancelOtomoFieldWork(otomo, "PlayActionByType-work:" .. tostring(typ))
                        end)
                        return
                    end
                end
            end
        end)
        log("mark: hooked PlayActionByType (otomo field-work cancel)")
    end)

    -- Undo free combat AI only while unmarked (standby). Marked = engage → leave combat AI alone.
    pcall(function()
        RegisterHook(
            "/Script/Pal.PalAIActionOtomoDefault:SetOtomoCombatAction",
            function(Context)
                if not MarkStandby.IsManualMode() then
                    return
                end
                if MarkStandby.HasMarkedTarget() then
                    return
                end
                local self = unwrap(Context)
                pcall(function()
                    if self ~= nil and self.SetOtomoFollowAction ~= nil then
                        self:SetOtomoFollowAction()
                    end
                end)
            end,
            function(_Context)
                if not MarkStandby.IsManualMode() then
                    return
                end
                if MarkStandby.HasMarkedTarget() then
                    return
                end
                requestNotCombatOrder("post-SetOtomoCombatAction")
                forceStandby(getActiveOtomoActor(), "post-SetOtomoCombatAction")
            end
        )
        log("mark: SetOtomoCombatAction → undo free combat while unmarked")
    end)

    if not MarkStandby.damageHooked then
        MarkStandby.damageHooked = true
        local function onOtomoDamageHook(Context, Info, label)
            tryBlockOutgoingOtomoDamage(Context, Info, label)
        end
        pcall(function()
            RegisterHook("/Script/Pal.PalDamageReactionComponent:ProcessDamage_ToServer", function(Context, Info)
                onOtomoDamageHook(Context, Info, "ProcessDamage")
            end)
            log("mark: hooked ProcessDamage_ToServer (block otomo damage while standby)")
        end)
        pcall(function()
            RegisterHook("/Script/Pal.PalDamageReactionComponent:SendDamage_ToServer", function(Context, _Target, Info)
                onOtomoDamageHook(Context, Info, "SendDamage")
            end)
            log("mark: hooked SendDamage_ToServer (block otomo damage while standby)")
        end)
    end

    local function bindKey(keyObj, label, fn)
        if keyObj == nil or RegisterKeyBind == nil then
            return
        end
        pcall(function()
            RegisterKeyBind(keyObj, function()
                fn()
            end)
            log("mark: " .. tostring(label))
        end)
    end

    if RegisterKeyBind ~= nil and Key ~= nil then
        local rmb = Key.RightMouseButton or Key.RIGHT_MOUSE_BUTTON or Key.RightMouse
        if rmb ~= nil then
            bindKey(rmb, "RMB = aim pulse", function()
                MarkStandby.rmbAimUntil = now() + 0.75
                debug("mark: RMB aim pulse")
            end)
        end
    end

    startStandbyLoop()
    log("mark standby ready — LogicMod/NotCombat unmarked; Aim+MMB mark → engage")
end

return MarkStandby
